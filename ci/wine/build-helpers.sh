#!/usr/bin/env bash
# Cross-compile the small Windows helpers the Wine tests run inside the Wine prefix:
#
#   ci/wine/build-helpers.sh <out dir>
#
#   pwsh.exe     (helpers/fakepwsh.c) a fake PowerShell 7 for shell.sh: writes C:\fake-pwsh-ran.txt, runs cmd.exe
#   hittest.exe  (helpers/hittest.c)  what Ghostty's window answers to WM_NCHITTEST, for titlebar.sh
#   ncsend.exe   (helpers/ncsend.c)   posts a caption button's non-client click, for titlebar.sh
#   emit.exe     (helpers/emit.c)     writes escape sequences to the console, for notify.sh
#   sendcmd.exe  (helpers/sendcmd.c)  posts a window menu WM_SYSCOMMAND, for about.sh
#
# Needs zig (ZIG=<path> to use another one): `zig cc -target x86_64-windows-gnu` links them
# against MinGW's kernel32 and user32, the only DLLs they use. The tests find them in
# WINE_HELPERS (default ci/wine/bin, where run-all.sh builds them).
set -eu
out=${1:?usage: build-helpers.sh <out dir>}
here=$(cd "$(dirname "$0")" && pwd)
zig=${ZIG:-zig}
mkdir -p "$out"
cc() { "$zig" cc -target x86_64-windows-gnu -O2 -o "$out/$1" "$here/helpers/$2" -lkernel32 -luser32; echo "built $out/$1"; }
cc pwsh.exe fakepwsh.c
cc hittest.exe hittest.c
cc ncsend.exe ncsend.c
cc emit.exe emit.c
cc sendcmd.exe sendcmd.c
