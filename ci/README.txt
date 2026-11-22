Ghostty @VERSION@ for Windows (@ARCH@)
=====================================

An early build of the Ghostty terminal for Windows 10 (1809 or later) and 11, from
https://github.com/congzhangzh/ghostty-release-kit. Not an official Ghostty release.

Run ghostty.exe. It opens one window with cmd.exe; set another shell in the config, e.g.

    command = pwsh.exe

The config file is Ghostty's usual one (see https://ghostty.org/docs/config); on Windows
ghostty.exe reads %LOCALAPPDATA%\ghostty\config.ghostty (the older name "config" there works
too), or the same under %XDG_CONFIG_HOME% when that is set.

Full screen: F11 or Ctrl+Enter (the whole monitor, no frame, the taskbar hidden); press it
again to go back. "fullscreen = true" in the config starts every window in full screen.

Tested before release (under Wine, see the release notes): the window, cmd.exe through
ConPTY, typing, drawing, and closing when the shell exits.
Written but first tried on real Windows with this build: PowerShell and WSL, IME input,
mouse and wheel, copy and paste, per-monitor DPI. Please report what breaks.
Not yet: tabs, splits, more than one window, the settings UI. Frames are copied through the
CPU, so very large windows use more CPU than they should.

To keep a log, start it from cmd.exe, which hands the file itself to ghostty:

    set GHOSTTY_LOG=stderr
    ghostty.exe 2> ghostty.log

(Windows PowerShell's 2> puts a pipe in between, which can stall ghostty.exe.)

It needs OpenGL 4.3, which any current GPU driver has. In a virtual machine without a GPU
driver, put Mesa's opengl32.dll (llvmpipe) beside ghostty.exe.

Ghostty is MIT licensed (LICENSE).
