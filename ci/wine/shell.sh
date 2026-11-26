#!/usr/bin/env bash
# The default shell under Wine, with no `command` in the config: always cmd.exe, as upstream
# (since 20261126.1; PowerShell is chosen in the Shell menu or with `command =`):
#
#   ci/wine/shell.sh <package dir: ghostty.exe [+ share/]> <out dir>
#
#   a. none   no pwsh.exe anywhere: cmd.exe
#   b. path   a fake pwsh.exe in C:\fakebin, put on PATH with WINEPATH: NOT run, cmd.exe
#   c. pf     a fake pwsh.exe in C:\Program Files\PowerShell\7: NOT run, cmd.exe
# The fake ($WINE_HELPERS/pwsh.exe, from helpers/fakepwsh.c; build-helpers.sh) writes
# C:\fake-pwsh-ran.txt with its own path, then runs cmd.exe.
# Each case gets a fresh Wine prefix. Run inside xvfb-run. Writes <out>/test.log.
set -u
export GHOSTTY_WHATSNEW=off GHOSTTY_BATCH=1 # What's new opens once after an upgrade, and every prefix here is new
pkg=$(cd "$1" && pwd) out=$2
mkdir -p "$out"
out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
fake=${WINE_HELPERS:-$here/bin}/pwsh.exe
log=$out/test.log
: > "$log"
[ -f "$fake" ] || { echo "FAIL no $fake: run build-helpers.sh" | tee -a "$log"; exit 1; }
say() { echo "$*" | tee -a "$log"; }
fails=0

# run <case>: start ghostty.exe in $WINEPREFIX, wait for the window, give the shell 8 s, stop.
run() {
	local c=$1 wid='' pid
	(cd "$pkg" && wine ./ghostty.exe > "$out/$c/ghostty.log" 2>&1) &
	pid=$!
	for _ in $(seq 1 60); do
		sleep 1
		wid=$(xdotool search --onlyvisible --name "Ghostty|cmd|pwsh|\\\\" 2> /dev/null | head -1)
		[ -n "$wid" ] && break
		kill -0 "$pid" 2> /dev/null || break
	done
	sleep 8
	kill -0 "$pid" 2> /dev/null && alive=yes || alive=no
	kill "$pid" 2> /dev/null
	wineserver -k 2> /dev/null
	shell_line=$(grep -o 'will default to using cmd' "$out/$c/ghostty.log" | head -1)
	say "#    $c: window ${wid:-none}, still running after 8 s: $alive"
	say "#    $c: log: ${shell_line:-<no default shell line>}"
}

check() { # check <case> <description> <condition...>
	local c=$1 d=$2
	shift 2
	if "$@"; then say "ok   $c: $d"; else say "FAIL $c: $d"; fails=$((fails + 1)); fi
}

for c in none path pf; do
	mkdir -p "$out/$c"
	export WINEPREFIX=$out/$c/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" GHOSTTY_LOG=stderr
	unset WINEPATH
	wineboot -i > "$out/$c/wineboot.log" 2>&1
	c_drive=$WINEPREFIX/drive_c
	rm -f "$c_drive/fake-pwsh-ran.txt"
	case $c in
	path)
		mkdir -p "$c_drive/fakebin" && cp "$fake" "$c_drive/fakebin/pwsh.exe"
		export WINEPATH='C:\fakebin'
		;;
	pf) mkdir -p "$c_drive/Program Files/PowerShell/7" && cp "$fake" "$c_drive/Program Files/PowerShell/7/pwsh.exe" ;;
	esac
	run "$c"
	marker=$(tr -d '\r' < "$c_drive/fake-pwsh-ran.txt" 2> /dev/null)
	check "$c" "cmd.exe is the default (the log says so)" grep -q 'will default to using cmd' "$out/$c/ghostty.log"
	check "$c" "the shell stays up (no window closed at once)" [ "$alive" = yes ]
	[ "$c" = none ] || check "$c" "the fake pwsh.exe did not run" [ -z "$marker" ]
done
[ $fails = 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
