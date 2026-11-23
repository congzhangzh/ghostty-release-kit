/* e2e (lane B, 2026-11-23): Ghostty for Windows end to end, through its test-control pipe.
 *
 *   e2e.exe <ghostty.exe> <out dir> [<emit.exe>]
 *
 * Starts ghostty.exe with GHOSTTY_TEST_CONTROL=1 (its log in <out>\ghostty.log), connects to
 * \\.\pipe\ghostty-<pid>.ctl (protocol 1, windows/testctl.c) and checks, step by step:
 *   hello; one window, one tab, one pane; a shell prompt; "echo e2e-ok" typed and its output
 *   read back; a new tab; a split; an OSC 9 notification and OSC 9;4 progress (written by
 *   emit.exe, as events); a resize changing the grid; closing the window.
 * Each step prints "ok   <what>" or "FAIL <what>: <why>" (also into <out>\e2e.log), and every
 * request and answer goes to <out>\e2e-wire.log. Exit 0 when all passed. The same exe runs
 * on Windows x64 and arm64 and under Wine.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *g_log, *g_wire;
static int g_fails;
static HANDLE g_pipe = INVALID_HANDLE_VALUE;
static int g_id;
static int g_pwsh = 1; /* the shell takes PowerShell's & form; found by the first notification */

static void say(const char *kind, const char *fmt, ...) {
	char msg[4096];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);
	printf("%-4s %s\n", kind, msg);
	fflush(stdout);
	if (g_log) { fprintf(g_log, "%-4s %s\n", kind, msg); fflush(g_log); }
	if (!strcmp(kind, "FAIL")) g_fails++;
}
#define OK(...) say("ok", __VA_ARGS__)
#define FAIL(...) say("FAIL", __VA_ARGS__)
#define INFO(...) say("#", __VA_ARGS__)

/* One request (a JSON object without "id": it is added) and its one-line answer, malloc'd. */
static char *ctl(const char *fmt, ...) {
	char req[8192], line[8300];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(req, sizeof req, fmt, ap);
	va_end(ap);
	snprintf(line, sizeof line, "{\"id\":%d,%s\n", ++g_id, req + 1);
	DWORD n;
	if (g_wire) { fprintf(g_wire, "> %s", line); fflush(g_wire); }
	if (!WriteFile(g_pipe, line, (DWORD)strlen(line), &n, NULL)) return NULL;
	size_t cap = 1 << 16, len = 0;
	char *buf = malloc(cap);
	for (;;) {
		char c;
		if (!ReadFile(g_pipe, &c, 1, &n, NULL) || n == 0) { free(buf); return NULL; }
		if (c == '\n') break;
		if (len + 2 > cap) { cap *= 2; buf = realloc(buf, cap); }
		buf[len++] = c;
	}
	buf[len] = 0;
	if (g_wire) { fprintf(g_wire, "< %.2000s%s\n", buf, len > 2000 ? "..." : ""); fflush(g_wire); }
	return buf;
}

static int has(const char *s, const char *needle) { return s && strstr(s, needle) != NULL; }

/* Count occurrences of needle in s. */
static int count(const char *s, const char *needle) {
	int n = 0;
	for (const char *p = s; p && (p = strstr(p, needle)); p += strlen(needle)) n++;
	return n;
}

/* The number after "key": in s (the first one), or def. */
static long num(const char *s, const char *key, long def) {
	char k[64];
	snprintf(k, sizeof k, "\"%s\":", key);
	const char *p = s ? strstr(s, k) : NULL;
	return p ? strtol(p + strlen(k), NULL, 10) : def;
}

/* The pane ids in a "list" answer, in order. */
static int panes(const char *list, int *ids, int max) {
	int n = 0;
	for (const char *p = list; p && n < max && (p = strstr(p, "\"pane\":")); p += 7) ids[n++] = atoi(p + 7);
	return n;
}

/* Poll "read" (of `pane`, or the focused one when <0) until `needle` shows up `times` times,
   up to `ms`. Returns the last text answer (malloc'd) or NULL. */
static char *wait_text(int pane, const char *needle, int times, int ms) {
	char *r = NULL;
	for (int t = 0; t < ms; t += 250) {
		free(r);
		r = pane >= 0 ? ctl("{\"cmd\":\"read\",\"pane\":%d}", pane) : ctl("{\"cmd\":\"read\"}");
		if (count(r, needle) >= times) return r;
		Sleep(250);
	}
	return r;
}

/* Poll "events" from *since until one contains all of the needles (NULL-terminated). */
static char *wait_event(long *since, int ms, ...) {
	const char *needles[8];
	int nn = 0;
	va_list ap;
	va_start(ap, ms);
	for (const char *s; nn < 8 && (s = va_arg(ap, const char *));) needles[nn++] = s;
	va_end(ap);
	for (int t = 0; t < ms; t += 250) {
		char *r = ctl("{\"cmd\":\"events\",\"since\":%ld}", *since);
		if (!r) return NULL;
		/* each event is one {...} inside "events":[...] */
		for (const char *e = strstr(r, "{\"seq\":"); e; e = strstr(e + 1, "{\"seq\":")) {
			const char *end = strstr(e + 1, "{\"seq\":");
			if (!end) end = strstr(e, "}],\"next\":");
			size_t len = end ? (size_t)(end - e) + (*end == '}' ? 1 : 0) : strlen(e);
			while (len && (e[len - 1] == ',')) len--;
			char *one = malloc(len + 1);
			memcpy(one, e, len);
			one[len] = 0;
			int all = 1;
			for (int i = 0; i < nn; i++) all &= has(one, needles[i]);
			if (all) {
				*since = num(r, "next", *since);
				free(r);
				return one;
			}
			free(one);
		}
		free(r);
		Sleep(250);
	}
	return NULL;
}

/* Type a line into pane `pane` (or the focused one when < 0): as text, then Enter as a key. */
static void type_line_in(int pane, const char *text) {
	char esc[2048], where[32] = "";
	size_t o = 0;
	for (const char *p = text; *p && o + 3 < sizeof esc; p++) {
		if (*p == '"' || *p == '\\') esc[o++] = '\\';
		esc[o++] = *p;
	}
	esc[o] = 0;
	if (pane >= 0) snprintf(where, sizeof where, ",\"pane\":%d", pane);
	free(ctl("{\"cmd\":\"text\",\"text\":\"%s\"%s}", esc, where));
	free(ctl("{\"cmd\":\"key\",\"key\":\"enter\"%s}", where));
}

/* Type a line into the focused pane: as text (a paste), then Enter as a key. */
static void type_line(const char *text) {
	char esc[2048];
	size_t o = 0;
	for (const char *p = text; *p && o + 3 < sizeof esc; p++) {
		if (*p == '"' || *p == '\\') esc[o++] = '\\';
		esc[o++] = *p;
	}
	esc[o] = 0;
	free(ctl("{\"cmd\":\"text\",\"text\":\"%s\"}", esc));
	free(ctl("{\"cmd\":\"key\",\"key\":\"enter\"}"));
}

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: e2e.exe <ghostty.exe> <out dir> [<emit.exe>]\n"); return 2; }
	const char *exe = argv[1], *out = argv[2], *emit = argc > 3 ? argv[3] : NULL;
	char path[MAX_PATH * 2];
	CreateDirectoryA(out, NULL);
	snprintf(path, sizeof path, "%s\\e2e.log", out);
	g_log = fopen(path, "w");
	snprintf(path, sizeof path, "%s\\e2e-wire.log", out);
	g_wire = fopen(path, "w");
	DWORD t0 = GetTickCount();

	/* Start Ghostty with the pipe on and its log in a file. */
	SetEnvironmentVariableA("GHOSTTY_TEST_CONTROL", "1");
	SetEnvironmentVariableA("GHOSTTY_WHATSNEW", "off");
	SetEnvironmentVariableA("GHOSTTY_LOG", "stderr");
	snprintf(path, sizeof path, "%s\\ghostty.log", out);
	SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
	HANDLE logf = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS, 0, NULL);
	STARTUPINFOA si = {sizeof si};
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdError = logf;
	si.hStdOutput = logf;
	si.hStdInput = NULL;
	PROCESS_INFORMATION pi;
	char cmd[MAX_PATH * 2];
	snprintf(cmd, sizeof cmd, "\"%s\"", exe);
	if (!CreateProcessA(exe, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
		FAIL("start %s: error %lu", exe, GetLastError());
		return 1;
	}
	INFO("ghostty.exe started, pid %lu", pi.dwProcessId);

	/* Connect to its pipe. */
	char pipe[64];
	snprintf(pipe, sizeof pipe, "\\\\.\\pipe\\ghostty-%lu.ctl", pi.dwProcessId);
	for (int t = 0; t < 30000 && g_pipe == INVALID_HANDLE_VALUE; t += 250) {
		g_pipe = CreateFileA(pipe, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
		if (g_pipe == INVALID_HANDLE_VALUE) {
			if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) break;
			Sleep(250);
		}
	}
	if (g_pipe == INVALID_HANDLE_VALUE) {
		DWORD code = 0;
		GetExitCodeProcess(pi.hProcess, &code);
		FAIL("the test pipe %s within 30 s (ghostty.exe %s)", pipe,
		     WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0 ? "exited" : "still running");
		TerminateProcess(pi.hProcess, 1);
		return 1;
	}
	OK("the test pipe after %lu ms", GetTickCount() - t0);

	char *r = ctl("{\"cmd\":\"hello\"}");
	if (has(r, "\"protocol\":1")) OK("hello: protocol 1 (%.200s)", r); else FAIL("hello: %s", r ? r : "no answer");
	free(r);

	r = ctl("{\"cmd\":\"list\"}");
	int ids[16], n = panes(r, ids, 16);
	if (count(r, "\"window\":") == 1 && n == 1) OK("one window, one pane (pane %d)", ids[0]);
	else FAIL("one window, one pane: %.500s", r ? r : "no answer");
	free(r);

	/* A prompt: the viewport shows something (pwsh: "PS ", cmd: ">"). */
	r = wait_text(-1, ">", 1, 30000);
	if (has(r, ">")) OK("a shell prompt"); else FAIL("a shell prompt within 30 s: %.300s", r ? r : "no answer");
	free(r);

	/* Type a command and read its output back: the word shows twice, on the command line and
	   as its output. */
	type_line("echo e2e-ok");
	r = wait_text(-1, "e2e-ok", 2, 15000);
	if (count(r, "e2e-ok") >= 2) OK("typed \"echo e2e-ok\", read its output back");
	else FAIL("typed \"echo e2e-ok\": no output in 15 s: %.400s", r ? r : "no answer");
	free(r);

	long since = 0;
	r = ctl("{\"cmd\":\"events\",\"since\":0}");
	since = num(r, "next", 0);
	free(r);

	/* Notification and progress, written by emit.exe in this tab. */
	if (emit) {
		char line[MAX_PATH * 2 + 64];
		snprintf(line, sizeof line, "& \"%s\" \"\\e]9;e2e note\\e\\\\\"", emit);
		/* pwsh needs & for a quoted path; cmd does not take it: try the pwsh form, then cmd's. */
		type_line(line);
		int pwsh = 1;
		char *e = wait_event(&since, 8000, "\"kind\":\"notification\"", "e2e note", NULL);
		if (!e) {
			pwsh = g_pwsh = 0;
			snprintf(line, sizeof line, "\"%s\" \"\\e]9;e2e note\\e\\\\\"", emit);
			type_line(line);
			e = wait_event(&since, 8000, "\"kind\":\"notification\"", "e2e note", NULL);
		}
		if (e) OK("OSC 9 notification as an event: %.300s", e); else FAIL("OSC 9 notification: no event in 16 s");
		if (e) INFO("the shell takes the %s form", pwsh ? "PowerShell (&)" : "cmd");
		free(e);
		snprintf(line, sizeof line, "%s\"%s\" \"\\e]9;4;1;42\\e\\\\\"", pwsh ? "& " : "", emit);
		type_line(line);
		e = wait_event(&since, 8000, "\"kind\":\"progress\"", "\"value\":42", NULL);
		if (e) OK("OSC 9;4 progress 42 as an event: %.300s", e); else FAIL("OSC 9;4 progress: no event in 8 s");
		free(e);
		r = ctl("{\"cmd\":\"list\"}");
		if (has(r, "\"progress\":{")) OK("list shows the window's progress"); else INFO("list: no progress object (%.200s)", r ? r : "");
		free(r);
		snprintf(line, sizeof line, "%s\"%s\" \"\\e]9;4;0\\e\\\\\"", pwsh ? "& " : "", emit);
		type_line(line);
		e = wait_event(&since, 8000, "\"kind\":\"progress\"", "\"state\":\"none\"", NULL);
		if (e) OK("progress removed"); else FAIL("progress removed: no event in 8 s");
		free(e);
	} else INFO("no emit.exe given: notification and progress not tried");

	/* A new tab. */
	r = ctl("{\"cmd\":\"action\",\"action\":\"new_tab\"}");
	free(r);
	Sleep(1500);
	r = ctl("{\"cmd\":\"list\"}");
	if (count(r, "\"selected\":") == 2) OK("new_tab: two tabs"); else FAIL("new_tab: %.400s", r ? r : "no answer");
	free(r);

	/* A split in it. */
	r = ctl("{\"cmd\":\"action\",\"action\":\"new_split:right\"}");
	int performed = has(r, "\"performed\":true");
	free(r);
	Sleep(1500);
	r = ctl("{\"cmd\":\"list\"}");
	n = panes(r, ids, 16);
	if (performed && n == 3) OK("new_split:right: three panes in two tabs");
	else FAIL("new_split:right (performed %d): %d panes: %.400s", performed, n, r ? r : "no answer");
	free(r);
	/* The new pane runs a shell too. */
	r = wait_text(-1, ">", 1, 20000);
	if (has(r, ">")) OK("the split's shell prompt"); else FAIL("the split's shell prompt: %.200s", r ? r : "no answer");
	free(r);

	/* A notification from the split's other pane, the one not focused: shown (macOS: only the
	   focused surface of the key window is quiet). ids[1] is the second tab's first pane. */
	if (emit && n == 3) {
		char line[MAX_PATH * 2 + 64];
		snprintf(line, sizeof line, "%s\"%s\" \"\\e]9;e2e from the other pane\\e\\\\\"", g_pwsh ? "& " : "", emit);
		type_line_in(ids[1], line);
		char *e = wait_event(&since, 10000, "\"kind\":\"notification\"", "e2e from the other pane", NULL);
		if (e && has(e, "\"shown\":true")) OK("a notification from the split's unfocused pane is shown: %.200s", e);
		else FAIL("a notification from the split's unfocused pane: %.300s", e ? e : "no event in 10 s");
		free(e);
		/* A long notification body (OSC 777), 2000 bytes of "&<": XML escaping makes it about
		   9000 characters, beyond the 4096-character buffer the first toast code had (lane A's
		   review). Shown, cut to fit, and Ghostty lives on. (The core drops an OSC over 2048
		   bytes, so a longer body never reaches the host.) */
		Sleep(1500); /* the core lets one notification through per second (Surface.zig) */
		snprintf(line, sizeof line, "%s\"%s\" --long-notify 2000", g_pwsh ? "& " : "", emit);
		type_line_in(ids[1], line);
		e = wait_event(&since, 10000, "\"kind\":\"notification\"", "\"title\":\"long\"", NULL);
		char *alive = ctl("{\"cmd\":\"hello\"}");
		if (e && has(alive, "\"ok\":true")) OK("a 2000-byte notification body of \"&<\" (OSC 777): an event, and Ghostty still answers");
		else FAIL("a 2000-byte notification body: event %s, Ghostty %s", e ? "yes" : "none in 10 s", has(alive, "\"ok\":true") ? "answers" : "does not answer");
		free(e);
		free(alive);
	}

	/* Resize: the grid follows. */
	r = ctl("{\"cmd\":\"read\"}");
	long c1 = num(r, "cols", 0), r1 = num(r, "rows", 0);
	free(r);
	free(ctl("{\"cmd\":\"window\",\"rect\":[40,40,700,450]}"));
	Sleep(1500);
	r = ctl("{\"cmd\":\"read\"}");
	long c2 = num(r, "cols", 0), r2 = num(r, "rows", 0);
	free(r);
	if (c2 && r2 && (c2 != c1 || r2 != r1)) OK("resize to 700x450: grid %ldx%ld -> %ldx%ld", c1, r1, c2, r2);
	else FAIL("resize to 700x450: grid %ldx%ld -> %ldx%ld", c1, r1, c2, r2);
	free(ctl("{\"cmd\":\"window\",\"state\":\"maximize\"}"));
	Sleep(1500);
	r = ctl("{\"cmd\":\"list\"}");
	if (has(r, "\"maximized\":true")) OK("maximize"); else FAIL("maximize: %.200s", r ? r : "no answer");
	free(r);

	/* Close: every pane's shell exits, then the process. */
	for (int i = 0; i < 6; i++) {
		r = ctl("{\"cmd\":\"list\"}");
		n = panes(r, ids, 16);
		free(r);
		if (n == 0) break;
		type_line("exit");
		Sleep(1500);
	}
	DWORD w = WaitForSingleObject(pi.hProcess, 15000);
	if (w == WAIT_OBJECT_0) OK("closing every pane ends ghostty.exe");
	else {
		FAIL("ghostty.exe still runs 15 s after every shell was told to exit");
		TerminateProcess(pi.hProcess, 1);
	}
	CloseHandle(g_pipe);
	say(g_fails ? "FAIL" : "ok", "e2e: %s in %lu s", g_fails ? "failed" : "passed", (GetTickCount() - t0) / 1000);
	return g_fails ? 1 : 0;
}
