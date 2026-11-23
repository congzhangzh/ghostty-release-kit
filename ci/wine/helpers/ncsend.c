// ncsend.exe <min|max|close>: post WM_NCLBUTTONDOWN then WM_NCLBUTTONUP with that hit code
// (HTMINBUTTON 8, HTMAXBUTTON 9, HTCLOSE 20) to Ghostty's window, at its top-right corner: what a
// click on Windows' caption button sends when DWM leaves it to the window. For a maximized window
// under Wine, whose X window a click cannot reach (no window manager to resize it).
#include <windows.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char** argv) {
  HWND h = FindWindowW(L"GhosttyWindow", NULL);
  if (!h || argc < 2) { printf("no window\n"); return 1; }
  WPARAM ht = !strcmp(argv[1], "min") ? HTMINBUTTON : !strcmp(argv[1], "max") ? HTMAXBUTTON : HTCLOSE;
  RECT r; GetWindowRect(h, &r);
  LPARAM lp = MAKELPARAM(r.right - 10, r.top + 10);
  PostMessageW(h, WM_NCLBUTTONDOWN, ht, lp);
  PostMessageW(h, WM_NCLBUTTONUP, ht, lp);
  printf("posted %s\n", argv[1]);
  return 0;
}
