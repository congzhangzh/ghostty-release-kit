// sendcmd.exe <id>: post WM_SYSCOMMAND <id> (hex or decimal) to Ghostty's window (GhosttyWindow),
// as choosing an item of its window menu does.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char** argv) {
  HWND h = FindWindowW(L"GhosttyWindow", NULL);
  if (!h || argc < 2) { printf("no window\n"); return 1; }
  PostMessageW(h, WM_SYSCOMMAND, (WPARAM)strtoul(argv[1], NULL, 0), 0);
  printf("posted\n");
  return 0;
}
