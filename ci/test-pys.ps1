# test-pys.ps1 (lane B, 2026-11-24): pys (py-screen) inside Ghostty for Windows, through
# Ghostty's test-control pipe. pys forwards a background window's notifications (OSC 9 and
# 777;notify) and its progress (OSC 9;4) to the terminal it is attached from (FORWARD_NOTIFY,
# on by default), so Ghostty's tab and toast show what an agent in any pys window does.
#
#   pwsh -File ci/test-pys.ps1 -Zip <ghostty zip> [-Out pystest]
#
# Needs `pys` on PATH (the job installs it with uv). Two sessions, each with a PYS_DIR of its
# own, so no real pys is touched:
#   forward  Ghostty's tab runs `pys` (window 0, in front). `pys new` adds window 1 in the
#            back, titled "build", whose pwsh writes OSC 777;notify;T;hello, OSC 9;4;1;40 and a
#            BEL. Ghostty must get a notification "build: T" / "hello" (an event), and its
#            "list" must show progress 40 while window 1 lives. (A BEL is kept in pys by
#            design: it marks the window, so a Ghostty bell event is only reported.)
#   off      The same with PYS_CONFIG holding FORWARD_NOTIFY = False: no notification and no
#            progress may reach Ghostty.
# Prints "ok"/"FAIL"/"info" lines, writes <Out>\results.md and the job summary; every request
# and answer goes to <Out>\<case>\wire.log. Exit 1 when a check failed.
param(
	[Parameter(Mandatory)] [string] $Zip,
	[string] $Out = 'pystest'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$script:fails = 0
$script:lines = @()
function Say([string] $kind, [string] $text) {
	$l = "{0,-4} {1}" -f $kind, $text
	$l
	$script:lines += $l
	if ($kind -eq 'FAIL') { $script:fails++ }
}

$pys = (Get-Command pys -ErrorAction Stop).Source
Say 'info' "pys: $pys"
Expand-Archive -Path $Zip -DestinationPath (Join-Path $Out 'pkg') -Force
$ghostty = (Get-ChildItem (Join-Path $Out 'pkg') -Recurse -Filter ghostty.exe | Select-Object -First 1).FullName

# One request (a JSON object without "id") and its one-line answer.
$script:id = 0
function Ctl([string] $json) {
	$script:id++
	$req = '{"id":' + $script:id + ',' + $json.Substring(1)
	Add-Content $script:wire "> $req" -Encoding utf8
	$script:w.WriteLine($req)
	$a = $script:r.ReadLine()
	Add-Content $script:wire ("< " + $(if ($a.Length -gt 8000) { $a.Substring(0, 8000) } else { $a })) -Encoding utf8
	return $a
}

# Events since $script:since that contain every needle; the first such, or $null after $ms.
function Wait-Event([int] $ms, [string[]] $needles) {
	for ($t = 0; $t -lt $ms; $t += 250) {
		$a = Ctl ('{"cmd":"events","since":' + $script:since + '}')
		foreach ($m in [regex]::Matches($a, '\{"seq":.*?(?=,\{"seq":|\],"next":)')) {
			$e = $m.Value
			if (-not ($needles | Where-Object { -not $e.Contains($_) })) { return $e }
		}
		Start-Sleep -Milliseconds 250
	}
	return $null
}

function Pys([string[]] $argv) {
	$o = & $pys @argv 2>&1
	Add-Content $script:wire ("pys " + ($argv -join ' ') + " -> " + ($o -join ' | ')) -Encoding utf8
	return ($o -join "`n")
}

function Run-Case([string] $name, [bool] $forward) {
	$dir = Join-Path $Out $name
	New-Item -ItemType Directory -Force $dir | Out-Null
	$script:wire = Join-Path $dir 'wire.log'
	# The session: its own PYS_DIR (its pipes' names come from it), its own config.
	$env:PYS_DIR = Join-Path $dir 'pysdir'
	New-Item -ItemType Directory -Force $env:PYS_DIR | Out-Null
	$env:PYS_CONFIG = Join-Path $dir 'config.py'
	Set-Content $env:PYS_CONFIG $(if ($forward) { '# defaults: FORWARD_NOTIFY = True' } else { 'FORWARD_NOTIFY = False' }) -Encoding utf8
	$env:GHOSTTY_TEST_CONTROL = '1'
	$env:GHOSTTY_WHATSNEW = 'off'
	$env:GHOSTTY_LOG = 'stderr'
	$p = Start-Process -FilePath $ghostty -ArgumentList "`"--command=$pys`"" -PassThru `
		-RedirectStandardError (Join-Path $dir 'ghostty.log')
	$pipe = $null
	for ($i = 0; $i -lt 60 -and -not $pipe; $i++) {
		try {
			$c = [System.IO.Pipes.NamedPipeClientStream]::new('.', "ghostty-$($p.Id).ctl", [System.IO.Pipes.PipeDirection]::InOut)
			$c.Connect(500)
			$pipe = $c
		} catch { Start-Sleep -Milliseconds 500 }
	}
	if (-not $pipe) { Say 'FAIL' "${name}: Ghostty's test pipe never answered"; Stop-Process $p -Force -ErrorAction SilentlyContinue; return }
	$utf8 = [System.Text.UTF8Encoding]::new($false)
	$script:w = [System.IO.StreamWriter]::new($pipe, $utf8)
	$script:w.AutoFlush = $true
	$script:r = [System.IO.StreamReader]::new($pipe, $utf8)
	$script:since = 0
	try {
		# pys is up when its server answers "ls" and Ghostty's tab shows its status line.
		$ls = $null
		for ($i = 0; $i -lt 60; $i++) {
			$j = Pys @('ls', '--json')
			if ($j -match '"current"') { $ls = $j; break }
			Start-Sleep -Seconds 1
		}
		if (-not $ls) { Say 'FAIL' "${name}: pys started in Ghostty's tab never answered 'pys ls' (60 s)"; return }
		Say 'ok' "${name}: pys runs in Ghostty's tab, its server answers"
		$screen = Ctl '{"cmd":"read"}'
		if ($screen -match 'pys') { Say 'ok' "${name}: Ghostty's pane shows pys's screen" }
		else { Say 'info' "${name}: Ghostty's pane text has no 'pys': $($screen.Substring(0, [Math]::Min(300, $screen.Length)))" }
		$e0 = Ctl '{"cmd":"events","since":0}'
		if ($e0 -match '"next":(\d+)') { $script:since = [long]$Matches[1] }

		# Window 1, in the back: after 4 s a notification, progress 40 and a BEL; then it stays.
		$body = '$e=[char]27; Start-Sleep 4; [Console]::Write($e+'']777;notify;T;hello''+$e+''\''); ' +
			'[Console]::Write($e+'']9;4;1;40''+$e+''\''); [Console]::Write([char]7); Start-Sleep 60'
		Pys @('new', '--', 'pwsh', '-NoLogo', '-NoProfile', '-Command', $body) | Out-Null
		Pys @('title', '--wid', '1', 'build') | Out-Null
		$ls = Pys @('ls', '--json')
		$cur = if ($ls -match '"client_views":\s*\[\s*\{[^}]*"current":\s*(\d+)') { $Matches[1] } else { '?' }
		if ($cur -eq '1') { Pys @('select', '0') | Out-Null; Say 'info' "${name}: window 1 came to the front; selected 0 again" }
		else { Say 'info' "${name}: the Ghostty client's current window: $cur (window 1 in the back)" }

		$n = Wait-Event 15000 @('"kind":"notification"', 'hello')
		$pl = $null
		for ($i = 0; $i -lt 20; $i++) {
			$pl = Ctl '{"cmd":"list"}'
			if ($pl -match '"progress":\{[^}]*"value":40') { break }
			Start-Sleep -Milliseconds 250
		}
		$hasProgress = $pl -match '"progress":\{[^}]*"value":40'
		if ($forward) {
			if ($n -and $n.Contains('build')) { Say 'ok' "${name}: window 1's notification reached Ghostty: $n" }
			elseif ($n) { Say 'FAIL' "${name}: a notification came, but not titled after window 1 ('build'): $n" }
			else { Say 'FAIL' "${name}: no notification from pys's window 1 reached Ghostty in 15 s" }
			if ($hasProgress) { Say 'ok' "${name}: window 1's progress 40 shows in Ghostty's list" }
			else { Say 'FAIL' "${name}: no progress 40 in Ghostty's list: $($pl.Substring(0, [Math]::Min(400, $pl.Length)))" }
			if ($pl -match '"notifications":\{') { Say 'info' "${name}: list's notifications: $([regex]::Match($pl, '"notifications":\{[^}]*\}').Value)" }
		} else {
			if ($n) { Say 'FAIL' "${name}: FORWARD_NOTIFY = False, yet a notification reached Ghostty: $n" }
			else { Say 'ok' "${name}: FORWARD_NOTIFY = False: no notification reached Ghostty in 15 s" }
			if ($hasProgress) { Say 'FAIL' "${name}: FORWARD_NOTIFY = False, yet Ghostty shows progress 40" }
			else { Say 'ok' "${name}: FORWARD_NOTIFY = False: no progress in Ghostty" }
		}
		$b = Wait-Event 1000 @('"kind":"bell"')
		Say 'info' "${name}: Ghostty bell event: $(if ($b) { $b } else { 'none (pys keeps a bell: it marks the window)' })"
		$j = Pys @('ls', '--json')
		Say 'info' "${name}: pys ls: $(([regex]::Matches($j, '"progress":\s*(null|\[[^\]]*\])') | ForEach-Object Value) -join ', ')"
	} finally {
		Pys @('kill') | Out-Null
		Start-Sleep -Seconds 2
		$pipe.Dispose()
		if (-not $p.HasExited) { Stop-Process $p -Force -ErrorAction SilentlyContinue }
		Remove-Item Env:PYS_DIR, Env:PYS_CONFIG -ErrorAction SilentlyContinue
	}
}

Run-Case 'forward' $true
Run-Case 'off' $false

$md = @("### pys inside Ghostty ($(if ($script:fails) { "$($script:fails) failed" } else { 'passed' }))", '', '```') + $script:lines + '```'
$md | Set-Content (Join-Path $Out 'results.md') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) { $md | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($script:fails) { exit 1 }
exit 0
