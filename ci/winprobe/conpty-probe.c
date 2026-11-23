/* conpty-probe v4 (lane B, 2026-11-22; v4: three text-width tests (emoji ZWJ, CJK, combining), UTF-8 output; v2: detach from our console under Wine; v3: STARTF_USESTDHANDLES
 * with null handles, so the child can't inherit our std handles and uses the pseudoconsole, as Ghostty does): what a pseudoconsole does to the VT a program writes.
 *
 *   conpty-probe.exe [--dll <conpty.dll>] [--flags <n>] [--out <file>] [-- <command line>]
 *
 * Creates a pseudoconsole (the in-box one from kernel32, or ConptyCreatePseudoConsole from the
 * conpty.dll given, which starts the OpenConsole.exe beside it), runs a child in it and reads what
 * comes out of its output pipe: the bytes a terminal such as Ghostty receives.
 * With no command line the child is this exe itself in --child mode: it turns on
 * ENABLE_VIRTUAL_TERMINAL_PROCESSING and writes each test sequence between two plain-text markers.
 * For each test the probe prints PASS when the exact bytes came out between its markers, CHANGED
 * when something else did (shown escaped), DROPPED when nothing did. With a command line given
 * (e.g. -- wsl.exe printf '\033]8;;x\033\\'), it writes the escaped output only.
 * Output also goes to --out (default conpty-probe.txt). Answers to queries, which a real terminal
 * would give, are not sent: a test that waits for one shows what ConPTY does without it.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#define ENABLE_VIRTUAL_TERMINAL_PROCESSING 0x0004
#endif
#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

struct test {
	const char *name;
	const char *seq;
};

/* ESC = \033, ST = ESC \ . Each is what a modern program would write. */
static const struct test tests[] = {
	{"SGR truecolor fg", "\033[38;2;255;100;0mX\033[0m"},
	{"SGR 256-colour fg", "\033[38;5;208mX\033[0m"},
	{"SGR curly underline 4:3", "\033[4:3mX\033[0m"},
	{"SGR underline colour 58:2", "\033[4;58:2::255:0:0mX\033[0m"},
	{"OSC 0 title", "\033]0;probe title\007"},
	{"OSC 8 hyperlink", "\033]8;;https://example.com\033\\link\033]8;;\033\\"},
	{"OSC 52 clipboard set", "\033]52;c;cHJvYmU=\007"},
	{"OSC 7 cwd", "\033]7;file://host/C:/Users\033\\"},
	{"OSC 133 prompt mark", "\033]133;A\007"},
	{"OSC 9;4 progress", "\033]9;4;1;50\007"},
	{"DECSET 2026 sync output", "\033[?2026hX\033[?2026l"},
	{"DECSET 1000+1006 mouse", "\033[?1000h\033[?1006h\033[?1006l\033[?1000l"},
	{"DECSET 1003 any-motion mouse", "\033[?1003h\033[?1003l"},
	{"DECSET 2004 bracketed paste", "\033[?2004h\033[?2004l"},
	{"DECSET 1004 focus events", "\033[?1004h\033[?1004l"},
	{"kitty keyboard push/pop", "\033[>1u\033[<u"},
	{"DECSCUSR cursor bar", "\033[6 q"},
	{"kitty graphics APC", "\033_Ga=T,f=24,s=1,v=1;AAAA\033\\"},
	{"sixel DCS", "\033Pq#0;2;100;0;0#0~-\033\\"},
	{"DECSET 1049 alt screen", "\033[?1049hX\033[?1049l"},
	/* Text whose width the console must measure (UTF-8): a console that re-renders moves the
	   cursor by its own idea of the width; PSEUDOCONSOLE_GLYPH_WIDTH_* chooses that idea. */
	{"width: emoji ZWJ family", "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7X"},
	{"width: CJK", "\xe4\xb8\xad\xe6\x96\x87X"},
	{"width: combining accent", "e\xcc\x81X"},
	{"XTVERSION query", "\033[>0q"},
	{"DA1 query", "\033[c"},
};
#define NTESTS (sizeof tests / sizeof tests[0])

static int child(void)
{
	HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
	DWORD mode = 0, n;
	GetConsoleMode(out, &mode);
	SetConsoleMode(out, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
	SetConsoleOutputCP(CP_UTF8); /* the width tests are UTF-8 bytes */
	char buf[512];
	for (size_t i = 0; i < NTESTS; i++) {
		int len = snprintf(buf, sizeof buf, "<<B%02u>>%s<<E%02u>>\r\n", (unsigned)i, tests[i].seq, (unsigned)i);
		WriteFile(out, buf, (DWORD)len, &n, NULL);
		Sleep(30);
	}
	WriteFile(out, "<<DONE>>\r\n", 10, &n, NULL);
	Sleep(1500); /* let the console flush before we exit */
	return 0;
}

typedef HRESULT(WINAPI *create_fn)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
typedef void(WINAPI *close_fn)(HPCON);

static FILE *report;
static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	if (report) {
		va_start(ap, fmt);
		vfprintf(report, fmt, ap);
		va_end(ap);
	}
}

/* Printable form of bytes: ESC as \e, control chars as \xNN. */
static void escaped(const char *p, size_t n, char *dst, size_t cap)
{
	size_t o = 0;
	for (size_t i = 0; i < n && o + 5 < cap; i++) {
		unsigned char c = (unsigned char)p[i];
		if (c == 0x1b) o += snprintf(dst + o, cap - o, "\\e");
		else if (c < 0x20 || c == 0x7f) o += snprintf(dst + o, cap - o, "\\x%02x", c);
		else dst[o++] = (char)c;
	}
	dst[o] = 0;
}

int main(int argc, char **argv)
{
	const char *dll = NULL, *outpath = "conpty-probe.txt";
	DWORD flags = 0;
	char cmdline[4096] = "";
	int i;
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--child")) return child();
		else if (!strcmp(argv[i], "--dll") && i + 1 < argc) dll = argv[++i];
		else if (!strcmp(argv[i], "--flags") && i + 1 < argc) flags = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc) outpath = argv[++i];
		else if (!strcmp(argv[i], "--")) { i++; break; }
		else { fprintf(stderr, "usage: conpty-probe [--dll conpty.dll] [--flags n] [--out file] [-- command]\n"); return 2; }
	}
	int custom = i < argc;
	if (custom) {
		for (; i < argc; i++) {
			strncat(cmdline, argv[i], sizeof cmdline - strlen(cmdline) - 2);
			strcat(cmdline, " ");
		}
	} else {
		char self[MAX_PATH];
		GetModuleFileNameA(NULL, self, MAX_PATH);
		snprintf(cmdline, sizeof cmdline, "\"%s\" --child", self);
	}
	report = fopen(outpath, "wb");

	OSVERSIONINFOW v;
	memset(&v, 0, sizeof v);
	v.dwOSVersionInfoSize = sizeof v;
	typedef LONG(WINAPI * rtl_fn)(OSVERSIONINFOW *);
	rtl_fn rtl = (rtl_fn)GetProcAddress(GetModuleHandleA("ntdll.dll"), "RtlGetVersion");
	if (rtl) rtl(&v);
	int wine = GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version") != NULL;
	say("# conpty-probe v4: Windows %lu.%lu.%lu%s, console %s, flags 0x%lx\n", v.dwMajorVersion, v.dwMinorVersion,
	    v.dwBuildNumber, wine ? " (Wine)" : "", dll ? dll : "in-box (kernel32)", flags);

	/* Under Wine a child joins the parent's console when the parent has one, whatever the
	   pseudoconsole attribute says, so leave ours first (Ghostty, a GUI app, has none). Our
	   stdout from Wine is a Unix pipe or file, which stays usable. */
	if (wine) FreeConsole();

	create_fn create = NULL;
	close_fn close_pc = NULL;
	if (dll) {
		HMODULE m = LoadLibraryA(dll);
		if (!m) { say("FAIL cannot load %s (error %lu)\n", dll, GetLastError()); return 1; }
		create = (create_fn)GetProcAddress(m, "ConptyCreatePseudoConsole");
		close_pc = (close_fn)GetProcAddress(m, "ConptyClosePseudoConsole");
	} else {
		HMODULE k = GetModuleHandleA("kernel32.dll");
		create = (create_fn)GetProcAddress(k, "CreatePseudoConsole");
		close_pc = (close_fn)GetProcAddress(k, "ClosePseudoConsole");
	}
	if (!create || !close_pc) { say("FAIL no CreatePseudoConsole here\n"); return 1; }

	HANDLE in_r, in_w, out_r, out_w;
	CreatePipe(&in_r, &in_w, NULL, 0);
	CreatePipe(&out_r, &out_w, NULL, 0);
	HPCON pc;
	HRESULT hr = create((COORD){120, 40}, in_r, out_w, flags, &pc);
	if (FAILED(hr)) { say("FAIL CreatePseudoConsole: 0x%08lx\n", (unsigned long)hr); return 1; }
	CloseHandle(in_r);
	CloseHandle(out_w);

	STARTUPINFOEXA si = {0};
	si.StartupInfo.cb = sizeof si;
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES; /* null std handles: the console's, not ours */
	SIZE_T attr_size = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
	si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
	InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size);
	UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pc, sizeof pc, NULL, NULL);
	PROCESS_INFORMATION pi;
	if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi)) {
		say("FAIL CreateProcess(%s): error %lu\n", cmdline, GetLastError());
		return 1;
	}

	/* Read everything until the child is done and the console closes. A thread reads, because
	   ClosePseudoConsole waits for its output to be drained. */
	static char data[1 << 20];
	size_t len = 0;
	DWORD start = GetTickCount();
	for (;;) {
		DWORD avail = 0, got = 0;
		if (PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL) && avail) {
			if (len + avail > sizeof data) avail = (DWORD)(sizeof data - len);
			if (!avail || !ReadFile(out_r, data + len, avail, &got, NULL)) break;
			len += got;
			continue;
		}
		if (WaitForSingleObject(pi.hProcess, 50) == WAIT_OBJECT_0 && GetTickCount() - start > 500) {
			Sleep(300);
			if (PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL) && avail) continue;
			break;
		}
		if (GetTickCount() - start > 20000) { say("# timeout after 20 s\n"); break; }
	}
	close_pc(pc);
	say("# %zu bytes from the console\n", len);

	static char esc[1 << 16];
	if (custom) {
		escaped(data, len, esc, sizeof esc);
		say("%s\n", esc);
		return 0;
	}
	int pass = 0;
	for (size_t t = 0; t < NTESTS; t++) {
		char b[16], e[16];
		snprintf(b, sizeof b, "<<B%02u>>", (unsigned)t);
		snprintf(e, sizeof e, "<<E%02u>>", (unsigned)t);
		/* The data isn't NUL-terminated and may hold NULs: search with memmem-like loops. */
		const char *pb = NULL, *pe = NULL;
		for (size_t k = 0; k + strlen(b) <= len; k++)
			if (!memcmp(data + k, b, strlen(b))) { pb = data + k + strlen(b); break; }
		if (pb)
			for (const char *k = pb; k + strlen(e) <= data + len; k++)
				if (!memcmp(k, e, strlen(e))) { pe = k; break; }
		if (!pb || !pe) { say("LOST    %-28s markers not found\n", tests[t].name); continue; }
		size_t n = (size_t)(pe - pb);
		const char *want = tests[t].seq;
		if (n == strlen(want) && !memcmp(pb, want, n)) { say("PASS    %s\n", tests[t].name); pass++; continue; }
		escaped(pb, n, esc, sizeof esc);
		if (n == 0) say("DROPPED %s\n", tests[t].name);
		else say("CHANGED %-28s got: %s\n", tests[t].name, esc);
	}
	say("# %d of %zu passed through unchanged\n", pass, NTESTS);
	if (report) fclose(report);
	return 0;
}
