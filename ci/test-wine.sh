#!/usr/bin/env bash
# Test ghostty.exe under Wine on a virtual X server (Xvfb, OpenGL from Mesa's llvmpipe):
#
#   ci/test-wine.sh <ghostty.exe> <out dir>
#
# Run it inside xvfb-run (DISPLAY set). Each check proves one layer, from the window down:
#   1. window   the host creates its window and libghostty its surface
#   2. input    typed keys reach cmd.exe through ConPTY: the command it runs writes a marker file
#   3. render   the renderer drew the text: the screenshot after typing has text-coloured pixels
#               and differs from the one before
#   4. exit     typing "exit" ends the shell, which closes the window, which ends ghostty.exe
# Writes <out dir>/test.log (one line per check) and the screenshots; exits 1 on the first failure.
set -u
exe=$1 out=$2
mkdir -p "$out"
out=$(cd "$out" && pwd) # absolute: Wine refuses a relative WINEPREFIX
log=$out/test.log
: > "$log"
# Keep Ghostty's log and Wine's errors in ghostty.log: a failure on a runner is read from them.
export WINEPREFIX=${WINEPREFIX:-$out/wineprefix} WINEDEBUG=${WINEDEBUG:-err+all,fixme-all} WINEDLLOVERRIDES="mscoree,mshtml="
export GHOSTTY_LOG=${GHOSTTY_LOG:-stderr}

say() { echo "$*" | tee -a "$log"; }
fail() { say "FAIL $*"; cleanup; exit 1; }
cleanup() { [ -n "${pid:-}" ] && kill "$pid" 2> /dev/null; wineserver -k 2> /dev/null; }

[ -n "${DISPLAY:-}" ] || { echo "test-wine.sh: no DISPLAY; run it inside xvfb-run" >&2; exit 2; }
[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
echo "# $(wine --version 2> /dev/null)" | tee -a "$log"
glxinfo -B 2> /dev/null | grep -E "renderer string|core profile version" | sed 's/^/# /' | tee -a "$log"

marker=ghostty-wine-$RANDOM$RANDOM
markwin='C:\ghostty-test.txt'
markunix=$(winepath -u "$markwin" 2> /dev/null)
rm -f "$markunix"

wine "$exe" > "$out/ghostty.log" 2>&1 &
pid=$!

# 1. window
wid=
for _ in $(seq 1 60); do
	sleep 1
	wid=$(xdotool search --onlyvisible --class "ghostty" 2> /dev/null | head -1)
	[ -n "$wid" ] || wid=$(xdotool search --onlyvisible --name "Ghostty|cmd|\\\\" 2> /dev/null | head -1)
	[ -n "$wid" ] && break
	kill -0 "$pid" 2> /dev/null || fail "window: ghostty.exe exited before a window appeared (log: ghostty.log)"
done
[ -n "$wid" ] || fail "window: none after 60s"
say "ok   window $wid"
sleep 6
import -window root "$out/before.png"

# 2. input
xdotool windowactivate --sync "$wid" 2> /dev/null
xdotool windowfocus --sync "$wid" 2> /dev/null
xdotool type --delay 60 "echo $marker> $markwin"
xdotool key Return
sleep 1
xdotool type --delay 60 "echo hello from ghostty"
xdotool key Return
for _ in $(seq 1 20); do
	[ -s "$markunix" ] && break
	sleep 1
done
grep -q "$marker" "$markunix" 2> /dev/null || fail "input: cmd.exe did not write the marker to $markwin"
say "ok   input: cmd.exe ran the typed command"
sleep 3
import -window root "$out/after.png"

# 3. render: count the pixels much brighter than the background (text), before and after
bright() { convert "$1" -colorspace Gray -threshold 60% -format "%[fx:int(mean*w*h)]" info:; }
b0=$(bright "$out/before.png") b1=$(bright "$out/after.png")
diff=$(compare -metric AE "$out/before.png" "$out/after.png" null: 2>&1 | cut -d' ' -f1)
say "#    text pixels before=$b0 after=$b1, pixels changed=$diff"
[ "${b1:-0}" -gt 2000 ] || fail "render: almost no text on screen after typing ($b1 bright pixels)"
[ "${b1:-0}" -gt "${b0:-0}" ] || fail "render: no more text after typing than before"
[ "${diff%%.*}" -gt 1000 ] 2> /dev/null || fail "render: the screen did not change after typing"
say "ok   render: the typed command and its output were drawn"

# 4. exit
xdotool type --delay 60 "exit"
xdotool key Return
for _ in $(seq 1 20); do
	kill -0 "$pid" 2> /dev/null || break
	sleep 1
done
if kill -0 "$pid" 2> /dev/null; then fail "exit: ghostty.exe still runs 20s after the shell exited"; fi
say "ok   exit: the shell exited and ghostty.exe closed"
pid=
cleanup
say "PASS"
