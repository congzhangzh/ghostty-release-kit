#!/usr/bin/env bash
# Run every Wine test on one unpacked Ghostty for Windows x86_64 package:
#
#   ci/wine/run-all.sh <package dir: ghostty.exe + share/ + conpty.dll + OpenConsole.exe> <out dir> <build tag>
#
# <build tag> is the build statsipc.sh expects in /stats (e.g. 20261122.10, as in BUILDINFO.txt).
# Builds the helpers first (build-helpers.sh into <out>/helpers, unless WINE_HELPERS already
# names a directory with them), then runs ci/test-wine.sh and each test in ci/wine/, each in its
# own `xvfb-run -a -s "-screen 0 1280x800x24"` and its own Wine prefix, one after the other:
#   test-wine  window, typing through ConPTY, drawing, exit (ci/test-wine.sh)
#   tabs       new tab, switching, the + button, Alt+N, closing tabs
#   theme      the resources dir is found: a theme's background is drawn
#   statsipc   the stats pipe and `ghostty.exe /stats`, with a stuck reader and with it off
#   shell      the default shell: cmd.exe, or pwsh.exe on PATH or in Program Files
#   titlebar   the caption buttons (hit tests, clicks, maximized) and the window menu
#   conpty     in-box ConPTY vs the side-loaded conpty.dll + OpenConsole.exe (runs test-wine 4 times)
#   notify     desktop notifications and taskbar progress from OSC 9 / 777
#   about      What's new on a fresh profile, About and What's new from the window menu, the motto
# Goes on past a failure. Writes <out>/<test>/ (the test's test.log, logs, screenshots),
# <out>/<test>.out (its whole output) and <out>/summary.md (test | result | seconds | last line);
# exits 1 if any test failed. WINE_TEST_TIMEOUT (default 600 s) ends a test that hangs.
#
# Needs: wine, wineboot, winepath, wineserver (WineHQ's winehq-stable), xvfb-run (xvfb, xauth),
# xdotool, imagemagick (import, convert, compare, identify), python3, zig (ZIG=<path>, for the
# helpers), coreutils' timeout; glxinfo (mesa-utils) is optional, only logged; Mesa's
# llvmpipe (libgl1-mesa-dri) gives the OpenGL the renderer draws with.
set -u
pkg=${1:?usage: run-all.sh <package dir> <out dir> <build tag>} out=${2:?out dir} tag=${3:?build tag}
pkg=$(cd "$pkg" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
ci=$(cd "$here/.." && pwd)
exe=$pkg/ghostty.exe
[ -f "$exe" ] || { echo "run-all.sh: no ghostty.exe in $pkg" >&2; exit 2; }

missing=
for t in wine wineboot winepath wineserver xvfb-run xdotool import convert compare identify python3 timeout; do
	command -v "$t" > /dev/null || missing="$missing $t"
done
[ -n "$missing" ] && { echo "run-all.sh: missing:$missing" >&2; exit 2; }

if [ -z "${WINE_HELPERS:-}" ]; then
	WINE_HELPERS=$out/helpers
	bash "$here/build-helpers.sh" "$WINE_HELPERS" > "$out/build-helpers.log" 2>&1 || {
		cat "$out/build-helpers.log" >&2
		echo "run-all.sh: building the helpers failed" >&2
		exit 2
	}
fi
export WINE_HELPERS
# What's new opens once after an upgrade when the build has notes, in every fresh prefix: it would
# take the typing. Off for every test; about.sh unsets it itself, as it tests that box.
export GHOSTTY_WHATSNEW=off GHOSTTY_BATCH=1

summary=$out/summary.md
results=()
total=0 failed=0
run() { # run <name> <script> <args...>
	local name=$1 t0 t1 rc secs last result
	shift
	echo "== $name"
	t0=$(date +%s)
	timeout -k 10 "${WINE_TEST_TIMEOUT:-600}" xvfb-run -a -s "-screen 0 1280x800x24" bash "$@" > "$out/$name.out" 2>&1
	rc=$?
	t1=$(date +%s)
	secs=$((t1 - t0))
	total=$((total + secs))
	# a test that timed out or crashed may leave its wineserver behind
	WINEPREFIX=$out/$name/wineprefix wineserver -k 2> /dev/null
	last=$(tr -d '\r' < "$out/$name.out" | sed '/^[[:space:]]*$/d' | tail -1)
	[ $rc = 124 ] && last="timed out after ${WINE_TEST_TIMEOUT:-600} s; $last"
	if [ $rc = 0 ] && [ "$last" = PASS ]; then result=PASS; else result="FAIL (exit $rc)"; failed=$((failed + 1)); fi
	echo "   $result in ${secs}s: $last"
	results+=("| $name | $result | $secs | $(sed 's/|/\\|/g; s/`/'"'"'/g' <<< "${last:0:200}") |")
}

run test-wine "$ci/test-wine.sh" "$exe" "$out/test-wine"
run tabs "$here/tabs.sh" "$exe" "$out/tabs"
run theme "$here/theme.sh" "$pkg" "$out/theme"
run statsipc "$here/statsipc.sh" "$exe" "$out/statsipc" "$tag"
run shell "$here/shell.sh" "$pkg" "$out/shell"
run titlebar "$here/titlebar.sh" "$exe" "$out/titlebar"
run conpty "$here/conpty.sh" "$pkg" "$out/conpty"
run notify "$here/notify.sh" "$exe" "$out/notify"
run about "$here/about.sh" "$exe" "$out/about"

{
	echo "**Wine tests** on \`$(basename "$pkg")\` ($(wine --version 2> /dev/null)), build tag \`$tag\`: $((${#results[@]} - failed)) of ${#results[@]} passed"
	echo
	echo "| test | result | seconds | last line |"
	echo "|---|---|---:|---|"
	printf '%s\n' "${results[@]}"
	echo "| **total** | $failed failed | $total | |"
} > "$summary"
cat "$summary"
[ $failed = 0 ]
