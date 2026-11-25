#!/usr/bin/env bash
# The default shell under Wine, with no `command` in the config:
#
#   ci/wine/shell.sh <package dir: ghostty.exe [+ share/]> <out dir>
#
#   a. none   no pwsh.exe anywhere: cmd.exe, and the log gives the Wine reason (Wine's
#             powershell.exe is a stub, so it is skipped)
#   b. path   a fake pwsh.exe in C:\fakebin, put on PATH with WINEPATH: it runs
#   c. pf     a fake pwsh.exe in C:\Program Files\PowerShell\7 (a path with a space): it runs
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
	shell_line=$(grep -o 'default shell src=detect value=.*' "$out/$c/ghostty.log" | head -1)
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
	case $c in
	none)
		check none "cmd.exe, skipping Wine's stub powershell.exe" \
			grep -q 'value=cmd.exe (no PowerShell 7; running under Wine, whose powershell.exe is a stub)' "$out/none/ghostty.log"
		check none "the shell stays up (no window closed at once)" [ "$alive" = yes ]
		;;
	path)
		check path "the log names C:\\fakebin\\pwsh.exe, on PATH" \
			grep -qi 'value=C:\\fakebin\\pwsh.exe (PowerShell 7, pwsh.exe on PATH)' "$out/path/ghostty.log"
		check path "the fake pwsh.exe ran ($marker)" [ -n "$marker" ]
		;;
	pf)
		check pf "the log names C:\\Program Files\\PowerShell\\7\\pwsh.exe" \
			grep -qi 'value=C:\\Program Files\\PowerShell\\7\\pwsh.exe (PowerShell 7, in its install folder)' "$out/pf/ghostty.log"
		check pf "the fake pwsh.exe ran from the path with a space ($marker)" [ -n "$marker" ]
		;;
	esac
done
[ $fails = 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
