/* emit (lane B, 2026-11-22): write escape sequences to the console, for Wine tests.
 *   emit.exe [--delay <seconds>] <text>...   \e = ESC, \a = BEL, \\ = backslash; args joined.
 *   emit.exe --long-notify <bytes>           an OSC 777 notification titled "long" whose body is
 *                                            <bytes> of "&<", which XML escaping makes 4.5 times
 *                                            longer (a program's oversized body). */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char** argv) {
	int i = 1;
	if (argc > 2 && !strcmp(argv[1], "--delay")) { Sleep((DWORD)(atof(argv[2]) * 1000)); i = 3; }
	HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
	DWORD mode = 0, n;
	if (GetConsoleMode(out, &mode)) SetConsoleMode(out, mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
	if (argc == 3 && !strcmp(argv[1], "--long-notify")) {
		size_t len = (size_t)atol(argv[2]);
		char* b = malloc(len + 32);
		if (!b) return 1;
		size_t o = (size_t)sprintf(b, "\x1b]777;notify;long;");
		for (size_t k = 0; k < len; k++) b[o++] = (k % 2) ? '<' : '&';
		b[o++] = 0x1b, b[o++] = '\\';
		WriteFile(out, b, (DWORD)o, &n, NULL);
		return 0;
	}
	static char buf[4096];
	size_t o = 0;
	for (; i < argc; i++)
		for (const char* p = argv[i]; *p && o + 2 < sizeof buf; p++) {
			if (*p == '\\' && p[1] == 'e') { buf[o++] = 0x1b; p++; }
			else if (*p == '\\' && p[1] == 'a') { buf[o++] = 0x07; p++; }
			else if (*p == '\\' && p[1] == '\\') { buf[o++] = '\\'; p++; }
			else buf[o++] = *p;
		}
	WriteFile(out, buf, (DWORD)o, &n, NULL);
	return 0;
}
