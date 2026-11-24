# agent A (the agents demo): a job with progress (OSC 9;4: a thin bar along its pane's top),
# then a bell (BEL: a bell before its tab's title while you look elsewhere).
$e = [char]27
'agent A: building'
foreach ($p in 0..100) {
	[Console]::Write("$e]9;4;1;$p$e\")
	if ($p -and $p % 25 -eq 0) { "  $p%" }
	Start-Sleep -Milliseconds 50
}
[Console]::Write("$e]9;4;0$e\")
'agent A: done, your turn'
[Console]::Write([char]7)
