Ghostty @VERSION@ for Windows (@ARCH@)
=====================================

An early build of the Ghostty terminal for Windows 10 (1809 or later) and 11, from
https://github.com/congzhangzh/ghostty-release-kit. Not an official Ghostty release.

Run ghostty.exe. It opens one window with PowerShell 7 (pwsh.exe) when it is installed, else
Windows PowerShell, else cmd.exe; set another shell in the config, e.g.

    command = cmd.exe

The config file is Ghostty's usual one (see https://ghostty.org/docs/config); on Windows
ghostty.exe reads %LOCALAPPDATA%\ghostty\config.ghostty (the older name "config" there works
too), or the same under %XDG_CONFIG_HOME% when that is set.

Themes: "theme = <name>" in the config, from the themes in share\ghostty\themes here (the few
whose names have a colon are left out: Windows can't hold such a file name), or your own
under %LOCALAPPDATA%\ghostty\themes. Keep the share folder beside ghostty.exe: it also has
Ghostty's shell integration for bash, zsh, fish, elvish and nushell (not yet tried on Windows).

conpty.dll and OpenConsole.exe beside ghostty.exe are Microsoft's console host (MIT, see
THIRD-PARTY-NOTICES.txt): ghostty.exe runs the shell in it, so what programs write (mouse modes,
bracketed paste, the kitty keyboard protocol, graphics, the title, OSC 52) reaches it unchanged.
Without them, or with GHOSTTY_CONPTY=inbox set, it uses Windows' own console, which drops those.

OpenGL: Ghostty draws with OpenGL 4.3. With a graphics driver that has it, the system's
OpenGL is used. Without one (a virtual machine's basic display adapter, as in UTM; some
remote desktops) Ghostty falls back to Mesa's software OpenGL in the opengl folder here (Mesa
llvmpipe, see THIRD-PARTY-NOTICES.txt): it works everywhere, using the CPU. Keep the opengl
folder beside ghostty.exe. GHOSTTY_GL=mesa or GHOSTTY_GL=system picks one; "ghostty.exe
/stats" names the one in use. When neither works, Ghostty says why in a message box.

Presenting frames: by default each frame is copied to the window through the CPU (readback),
the steadiest path today. GHOSTTY_PRESENT=dxgi (a DXGI flip-model swap chain) or
GHOSTTY_PRESENT=interop (zero-copy, where the OpenGL driver has WGL_NV_DX_interop2) opts in
to the GPU paths; they still have known problems (a stall under load, a hang on close) that
are being fixed. Without GHOSTTY_PRESENT, Ghostty says "present: default readback" on
stderr at start.

Batch mode, for scripts and tests: set GHOSTTY_BATCH=1. Nothing opens by itself and nothing
waits for a click: no What's new after an upgrade (it shows at the next normal start), no
hints; OpenGL errors and /buildinfo go to stderr; a clipboard read or write that would ask for
confirmation is denied. Menus, About and What's new still work when clicked. The variable is
not passed on to the shells inside.

Full screen: F11 or Ctrl+Enter (the whole monitor, no frame, the taskbar hidden); press it
again to go back. "fullscreen = true" in the config starts every window in full screen.

Tabs: Ctrl+Shift+T or the + on the tab bar opens one; Ctrl+Tab,
Ctrl+PageUp/PageDown or Alt+1..9 switch; Ctrl+Shift+PageUp/PageDown move a tab; Ctrl+Shift+W,
the x on a tab or a middle click closes it. Ctrl+Shift+N opens a new window.

Tested before release (under Wine, see the release notes): the window, cmd.exe through
ConPTY, typing, drawing, and closing when the shell exits.
Written but first tried on real Windows with this build: PowerShell and WSL, IME input,
mouse and wheel, copy and paste, per-monitor DPI. Please report what breaks.
Not yet: splits, the settings UI. Frames are copied through the
CPU, so very large windows use more CPU than they should.

Ghostty for Windows opens a local stats pipe (\\.\pipe\ghostty-<pid>.stats) for your own tools:
frame timings, CPU and memory, tab titles. Only processes of your own user on this machine can
open it, and it never carries what is on the screen. GHOSTTY_STATS_IPC=off turns it off.

What this build is (release, commits, core components): BUILDINFO.txt here, or

    ghostty.exe /buildinfo

If ghostty stops responding for 5 seconds or crashes, it writes a report (the stacks of its
threads and a minidump) to %LOCALAPPDATA%\ghostty\hangs or ...\crashes. Please attach those
files when you report the problem.

To keep a log, start it from cmd.exe, which hands the file itself to ghostty:

    set GHOSTTY_LOG=stderr
    ghostty.exe 2> ghostty.log

(Windows PowerShell's 2> puts a pipe in between, which can stall ghostty.exe.)

It needs OpenGL 4.3, which any current GPU driver has. In a virtual machine without a GPU
driver, put Mesa's opengl32.dll (llvmpipe) beside ghostty.exe.

Ghostty is MIT licensed (LICENSE).
