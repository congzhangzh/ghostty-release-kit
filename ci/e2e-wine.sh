#!/usr/bin/env bash
# e2e-wine.sh (lane B, 2026-11-23): the end-to-end test (ci/winprobe/e2e.c) of a ghostty.exe under
# Wine, through its test-control pipe. Run inside xvfb-run.
#
#   ci/e2e-wine.sh <ghostty.exe> <dir with e2e.exe and emit.exe, this arch> <out dir>
#
# Writes <out>/e2e.log (ok/FAIL lines), e2e-wire.log (every request and answer) and
# ghostty.log; exits as e2e.exe does (0: all passed).
set -u
exe=$(cd "$(dirname "$1")" && pwd)/$(basename "$1") probes=$(cd "$2" && pwd) out=$3
mkdir -p "$out"
out=$(cd "$out" && pwd)
export WINEPREFIX=${WINEPREFIX:-$out/wineprefix} WINEDEBUG=${WINEDEBUG:--all} WINEDLLOVERRIDES="mscoree,mshtml="
[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
timeout 300 wine "$probes/e2e.exe" "$(winepath -w "$exe")" "$(winepath -w "$out")" "$(winepath -w "$probes/emit.exe")"
rc=$?
wineserver -k 2> /dev/null
exit $rc
