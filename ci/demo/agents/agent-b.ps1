# agent B (the agents demo): failing tests (OSC 9;4 error: the bar turns red).
$e = [char]27
'agent B: running the tests'
Start-Sleep -Milliseconds 700
[Console]::Write("$e]9;4;2;60$e\")
'agent B: 3 tests failing'
