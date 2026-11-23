/* glprobe (lane B, 2026-11-22): what OpenGL a WGL window gets on this Windows machine.
 *
 *   glprobe.exe
 *
 * Ghostty's renderer needs an OpenGL 4.3 core context (src/renderer/OpenGL.zig). This makes a
 * hidden window, takes a pixel format with ChoosePixelFormat (as a WGL program does), makes the
 * plain context and prints its vendor, renderer and version, and whether the pixel format is
 * Microsoft's GDI generic one (OpenGL 1.1, no driver), then asks wglCreateContextAttribsARB for
 * 4.3 core and prints what it gets. Exit 0 when 4.3 core was made, 2 when not, 1 on an error
 * before that. Lines are "key: value", for the job summary.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define WGL_CONTEXT_MAJOR_VERSION_ARB 0x2091
#define WGL_CONTEXT_MINOR_VERSION_ARB 0x2092
#define WGL_CONTEXT_PROFILE_MASK_ARB 0x9126
#define WGL_CONTEXT_CORE_PROFILE_BIT_ARB 0x00000001

typedef const unsigned char *(WINAPI *glGetString_t)(unsigned int);
typedef HGLRC(WINAPI *wglCreateContextAttribsARB_t)(HDC, HGLRC, const int *);

static const char *str(glGetString_t gs, unsigned int name) {
	const unsigned char *s = gs ? gs(name) : NULL;
	return s ? (const char *)s : "(none)";
}

int main(void) {
	HINSTANCE inst = GetModuleHandleW(NULL);
	WNDCLASSW wc = {0};
	wc.style = CS_OWNDC;
	wc.lpfnWndProc = DefWindowProcW;
	wc.hInstance = inst;
	wc.lpszClassName = L"glprobe";
	if (!RegisterClassW(&wc)) { printf("error: RegisterClass %lu\n", GetLastError()); return 1; }
	HWND hwnd = CreateWindowExW(0, L"glprobe", L"glprobe", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, NULL, NULL, inst, NULL);
	if (!hwnd) { printf("error: CreateWindow %lu\n", GetLastError()); return 1; }
	HDC dc = GetDC(hwnd);

	PIXELFORMATDESCRIPTOR pfd = {0};
	pfd.nSize = sizeof pfd;
	pfd.nVersion = 1;
	pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
	pfd.iPixelType = PFD_TYPE_RGBA;
	pfd.cColorBits = 32;
	pfd.cDepthBits = 24;
	pfd.cStencilBits = 8;
	int pf = ChoosePixelFormat(dc, &pfd);
	if (!pf) { printf("error: ChoosePixelFormat %lu\n", GetLastError()); return 1; }
	PIXELFORMATDESCRIPTOR got = {0};
	DescribePixelFormat(dc, pf, sizeof got, &got);
	/* GDI generic: PFD_GENERIC_FORMAT without PFD_GENERIC_ACCELERATED is Microsoft's software
	   OpenGL 1.1 in opengl32.dll; anything else comes from an ICD (a driver, or GLon12). */
	int generic = (got.dwFlags & PFD_GENERIC_FORMAT) && !(got.dwFlags & PFD_GENERIC_ACCELERATED);
	printf("pixel format: %d, flags 0x%08lx, %s\n", pf, got.dwFlags,
	       generic ? "GDI generic (Microsoft's OpenGL 1.1, no driver)" : "from an ICD (a driver)");
	if (!SetPixelFormat(dc, pf, &pfd)) { printf("error: SetPixelFormat %lu\n", GetLastError()); return 1; }

	HGLRC legacy = wglCreateContext(dc);
	if (!legacy || !wglMakeCurrent(dc, legacy)) { printf("error: wglCreateContext/MakeCurrent %lu\n", GetLastError()); return 1; }
	glGetString_t gs = (glGetString_t)(void *)GetProcAddress(GetModuleHandleW(L"opengl32.dll"), "glGetString");
	printf("plain context vendor: %s\n", str(gs, GL_VENDOR));
	printf("plain context renderer: %s\n", str(gs, GL_RENDERER));
	printf("plain context version: %s\n", str(gs, GL_VERSION));

	wglCreateContextAttribsARB_t cca = (wglCreateContextAttribsARB_t)(void *)wglGetProcAddress("wglCreateContextAttribsARB");
	if (!cca) {
		printf("4.3 core: no (no wglCreateContextAttribsARB)\n");
		return 2;
	}
	const int attrs[] = {WGL_CONTEXT_MAJOR_VERSION_ARB, 4, WGL_CONTEXT_MINOR_VERSION_ARB, 3,
	                     WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB, 0};
	HGLRC core = cca(dc, NULL, attrs);
	if (!core) {
		printf("4.3 core: no (wglCreateContextAttribsARB failed, error 0x%lx)\n", GetLastError());
		return 2;
	}
	wglMakeCurrent(dc, core);
	printf("4.3 core: yes\n");
	printf("core context version: %s\n", str(gs, GL_VERSION));
	printf("core context GLSL: %s\n", str(gs, GL_SHADING_LANGUAGE_VERSION));
	printf("core context renderer: %s\n", str(gs, GL_RENDERER));
	wglMakeCurrent(NULL, NULL);
	wglDeleteContext(core);
	wglDeleteContext(legacy);
	return 0;
}
