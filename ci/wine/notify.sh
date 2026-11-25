#!/usr/bin/env bash
# Desktop notifications and taskbar progress under Wine:
#
#   ci/wine/notify.sh <ghostty.exe> <out dir>
#
# Types commands into cmd.exe in Ghostty that run emit.exe ($WINE_HELPERS, default ci/wine/bin;
# build-helpers.sh; copied to C:\), which writes OSC sequences (ST-terminated: Wine's console
# drops a BEL terminator), then checks the host's log lines ("ghostty: notify: ...", naming the
# title and body):
#   1. a notification from the selected tab of the foreground window is not shown
#   2. one from a background tab (tab 1, after a second tab opened) is shown
#   3. progress set 50 in tab 1 reaches the taskbar (ITaskbarList3) as "normal 50"
#   4. error in the selected tab 2 shows "error"; back on tab 1 shows "normal 50" again
#   5. removing both clears the button ("none")
# Under Wine the balloon itself may not appear (no notification area on Xvfb); the log shows
# what was asked and its result. Run inside xvfb-run. Writes <out>/test.log; runs every step,
# exits 1 if any failed.
set -u
export GHOSTTY_WHATSNEW=off GHOSTTY_BATCH=1 GHOSTTY_LOG=stderr
exe=$1 out=$2
mkdir -p "$out"
out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
export WINEPREFIX=$out/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
log=$out/test.log
: > "$log"
say() { echo "$*" | tee -a "$log"; }
fails=0
check() { # check <what> <grep -E pattern>
	if grep -qE -- "$2" "$out/ghostty.log"; then say "ok   $1"; else say "FAIL $1 (no /$2/ in ghostty.log)"; fails=$((fails + 1)); fi
}

wineboot -i > "$out/wineboot.log" 2>&1
cp "${WINE_HELPERS:-$here/bin}/emit.exe" "$WINEPREFIX/drive_c/emit.exe" || { say "FAIL no emit.exe: run build-helpers.sh"; exit 1; }
wine "$exe" > "$out/ghostty.log" 2>&1 &
pid=$!
wid=
for _ in $(seq 60); do
	sleep 1
	wid=$(xdotool search --onlyvisible --name "Ghostty|cmd|\\\\" 2> /dev/null | head -1)
	[ -n "$wid" ] && break
done
[ -n "$wid" ] || { say "FAIL no window"; wineserver -k; exit 1; }
sleep 5
focus() { xdotool windowactivate --sync "$wid" 2> /dev/null; xdotool windowfocus --sync "$wid" 2> /dev/null; }
run() { focus; xdotool type --delay 40 "$1"; xdotool key Return; sleep "${2:-2}"; }

# 1. selected tab, foreground window
run 'C:\emit.exe "\e]9;one\e\\"' 3
# The reason's wording: "its tab is the selected tab" before split-aware notifications (lane B's
# 8a0cad108, allfeat 1bfc48713), "its pane is the focused pane" since (macOS: the focused surface).
check "1. from the selected tab of the foreground window: not shown" 'notify: "[^"]*" / "one" not shown: its (tab is the selected tab|pane is the focused pane)'
# 3. progress in tab 1
run 'C:\emit.exe "\e]9;4;1;50\e\\"' 3
check "3. progress 50 reaches the taskbar" 'notify: taskbar progress normal 50 \(HRESULT'
# 2. a background tab: tab 1 emits after 6 s, while tab 2 is selected
run 'start /b C:\emit.exe --delay 6 "\e]777;notify;Build;done in tab one\e\\"' 1
focus; xdotool key ctrl+shift+t; sleep 9
check "2. from a background tab: shown" 'notify: "Build" / "done in tab one" shown'
grep -E 'Shell_NotifyIcon' "$out/ghostty.log" | sed 's/^/#    /' | tee -a "$log"
# 4. error in tab 2 (selected) wins; back on tab 1, its normal 50 again
run 'C:\emit.exe "\e]9;4;2;80\e\\"' 3
check "4a. error in the selected tab shows" 'notify: taskbar progress error 80'
focus; xdotool key ctrl+Page_Up; sleep 2
n50=$(grep -cE 'taskbar progress normal 50' "$out/ghostty.log")
[ "$n50" -ge 2 ] && say "ok   4b. back on tab 1: normal 50 again" || { say "FAIL 4b. back on tab 1: no second 'normal 50' ($n50)"; fails=$((fails + 1)); }
# 5. remove both
run 'C:\emit.exe "\e]9;4;0\e\\"' 2
focus; xdotool key ctrl+Page_Down; sleep 1
run 'C:\emit.exe "\e]9;4;0\e\\"' 2
check "5. removing both clears the button" 'notify: taskbar progress none'

grep -E 'ghostty: notify:' "$out/ghostty.log" | sed 's/^/#    /' | tee -a "$log"
kill "$pid" 2> /dev/null
wineserver -k 2> /dev/null
[ $fails = 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
