#!/usr/bin/env bash
# Tabs under Wine:
#
#   ci/wine/tabs.sh <ghostty.exe> <out dir>
#
# Run it inside xvfb-run. Each step writes a marker file from the shell it typed into:
#   1. Ctrl+Shift+T opens a second tab with its own shell: a variable set in tab 1 is unset there.
#   2. Ctrl+PageUp goes back to tab 1, whose shell still has it.
#   3. A click on the tab bar's + opens a third tab.
#   4. Alt+3 jumps to the last tab and Alt+1 to the first, typing no stray digit
#      (the + put its tab after tab 1: window-new-tab-position = current).
#   5. `exit` in each tab closes that tab only; the last one ends ghostty.exe.
# Writes <out dir>/test.log and a screenshot per step; runs every step, exits 1 if any failed.
set -u
export GHOSTTY_WHATSNEW=off # What's new opens once after an upgrade, and every prefix here is new
exe=$1 out=$2; mkdir -p "$out"; out=$(cd "$out" && pwd)
log=$out/test.log; : > "$log"
say() { echo "$*" | tee -a "$log"; }
export WINEPREFIX=$out/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" GHOSTTY_LOG=stderr
wineboot -i > "$out/wineboot.log" 2>&1
win=$(winepath -w "$out")
wine "$exe" > "$out/ghostty.log" 2>&1 & pid=$!
for _ in $(seq 60); do sleep 1; wid=$(xdotool search --onlyvisible --name "Ghostty|cmd|\\\\" 2>/dev/null | head -1); [ -n "$wid" ] && break; done
[ -n "${wid:-}" ] || { say "FAIL no window"; wineserver -k; exit 1; }
sleep 5
fails=0
focus() { xdotool windowactivate --sync "$wid" 2>/dev/null; xdotool windowfocus --sync "$wid" 2>/dev/null; }
key() { focus; xdotool key --clearmodifiers "$1"; sleep 3; }
run() { focus; xdotool type --delay 50 "$1"; xdotool key Return; sleep 2; }
shot() { import -window root "$out/$1.png"; }
check() { # check <file> <expected content> <what>
	local got; got=$(tr -d '\r' < "$out/$1" 2>/dev/null | sed 's/ *$//')
	if [ "$got" = "$2" ]; then say "ok   $3"; else say "FAIL $3 (got '$got', want '$2')"; fails=$((fails+1)); fi
}

shot 0-start
run "set T=first"
run "echo %T%> $win\\m1.txt"; check m1.txt first "tab 1 has its variable"

key ctrl+shift+t; shot 1-two-tabs
run "echo %T%> $win\\m2.txt"; check m2.txt %T% "1. new tab is a new shell (variable unset)"

key ctrl+Prior; shot 2-back-to-1
run "echo %T%> $win\\m3.txt"; check m3.txt first "2. Ctrl+PageUp went back to tab 1"

# The + is the last bar-height square at the right of the bar, which is the top of the client
# area. Find the client area's origin from the X window tree (Wine draws the frame itself when
# no window manager runs, so the client is offset by the caption).
eval "$(xdotool getwindowgeometry --shell "$wid")"
bar=30
cx=$((WIDTH - bar / 2)); cy=$((bar / 2))
# The client area starts below the caption: find the first row of the bar's color under it.
xdotool mousemove --window "$wid" "$cx" "$((cy + ${CAPTION:-0}))"
say "#    window ${WIDTH}x${HEIGHT} at $X,$Y; clicking + at $cx,$((cy + ${CAPTION:-0})) (window coords)"
xdotool click 1; sleep 3; shot 3-plus
run "echo %T%> $win\\m4.txt"; check m4.txt %T% "3. the + opened a new tab (variable unset)"

key alt+3; shot 4-alt3
run "set T=third"
run "echo %T%> $win\\m5.txt"; check m5.txt third "4a. Alt+3, then typing reaches that tab with no stray 3"
key alt+1
run "echo %T%> $win\\m6.txt"; check m6.txt first "4b. Alt+1 went back to tab 1"

# Close them one by one.
run exit; shot 5-closed-one
kill -0 $pid 2>/dev/null && say "ok   5a. exit closed one tab, ghostty.exe still runs" || { say "FAIL 5a. ghostty.exe ended after one exit"; fails=$((fails+1)); }
run exit; shot 6-closed-two
kill -0 $pid 2>/dev/null && say "ok   5b. second exit, one tab left" || { say "FAIL 5b. ghostty.exe ended early"; fails=$((fails+1)); }
run exit
for _ in $(seq 20); do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then say "FAIL 5c. still running after the last tab"; fails=$((fails+1)); shot 7-still; else say "ok   5c. the last exit ended ghostty.exe"; fi
wineserver -k 2>/dev/null
[ $fails -eq 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
