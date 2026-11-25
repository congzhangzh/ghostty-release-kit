#!/usr/bin/env bash
# resize-prompt-test.v2.sh <exe> <share/ghostty dir> <out> [present] [integration] [command] (v2: RUN= runs it
# natively on Windows from Git Bash, as fonts-test.v3; a command, e.g. powershell.exe, for the shell;
# a pane screenshot after each step). v1: the owner's .6 report
# "after a split or a zoom, the line where the cursor is goes missing; the cursor stays where it was".
# cmd with Ghostty's shell integration (its PROMPT carries OSC 133;A … 133;B), a command typed but not
# run; then a split, a zoom, an unzoom and full screen: after each, the first pane's text must still hold
# the prompt and the typed command. integration=none is the control (no OSC 133 at all).
# Cause found (2026-11-24): the core clears the prompt + input rows on a resize unless the shell's
# 133;A says redraw=0 (Terminal.zig shell_redraws_prompt, default true, Screen.resize prompt_redraw);
# cmd and PowerShell never redraw on a resize (no SIGWINCH on Windows), so the rows stay blank.
set -u
exe=$1 res=$2 out=$3 mode=${4:-readback} integ=${5:-detect} shellcmd=${6:-}; mkdir -p "$out"; out=$(cd "$out" && pwd)
RUN=${RUN-wine} PY=${PY:-python3}
export GHOSTTY_PRESENT=$mode GHOSTTY_WHATSNEW=off GHOSTTY_BATCH=1 GHOSTTY_TEST_CONTROL=1 GHOSTTY_LOG=stderr
if [ "$RUN" = wine ]; then
	export WINEPREFIX=$out/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
	[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
	export GHOSTTY_RESOURCES_DIR=$(winepath -w "$res")
	cfg="$WINEPREFIX/drive_c/users/$USER/AppData/Local/ghostty"
else
	export GHOSTTY_RESOURCES_DIR=$(cygpath -w "$res")
	cfg="$(cygpath -u "$LOCALAPPDATA")/ghostty"
fi
mkdir -p "$cfg"
printf 'shell-integration = %s\n' "$integ" > "$cfg/config.ghostty"
[ -n "$shellcmd" ] && printf 'command = %s\n' "$shellcmd" >> "$cfg/config.ghostty"
printf '# t\nfullscreen_hint = seen\n' > "$cfg/host.ini"
fails=0
ctl() { timeout 30 $RUN "$exe" --ctl "$1" 2> /dev/null | tr -d '\r'; }
fact() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fails=$((fails+1)); fi; }
# Does pane 1's text still hold the typed command (wrapped lines joined)? 1 or 0.
held() { ctl '{"cmd":"read","pane":'"$p1"'}' > "$out/read-$1.json"; $PY -I -c "
import json,sys
t=json.load(open(sys.argv[1],encoding='utf-8')).get('text','').replace(chr(10),'')
print(int('echo keep-me-typed' in t))" "$out/read-$1.json"
	ctl '{"cmd":"screenshot","pane":'"$p1"',"target":"pane","format":"png"}' > "$out/shot-$1.json"; }
panes() { ctl '{"cmd":"list"}' | $PY -I -c "
import json,sys
r=json.load(sys.stdin); print(' '.join(str(p['pane']) for w in r['windows'] for t in w['tabs'] for p in t['panes']))"; }
$RUN "$exe" > "$out/ghostty.log" 2>&1 & pid=$!
for _ in $(seq 60); do sleep 1; ctl '{"cmd":"hello"}' | grep -q '"ok":true' && break; done; sleep 4
p1=$(panes | awk '{print $1}')
echo "#    integration injected: $(grep -c 'shell integration automatically injected' "$out/ghostty.log") (mode $mode, shell-integration $integ, command ${shellcmd:-default})"
ctl '{"cmd":"text","text":"echo keep-me-typed"}' > /dev/null
# Up to 10 s: a slow shell start (Windows PowerShell 5.1 on the Arm runner) shows the typed text late.
for _ in $(seq 10); do sleep 1; [ "$(held 1)" = 1 ] && break; done
fact "1. the typed command shows" "$(held 1)" 1
ctl '{"cmd":"action","action":"new_split:down","pane":'"$p1"'}' > /dev/null; sleep 4
fact "2. after a split down, the first pane keeps it" "$(held 2)" 1
ctl '{"cmd":"action","action":"toggle_split_zoom","pane":'"$p1"'}' > /dev/null; sleep 3
fact "3. after a zoom, it is still there" "$(held 3)" 1
ctl '{"cmd":"action","action":"toggle_split_zoom","pane":'"$p1"'}' > /dev/null; sleep 3
fact "4. after the unzoom, it is still there" "$(held 4)" 1
ctl '{"cmd":"window","state":"fullscreen"}' > /dev/null; sleep 3
fact "5. after full screen, it is still there" "$(held 5)" 1
kill $pid 2> /dev/null; [ "$RUN" = wine ] && wineserver -k 2> /dev/null
echo "fails=$fails"
[ "$fails" = 0 ]
