# Ghostty on Windows: the technical roadmap

What each part of the port is and whether it has landed; kept current as parts land. Opened
2026-11-21; parts 1 to 3 landed 2026-11-22 (the first release). Each part ships on its own
release when it is ripe.

## Goal

A Ghostty terminal that runs natively on Windows 10/11 (x64 and Arm64), built and released by
this kit as a zip: `ghostty.exe`, libghostty linked in statically, from our fork's
`release-<YYYYMMDD>.<N>` branches, tested on Windows before every release.

## Where upstream is (main, November 2026)

What already works on Windows upstream, and what this plan builds on:

| Piece | Where | State |
|---|---|---|
| Pseudo console (ConPTY) | `src/pty.zig` (`WindowsPty`) | present |
| Reading the pty | `src/termio/Exec.zig` (`threadMainWindows`, `CancelIoEx`) | present |
| Default shell | `src/termio/Exec.zig` (`cmd.exe`) | present |
| Fonts | `src/font/backend.zig` (`freetype_windows`, a font-directory scanner) | present |
| The core as a library | `build.zig`: app runtime `none` installs `ghostty-internal.dll` + `.lib` | present |
| libghostty-vt | prebuilt Windows zips, x64 and Arm64, tested on Windows in CI | released |
| **Rendering** | `src/renderer/OpenGL.zig` creates its context with **EGL** (surfaceless) and hands frames to the app as a dmabuf or as CPU pixels | **no Windows path** |
| **App runtime** | `src/apprt/embedded.zig` knows `macos` and `ios` only; there is no Windows app | **missing** |

So the gap is the top of the stack: an OpenGL context on Windows, a Windows platform in the
embedded runtime, and the app around it.

## Shape

The macOS app is a Swift program on top of libghostty's embedded runtime; the Windows app takes
the same shape. The core stays the core; Windows gets a host:

```
ghostty.exe (windows/, Zig, Win32)        window, message loop, keys, IME, mouse, clipboard, DPI
   │ ghostty.h C API
ghostty-internal.dll (src/, apprt=embedded) terminal, termio (ConPTY), fonts, renderer
   │
OpenGL 4.3 core via WGL, offscreen         frames come back as CPU pixels first (the path the
                                           renderer already has), zero-copy later
```

Why a native host and not the GTK app on Windows: GTK4 + libadwaita on Windows is a large DLL
stack, and the GTK runtime leans on X11/Wayland, D-Bus and cgroups. The embedded runtime is the
one upstream designed for non-GTK hosts.

## Parts, in order

The port lives in the fork (`congzhangzh/ghostty`) on one branch, `feature-windows`, on
upstream `main`, one commit per part (a part grows its own branch when it gets big);
`integration-windows` is rebuilt from it; a tested integration commit is picked as
`release-<YYYYMMDD>.<N>` and pinned in this kit's `sources.lock`.

| # | Part | What | State |
|---|---|---|---|
| 1 | WGL | A WGL backend for `renderer/opengl/Device.zig` and the context calls in `OpenGL.zig` (a hidden window's DC, `wglCreateContextAttribsARB` for 4.3 core, made current on the render thread); presentation stays on the CPU-pixel path | done |
| 2 | embedded | `GHOSTTY_PLATFORM_WINDOWS` (an `HWND`) and `ghostty_surface_take_frame` / `ghostty_frame_free` for a host that presents frames itself | done |
| 3 | host | `windows/`: `ghostty.exe` in C on Win32: one window, one surface, the frame blitted on `WM_PAINT`, keys as scan codes with their text, IME text, mouse and wheel, resize, per-monitor DPI v2, clipboard with confirmations | done; tested under Wine (window, typing, drawing, exit) before every release, and by hand on Windows 11 with an NVIDIA GPU (a hang on that driver fixed in 20261122.2) |
| 4 | host UI | full screen (Ctrl+Enter, F11, `fullscreen = true`); tabs, splits, new window, the close confirmation, the IME candidate window position | full screen landed in 20261122.3, tabs and more than one window in 20261122.4; the rest open |
| 5 | present | zero-copy presentation (`WGL_NV_DX_interop2` into a D3D11 flip swap chain, or a DirectComposition surface), so frames stop going through the CPU | later |
| 6 | later | a D3D11 renderer (as Metal is to macOS), MSIX/winget packaging, code signing | open |

Upstream had never run its Windows paths outside libghostty-vt, so the port also fixes them:
the core did not compile (`pwd.h`, a misplaced `dupeSentinel` argument, DMABUF fds), the
OpenGL bindings were translated for the build host (an LLP64 ABI slip: `GLsizeiptr` came out
32-bit), `ghostty_init` refused Windows, the pty read thread could never be stopped (the quit
pipe was written with the C runtime's `write` on a Win32 `HANDLE`, an end-of-pipe read looped
forever), and stripped builds dropped the unwind tables Windows needs.

## The kit

As our other kits do (rolling releases `<YYYYMMDD>.<N>`, published once, never replaced; no
build for an unimportant push, decided by `ci/changes.sh`):

1. `ci/resolve.sh` checks the pin: the pinned commit must still be the tip of its release
   branch.
2. Build: cross-compiled with Zig on Linux for `x86_64-windows-gnu` and `aarch64-windows-gnu`.
3. Test the x64 build under Wine on a virtual X server, with OpenGL from Mesa's llvmpipe: the
   window appears, typed keys reach `cmd.exe` through ConPTY, the text is drawn, `exit` closes
   it. Real Windows (a GPU driver, Arm64) is tried by hand on each release for now; Windows
   runners in CI have no OpenGL 4.3 without shipping Mesa.
4. On `main`, for the pin only, after every test passed: the rolling release, a zip per
   architecture plus `SHA256SUMS`.

## Risks and open questions

- **Arm64 is built, not yet run.** Wine on x64 cannot run it; it needs a Windows on Arm
  device.
- **OpenGL 4.3 on Windows on Arm and in VMs.** Native Arm64 drivers and Microsoft's GL-on-D3D12
  layer may report less than 4.3. Ship Mesa llvmpipe as a fallback, lower the minimum, or move
  to part 6 sooner? To be measured on real devices.
- **CPU presentation cost** at high resolutions until part 5.
- **Keyboard mapping**: Windows virtual keys and scan codes to Ghostty's key enum, dead keys,
  AltGr (which arrives as Ctrl+Alt), and the IME.
- **ConPTY quirks**: its own VT rewriting, resize behavior, and the `conhost` version a system
  ships.
- **Fonts**: the font-directory scanner versus DirectWrite (fallback for CJK and emoji).

## Upstream

Ghostty's AI policy asks for full disclosure and a human who fully understands every change.
Nothing from this work is submitted upstream by an agent; anything worth offering upstream is
taken there by a person, in their own words and code.
