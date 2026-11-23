# test-installer.ps1 (lane B, 2026-11-23): Ghostty's per-user installer on a real Windows runner:
# install silently, check what it made, start ghostty.exe, install over it (an upgrade in place),
# uninstall silently, check that nothing of it is left.
#
#   pwsh -File ci/test-installer.ps1 -Setup <ghostty-...-setup.exe> [-Out <dir>] [-Probes <dir>]
#
# With -Probes (e2e.exe and emit.exe of this architecture) the installed Ghostty also runs the
# end-to-end test: installed, it takes the shortcut's AppUserModelID, so its notifications are
# WinRT toasts; its log must say so.
#
# "ok|FAIL|info  <what>" lines, also into the job summary; exit 1 on a FAIL.
param([Parameter(Mandatory)] [string] $Setup, [string] $Out = 'installer-test', [string] $Probes = '')
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Setup = (Resolve-Path $Setup).Path
# Absolute: e2e.exe types emit.exe's path into Ghostty's shell, which runs in another folder
# (run 45193109073: a relative probes\x86_64\emit.exe was never found, so no notification came).
if ($Probes) { $Probes = (Resolve-Path $Probes).Path }
$fails = 0
$lines = [System.Collections.Generic.List[string]]::new()
function Say([string] $kind, [string] $what) { $l = '{0,-5} {1}' -f $kind, $what; Write-Host $l; $lines.Add($l) }
function Check([bool] $ok, [string] $what) { if ($ok) { Say 'ok' $what } else { Say 'FAIL' $what; $script:fails++ } }

$app = Join-Path $env:LOCALAPPDATA 'Programs\Ghostty'
$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B571D04E-49C4-4A35-8733-ABF73170E79D}_is1'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Ghostty.lnk'
$menus = 'HKCU:\Software\Classes\Directory\shell\GhosttyHere', 'HKCU:\Software\Classes\Directory\Background\shell\GhosttyHere', 'HKCU:\Software\Classes\Drive\shell\GhosttyHere'
$aumid = 'GhosttyForWindows.Ghostty'

function Install([string] $log, [string[]] $more = @()) {
	$t = Get-Date
	$p = Start-Process -FilePath $Setup -ArgumentList (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$log") + $more) -PassThru -Wait
	return @($p.ExitCode, [int]((Get-Date) - $t).TotalSeconds)
}

Say 'info' "setup: $(Split-Path $Setup -Leaf), $((Get-Item $Setup).Length) bytes, signed: $((Get-AuthenticodeSignature $Setup).Status)"
Check (-not (Test-Path $app)) "nothing installed before ($app)"

# 1. install
$r = Install "$Out\install.log"
Check ($r[0] -eq 0) "silent install: exit $($r[0]) in $($r[1]) s (no admin: per user)"
Check (Test-Path "$app\ghostty.exe") "ghostty.exe in $app"
foreach ($f in 'conpty.dll', 'OpenConsole.exe', 'opengl\opengl32.dll', 'share\terminfo', 'THIRD-PARTY-NOTICES.txt') {
	if (Test-Path "$app\$f") { Say 'ok' "  $f" } else { Say 'info' "  $f not there (not in this zip?)" }
}
$u = Get-ItemProperty $uninstKey -ErrorAction SilentlyContinue
Check ($null -ne $u) "an Apps & features entry: '$($u.DisplayName)' $($u.DisplayVersion), by '$($u.Publisher)'"
Check (Test-Path $lnk) "the Start-menu shortcut ($lnk)"
if (Test-Path $lnk) {
	# The AppUserModelID is stored in the .lnk as UTF-16 text (its property store).
	$bytes = [IO.File]::ReadAllBytes($lnk)
	$has = [Text.Encoding]::Unicode.GetString($bytes).Contains($aumid) -or [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1).Contains($aumid)
	Check $has "the shortcut carries the AppUserModelID $aumid"
	$target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
	Check ($target -eq "$app\ghostty.exe") "the shortcut starts $target"
}
foreach ($m in $menus) {
	$cmd = (Get-ItemProperty "$m\command" -ErrorAction SilentlyContinue).'(default)'
	Check ([bool]$cmd -and $cmd.Contains("$app\ghostty.exe") -and $cmd.Contains('--working-directory=')) "'Open Ghostty here': $($m.Split('\')[-3..-1] -join '\') = $cmd"
}

# 2. it runs
$p = Start-Process -FilePath "$app\ghostty.exe" -ArgumentList '/buildinfo' -RedirectStandardOutput "$Out\buildinfo.txt" -NoNewWindow -PassThru -Wait
$bi = Get-Content "$Out\buildinfo.txt" -Raw -ErrorAction SilentlyContinue
Check ($bi -match 'version: ') "the installed ghostty.exe /buildinfo: $((($bi -split "`r?`n") | Where-Object { $_ -match '^(version|release):' }) -join '; ')"

# 2b. installed, notifications are toasts: e2e.exe against the installed ghostty.exe (a
# notification from a split's unfocused pane is shown), then its log
if ($Probes -and (Test-Path "$Probes\e2e.exe")) {
	$e2eOut = Join-Path $Out 'e2e'
	$p = Start-Process -FilePath "$Probes\e2e.exe" -ArgumentList @("$app\ghostty.exe", $e2eOut, "$Probes\emit.exe") -NoNewWindow -PassThru -RedirectStandardOutput "$Out\e2e.stdout"
	if (-not $p.WaitForExit(240000)) { $p.Kill(); Say 'FAIL' 'e2e: no exit in 240 s' }
	Get-Content "$Out\e2e.stdout" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(ok|FAIL)\s' } | ForEach-Object { if ($_ -match '^FAIL') { Say 'FAIL' "e2e: $($_.Substring(5))"; $script:fails++ } else { Say 'ok' "e2e: $($_.Substring(5))" } }
	$log = Get-Content "$e2eOut\ghostty.log" -ErrorAction SilentlyContinue
	$init = $log | Where-Object { $_ -match 'notify: AppUserModelID' } | Select-Object -First 1
	Check ($init -match ': toasts$') "installed, Ghostty takes the AppUserModelID and a toast notifier: $init"
	$shown = $log | Where-Object { $_ -match 'notify: toast ' } | Select-Object -First 1
	Check ($shown -match 'toast shown') "a notification is a WinRT toast: $shown"
	Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
} else { Say 'info' 'no -Probes: the toast check is not run' }

# 2c. "Open Ghostty here" on a folder with a Chinese name: the menu's own command with %V
# filled in. The core reads the UTF-16 command line (lane A), so the shell must start there.
$cn = [string][char]0x9879 + [char]0x76EE  # a two-character Chinese word ("project")
$dir = Join-Path $env:TEMP "ghostty-open-here-$cn"
New-Item -ItemType Directory -Force $dir | Out-Null
$menu = (Get-ItemProperty 'HKCU:\Software\Classes\Directory\shell\GhosttyHere\command' -ErrorAction SilentlyContinue).'(default)'
if ($menu -match '^"([^"]+)" (.*)$') {
	$args2 = $Matches[2].Replace('%V', $dir)
	$env:GHOSTTY_TEST_CONTROL = '1'
	$g = Start-Process -FilePath $Matches[1] -ArgumentList $args2 -PassThru
	$text = ''
	[Console]::OutputEncoding = [Text.Encoding]::UTF8
	for ($i = 0; $i -lt 30 -and $text -notmatch [regex]::Escape($cn); $i++) {
		Start-Sleep -Seconds 1
		$text = (& "$app\ghostty.exe" --ctl $g.Id '{"cmd":"read"}' 2>$null | Out-String)
	}
	Remove-Item Env:GHOSTTY_TEST_CONTROL -ErrorAction SilentlyContinue
	Check ($text -match [regex]::Escape($cn)) "'Open Ghostty here' on a Chinese-named folder: the shell starts in it ($args2)"
	Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue
} else { Check $false "the folder menu's command: $menu" }
Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# 3. an upgrade over a running Ghostty (the PO's rule: closing it ends its shells, so a silent
# setup never does that unless told to)
# 3a. silent, not told: it refuses (exit 5, the log line), closes nothing, changes nothing
$g = Start-Process -FilePath "$app\ghostty.exe" -PassThru
Start-Sleep -Seconds 4
$before = (Get-FileHash "$app\ghostty.exe").Hash + (Get-Item "$app\ghostty.exe").LastWriteTimeUtc.Ticks
$r = Install "$Out\upgrade-refused.log"
$logText = Get-Content "$Out\upgrade-refused.log" -Raw -ErrorAction SilentlyContinue
Check ($r[0] -eq 5) "silent upgrade over a running Ghostty refuses: exit $($r[0]) (5: setup cannot proceed)"
Check ($logText -match 'Ghostty is running; close it or pass /FORCECLOSEAPPLICATIONS') "  its log says: Ghostty is running; close it or pass /FORCECLOSEAPPLICATIONS"
Check (-not $g.HasExited) "  the running Ghostty was left running"
$after = (Get-FileHash "$app\ghostty.exe").Hash + (Get-Item "$app\ghostty.exe").LastWriteTimeUtc.Ticks
Check ($before -eq $after) "  nothing changed: ghostty.exe is the same file"
# 3b. silent, told to (/FORCECLOSEAPPLICATIONS): it closes Ghostty and installs
$r = Install "$Out\upgrade-forced.log" @('/FORCECLOSEAPPLICATIONS')
Check ($r[0] -eq 0) "silent upgrade with /FORCECLOSEAPPLICATIONS: exit $($r[0]) in $($r[1]) s"
Start-Sleep -Seconds 1
Check $g.HasExited "  setup closed the running Ghostty"
Check (Test-Path "$app\ghostty.exe") "  ghostty.exe there after the upgrade"
Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process OpenConsole -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$app*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# 4. uninstall: the entry's own uninstaller, silently. unins000.exe copies itself to %TEMP%
# and runs from there, so wait for the folder and the entry to go.
$u = Get-ItemProperty $uninstKey -ErrorAction SilentlyContinue
$cmd = $u.UninstallString
Say 'info' "uninstall: $cmd"
if ($cmd) {
	$exe = $cmd.Trim('"')
	$t = Get-Date
	$p = Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$Out\uninstall.log") -PassThru -Wait
	for ($i = 0; $i -lt 60 -and ((Test-Path $app) -or (Test-Path $uninstKey)); $i++) { Start-Sleep -Milliseconds 500 }
	Say 'info' "uninstaller exit $($p.ExitCode), done in $([int]((Get-Date) - $t).TotalSeconds) s"
}
Check (-not (Test-Path $app)) "nothing left in $app$(if (Test-Path $app) { ': ' + ((Get-ChildItem $app -Recurse | Select-Object -First 5 | ForEach-Object Name) -join ', ') })"
Check (-not (Test-Path $uninstKey)) "the Apps & features entry is gone"
Check (-not (Test-Path $lnk)) "the Start-menu shortcut is gone"
foreach ($m in $menus) { Check (-not (Test-Path $m)) "'Open Ghostty here' is gone: $($m.Split('\')[-3..-1] -join '\')" }

$lines.Add(''); $lines.Add($(if ($fails) { "FAIL ($fails)" } else { 'PASS' }))
if ($env:GITHUB_STEP_SUMMARY) {
	"### Installer: $(Split-Path $Setup -Leaf) on $env:ImageOS`n" | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
	'```' | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
	$lines | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
	'```' | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
if ($fails) { exit 1 }
