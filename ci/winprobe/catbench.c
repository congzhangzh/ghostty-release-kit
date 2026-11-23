/* catbench (lane B, 2026-11-23): how fast a terminal takes a program's output.
 *
 *   catbench.exe <file> <result file>
 *
 * Writes <file> to standard output in 64 KB writes, as `cat` does, and when the last write
 * returned, the bytes and milliseconds as one line "bytes ms" into <result file>. The time is the
 * program's own: how long the terminal (its console, ConPTY, its parser and renderer) took to
 * accept the output, which is what a user waits for. Then it exits, so the terminal closes.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

int main(int argc, char** argv) {
	if (argc != 3) { fprintf(stderr, "usage: catbench.exe <file> <result file>\n"); return 2; }
	HANDLE in = CreateFileA(argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
	if (in == INVALID_HANDLE_VALUE) return 1;
	HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
	DWORD mode = 0;
	if (GetConsoleMode(out, &mode)) SetConsoleMode(out, mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
	static char buf[65536];
	LARGE_INTEGER f, t0, t1;
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&t0);
	unsigned long long total = 0;
	DWORD n, w;
	while (ReadFile(in, buf, sizeof buf, &n, NULL) && n > 0) {
		for (DWORD o = 0; o < n; o += w)
			if (!WriteFile(out, buf + o, n - o, &w, NULL) || w == 0) return 3;
		total += n;
	}
	QueryPerformanceCounter(&t1);
	CloseHandle(in);
	FILE* r = fopen(argv[2], "w");
	if (!r) return 4;
	fprintf(r, "%llu %.1f\n", total, (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / (double)f.QuadPart);
	fclose(r);
	return 0;
}
