// hittest.exe [x y ...]: for each point in the client coordinates of Ghostty's window
// (class GhosttyWindow), what its WM_NCHITTEST answers. First prints the window and client rects and whether it is zoomed (maximized) or iconic.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
static const char* name(LRESULT r) {
  switch (r) {
    case HTCLIENT: return "client"; case HTCAPTION: return "caption"; case HTTOP: return "top";
    case HTTOPLEFT: return "topleft"; case HTTOPRIGHT: return "topright"; case HTLEFT: return "left";
    case HTRIGHT: return "right"; case HTBOTTOM: return "bottom"; case HTNOWHERE: return "nowhere";
    case HTCLOSE: return "close"; case HTMAXBUTTON: return "max"; case HTMINBUTTON: return "min";
    default: return "other";
  }
}
int main(int argc, char** argv) {
  HWND h = FindWindowW(L"GhosttyWindow", NULL);
  if (!h) { printf("no window\n"); return 1; }
  RECT wr, cr; POINT o = {0, 0};
  GetWindowRect(h, &wr); GetClientRect(h, &cr); ClientToScreen(h, &o);
  printf("window %ld,%ld %ldx%ld client origin %ld,%ld %ldx%ld zoomed %d iconic %d\n", wr.left, wr.top,
         wr.right - wr.left, wr.bottom - wr.top, o.x, o.y, cr.right, cr.bottom, IsZoomed(h) ? 1 : 0, IsIconic(h) ? 1 : 0);
  for (int i = 1; i + 1 < argc; i += 2) {
    int x = atoi(argv[i]), y = atoi(argv[i + 1]);
    POINT p = {x, y}; ClientToScreen(h, &p);
    LRESULT r = SendMessageW(h, WM_NCHITTEST, 0, MAKELPARAM(p.x, p.y));
    printf("%d,%d %s\n", x, y, name(r));
  }
  return 0;
}
