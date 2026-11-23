# bench-throughput.ps1 (lane B, 2026-11-23): how fast terminals on this machine take a program's
# output: catbench.exe writes a <SizeMB> MB file of coloured text lines (64 KB writes) and
# times it, in Ghostty, in Windows' own console (conhost) and in Windows Terminal when the
# machine has it. A trend line for CI, not a claim: a runner has no GPU (Ghostty draws with
# Mesa's software OpenGL there), and its CPU is shared. The real numbers come from a real box.
#
#   pwsh -File ci/bench-throughput.ps1 -Zip <ghostty zip> -Probes <dir with catbench.exe> [-Out <dir>]
#        [-SizeMB 50] [-Runs 3]
#
# Writes <Out>\bench.json (one record per terminal: MB/s per run and the median) and a table
# into the job summary. Never fails on speed; exit 1 only when no terminal could be measured.
param(
	[Parameter(Mandatory)] [string] $Zip,
	[Parameter(Mandatory)] [string] $Probes,
	[string] $Out = 'bench',
	[int] $SizeMB = 50,
	[int] $Runs = 3
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Probes = (Resolve-Path $Probes).Path
$cat = Join-Path $Probes 'catbench.exe'

# The data: numbered lines in seven colours and words, CRLF, like a busy build log.
$data = Join-Path $Out 'data.txt'
$words = 'the quick brown fox jumps over the lazy dog 0123456789 ghostty terminal build compile link test'.Split(' ')
$sb = [System.Text.StringBuilder]::new($SizeMB * 1MB + 4096)
$rand = [System.Random]::new(1)
$e = [char]27
for ($i = 0; $sb.Length -lt $SizeMB * 1MB; $i++) {
	[void]$sb.Append("$e[$(31 + $i % 7)m$($i.ToString().PadLeft(8))$e[0m")
	for ($k = 0; $k -lt 12; $k++) { [void]$sb.Append(' ').Append($words[$rand.Next($words.Length)]) }
	[void]$sb.Append("`r`n")
}
[IO.File]::WriteAllText($data, $sb.ToString(), [Text.UTF8Encoding]::new($false))
$bytes = (Get-Item $data).Length
"data: $bytes bytes"

$pkgRoot = Join-Path $Out 'pkg'
Expand-Archive -Path $Zip -DestinationPath $pkgRoot -Force
$ghostty = (Get-ChildItem $pkgRoot -Recurse -Filter ghostty.exe | Select-Object -First 1).FullName

function Wait-Result([string] $result, [int] $seconds) {
	for ($i = 0; $i -lt $seconds * 2; $i++) {
		if ((Test-Path $result) -and (Get-Content $result -Raw -ErrorAction SilentlyContinue)) { return (Get-Content $result -Raw).Trim() }
		Start-Sleep -Milliseconds 500
	}
	return $null
}

# One run in one terminal: returns MB/s, or $null.
function Run-One([string] $name, [int] $run) {
	$result = Join-Path $Out "$name-$run.txt"
	Remove-Item $result -ErrorAction SilentlyContinue
	$before = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object Id)
	switch ($name) {
		'ghostty' {
			$env:GHOSTTY_WHATSNEW = 'off'
			# One argument: Start-Process joins its list unquoted, so "--command=a b c" must carry its
			# own quotes or Ghostty gets --command=a and two stray arguments (run 45204591235: no
			# Ghostty result on either arch, catbench ran without its file).
			$p = Start-Process -FilePath $ghostty -ArgumentList "`"--command=$cat $data $result`"" -PassThru
		}
		'conhost' { $p = Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -ArgumentList "`"$cat`" `"$data`" `"$result`"" -PassThru }
		'windows-terminal' { $p = Start-Process -FilePath 'wt.exe' -ArgumentList "-w new `"$cat`" `"$data`" `"$result`"" -PassThru }
	}
	$r = Wait-Result $result 300
	# Close what this run started (Windows Terminal leaves its window open).
	Start-Sleep -Seconds 1
	Get-Process -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id -and $_.ProcessName -match '^(ghostty|conhost|WindowsTerminal|OpenConsole|catbench)$' } |
		Stop-Process -Force -ErrorAction SilentlyContinue
	if (-not $r) {
		"  $name run ${run}: no result in 300 s"
		if ($name -eq 'ghostty') { "  (Ghostty's command line: --command=$cat $data $result)" }
		return $null
	}
	$f = $r.Split(' ')
	$mbs = [math]::Round(([double]$f[0] / 1e6) / ([double]$f[1] / 1000), 1)
	"  $name run ${run}: $($f[0]) bytes in $($f[1]) ms = $mbs MB/s"
	return $mbs
}

$terms = @('ghostty', 'conhost')
if (Get-Command wt.exe -ErrorAction SilentlyContinue) { $terms += 'windows-terminal' } else { 'Windows Terminal: not on this machine' }
$records = @()
foreach ($t in $terms) {
	$speeds = @()
	for ($run = 1; $run -le $Runs; $run++) {
		$o = Run-One $t $run
		$o | Where-Object { $_ -is [string] } | ForEach-Object { $_ }
		$v = $o | Where-Object { $_ -is [double] } | Select-Object -Last 1
		if ($null -ne $v) { $speeds += $v }
	}
	$sorted = @($speeds | Sort-Object)
	$median = if ($sorted.Count) { $sorted[[int][math]::Floor($sorted.Count / 2)] } else { $null }
	$records += [ordered]@{ terminal = $t; runs = $speeds; median_mb_s = $median }
}
$meta = [ordered]@{
	machine = "$env:ImageOS $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
	cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
	size_bytes = $bytes
	ghostty = (Split-Path $Zip -Leaf)
	run = $env:GITHUB_RUN_ID
	results = $records
}
$meta | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Out 'bench.json') -Encoding utf8
$table = @("| terminal | MB/s (median of $Runs) | runs |", '|---|---|---|')
foreach ($r in $records) { $table += "| $($r.terminal) | $($r.median_mb_s) | $($r.runs -join ', ') |" }
$table
if ($env:GITHUB_STEP_SUMMARY) {
	"### Throughput: $SizeMB MB of coloured lines, $($meta.machine) ($($meta.cpu))`n" | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
	$table | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
	"`nA trend, not a claim: no GPU here (Ghostty draws with Mesa's software OpenGL), shared CPU." | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
if (-not ($records | Where-Object { $null -ne $_.median_mb_s })) { exit 1 }
exit 0
