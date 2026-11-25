#!/usr/bin/env bash
# The stats pipe and `ghostty.exe /stats` under Wine:
#
#   ci/wine/statsipc.sh <ghostty.exe> <out dir> <build tag>
#
# Run it inside xvfb-run. statsipc-check.py checks each /stats output: the asked number of JSON
# lines, seq consecutive, one pid, the build tag, one window with the expected tab count, a grid.
#   1. one tab: /stats --count 3
#   2. after Ctrl+Shift+T: /stats --count 2 shows two tabs
#   3. two readers at once both get their lines
#   4. a reader that stops reading (its stdout a FIFO never read) does not stall the UI, and a
#      new reader still gets its lines
#   5. GHOSTTY_STATS_IPC=off: no pipe, /stats says "no Ghostty with a stats pipe"
# Writes <out dir>/test.log; runs every step, exits 1 if any failed.
set -u
exe=$1 out=$2 build=$3; mkdir -p "$out"; out=$(cd "$out" && pwd); here=$(cd "$(dirname "$0")" && pwd)
export GHOSTTY_WHATSNEW=off GHOSTTY_BATCH=1 # What's new opens once after an upgrade, and every prefix here is new
log=$out/test.log; : > "$log"
say() { echo "$*" | tee -a "$log"; }
export WINEPREFIX=$out/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
fails=0
check() { python3 -I "$here/statsipc-check.py" "$@" | tee -a "$log"; [ "${PIPESTATUS[0]}" = 0 ] || fails=$((fails+1)); }
stats() { timeout 30 wine "$exe" /stats "$@" 2> "$out/stats-err.txt" | tr -d '\r'; }
win=$(winepath -w "$out" 2> /dev/null)
start() {
	wine "$exe" > "$out/ghostty-$1.log" 2>&1 & pid=$!
	for _ in $(seq 60); do sleep 1; wid=$(xdotool search --onlyvisible --name "Ghostty" 2> /dev/null | head -1); [ -n "$wid" ] && break; done
	sleep 4; xdotool windowfocus --sync "$wid" 2> /dev/null
}
stop() { for t in "$@"; do xdotool windowfocus --sync "$wid" 2> /dev/null; xdotool type --delay 60 exit; xdotool key Return; sleep 2; done
	for _ in $(seq 20); do kill -0 $pid 2> /dev/null || break; sleep 1; done
	kill -0 $pid 2> /dev/null && { say "FAIL exit"; fails=$((fails+1)); kill $pid; }; wineserver -k 2> /dev/null; }

start on
stats --count 3 > "$out/1.txt"; check "$out/1.txt" 3 1 "$build"
xdotool key --clearmodifiers ctrl+shift+t; sleep 3
stats --count 2 > "$out/2.txt"; check "$out/2.txt" 2 2 "$build"
# Two readers at once.
stats --count 2 > "$out/3a.txt" & a=$!; stats --count 2 > "$out/3b.txt"; wait $a
check "$out/3a.txt" 2 2 "$build"; check "$out/3b.txt" 2 2 "$build"
# A reader that stops reading: its stdout is a FIFO held but never read.
mkfifo "$out/stuck.fifo"; exec 3<> "$out/stuck.fifo"
timeout 60 wine "$exe" /stats --count 0 > "$out/stuck.fifo" 2> /dev/null & stuck=$!
sleep 20 # its 64 KB fills (about 120 lines), then the pipe's own buffer
xdotool type --delay 60 "echo alive> $win\\alive.txt"; xdotool key Return; sleep 3
grep -q alive "$out/alive.txt" 2> /dev/null && say "ok   the UI works while a reader is stuck" || { say "FAIL UI with a stuck reader"; fails=$((fails+1)); }
stats --count 2 > "$out/4.txt"; check "$out/4.txt" 2 2 "$build"
kill $stuck 2> /dev/null; exec 3<&-
stop 1 2

GHOSTTY_STATS_IPC=off start off
stats --count 1 > "$out/5.txt"; rc=$?
[ ! -s "$out/5.txt" ] && grep -q "no Ghostty with a stats pipe" "$out/stats-err.txt" && say "ok   GHOSTTY_STATS_IPC=off: no pipe ($(tr -d '\r' < "$out/stats-err.txt"))" || { say "FAIL off: got $(head -c 200 "$out/5.txt") / $(cat "$out/stats-err.txt")"; fails=$((fails+1)); }
stop 1
[ $fails = 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
