# Ghostty on Windows: the system design

How the Windows port works, from the GPU to the screen and from a key press to the shell.
[PLAN.md](PLAN.md) is the technical roadmap. Labels: ✅ verified (run or read), 🔎 inferred
from evidence, ⚠️ open or a guess.

## Layers

```
ghostty.exe          windows/*.c (about 10,000 lines of C in 25 files, Win32)
  │                  window, message loop, keys, text, mouse, clipboard, DPI, painting,
  │                  tabs, splits, menus, palette, presenting (paint.c, dxgi.c)
  │ include/ghostty.h (the C API, plus: GHOSTTY_PLATFORM_WINDOWS, ghostty_frame_s,
  │                    ghostty_surface_take_frame, ghostty_frame_free)
libghostty           src/, app runtime "embedded", linked statically
  │  terminal + termio ── ConPTY (src/pty.zig WindowsPty), a read thread per surface
  │  fonts ────────────── FreeType, Windows font-directory scanner
  │  renderer ─────────── OpenGL 4.3 core, offscreen, context from WGL (pkg/opengl/wgl.zig)
opengl32.dll         the GPU driver's ICD (or Mesa's llvmpipe under Wine / in a VM)
```

Why this shape: the embedded runtime is the one upstream designed for hosts that aren't GTK
(the macOS app uses it). Running the GTK app on Windows would mean shipping GTK4 and
libadwaita, and GTK's runtime leans on X11/Wayland, D-Bus and cgroups.

## Threads

| Thread | Owner | Does |
|---|---|---|
| UI (main) | host | `GetMessage` loop; every window message; `ghostty_app_tick` on a wakeup |
| renderer, one per surface | libghostty | makes the WGL context current, draws, reads the frame back |
| I/O, one per surface | libghostty | the terminal state machine, writes to the pty |
| pty reader, one per surface | libghostty | blocking `ReadFile` on the ConPTY output pipe |

A wakeup from any libghostty thread calls the host's `wakeup_cb`. It posts
`WM_GHOSTTY_WAKEUP` to a message-only window, at most one at a time
(`InterlockedExchange` on a flag). The UI thread then runs `ghostty_app_tick`, which delivers
actions on the UI thread. The host never drains its queue with `PeekMessage`, because that also
takes a `WM_QUIT` (whatever filter it is given).

## A frame, from the GPU to the screen

1. The renderer thread draws into an offscreen framebuffer. Its WGL context is made on a
   hidden window's DC: a dummy context loads `wglCreateContextAttribsARB`, which then makes a
   4.3 core context. GL entry points come from `wglGetProcAddress`, falling back to
   `opengl32.dll`'s `GetProcAddress` for the GL 1.1 functions, which `wglGetProcAddress` doesn't
   return.
2. The frame is read back with `glReadPixels` into CPU memory (the renderer's existing
   `ExportedFrame.memory` path, used on Linux too). It is premultiplied RGBA8, rows bottom
   first.
3. libghostty raises `GHOSTTY_ACTION_RENDER`. On the UI thread the host calls
   `ghostty_surface_take_frame`, which hands over the newest frame and keeps ownership until
   `ghostty_frame_free`. The host swizzles it to BGRA.
4. `InvalidateRect`, then on `WM_PAINT`, `SetDIBitsToDevice` with a **positive** height, a
   bottom-up DIB, which is the order OpenGL reads rows in, so no flip is needed. While a resize
   waits for its frame, the uncovered part is filled black.

Cost: one GPU→CPU readback and one CPU copy per frame. That is fine at desktop sizes (🔎 not
yet measured on real hardware) and is the reason for part 5.

This readback path is the default (again since 20261124.8; Ghostty says "present: default
readback" on stderr at start). `GHOSTTY_PRESENT` opts in to the GPU paths of part 5
(`windows/dxgi.c`), which still have a stall under load and a hang on close:

- `dxgi`: the frame is still read back, then uploaded into a DXGI flip-model swap chain on the
  pane's window (2 buffers, BGRA8, a waitable latency object, at most one frame queued)
  instead of GDI. The D3D11 device is made on OpenGL's GPU: the adapter whose LUID OpenGL
  reports, else the one of its vendor. Any failure falls back to GDI, said once.
- `interop`: kept for the zero-copy step (OpenGL sharing its texture with D3D11 through
  `WGL_NV_DX_interop2`); ⚠️ until that blit lands, its frames go through the `dxgi` path.
  Without the extension (Wine, Mesa, the CI runners) it uses `SwapBuffers`.

## Input

- **Keys:** `WM_KEYDOWN`/`WM_SYSKEYDOWN` are sent as the hardware scan code (`0xE000 | sc` for
  extended keys), which is the keycode libghostty's embedded runtime maps. The text the key
  produced is collected from the `WM_CHAR` messages that `TranslateMessage` queued behind it,
  so a key and its text reach libghostty as one event. A `WM_DEADCHAR` marks the key as composing.
- **Text with no key:** IME results and `SendInput` Unicode arrive as a bare `WM_CHAR`; UTF-16
  surrogate pairs are joined, then the text goes to `ghostty_surface_text`.
- **Mouse:** buttons, movement, both wheels, with the current modifiers. **DPI:** per-monitor
  v2; `WM_DPICHANGED` sets the content scale.
- **Clipboard:** `CF_UNICODETEXT` both ways, with libghostty's confirmation for an untrusted
  paste or read.

## Shutdown

The shell exits, then ConPTY's pipe ends, then the read thread sees EOF/`BROKEN_PIPE`, stops
reading and waits on the quit pipe. libghostty asks the host to close the surface, and the host
**posts** `WM_GHOSTTY_DESTROY` rather than destroying the window inside the callback, since
freeing a surface inside one of its own callbacks is a use-after-free. `WM_DESTROY` frees the
surface. Its termio closes the pseudo console, writes the quit byte with `WriteFile` (not the C
runtime's `write`, which takes a CRT fd, not a `HANDLE`) and joins the thread. The last window
ends the loop.

## What upstream had never run on Windows

The port found and fixed these, each in its own commit, all ✅ reproduced and verified:

| Trap | Symptom | Fix |
|---|---|---|
| `pwd.h` in the C headers, a `dupeSentinel` argument in the wrong call, POSIX dmabuf fds | the core didn't compile for Windows | per-OS headers and types; the sentinel moved |
| the OpenGL bindings translated for the build host | `GLsizeiptr` 32-bit instead of 64 (LLP64 vs LP64), so the ABI was wrong | translate for the target |
| `ghostty_init` read argv the POSIX way | the C API refused to start | the command line from the PEB |
| the quit byte written with `posix.write` on a Win32 `HANDLE`; EOF looped | the read thread could never stop, so the exit hung | `WriteFile`, close the console first, stop on EOF |
| ReleaseFast stripped the unwind tables | mingw's SEH directives failed to assemble (both arches) | keep unwind tables on Windows |
| a surface freed inside its own callback | a crash or hang on close | post the destroy |

## Build and test pipeline (this kit)

```
sources.lock pin ─► ci/resolve.sh ─► ci/build.sh ─────────────► ci/test-wine.sh ─► publish
(fork release       (pin = tip of    Zig 0.17.1, cross:          WineHQ stable,     rolling
 branch + commit)    its branch;     x86_64- / aarch64-          Xvfb, llvmpipe:    <YYYYMMDD>.<N>,
                     base is an      windows-gnu; lib ReleaseFast window, input,    zips +
                     ancestor)       + host via zig cc/c++; zip  render, exit       SHA256SUMS
```

Beside Wine, the `windows` job runs both builds on GitHub's Windows virtual machines
(`windows-latest`, `windows-11-arm`) with `ci/test-windows.ps1`. They have no GPU driver, so
Mesa's llvmpipe goes beside `ghostty.exe` when the in-box OpenGL is below 4.3 (as the zips carry
it in their `opengl` folder); the checks look at the window's pixels (`PrintWindow`) and drive
the real `ghostty.exe` through its test-control pipe. The `gate` job requires the
build, `wine-x64` and `windows`; the tests run Ghostty with `GHOSTTY_BATCH=1`, so no window opens
by itself and nothing waits for a click.

`ci/changes.sh` decides what a push needs: `none` (docs), `test` (scripts, the workflow), or
`release` (a pin line, `ci/build.sh`, `ci/about.py`, `ci/README.txt`, the notices, the setup
script). A manual run on `main` counts as `release`. The publish step refuses a version, or a
kit-key of inputs, that is already released.

Why Wine too: it gives OpenGL 4.5–4.6 through Mesa's llvmpipe on any Linux runner, and its
checks drive the real `ghostty.exe` through X (xdotool types, ImageMagick compares
screenshots).

