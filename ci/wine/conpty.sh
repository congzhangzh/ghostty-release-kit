#!/usr/bin/env bash
# The side-loaded ConPTY's choices under Wine:
#
#   ci/wine/conpty.sh <package dir: ghostty.exe [+ share/ + conpty.dll + OpenConsole.exe]> <out dir>
#
# Each case copies the package to its own folder, shaped for the case, and runs ci/test-wine.sh
# on it (window, typing through ConPTY, drawing, exit), then checks ghostty.log:
#   nodll     no conpty.dll: the in-box ConPTY, "no conpty.dll beside ghostty.exe"
#   noconsole conpty.dll without OpenConsole.exe: in-box, "OpenConsole.exe is not"
#   inbox     both files and GHOSTTY_CONPTY=inbox: in-box, "(GHOSTTY_CONPTY=inbox)"
#   fallback  both files: the side-loaded one is chosen (file version logged), fails under Wine
#             (its console driver lacks what OpenConsole.exe needs) and the in-box one takes over
# Run inside xvfb-run. Writes <out>/test.log; runs every case, exits 1 if any failed.
set -u
export GHOSTTY_WHATSNEW=off # What's new opens once after an upgrade, and every prefix here is new
pkg=$(cd "$1" && pwd) out=$2
mkdir -p "$out"
out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
testwine=${TESTWINE:-$here/../test-wine.sh}
log=$out/test.log
: > "$log"
say() { echo "$*" | tee -a "$log"; }
fails=0
[ -f "$pkg/conpty.dll" ] && [ -f "$pkg/OpenConsole.exe" ] || { say "FAIL $pkg needs conpty.dll and OpenConsole.exe"; exit 1; }

check() { # check <case> <what> <grep pattern>
	if grep -q -- "$3" "$out/$1/test/ghostty.log"; then say "ok   $1: $2"; else say "FAIL $1: $2 (no \"$3\" in its ghostty.log)"; fails=$((fails + 1)); fi
}

for c in nodll noconsole inbox fallback; do
	d=$out/$c/pkg
	mkdir -p "$d"
	cp -r "$pkg/." "$d/"
	case $c in
	nodll) rm -f "$d/conpty.dll" "$d/OpenConsole.exe" ;;
	noconsole) rm -f "$d/OpenConsole.exe" ;;
	esac
	if [ $c = inbox ]; then export GHOSTTY_CONPTY=inbox; else unset GHOSTTY_CONPTY; fi
	bash "$testwine" "$d/ghostty.exe" "$out/$c/test" > "$out/$c/test-wine.out" 2>&1
	rc=$?
	if [ $rc = 0 ]; then say "ok   $c: test-wine PASS ($(grep -c '^ok' "$out/$c/test/test.log") checks)"; else
		say "FAIL $c: test-wine exit $rc: $(grep FAIL "$out/$c/test/test.log" | head -1)"
		fails=$((fails + 1))
	fi
	case $c in
	nodll) check nodll "in-box, no conpty.dll" "using the in-box ConPTY (no conpty.dll beside ghostty.exe)" ;;
	noconsole) check noconsole "in-box, OpenConsole.exe missing" "conpty.dll is there but OpenConsole.exe is not" ;;
	inbox) check inbox "in-box, by GHOSTTY_CONPTY=inbox" "using the in-box ConPTY (GHOSTTY_CONPTY=inbox)" ;;
	fallback)
		check fallback "the side-loaded one chosen, with its file version" "using the side-loaded ConPTY .*conpty.dll (file version 1\."
		check fallback "its failure logged, the in-box one used" "side-loaded ConPTY failed to create a pseudoconsole (HRESULT 0x"
		;;
	esac
	say "#    $c: $(grep -o 'conpty): .*' "$out/$c/test/ghostty.log" | head -2 | tr '\n' ' ')"
done
unset GHOSTTY_CONPTY
[ $fails = 0 ] && say PASS || { say "FAIL ($fails)"; exit 1; }
