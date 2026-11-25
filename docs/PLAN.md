# Ghostty on Windows: the technical roadmap

What each part of the port is and whether it has landed; kept current as parts land. Opened
2026-11-21; parts 1 to 3 landed 2026-11-22 (the first release). Each part ships on its own
release when it is ripe. Brought up to date on 2026-11-25, at release 20261124.9.

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
| 3 | host | `windows/`: `ghostty.exe` in C on Win32: one window, one surface, the frame blitted on `WM_PAINT`, keys as scan codes with their text, IME text, mouse and wheel, resize, per-monitor DPI v2, clipboard with confirmations | done (now about 10,000 lines of C in 25 files); tested before every release under Wine and on GitHub's Windows virtual machines, x64 and Arm64 (see the kit below), and by hand on Windows 11 with an NVIDIA GPU (a hang on that driver fixed in 20261122.2) |
| 4 | host UI | full screen (Ctrl+Enter, F11, `fullscreen = true`); tabs, splits, new window, the close confirmation, the IME candidate window position | full screen landed in 20261122.3, tabs and more than one window in 20261122.4, splits in 20261123.1 (dragging the divider in 20261123.2), the IME candidate list beside the composed text in 20261123.3; beyond the list: the Quick Terminal (20261123.4), the command palette (20261123.6), the cheat sheet (20261123.12); open: the close confirmation, the settings UI |
| 5 | present | presentation through the GPU: a DXGI flip-model swap chain, then zero-copy (`WGL_NV_DX_interop2` sharing the frame with D3D11), so frames stop going through the CPU | in progress: the DXGI path landed in 20261123.11 and was the default until 20261124.7; since 20261124.8 the CPU readback is the default again and `GHOSTTY_PRESENT=dxgi` or `interop` opts in, while a stall under load and a hang on close are fixed. The DXGI path still reads the frame back and uploads it; the zero-copy step is not finished |
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
   it.
4. Test both builds on GitHub's Windows virtual machines (`windows-latest` for x64,
   `windows-11-arm` for Arm64), with Mesa's llvmpipe, since they have no GPU driver; also the
   setup, the PyPI wheels, a throughput bench and the feature demos. A GPU driver is still
   tried by hand.
5. On `main`, for the pin only, after the required tests passed: the rolling release, a zip and
   a setup per architecture plus `SHA256SUMS`, and the wheels on PyPI.

## Risks and open questions

- **Arm64 runs on virtual machines only.** It passes the end-to-end and setup tests on GitHub's
  Windows on Arm virtual machines; not yet tested on Arm hardware.
- **OpenGL 4.3 on Windows on Arm and in VMs.** Native Arm64 drivers and Microsoft's GL-on-D3D12
  layer may report less than 4.3. Mesa's llvmpipe ships as the fallback (the `opengl` folder,
  since 20261123.1); native Arm64 drivers are still to be measured on real devices.
- **CPU presentation cost** at high resolutions while the readback is the default (part 5).
- **Keyboard mapping**: Windows virtual keys and scan codes to Ghostty's key enum, dead keys,
  AltGr (which arrives as Ctrl+Alt), and the IME.
- **ConPTY quirks**: its own VT rewriting, resize behavior, and the `conhost` version a system
  ships.
- **Fonts**: the font-directory scanner versus DirectWrite (fallback for CJK and emoji).

## Upstream

Ghostty's AI policy asks for full disclosure and a human who fully understands every change.
Nothing from this work is submitted upstream by an agent; anything worth offering upstream is
taken there by a person, in their own words and code.
