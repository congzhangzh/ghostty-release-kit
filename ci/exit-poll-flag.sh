#!/usr/bin/env bash
# Flags (never fails) a run where Ghostty's exit poll had to close a window: the core saw its
# shell gone only through the poll, because Windows' job-object message never came. That is a
# safety net over a cause still being looked for, so a catch must be seen, not pass silently.
#
#   ci/exit-poll-flag.sh <results dir> <label>
#
# Looks in every file under the dir for the stderr line ("child process exit seen by the exit
# poll") and for a stats count above 0 ("exit_poll_catches": N). Prints a ::warning:: per hit
# and a summary line (to $GITHUB_STEP_SUMMARY when set); exit 0 either way.
set -uo pipefail
dir=${1:?usage: exit-poll-flag.sh <results dir> <label>} label=${2:-$1}
[ -d "$dir" ] || { echo "exit-poll-flag: no $dir"; exit 0; }
# Not in binaries: the line is a string literal in ghostty.exe itself, and test-windows.ps1,
# test-pys.ps1 and bench-throughput.ps1 unpack the package under their results dir (<dir>/pkg),
# so a plain grep -r -a would flag every run of a build that has the poll.
skip=(--exclude-dir=pkg --exclude='*.exe' --exclude='*.dll' --exclude='*.pdb' --exclude='*.zip'
	--exclude='*.png' --exclude='*.bmp' --exclude='*.gif' --exclude='*.mp4')
lines=$(grep -r -a -l -F "${skip[@]}" 'child process exit seen by the exit poll' "$dir" 2> /dev/null || true)
counts=$(grep -r -a -o -E "${skip[@]}" '"?exit_poll_catches"?[[:space:]]*[:=][[:space:]]*[1-9][0-9]*' "$dir" 2> /dev/null || true)
n=$(printf '%s\n' "$lines" | grep -c . || true)
if [ -z "$lines$counts" ]; then
	msg="exit poll: no catch in $label"
else
	msg="⚠️ exit poll CAUGHT a shell exit Windows did not report in $label: $n file(s) with the stderr line${counts:+; stats: $(printf '%s' "$counts" | tr '\n' ' ')}"
	while IFS= read -r f; do [ -n "$f" ] && echo "::warning file=$f::exit poll caught a shell exit (the job object's message never came)"; done <<< "$lines"
	while IFS= read -r c; do [ -n "$c" ] && echo "::warning::exit poll stats: $c"; done <<< "$counts"
fi
echo "$msg"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '\n%s\n' "$msg" >> "$GITHUB_STEP_SUMMARY"
exit 0
