"""Ghostty for Windows: start the ghostty.exe this wheel carries, with the arguments passed on.

The `ghostty` command (this package's GUI script) runs ghostty.exe from ghostty/ beside this file,
the release's whole package: conpty.dll and OpenConsole.exe, Mesa's OpenGL in opengl/, the
themes and shell integration in share/. It waits for ghostty.exe and returns its exit code,
and hands it this process's standard handles, so `ghostty /buildinfo > info.txt` and
`ghostty /stats` work as ghostty.exe's own do (a GUI script runs under
pythonw, whose sys.stdout is None: the handles are taken from Windows itself).
"""

import subprocess
import sys
from pathlib import Path

from ._version import __version__

EXE = Path(__file__).resolve().parent / "ghostty" / "ghostty.exe"


def _std_handle(which: int):
    """A file descriptor for this process's standard handle -10, -11 or -12, or None."""
    if sys.platform != "win32":
        return None
    import _winapi
    import msvcrt

    handle = _winapi.GetStdHandle(which)
    if not handle or handle == _winapi.INVALID_HANDLE_VALUE:
        return None
    try:
        return msvcrt.open_osfhandle(handle, 0)
    except OSError:
        return None


def main() -> int:
    if not EXE.is_file():
        sys.exit(
            "ghostty (ghostty-for-windows): no ghostty.exe in this install. Only the Windows wheels "
            "(win_amd64, win_arm64) carry it; reinstall on Windows x64 or Arm64."
        )
    return subprocess.run(
        [str(EXE), *sys.argv[1:]],
        stdin=_std_handle(-10),
        stdout=_std_handle(-11),
        stderr=_std_handle(-12),
    ).returncode


__all__ = ["EXE", "main", "__version__"]
