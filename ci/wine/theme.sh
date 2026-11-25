#!/usr/bin/env bash
# Prove ghostty.exe finds its resources dir (share/) under Wine:
#
#   ci/wine/theme.sh <package dir: ghostty.exe [+ share/]> <out dir> ["<theme>" <expected bg RRGGBB>]
#
# (default theme: Dracula, background 282a36). Writes %LOCALAPPDATA%\ghostty\config.ghostty with
# `theme = <theme>`, starts ghostty.exe, takes a screenshot of its window and reads the colour of
# a background pixel (the bottom-right corner of the terminal area). PASS when that pixel is the
# theme's background, the log says "found Ghostty resources dir" and does not say "no resources
# dir set" or "not found". Run inside xvfb-run. Writes <out>/test.log, <out>/window.png, <out>/ghostty.log.
set -u
export GHOSTTY_WHATSNEW=off GHOSTTY_BATCH=1 # What's new opens once after an upgrade, and every prefix here is new
pkg=$1 out=$2 theme=${3:-Dracula} want=${4:-282a36}; want=${want,,}
mkdir -p "$out"
out=$(cd "$out" && pwd)
pkg=$(cd "$pkg" && pwd)
log=$out/test.log
: > "$log"
export WINEPREFIX=$out/wineprefix WINEDEBUG=${WINEDEBUG:-err+all,fixme-all} WINEDLLOVERRIDES="mscoree,mshtml="
export GHOSTTY_LOG=stderr
say() { echo "$*" | tee -a "$log"; }
cleanup() { [ -n "${pid:-}" ] && kill "$pid" 2> /dev/null; wineserver -k 2> /dev/null; }
fail() { say "FAIL $*"; cleanup; exit 1; }

[ -n "${DISPLAY:-}" ] || { echo "theme-test: no DISPLAY; run it inside xvfb-run" >&2; exit 2; }
[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
lad=$(wine cmd /c echo %LOCALAPPDATA% 2> /dev/null | tr -d '\r')
cfgdir=$(winepath -u "$lad\\ghostty" 2> /dev/null)
mkdir -p "$cfgdir"
printf 'theme = %s\nwindow-padding-x = 0\nwindow-padding-y = 0\n' "$theme" > "$cfgdir/config.ghostty"
say "# package $(basename "$pkg"); share/: $([ -d "$pkg/share" ] && echo yes || echo no)"
say "# config $lad\\ghostty\\config.ghostty: theme = $theme (want background #$want)"

(cd "$pkg" && wine ./ghostty.exe > "$out/ghostty.log" 2>&1) &
pid=$!
wid=
for _ in $(seq 1 60); do
	sleep 1
	wid=$(xdotool search --onlyvisible --class "ghostty" 2> /dev/null | head -1)
	[ -n "$wid" ] || wid=$(xdotool search --onlyvisible --name "Ghostty|cmd|\\\\" 2> /dev/null | head -1)
	[ -n "$wid" ] && break
	kill -0 "$pid" 2> /dev/null || fail "ghostty.exe exited before a window appeared (log: ghostty.log)"
done
[ -n "$wid" ] || fail "no window after 60s"
sleep 8
import -window "$wid" "$out/window.png"
geo=$(identify -format "%w %h" "$out/window.png")
read -r w h <<< "$geo"
# 20 px in from the bottom-right corner: inside the terminal, away from the prompt and title bar.
got=$(convert "$out/window.png" -format "%[hex:p{$((w - 20)),$((h - 20))}]" info: | cut -c1-6 | tr 'A-F' 'a-f')
say "#    window ${w}x$h, background pixel #$got"
cleanup
pid=

ok=1
if grep -q "found Ghostty resources dir" "$out/ghostty.log"; then
	say "ok   log: $(grep -o 'found Ghostty resources dir: .*' "$out/ghostty.log" | head -1)"
else
	say "FAIL log: no \"found Ghostty resources dir\""; ok=0
fi
if grep -q "no resources dir set" "$out/ghostty.log"; then say "FAIL log: \"no resources dir set\""; ok=0; else say "ok   log: no \"no resources dir set\""; fi
if grep -q "not found, tried path" "$out/ghostty.log"; then say "FAIL log: $(grep -o 'theme .*not found.*' "$out/ghostty.log" | head -1)"; ok=0; else say "ok   log: no \"theme not found\""; fi
if [ "$got" = "$want" ]; then say "ok   colour: background is the theme's #$want"; else say "FAIL colour: background #$got, want #$want"; ok=0; fi
[ $ok = 1 ] && say PASS || { say FAIL; exit 1; }
