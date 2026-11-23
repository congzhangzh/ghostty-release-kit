/* emit: write escape sequences to the console, for Wine tests.
 *   emit.exe [--delay <seconds>] <text>...   \e = ESC, \a = BEL, \\ = backslash; args joined. */
#include <windows.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char** argv) {
	int i = 1;
	if (argc > 2 && !strcmp(argv[1], "--delay")) { Sleep((DWORD)(atof(argv[2]) * 1000)); i = 3; }
	HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
	DWORD mode = 0, n;
	if (GetConsoleMode(out, &mode)) SetConsoleMode(out, mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
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
