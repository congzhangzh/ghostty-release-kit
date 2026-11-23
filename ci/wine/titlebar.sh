#!/usr/bin/env bash
# The title bar's buttons and window menu under Wine (X11 Decorated=N, GHOSTTY_TITLEBAR=tabs):
#
#   ci/wine/titlebar.sh <ghostty.exe> <out dir>
#
# Wine has no DWM: the buttons' room (138 px at 96 dpi) answers as minimize | maximize | close,
# 46 px each, so their clicks are tested here: maximize, restore WHILE MAXIMIZED, minimize while
# maximized, close while maximized (a second launch). Wine without a window manager never resizes
# the X window of a maximized window, so real clicks cannot reach its buttons: maximized restore,
# minimize and close go through ncsend.exe (the messages a DWM-left click sends); hittest.exe asks
# the window what each point is (WM_NCHITTEST). After full screen it waits for the window to settle
# before the maximize click. The window menu: right-click on the caption, Alt+Space in the
# terminal, Shift+right-click in the terminal, right-click on the full screen tab bar (a menu = a
# new visible window); menus are checked while not maximized. Also the + place.
# Helpers from $WINE_HELPERS (default ci/wine/bin; build-helpers.sh). Run inside xvfb-run.
# Writes <out dir>/test.log and a screenshot per menu; runs every step, exits 1 if any failed.
set -u
exe=$1 out=$2; mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd); helpers=${WINE_HELPERS:-$here/bin}
ht=$helpers/hittest.exe; nc() { wine "$helpers/ncsend.exe" "$1" > /dev/null 2>&1; sleep 2; }
log=$out/test.log; : > "$log"
say() { echo "$*" | tee -a "$log"; }
for h in hittest ncsend; do [ -f "$helpers/$h.exe" ] || { say "FAIL no $helpers/$h.exe: run build-helpers.sh"; exit 1; }; done
export WINEPREFIX=$out/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" GHOSTTY_TITLEBAR=tabs GHOSTTY_WHATSNEW=off
[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
wine reg add "HKCU\\Software\\Wine\\X11 Driver" /v Decorated /t REG_SZ /d N /f > /dev/null 2>&1
fails=0
info() { wine "$ht" 2> /dev/null | tr -d '\r' | head -1; }
field() { sed -E "s/.* $1 ([-0-9]+).*/\1/" <<< "$(info)"; }
geo() { local i; i=$(info); W=$(sed -E 's/.*client origin [-0-9]+,[-0-9]+ ([0-9]+)x.*/\1/' <<< "$i"); ox=$(sed -E 's/.*client origin ([-0-9]+),.*/\1/' <<< "$i"); oy=$(sed -E 's/.*client origin [-0-9]+,([-0-9]+) .*/\1/' <<< "$i"); }
expect() { local got; got=$(wine "$ht" "$1" "$2" 2> /dev/null | tr -d '\r' | sed -n "s/^$1,$2 //p")
	if [ "$got" = "$3" ]; then say "ok   $4 ($1,$2: $got)"; else say "FAIL $4 ($1,$2: got '$got', want '$3')"; fails=$((fails+1)); fi; }
fact() { if [ "$2" = "$3" ]; then say "ok   $1"; else say "FAIL $1 (got $2, want $3)"; fails=$((fails+1)); fi; }
click() { geo; xdotool mousemove $((ox + $1)) $((oy + $2)); sleep 0.4; xdotool click ${3:-1}; sleep 2; }
nwin() { xdotool search --onlyvisible --name '.*' 2> /dev/null | wc -l; }
menu() { # menu <what> <action…>: a menu opens (a new visible window), then Escape closes it
	local n0 n1; n0=$(nwin); "${@:2}"; sleep 1.5; n1=$(nwin); import -window root "$out/menu-$(tr ' ' _ <<< "$1").png"
	if [ "$n1" -gt "$n0" ]; then say "ok   window menu: $1"; else say "FAIL window menu: $1 ($n0 -> $n1 windows)"; fails=$((fails+1)); fi
	xdotool key Escape; sleep 1; }
launch() { wine "$exe" > "$out/ghostty-$1.log" 2>&1 & pid=$!; for _ in $(seq 60); do sleep 1; wid=$(xdotool search --onlyvisible --name "Ghostty" 2> /dev/null | head -1); [ -n "$wid" ] && break; done; sleep 4; }
stop() { kill $pid 2> /dev/null; wineserver -k 2> /dev/null; sleep 2; }

launch one; geo
expect 255 15 client "the + right after the one tab"
expect 400 15 caption "after the +: caption"
expect $((W - 115)) 15 min "the minimize button's place"
expect $((W - 69)) 15 max "the maximize button's place"
expect $((W - 23)) 15 close "the close button's place"
menu "right-click on the caption" click 400 15 3
menu "right-click on a tab" click 100 15 3
menu "Alt+Space in the terminal" bash -c "xdotool windowfocus --sync $wid 2>/dev/null; xdotool key --clearmodifiers alt+space"
geo; menu "Shift+right-click in the terminal" bash -c "xdotool mousemove $((ox + 300)) $((oy + 200)); xdotool keydown shift; xdotool click 3; xdotool keyup shift"
xdotool windowfocus --sync "$wid" 2> /dev/null; xdotool key --clearmodifiers ctrl+Return; sleep 3
menu "right-click on the full screen tab bar" click 100 15 3
xdotool key --clearmodifiers ctrl+Return; sleep 5
geo; fact "out of full screen, not maximized" "$(field zoomed)" 0
click $((W - 69)) 15; fact "maximize button maximizes (a real click)" "$(field zoomed)" 1
geo; expect $((W - 69)) 15 max "maximized: the maximize button's place"
nc max; fact "maximized: the maximize button restores" "$(field zoomed)" 0
geo; click $((W - 69)) 15; fact "maximize again" "$(field zoomed)" 1
nc min; fact "maximized: the minimize button minimizes" "$(field iconic)" 1
stop
launch two; geo; click $((W - 115)) 15; fact "minimize button minimizes (a real click)" "$(field iconic)" 1; stop
launch three; geo; click $((W - 69)) 15; nc close
for _ in $(seq 15); do kill -0 $pid 2> /dev/null || break; sleep 1; done
if kill -0 $pid 2> /dev/null; then say "FAIL maximized: close button closes"; fails=$((fails+1)); stop; else say "ok   maximized: close button closes (ghostty.exe ended)"; fi
wineserver -k 2> /dev/null
[ $fails = 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
