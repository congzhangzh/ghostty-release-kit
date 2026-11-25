# exit-poll-scan.ps1 (lane B, 2026-11-25): dot-sourced by the test scripts that decide PASS
# themselves (test-windows, test-installer, test-pys, test-batch, bench-throughput).
#
# Ghostty's exit poll (lane A, 20261125.1) closes a window whose shell is gone when Windows'
# job-object message about its end never came, and says so on stderr: "child process exit seen
# by the exit poll (the job object's message never came)", and in the stats as
# "exit_poll_catches": N. The poll is a safety net over a cause still being looked for, so a
# catch must show in the script's own results as a warning, never as a silent PASS. It is not a
# failure: the exit code stays what the checks made it. ci/exit-poll-flag.sh does the same for
# the job summary.
#
#   . "$PSScriptRoot/exit-poll-scan.ps1"
#   foreach ($w in Get-ExitPollHits $Out) { Say 'warn' $w }
#
# Looks at every log-like file under <dir> (*.log *.err *.stderr *.txt *.json, below 16 MB, not
# in an unpacked package), so it must run after the Ghosttys are done writing.
function Get-ExitPollHits([string] $dir) {
	if (-not (Test-Path $dir)) { return @() }
	$root = (Resolve-Path $dir).Path
	$files = @(Get-ChildItem $root -Recurse -File -Include *.log, *.err, *.stderr, *.txt, *.json -ErrorAction SilentlyContinue |
		Where-Object { $_.Length -lt 16MB -and $_.FullName -notmatch '[\\/]pkg[\\/]' })
	$hits = @()
	foreach ($m in @($files | Select-String -SimpleMatch 'child process exit seen by the exit poll' -ErrorAction SilentlyContinue)) {
		$hits += "exit poll caught a shell exit Windows did not report (the job object's message never came): $($m.Path.Substring($root.Length).TrimStart('\', '/')):$($m.LineNumber)"
	}
	foreach ($m in @($files | Select-String -Pattern '"?exit_poll_catches"?\s*[:=]\s*([1-9][0-9]*)' -ErrorAction SilentlyContinue)) {
		$hits += "exit poll stats: exit_poll_catches $($m.Matches[0].Groups[1].Value) in $($m.Path.Substring($root.Length).TrimStart('\', '/')):$($m.LineNumber)"
	}
	return $hits
}
