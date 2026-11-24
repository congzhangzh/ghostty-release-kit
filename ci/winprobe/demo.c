/* demo (lane B, 2026-11-23): record Ghostty's features as scenes, for the release's GIFs.
 *
 *   demo.exe <ghostty.exe> <scenes dir> <out dir> [-- <ghostty arguments>...]
 *
 * Sets the screen to 1920x1080 when the display allows it, then plays every <scenes dir>\*.scene
 * in name order, each in a Ghostty of its own (started with GHOSTTY_TEST_CONTROL=1 and the
 * arguments after --, its window 1100x680, every other window minimized), so each starts clean. While a scene plays, a second thread grabs Ghostty's
 * window from the screen (popups over it included) about 10 times a second into
 * <out>\<scene>\f%05d.png, and <out>\<scene>\frames.txt lists each frame and how long it stayed
 * (ffmpeg's concat format, for the GIF and MP4 assembly on Linux).
 *
 * A scene is lines of:
 *   ctl <json object>        a test-control request (protocol 1; "id" is added)
 *   key <key> [mods,...]      {"cmd":"key"}, e.g. "key t ctrl,shift"
 *   text <text>               {"cmd":"text"} (as typed: a paste); "\n" in it is Enter
 *   sleep <ms>
 *   move <x> <y> [ms]         the real mouse (SendInput) to a point of the window (0..1 of its
 *                             width and height), gliding over ms
 *   drag <x1> <y1> <x2> <y2> [ms]   press at one point, glide, release at the other
 *   click <x> <y> / rclick <x> <y>    a real left / right click at a point of the window
 *   vkey <combo>              a real key press (SendInput), e.g. "alt+space", "down", "enter",
 *                             "ctrl+shift+p": for what the pipe's keys can't reach (menus, popups)
 *   vtype <text>              real typing (SendInput, Unicode): into the palette, a dialog
 *   clickrect <name>          a real click at the middle of a rect "list" names: "<name>":[x,y,w,h]
 *                             (screen coordinates), e.g. the help button, "help"
 *   menuinvoke <text>         the first window-menu item whose text contains <text> (as {"cmd":
 *                             "menu"} lists it), invoked by id: fonts and shells differ by machine
 *   capture window|corner|screen   what the frames show from now on: Ghostty's window (the
 *                             default); "corner", from the window's top-left to the screen's
 *                             bottom-right (the taskbar's tray and a toast, the window readable);
 *                             or the whole screen
 *   # ...                     a comment
 * Each request and answer goes to <out>\demo-wire.log; a request that fails stops nothing.
 */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <wincodec.h>
#include <shlwapi.h>
#include <dwmapi.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE* g_wire;
static HANDLE g_pipe = INVALID_HANDLE_VALUE;
static int g_id;
static HWND g_hwnd;
static DWORD g_pid;

static void logf_(const char* fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fflush(stdout);
}

static char* ctl_line(const char* req) { /* req: a JSON object; returns the answer line */
	char line[16384];
	snprintf(line, sizeof line, "{\"id\":%d,%s\n", ++g_id, req + 1);
	DWORD n;
	if (g_wire) fprintf(g_wire, "> %s", line);
	if (!WriteFile(g_pipe, line, (DWORD)strlen(line), &n, NULL)) return NULL;
	size_t cap = 1 << 16, len = 0;
	char* buf = malloc(cap);
	for (;;) {
		char c;
		if (!ReadFile(g_pipe, &c, 1, &n, NULL) || n == 0) { free(buf); return NULL; }
		if (c == '\n') break;
		if (len + 2 > cap) { cap *= 2; buf = realloc(buf, cap); }
		buf[len++] = c;
	}
	buf[len] = 0;
	if (g_wire) { fprintf(g_wire, "< %.8000s\n", buf); fflush(g_wire); } /* the menu's whole list */
	return buf;
}

/* ---- the window, the screen and the mouse --------------------------------- */

/* The window's visible frame. GetWindowRect includes the invisible resize border (about 7 px
   each side but the top), which is see-through: run 45298827734's frames showed a console's
   text behind it. */
static void frame_rect(RECT* r) {
	if (FAILED(DwmGetWindowAttribute(g_hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, r, sizeof *r))) GetWindowRect(g_hwnd, r);
}

/* Every other visible top-level window minimized (the runner agent's console showed its log in
   run 45298827734's whole-screen scene), named in the log; the taskbar and desktop stay. */
static BOOL CALLBACK hide_other(HWND h, LPARAM l) {
	(void)l;
	DWORD pid;
	GetWindowThreadProcessId(h, &pid);
	char cls[64] = "", title[128] = "";
	GetClassNameA(h, cls, sizeof cls);
	GetWindowTextA(h, title, sizeof title);
	if (pid == g_pid || !IsWindowVisible(h) || IsIconic(h) || !title[0]) return TRUE;
	if (!strcmp(cls, "Shell_TrayWnd") || !strcmp(cls, "Progman") || !strcmp(cls, "WorkerW") || !strcmp(cls, "Shell_SecondaryTrayWnd")) return TRUE;
	logf_("#   minimized another window: class %s\n", cls);
	ShowWindow(h, SW_FORCEMINIMIZE);
	return TRUE;
}

static BOOL CALLBACK find_win(HWND h, LPARAM l) {
	(void)l;
	DWORD pid;
	GetWindowThreadProcessId(h, &pid);
	char cls[64];
	GetClassNameA(h, cls, sizeof cls);
	if (pid == g_pid && IsWindowVisible(h) && !strcmp(cls, "GhosttyWindow")) { g_hwnd = h; return FALSE; }
	return TRUE;
}

static void screen_1080p(void) {
	DEVMODEW dm = {0};
	dm.dmSize = sizeof dm;
	dm.dmPelsWidth = 1920;
	dm.dmPelsHeight = 1080;
	dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
	LONG r = ChangeDisplaySettingsW(&dm, CDS_FULLSCREEN);
	logf_("# screen 1920x1080: %s (%ld); now %dx%d\n", r == DISP_CHANGE_SUCCESSFUL ? "set" : "not set", r,
	      GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
}

static void mouse_at(int x, int y, DWORD flags) {
	int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
	INPUT i = {0};
	i.type = INPUT_MOUSE;
	i.mi.dx = (LONG)((x * 65535LL + sw / 2) / (sw - 1));
	i.mi.dy = (LONG)((y * 65535LL + sh / 2) / (sh - 1));
	i.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | flags;
	SendInput(1, &i, sizeof i);
}

static POINT g_mouse;
static void to_screen(double fx, double fy, int* x, int* y) {
	RECT r;
	frame_rect(&r);
	*x = r.left + (int)(fx * (r.right - r.left));
	*y = r.top + (int)(fy * (r.bottom - r.top));
}
static void glide(int x, int y, int ms) {
	int steps = ms > 0 ? ms / 16 : 1;
	if (steps < 1) steps = 1;
	POINT a = g_mouse;
	for (int s = 1; s <= steps; s++) {
		mouse_at(a.x + (x - a.x) * s / steps, a.y + (y - a.y) * s / steps, 0);
		Sleep(16);
	}
	g_mouse.x = x, g_mouse.y = y;
}

static void vk_send(WORD vk, int up) {
	INPUT i = {0};
	i.type = INPUT_KEYBOARD;
	i.ki.wVk = vk;
	i.ki.wScan = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
	i.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
	if (vk == VK_LEFT || vk == VK_RIGHT || vk == VK_UP || vk == VK_DOWN || vk == VK_PRIOR || vk == VK_NEXT ||
	    vk == VK_HOME || vk == VK_END || vk == VK_INSERT || vk == VK_DELETE)
		i.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
	SendInput(1, &i, sizeof i);
}

/* "ctrl+shift+p", "alt+space", "f11", "down", "enter", "escape", "?" */
static void vkey(const char* combo) {
	WORD mods[4];
	int nm = 0;
	char buf[128];
	snprintf(buf, sizeof buf, "%s", combo);
	WORD key = 0;
	for (char* t = strtok(buf, "+"); t; t = strtok(NULL, "+")) {
		if (!_stricmp(t, "ctrl")) mods[nm++] = VK_CONTROL;
		else if (!_stricmp(t, "shift")) mods[nm++] = VK_SHIFT;
		else if (!_stricmp(t, "alt")) mods[nm++] = VK_MENU;
		else if (!_stricmp(t, "win")) mods[nm++] = VK_LWIN;
		else if (!_stricmp(t, "space")) key = VK_SPACE;
		else if (!_stricmp(t, "enter")) key = VK_RETURN;
		else if (!_stricmp(t, "escape")) key = VK_ESCAPE;
		else if (!_stricmp(t, "tab")) key = VK_TAB;
		else if (!_stricmp(t, "up")) key = VK_UP;
		else if (!_stricmp(t, "down")) key = VK_DOWN;
		else if (!_stricmp(t, "left")) key = VK_LEFT;
		else if (!_stricmp(t, "right")) key = VK_RIGHT;
		else if ((t[0] == 'f' || t[0] == 'F') && t[1] >= '1' && t[1] <= '9') key = (WORD)(VK_F1 + atoi(t + 1) - 1);
		else if (t[0] && !t[1]) {
			SHORT r = VkKeyScanA(t[0]);
			key = (WORD)(r & 0xff);
			if ((r & 0x100) && nm < 4) mods[nm++] = VK_SHIFT;
		}
	}
	for (int i = 0; i < nm; i++) vk_send(mods[i], 0);
	if (key) { vk_send(key, 0); Sleep(30); vk_send(key, 1); }
	for (int i = nm - 1; i >= 0; i--) vk_send(mods[i], 1);
}

static void vtype(const char* utf8) {
	WCHAR w[1024];
	int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, 1024);
	for (int i = 0; i < n - 1; i++) {
		INPUT in[2] = {0};
		in[0].type = in[1].type = INPUT_KEYBOARD;
		in[0].ki.wScan = in[1].ki.wScan = w[i];
		in[0].ki.dwFlags = KEYEVENTF_UNICODE;
		in[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
		SendInput(2, in, sizeof in[0]);
		Sleep(45); /* a person's pace, for the recording */
	}
}

/* ---- frames: the window's part of the screen, as PNG through WIC ---------- */

static IWICImagingFactory* g_wic;
static volatile LONG g_recording;
static volatile LONG g_whole_screen; /* 0 window, 1 screen, 2 corner */
static char g_scene_dir[MAX_PATH];

static int save_png(const char* path, const BYTE* bgra, int w, int h) {
	WCHAR wp[MAX_PATH];
	MultiByteToWideChar(CP_UTF8, 0, path, -1, wp, MAX_PATH);
	/* a file stream that creates the file (IWICStream's own doesn't, under Wine) */
	IStream* st = NULL;
	IWICBitmapEncoder* enc = NULL;
	IWICBitmapFrameEncode* fr = NULL;
	HRESULT hr = SHCreateStreamOnFileEx(wp, STGM_CREATE | STGM_WRITE | STGM_SHARE_DENY_WRITE, FILE_ATTRIBUTE_NORMAL, TRUE, NULL, &st);
	if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateEncoder(g_wic, &GUID_ContainerFormatPng, NULL, &enc);
	if (SUCCEEDED(hr)) hr = IWICBitmapEncoder_Initialize(enc, st, WICBitmapEncoderNoCache);
	if (SUCCEEDED(hr)) hr = IWICBitmapEncoder_CreateNewFrame(enc, &fr, NULL);
	if (SUCCEEDED(hr)) hr = IWICBitmapFrameEncode_Initialize(fr, NULL);
	if (SUCCEEDED(hr)) hr = IWICBitmapFrameEncode_SetSize(fr, (UINT)w, (UINT)h);
	WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
	if (SUCCEEDED(hr)) hr = IWICBitmapFrameEncode_SetPixelFormat(fr, &fmt);
	if (SUCCEEDED(hr)) hr = IWICBitmapFrameEncode_WritePixels(fr, (UINT)h, (UINT)w * 4, (UINT)w * h * 4, (BYTE*)bgra);
	if (SUCCEEDED(hr)) hr = IWICBitmapFrameEncode_Commit(fr);
	if (SUCCEEDED(hr)) hr = IWICBitmapEncoder_Commit(enc);
	if (fr) IWICBitmapFrameEncode_Release(fr);
	if (enc) IWICBitmapEncoder_Release(enc);
	if (st) IStream_Release(st);
	static int told;
	if (FAILED(hr) && !told++) logf_("#   a PNG frame failed (WIC HRESULT 0x%08lx)\n", (unsigned long)hr);
	return SUCCEEDED(hr);
}

/* A 32-bit top-down BMP: the fallback when WIC has no PNG encoder (Wine without libpng). */
static int save_bmp(const char* path, const BYTE* bgra, int w, int h) {
	FILE* f = fopen(path, "wb");
	if (!f) return 0;
	DWORD size = 54 + (DWORD)w * h * 4;
	BITMAPFILEHEADER fh = {0x4D42, size, 0, 0, 54};
	BITMAPINFOHEADER ih = {sizeof ih, w, -h, 1, 32, BI_RGB, (DWORD)w * h * 4, 2835, 2835, 0, 0};
	int ok = fwrite(&fh, sizeof fh, 1, f) == 1 && fwrite(&ih, sizeof ih, 1, f) == 1 && fwrite(bgra, (size_t)w * h * 4, 1, f) == 1;
	fclose(f);
	return ok;
}

static DWORD WINAPI recorder(LPVOID arg) {
	(void)arg;
	CoInitializeEx(NULL, COINIT_MULTITHREADED);
	char list[MAX_PATH];
	snprintf(list, sizeof list, "%s\\frames.txt", g_scene_dir);
	FILE* lf = fopen(list, "w");
	if (!lf) return 1;
	fprintf(lf, "ffconcat version 1.0\n");
	LARGE_INTEGER f, t0, t;
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&t0);
	double last = 0;
	int n = 0, fixed_w = 0, fixed_h = 0;
	char prev[MAX_PATH] = "";
	while (g_recording) {
		RECT r;
		if (g_whole_screen == 1) SetRect(&r, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
		else {
			frame_rect(&r);
			if (g_whole_screen == 2) r.right = GetSystemMetrics(SM_CXSCREEN), r.bottom = GetSystemMetrics(SM_CYSCREEN);
		}
		int w = r.right - r.left, h = r.bottom - r.top;
		/* clip to the screen (a maximized window's border lies beyond it), even sizes for video */
		if (r.left < 0) { w += r.left; r.left = 0; }
		if (r.top < 0) { h += r.top; r.top = 0; }
		if (r.left + w > GetSystemMetrics(SM_CXSCREEN)) w = GetSystemMetrics(SM_CXSCREEN) - r.left;
		if (r.top + h > GetSystemMetrics(SM_CYSCREEN)) h = GetSystemMetrics(SM_CYSCREEN) - r.top;
		w &= ~1, h &= ~1;
		if (!fixed_w) fixed_w = w, fixed_h = h;
		if (w > 0 && h > 0) {
			HDC sdc = GetDC(NULL), mdc = CreateCompatibleDC(sdc);
			BITMAPINFO bi = {{sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB}};
			BYTE* px = NULL;
			HBITMAP bmp = CreateDIBSection(sdc, &bi, DIB_RGB_COLORS, (void**)&px, NULL, 0);
			HGDIOBJ old = SelectObject(mdc, bmp);
			BitBlt(mdc, 0, 0, w, h, sdc, r.left, r.top, SRCCOPY | CAPTUREBLT);
			GdiFlush();
			for (int i = 0; i < w * h; i++) px[i * 4 + 3] = 255;
			static int use_bmp;
			char path[MAX_PATH];
			snprintf(path, sizeof path, "%s\\f%05d.%s", g_scene_dir, n, use_bmp ? "bmp" : "png");
			QueryPerformanceCounter(&t);
			double now = (double)(t.QuadPart - t0.QuadPart) / (double)f.QuadPart;
			int saved = !use_bmp && save_png(path, px, w, h);
			if (!saved) {
				use_bmp = 1;
				snprintf(path, sizeof path, "%s\\f%05d.bmp", g_scene_dir, n);
				saved = save_bmp(path, px, w, h);
			}
			if (saved) {
				if (prev[0]) fprintf(lf, "duration %.3f\n", now - last);
				fprintf(lf, "file f%05d.%s\n", n, use_bmp ? "bmp" : "png");
				snprintf(prev, sizeof prev, "%s", path);
				last = now;
				n++;
			}
			SelectObject(mdc, old);
			DeleteObject(bmp);
			DeleteDC(mdc);
			ReleaseDC(NULL, sdc);
		}
		Sleep(80); /* with the grab and the PNG, about 10 frames a second */
	}
	if (prev[0]) fprintf(lf, "duration 0.500\nfile %s\n", strrchr(prev, '\\') + 1); /* the concat demuxer drops the last duration */
	fclose(lf);
	logf_("#   %d frames, first %dx%d\n", n, fixed_w, fixed_h);
	CoUninitialize();
	return 0;
}

/* ---- the scenes ------------------------------------------------------------ */

static void json_escape(char* out, size_t cap, const char* s) {
	size_t o = 0;
	for (; *s && o + 7 < cap; s++) {
		if (*s == '"' || *s == '\\') out[o++] = '\\', out[o++] = *s;
		else out[o++] = *s;
	}
	out[o] = 0;
}

static void play(const char* file) {
	FILE* f = fopen(file, "r");
	if (!f) return;
	char line[8192];
	while (fgets(line, sizeof line, f)) {
		line[strcspn(line, "\r\n")] = 0;
		char* a = line;
		while (*a == ' ' || *a == '\t') a++;
		if (!*a || *a == '#') continue;
		char* rest = strchr(a, ' ');
		if (rest) *rest++ = 0; else rest = a + strlen(a);
		char req[8300];
		if (!strcmp(a, "ctl")) {
			free(ctl_line(rest));
		} else if (!strcmp(a, "key")) {
			char key[64] = "", mods[128] = "", m[160] = "";
			sscanf(rest, "%63s %127s", key, mods);
			if (mods[0]) {
				char* p = mods;
				strcat(m, ",\"mods\":[");
				for (char* tok = strtok(p, ","); tok; tok = strtok(NULL, ",")) {
					if (m[strlen(m) - 1] != '[') strcat(m, ",");
					strcat(m, "\""); strcat(m, tok); strcat(m, "\"");
				}
				strcat(m, "]");
			}
			snprintf(req, sizeof req, "{\"cmd\":\"key\",\"key\":\"%s\"%s}", key, m);
			free(ctl_line(req));
		} else if (!strcmp(a, "text")) {
			/* "\n" in the scene is Enter: the text before it, then the key */
			char* part = rest;
			for (;;) {
				char* nl = strstr(part, "\\n");
				if (nl) *nl = 0;
				if (*part) {
					char esc[4096];
					json_escape(esc, sizeof esc, part);
					snprintf(req, sizeof req, "{\"cmd\":\"text\",\"text\":\"%s\"}", esc);
					free(ctl_line(req));
				}
				if (!nl) break;
				free(ctl_line("{\"cmd\":\"key\",\"key\":\"enter\"}"));
				part = nl + 2;
			}
		} else if (!strcmp(a, "sleep")) {
			Sleep((DWORD)atoi(rest));
		} else if (!strcmp(a, "move")) {
			double fx = 0, fy = 0; int ms = 300, x, y;
			sscanf(rest, "%lf %lf %d", &fx, &fy, &ms);
			to_screen(fx, fy, &x, &y);
			glide(x, y, ms);
		} else if (!strcmp(a, "drag")) {
			double x1, y1, x2, y2; int ms = 600, ax, ay, bx, by;
			if (sscanf(rest, "%lf %lf %lf %lf %d", &x1, &y1, &x2, &y2, &ms) >= 4) {
				to_screen(x1, y1, &ax, &ay);
				to_screen(x2, y2, &bx, &by);
				glide(ax, ay, 200);
				mouse_at(ax, ay, MOUSEEVENTF_LEFTDOWN);
				Sleep(120);
				glide(bx, by, ms);
				mouse_at(bx, by, MOUSEEVENTF_LEFTUP);
			}
		} else if (!strcmp(a, "click") || !strcmp(a, "rclick")) {
			double fx = 0, fy = 0; int x, y;
			sscanf(rest, "%lf %lf", &fx, &fy);
			to_screen(fx, fy, &x, &y);
			glide(x, y, 250);
			int right = a[0] == 'r';
			mouse_at(x, y, right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN);
			Sleep(60);
			mouse_at(x, y, right ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP);
		} else if (!strcmp(a, "clickrect")) {
			char* r = ctl_line("{\"cmd\":\"list\"}");
			char key[80];
			snprintf(key, sizeof key, "\"%s\":[", rest);
			char* at = r ? strstr(r, key) : NULL;
			int x, y, w, h;
			if (at && sscanf(at + strlen(key), "%d,%d,%d,%d", &x, &y, &w, &h) == 4) {
				glide(x + w / 2, y + h / 2, 300);
				mouse_at(x + w / 2, y + h / 2, MOUSEEVENTF_LEFTDOWN);
				Sleep(60);
				mouse_at(x + w / 2, y + h / 2, MOUSEEVENTF_LEFTUP);
			} else logf_("# clickrect %s: not in list\n", rest);
			free(r);
		} else if (!strcmp(a, "menuinvoke")) {
			/* "font:<text>" and "shell:<text>" look only in lane A's Font (0x2000-0x23FF) and Shell
			   (0x2400-0x27FF) items, so "Default" there is not the theme's */
			int lo = 0, hi = 0x7fffffff;
			if (!strncmp(rest, "font:", 5)) lo = 0x2000, hi = 0x23ff, rest += 5;
			else if (!strncmp(rest, "shell:", 6)) lo = 0x2400, hi = 0x27ff, rest += 6;
			char* r = ctl_line("{\"cmd\":\"menu\"}");
			int id = -1;
			for (char* it = r ? strstr(r, "{\"id\":") : NULL; it && id < 0; it = strstr(it + 1, "{\"id\":")) {
				char* end = strchr(it, '}');
				char* tx = strstr(it, "\"text\":\"");
				if (tx && end && tx < end) {
					tx += 8;
					char* q = strchr(tx, '"');
					int cand = atoi(it + 6);
					if (q && cand >= lo && cand <= hi && (size_t)(q - tx) >= strlen(rest) && strstr(tx, rest) && strstr(tx, rest) < q) id = cand;
				}
			}
			free(r);
			if (id >= 0) {
				snprintf(req, sizeof req, "{\"cmd\":\"menu\",\"invoke\":%d}", id);
				free(ctl_line(req));
			} else logf_("# menuinvoke %s: no such item\n", rest);
		} else if (!strcmp(a, "capture")) {
			g_whole_screen = !strcmp(rest, "screen") ? 1 : !strcmp(rest, "corner") ? 2 : 0;
		} else if (!strcmp(a, "vkey")) {
			vkey(rest);
		} else if (!strcmp(a, "vtype")) {
			vtype(rest);
		} else {
			logf_("# unknown scene line: %s %s\n", a, rest);
		}
	}
	fclose(f);
}

static int cmp(const void* a, const void* b) { return strcmp(*(char* const*)a, *(char* const*)b); }

/* Ghostty started for one scene (each scene starts clean: one window, one tab, one pane),
   its pipe open, its window placed and in front. Returns 0 on failure. */
static int start_ghostty(const char* exe, const char* cmdline, const char* logpath, PROCESS_INFORMATION* pi) {
	SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
	HANDLE logh = CreateFileA(logpath, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS, 0, NULL);
	STARTUPINFOA si = {sizeof si};
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdError = logh;
	si.hStdOutput = logh;
	char cmd[8192];
	snprintf(cmd, sizeof cmd, "%s", cmdline);
	if (!CreateProcessA(exe, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, pi)) { logf_("FAIL start: %lu\n", GetLastError()); return 0; }
	CloseHandle(logh);
	g_pid = pi->dwProcessId;
	g_hwnd = NULL;
	g_pipe = INVALID_HANDLE_VALUE;
	char pipe[64];
	snprintf(pipe, sizeof pipe, "\\\\.\\pipe\\ghostty-%lu.ctl", g_pid);
	for (int t = 0; t < 30000 && g_pipe == INVALID_HANDLE_VALUE; t += 250) {
		g_pipe = CreateFileA(pipe, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
		if (g_pipe == INVALID_HANDLE_VALUE) Sleep(250);
	}
	if (g_pipe == INVALID_HANDLE_VALUE) { logf_("FAIL no test pipe\n"); return 0; }
	for (int t = 0; t < 30000 && !g_hwnd; t += 250) { EnumWindows(find_win, 0); if (!g_hwnd) Sleep(250); }
	if (!g_hwnd) { logf_("FAIL no window\n"); return 0; }
	EnumWindows(hide_other, 0);
	/* 1100x680, or what fits a smaller screen (a runner's default is 1024x768) */
	int ww = 1100, wh = 680, scw = GetSystemMetrics(SM_CXSCREEN), sch = GetSystemMetrics(SM_CYSCREEN);
	if (ww > scw - 24) ww = scw - 24;
	if (wh > sch - 88) wh = sch - 88;
	int sx = (scw - ww) / 2, sy = (sch - 48 - wh) / 2;
	snprintf(cmd, sizeof cmd, "{\"cmd\":\"window\",\"rect\":[%d,%d,%d,%d]}", sx < 0 ? 0 : sx, sy < 0 ? 0 : sy, ww, wh);
	free(ctl_line(cmd));
	SetForegroundWindow(g_hwnd);
	GetCursorPos(&g_mouse);
	Sleep(3000); /* the shell's first prompt */
	return 1;
}

static void stop_ghostty(PROCESS_INFORMATION* pi) {
	if (g_pipe != INVALID_HANDLE_VALUE) CloseHandle(g_pipe);
	g_pipe = INVALID_HANDLE_VALUE;
	TerminateProcess(pi->hProcess, 0);
	WaitForSingleObject(pi->hProcess, 10000);
	CloseHandle(pi->hProcess);
	CloseHandle(pi->hThread);
	Sleep(500);
}

int main(int argc, char** argv) {
	if (argc < 4) { fprintf(stderr, "usage: demo.exe <ghostty.exe> <scenes dir> <out dir> [-- <ghostty args>]\n"); return 2; }
	const char *exe = argv[1], *scenes = argv[2], *out = argv[3];
	CreateDirectoryA(out, NULL);
	char path[MAX_PATH * 2];
	snprintf(path, sizeof path, "%s\\demo-wire.log", out);
	g_wire = fopen(path, "w");
	CoInitializeEx(NULL, COINIT_MULTITHREADED);
	if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void**)&g_wic))) {
		logf_("FAIL no WIC imaging factory\n");
		return 1;
	}
	screen_1080p();

	/* Ghostty's command line, with the arguments after "--" */
	char cmd[8192];
	snprintf(cmd, sizeof cmd, "\"%s\"", exe);
	for (int i = 4; i < argc; i++) {
		if (i == 4 && !strcmp(argv[i], "--")) continue;
		strcat(cmd, " \"");
		strcat(cmd, argv[i]);
		strcat(cmd, "\"");
	}
	SetEnvironmentVariableA("GHOSTTY_TEST_CONTROL", "1");
	SetEnvironmentVariableA("GHOSTTY_WHATSNEW", "off");
	SetEnvironmentVariableA("GHOSTTY_LOG", "stderr");

	/* the scenes, in name order, each in a Ghostty of its own */
	char* names[64];
	int nn = 0, done = 0;
	WIN32_FIND_DATAA fd;
	snprintf(path, sizeof path, "%s\\*.scene", scenes);
	HANDLE fh = FindFirstFileA(path, &fd);
	if (fh != INVALID_HANDLE_VALUE) {
		do { if (nn < 64) names[nn++] = _strdup(fd.cFileName); } while (FindNextFileA(fh, &fd));
		FindClose(fh);
	}
	qsort(names, (size_t)nn, sizeof names[0], cmp);
	for (int i = 0; i < nn; i++) {
		char base[MAX_PATH];
		snprintf(base, sizeof base, "%s", names[i]);
		*strrchr(base, '.') = 0;
		snprintf(g_scene_dir, sizeof g_scene_dir, "%s\\%s", out, base);
		CreateDirectoryA(g_scene_dir, NULL);
		logf_("# scene %s\n", base);
		PROCESS_INFORMATION pi;
		/* Settings of its own: the theme or font a scene picks from the menu is saved in the user's
		   config, and run 45304911856's later scenes all inherited the look scene's light theme.
		   Each Ghostty gets a fresh LOCALAPPDATA (Ghostty's config lives in %LOCALAPPDATA%\ghostty),
		   so no scene sees another's, and no real user's config is ever touched. */
		char appdata[MAX_PATH];
		snprintf(appdata, sizeof appdata, "%s\\appdata", g_scene_dir);
		CreateDirectoryA(appdata, NULL);
		SetEnvironmentVariableA("LOCALAPPDATA", appdata);
		snprintf(path, sizeof path, "%s\\ghostty.log", g_scene_dir);
		if (!start_ghostty(exe, cmd, path, &pi)) continue;
		if (i == 0) {
			RECT r;
			frame_rect(&r);
			logf_("# window %ldx%ld on a %dx%d screen\n", r.right - r.left, r.bottom - r.top, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
		}
		g_recording = 1;
		g_whole_screen = 0;
		HANDLE th = CreateThread(NULL, 0, recorder, NULL, 0, NULL);
		snprintf(path, sizeof path, "%s\\%s", scenes, names[i]);
		DWORD t0 = GetTickCount();
		play(path);
		Sleep(800);
		g_recording = 0;
		WaitForSingleObject(th, 10000);
		CloseHandle(th);
		logf_("#   %lu ms\n", GetTickCount() - t0);
		stop_ghostty(&pi);
		done++;
	}
	logf_("%s demo: %d of %d scenes in %s\n", done == nn ? "ok" : "FAIL", done, nn, out);
	return done == nn ? 0 : 1;
}
