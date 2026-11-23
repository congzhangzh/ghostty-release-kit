# ghostty-for-windows

**An unofficial Windows build of Ghostty. This is not the Ghostty project's package.**

[Ghostty](https://ghostty.org), the fast, native terminal emulator, built for Windows x64 and
Windows on Arm: an early build, made by
[ghostty-release-kit](https://github.com/congzhangzh/ghostty-release-kit) from a fork of
[ghostty-org/ghostty](https://github.com/ghostty-org/ghostty). It is not made or supported by
the Ghostty project; please report problems
[here](https://github.com/congzhangzh/ghostty-release-kit/issues), not upstream.

## Install

```
uv tool install ghostty-for-windows
ghostty
```

Once, without installing: `uvx --from ghostty-for-windows ghostty`. Arguments go to
`ghostty.exe` as they are, e.g. `ghostty /buildinfo`. `uv tool upgrade ghostty-for-windows`
brings the newest release. (`pipx install ghostty-for-windows` works too.)

There are wheels for Windows x64 (`win_amd64`) and Windows on Arm (`win_arm64`) only; on
other systems, install Ghostty from [ghostty.org](https://ghostty.org).

## What is inside

The wheel carries the release's whole package, as in its zip on the
[releases page](https://github.com/congzhangzh/ghostty-release-kit/releases):

- `ghostty.exe`, with the themes, shell integration and terminfo in `share\`;
- Microsoft's console host, `conpty.dll` and `OpenConsole.exe`: what programs write reaches
  Ghostty unchanged (mouse modes, the kitty keyboard protocol, graphics, OSC 52);
- Mesa's software OpenGL in `opengl\`: Ghostty draws with OpenGL 4.3. When Windows has no
  graphics driver with it (a virtual machine's basic display adapter, some remote desktops),
  Ghostty uses Mesa's instead, on the CPU. `GHOSTTY_GL=mesa` or `GHOSTTY_GL=system` picks one.

`README.txt` beside `ghostty.exe` (in the package's `ghostty` folder) says what works and what
does not yet.

## Licences

- Ghostty: MIT (`LICENSE`).
- Microsoft's console host (conpty.dll, OpenConsole.exe): MIT.
- Mesa: MIT, with parts under BSL-1.0 and Apache-2.0; LLVM, which Mesa's software renderer is
  built with: Apache-2.0 WITH LLVM-exception.
- This launcher (the `ghostty` command): Apache-2.0, as ghostty-release-kit.

The texts are in `THIRD-PARTY-NOTICES.txt` and `LICENSE` beside `ghostty.exe`, and in the
wheel's `.dist-info/licenses/`.
