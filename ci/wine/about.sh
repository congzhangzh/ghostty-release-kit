#!/usr/bin/env bash
# About, What's new and the motto under Wine (X11 Decorated=N, GHOSTTY_TITLEBAR=tabs for the title bar):
#
#   ci/wine/about.sh <ghostty.exe> <out dir>
#
# Run it inside xvfb-run. It unsets GHOSTTY_WHATSNEW (step 1 needs the default) and turns it off
# only where a step says so:
#   1. a fresh profile: What's new opens by itself (when the build has notes)
#   2. the next start: it doesn't
#   3. GHOSTTY_WHATSNEW=off: it doesn't
#   4. the window menu's About (WM_SYSCOMMAND 0x1010) and What's new (0x1020) open their boxes,
#      posted by sendcmd.exe ($WINE_HELPERS, default ci/wine/bin; build-helpers.sh)
#   5. the motto: a shot with it and one with GHOSTTY_SLOGAN=false (compare the bar's right part)
# Writes <out dir>/test.log and the screenshots; runs every step, exits 1 if any failed.
set -u
exe=$1 out=$2; mkdir -p "$out"; out=$(cd "$out" && pwd); here=$(cd "$(dirname "$0")" && pwd)
unset GHOSTTY_WHATSNEW # step 1 needs the default: What's new opens in a fresh profile
sendcmd=${WINE_HELPERS:-$here/bin}/sendcmd.exe
log=$out/test.log; : > "$log"
say() { echo "$*" | tee -a "$log"; }
[ -f "$sendcmd" ] || { say "FAIL no $sendcmd: run build-helpers.sh"; exit 1; }
export WINEPREFIX=$out/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" GHOSTTY_TITLEBAR=tabs
[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
wine reg add "HKCU\\Software\\Wine\\X11 Driver" /v Decorated /t REG_SZ /d N /f > /dev/null 2>&1
fails=0
box() { xdotool search --name "$1" 2> /dev/null | head -1; }
launch() { wine "$exe" > "$out/ghostty-$1.log" 2>&1 & pid=$!; for _ in $(seq 40); do sleep 1; [ -n "$(box 'Ghostty|What.s new')" ] && break; done; sleep 4; }
stop() { kill $pid 2> /dev/null; wineserver -k 2> /dev/null; sleep 2; }
check() { if [ "$2" = "$3" ]; then say "ok   $1"; else say "FAIL $1 (got '$2', want '$3')"; fails=$((fails+1)); fi; }
has() { [ -n "$(box "$1")" ] && echo yes || echo no; }

launch first; import -window root "$out/1-first.png"
check "1. a fresh profile: What's new opens by itself" "$(has "What's new in Ghostty")" yes
w=$(box "What's new in Ghostty"); [ -n "$w" ] && { xdotool windowfocus "$w" 2> /dev/null; xdotool key Return; sleep 1; }
stop
launch second; check "2. the next start: What's new stays closed" "$(has "What's new in Ghostty")" no; stop
rm -f "$WINEPREFIX"/drive_c/users/*/AppData/Local/ghostty/whatsnew-seen.txt
GHOSTTY_WHATSNEW=off launch off; check "3. GHOSTTY_WHATSNEW=off: closed in a fresh profile" "$(has "What's new in Ghostty")" no
wine "$sendcmd" 0x1010 > /dev/null 2>&1; sleep 2; import -window root "$out/4-about.png"
check "4a. window menu: About opens" "$(has 'About Ghostty for Windows')" yes
w=$(box 'About Ghostty for Windows'); [ -n "$w" ] && { xdotool windowfocus "$w" 2> /dev/null; xdotool key Return; sleep 1; }
wine "$sendcmd" 0x1020 > /dev/null 2>&1; sleep 2
check "4b. window menu: What's new opens" "$(has "What's new in Ghostty")" yes
w=$(box "What's new in Ghostty"); [ -n "$w" ] && { xdotool windowfocus "$w" 2> /dev/null; xdotool key Return; sleep 1; }
sleep 1; import -window root "$out/5-motto.png"; stop
GHOSTTY_WHATSNEW=off GHOSTTY_SLOGAN=false launch noslogan; import -window root "$out/6-no-motto.png"; stop
convert "$out/5-motto.png" -crop 560x30+270+0 +repage "$out/5-bar.png"; convert "$out/6-no-motto.png" -crop 560x30+270+0 +repage "$out/6-bar.png"
d=$(compare -metric AE "$out/5-bar.png" "$out/6-bar.png" null: 2>&1 | cut -d' ' -f1)
[ "${d%%.*}" -gt 100 ] 2> /dev/null && say "ok   5. the motto shows in the bar ($d pixels differ without it)" || { say "FAIL 5. no motto difference ($d)"; fails=$((fails+1)); }
[ $fails = 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
