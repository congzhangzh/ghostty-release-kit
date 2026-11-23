# test-installer.ps1 (lane B, 2026-11-23): Ghostty's per-user installer on a real Windows runner:
# install silently, check what it made, start ghostty.exe, install over it (an upgrade in place),
# uninstall silently, check that nothing of it is left.
#
#   pwsh -File ci/test-installer.ps1 -Setup <ghostty-...-setup.exe> [-Out <dir>]
#
# "ok|FAIL|info  <what>" lines, also into the job summary; exit 1 on a FAIL.
param([Parameter(Mandatory)] [string] $Setup, [string] $Out = 'installer-test')
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Setup = (Resolve-Path $Setup).Path
$fails = 0
$lines = [System.Collections.Generic.List[string]]::new()
function Say([string] $kind, [string] $what) { $l = '{0,-5} {1}' -f $kind, $what; Write-Host $l; $lines.Add($l) }
function Check([bool] $ok, [string] $what) { if ($ok) { Say 'ok' $what } else { Say 'FAIL' $what; $script:fails++ } }

$app = Join-Path $env:LOCALAPPDATA 'Programs\Ghostty'
$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B571D04E-49C4-4A35-8733-ABF73170E79D}_is1'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Ghostty.lnk'
$menus = 'HKCU:\Software\Classes\Directory\shell\GhosttyHere', 'HKCU:\Software\Classes\Directory\Background\shell\GhosttyHere', 'HKCU:\Software\Classes\Drive\shell\GhosttyHere'
$aumid = 'GhosttyForWindows.Ghostty'

function Install([string] $log) {
	$t = Get-Date
	$p = Start-Process -FilePath $Setup -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', "/LOG=$log") -PassThru -Wait
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

# 3. an upgrade in place: the same setup again, while Ghostty runs
$g = Start-Process -FilePath "$app\ghostty.exe" -PassThru
Start-Sleep -Seconds 4
$r = Install "$Out\upgrade.log"
Check ($r[0] -eq 0) "install again over it, Ghostty running: exit $($r[0]) in $($r[1]) s"
Check (Test-Path "$app\ghostty.exe") "  ghostty.exe still there after the upgrade"
if (-not $g.HasExited) { Say 'info' "  the running Ghostty was not closed by setup (pid $($g.Id)); stopped now"; Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue }
else { Say 'info' "  the running Ghostty was closed by setup (Restart Manager)" }
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
