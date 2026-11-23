# test-windows.ps1 (lane B, 2026-11-22): Ghostty for Windows on a real Windows machine, a GitHub
# runner (windows-11-arm, windows-latest): what Wine can't show.
#
#   pwsh -File ci/test-windows.ps1 -Zip <ghostty-...-windows-<arch>.zip> -Probes <dir> -Out <dir>
#        [-Mesa <dir with llvmpipe\ and d3d12\ opengl32.dll>]
#
# <Probes> holds glprobe.exe, conpty-probe.exe and emit.exe for this machine's architecture
# (ci/winprobe/*.c). Steps, each a line "ok|FAIL|info  <what>" in <Out>\results.md, also the job
# summary:
#   1. the machine: Windows build, architecture, the session (an interactive desktop or not),
#      Explorer and its taskbar, the screen, the display adapter, the OpenGL drivers registered
#   2. OpenGL: glprobe with the in-box opengl32.dll, then with each Mesa one beside it
#   3. ConPTY: conpty-probe in the four cases (in-box / side-loaded conpty.dll, flags 0 / 8)
#   4. Ghostty: start, a window, "loaded OpenGL", which ConPTY, pixels drawn (PrintWindow)
#      (with Mesa's llvmpipe opengl32.dll beside it when the in-box OpenGL is below 4.3)
#   5. typing: real keys (SendInput) run a command in the shell, which writes a file
#   6. the caption buttons of the maximized window: found by WM_NCHITTEST along the top edge,
#      then clicked with real mouse input (SendInput): maximize/restore, minimize, close
#   7. with -CompatPack, last: Microsoft's OpenCL/OpenGL/Vulkan Compatibility Pack by winget,
#      then glprobe again (the only step that installs something: for a throwaway runner)
# Otherwise nothing is installed; everything stays in <Out>. Exit 1 when a step marked FAIL.
param(
	[Parameter(Mandatory)] [string] $Zip,
	[Parameter(Mandatory)] [string] $Probes,
	[Parameter(Mandatory)] [string] $Out,
	[string] $Mesa = '',
	[switch] $CompatPack
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$results = Join-Path $Out 'results.md'
Set-Content -Path $results -Value "## Ghostty on real Windows ($env:RUNNER_NAME $env:ImageOS)`n" -Encoding utf8
$script:fails = 0
$script:t0 = Get-Date
function Say([string] $kind, [string] $what) {
	$line = '{0,-5} {1}' -f $kind, $what
	Write-Host $line
	Add-Content -Path $results -Value "    $line" -Encoding utf8
	if ($kind -eq 'FAIL') { $script:fails++ }
}
function Check([bool] $ok, [string] $what) { if ($ok) { Say 'ok' $what } else { Say 'FAIL' $what } }
function Section([string] $name) {
	$s = [int]((Get-Date) - $script:t0).TotalSeconds
	Add-Content -Path $results -Value "`n### $name (at ${s} s)`n" -Encoding utf8
	Write-Host "=== $name"
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class W {
	[DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
	[DllImport("user32.dll", SetLastError = true)] public static extern bool GetUserObjectInformationW(IntPtr h, int index, byte[] info, int len, out int needed);
	[DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint tid);
	[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string name);
	[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
	[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
	[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
	[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
	[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
	[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
	[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
	[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
	[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
	[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
	[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
	[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
	[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
	[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
	[DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
	[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
	public delegate bool EnumProc(IntPtr h, IntPtr l);
	[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
	[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
	[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
	[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
	[DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
	[DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
	[DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
	[DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
	[DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, uint rop);
	[StructLayout(LayoutKind.Sequential)] public struct BITMAPINFOHEADER {
		public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
		public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
	[DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bi, uint usage, out IntPtr bits, IntPtr sec, uint off);
	[DllImport("dwmapi.dll")] public static extern int DwmIsCompositionEnabled(out bool on);

	[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
	[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
	[StructLayout(LayoutKind.Explicit)] public struct INPUTU { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
	[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTU u; }
	[DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

	public static List<IntPtr> TopWindows(uint pid) {
		var list = new List<IntPtr>();
		EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
		return list;
	}
	public static List<IntPtr> OtherTopWindows(uint pid) {
		var list = new List<IntPtr>();
		EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid && IsWindowVisible(h) && Text(h).Length > 0) list.Add(h); return true; }, IntPtr.Zero);
		return list;
	}
	public static string Text(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }
	public static string Class(IntPtr h) { var s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }
	// The window station's WSF_VISIBLE flag: 1 on an interactive desktop (WinSta0 of a logged-on
	// session), 0 on a service's non-interactive one, where nothing reaches a screen.
	public static string Station() {
		IntPtr ws = GetProcessWindowStation();
		byte[] name = new byte[512]; int n;
		GetUserObjectInformationW(ws, 2 /* UOI_NAME */, name, name.Length, out n);
		byte[] flags = new byte[12];
		GetUserObjectInformationW(ws, 1 /* UOI_FLAGS */, flags, flags.Length, out n);
		int dwFlags = BitConverter.ToInt32(flags, 8);
		IntPtr desk = GetThreadDesktop(GetCurrentThreadId());
		byte[] dname = new byte[512];
		GetUserObjectInformationW(desk, 2, dname, dname.Length, out n);
		return Encoding.Unicode.GetString(name).TrimEnd('\0') + "\\" + Encoding.Unicode.GetString(dname).TrimEnd('\0') +
			", WSF_VISIBLE=" + (dwFlags & 1);
	}
	// What the window shows, by PrintWindow(PW_RENDERFULLCONTENT) into a 32-bit DIB: the number of
	// distinct colours and the share of pixels not the most common colour. A window that never
	// drew is one colour (black or white). Also an FNV hash, to see a change between two grabs.
	public static string Grab(IntPtr h, out ulong hash) {
		RECT r; GetWindowRect(h, out r);
		int w = r.R - r.L, ht = r.B - r.T; hash = 0;
		if (w <= 0 || ht <= 0) return "empty rect";
		IntPtr sdc = GetDC(IntPtr.Zero), mdc = CreateCompatibleDC(sdc);
		var bi = new BITMAPINFOHEADER { biSize = 40, biWidth = w, biHeight = -ht, biPlanes = 1, biBitCount = 32 };
		IntPtr bits; IntPtr bmp = CreateDIBSection(mdc, ref bi, 0, out bits, IntPtr.Zero, 0);
		IntPtr old = SelectObject(mdc, bmp);
		bool ok = PrintWindow(h, mdc, 2 /* PW_RENDERFULLCONTENT */);
		int[] px = new int[w * ht];
		Marshal.Copy(bits, px, 0, px.Length);
		SelectObject(mdc, old); DeleteObject(bmp); DeleteDC(mdc); ReleaseDC(IntPtr.Zero, sdc);
		var counts = new Dictionary<int, int>();
		ulong f = 1469598103934665603UL;
		foreach (int p in px) { int c = p & 0xFFFFFF; int k; counts.TryGetValue(c, out k); counts[c] = k + 1; f = (f ^ (uint)c) * 1099511628211UL; }
		hash = f;
		int top = 0; int topc = 0;
		foreach (var kv in counts) if (kv.Value > top) { top = kv.Value; topc = kv.Key; }
		return string.Format("PrintWindow {0}, {1}x{2}, {3} colours, {4:F1}% not the main colour #{5:X6}",
			ok ? "ok" : "FAILED", w, ht, counts.Count, 100.0 * (px.Length - top) / px.Length, topc);
	}
	public static int Colours(string grab) {
		var m = System.Text.RegularExpressions.Regex.Match(grab, @"(\d+) colours");
		return m.Success ? int.Parse(m.Groups[1].Value) : 0;
	}
	static INPUT Mouse(int x, int y, uint flags) {
		int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
		var i = new INPUT { type = 0 };
		i.u.mi.dx = (int)((x * 65535L + sw / 2) / (sw - 1));
		i.u.mi.dy = (int)((y * 65535L + sh / 2) / (sh - 1));
		i.u.mi.dwFlags = flags | 0x8000 /* ABSOLUTE */ | 0x0001 /* MOVE */;
		return i;
	}
	// A real left click at a screen point: move, down, up, through the input queue (SendInput).
	public static uint Click(int x, int y) {
		var a = new INPUT[] { Mouse(x, y, 0), Mouse(x, y, 0x0002 /* LEFTDOWN */), Mouse(x, y, 0x0004 /* LEFTUP */) };
		uint n = SendInput(1, new INPUT[] { a[0] }, Marshal.SizeOf(typeof(INPUT)));
		System.Threading.Thread.Sleep(150);
		n += SendInput(2, new INPUT[] { a[1], a[2] }, Marshal.SizeOf(typeof(INPUT)));
		return n;
	}
	// Real keys: each character as KEYEVENTF_UNICODE down and up, then Enter as a virtual key.
	public static uint Type(string text) {
		var list = new List<INPUT>();
		foreach (char c in text) {
			var d = new INPUT { type = 1 }; d.u.ki.wScan = c; d.u.ki.dwFlags = 0x0004 /* UNICODE */;
			var u = new INPUT { type = 1 }; u.u.ki.wScan = c; u.u.ki.dwFlags = 0x0004 | 0x0002 /* KEYUP */;
			list.Add(d); list.Add(u);
		}
		// Enter with its scan code too: a terminal reads the key from the scan code (run 1:
		// with wScan 0 the text arrived but the line was never entered).
		var ed = new INPUT { type = 1 }; ed.u.ki.wVk = 0x0D; ed.u.ki.wScan = 0x1C;
		var eu = new INPUT { type = 1 }; eu.u.ki.wVk = 0x0D; eu.u.ki.wScan = 0x1C; eu.u.ki.dwFlags = 0x0002;
		list.Add(ed); list.Add(eu);
		uint n = 0;
		foreach (var i in list) { n += SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT))); System.Threading.Thread.Sleep(15); }
		return n;
	}
	// Foreground, by the usual means a test driver has: the Alt-key trick (a key event lifts the
	// foreground lock), AttachThreadInput to the current foreground thread, then SetForegroundWindow.
	public static bool Front(IntPtr h) {
		var alt = new INPUT[] { new INPUT { type = 1 }, new INPUT { type = 1 } };
		alt[0].u.ki.wVk = 0x12; alt[1].u.ki.wVk = 0x12; alt[1].u.ki.dwFlags = 0x0002;
		SendInput(2, alt, Marshal.SizeOf(typeof(INPUT)));
		uint pid; uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
		uint me = GetCurrentThreadId();
		if (fg != 0 && fg != me) AttachThreadInput(me, fg, true);
		BringWindowToTop(h); SetForegroundWindow(h);
		if (fg != 0 && fg != me) AttachThreadInput(me, fg, false);
		System.Threading.Thread.Sleep(300);
		return GetForegroundWindow() == h;
	}
	// WM_NCHITTEST at a screen point: what the window says is there (HTCLIENT 1, HTCAPTION 2,
	// HTMINBUTTON 8, HTMAXBUTTON 9, HTCLOSE 20, HTTOP 12, ...).
	public static int Hit(IntPtr h, int x, int y) {
		return (int)SendMessageW(h, 0x0084, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF)));
	}
}
'@

function Run-Probe([string] $exe, [string[]] $a, [string] $outFile) {
	$sp = @{ FilePath = $exe; NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $outFile; RedirectStandardError = "$outFile.err" }
	if ($a.Count) { $sp.ArgumentList = $a }  # Start-Process refuses an empty -ArgumentList
	$p = Start-Process @sp
	if (-not $p.WaitForExit(60000)) { $p.Kill(); return 124 }
	return $p.ExitCode
}

# --- 1. the machine
Section '1. The machine'
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Say 'info' "Windows: $($cv.ProductName) $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR), OS $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture), this process $([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
$sess = (Get-Process -Id $PID).SessionId
$station = [W]::Station()
Say 'info' "session $sess, window station $station, UserInteractive $([Environment]::UserInteractive), user $env:USERNAME"
$q = (& query.exe session 2>&1 | Out-String).Trim() -replace "`r?`n", ' | '
Say 'info' "query session: $q"
$interactive = $station -match 'WSF_VISIBLE=1' -and $sess -ne 0
Check $interactive 'an interactive desktop (session not 0, a visible window station)'
$explorer = @(Get-Process explorer -ErrorAction SilentlyContinue)
$tray = [W]::FindWindowW('Shell_TrayWnd', $null)
Say 'info' "Explorer processes: $($explorer.Count), taskbar window (Shell_TrayWnd): $(if ($tray -ne [IntPtr]::Zero) { 'yes' } else { 'no' })"
$dwm = $false; [void][W]::DwmIsCompositionEnabled([ref] $dwm)
Say 'info' "screen $([W]::GetSystemMetrics(0))x$([W]::GetSystemMetrics(1)), DWM composition $dwm, dwm.exe running $(@(Get-Process dwm -ErrorAction SilentlyContinue).Count -gt 0)"
Get-CimInstance Win32_VideoController | ForEach-Object { Say 'info' "display adapter: $($_.Name), driver $($_.DriverVersion), $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" }
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\MSOGL') {
	if (Test-Path $k) { Say 'info' "registry $k : $((Get-ItemProperty $k | Out-String).Trim() -replace '\s+', ' ')" }
}
# The Compatibility Pack's package is Microsoft.D3DMappingLayers.
$appx = @(Get-AppxPackage -Name '*D3DMappingLayers*' -ErrorAction SilentlyContinue)
Say 'info' "Microsoft's OpenCL/OpenGL Compatibility Pack: $(if ($appx.Count) { $appx[0].Version } else { 'not installed' })"

# --- 2. OpenGL
Section '2. OpenGL (glprobe: Ghostty needs 4.3 core)'
$gl = @{}
$cases = @(@{ name = 'in-box'; dll = '' })
if ($Mesa) { foreach ($m in 'llvmpipe', 'd3d12') { if (Test-Path "$Mesa\$m\opengl32.dll") { $cases += @{ name = "Mesa $m"; dll = "$Mesa\$m" } } } }
# Mesa's d3d12 (GLon12, the engine of Microsoft's Compatibility Pack) once more on WARP, the
# software D3D12 device every Windows has (D3D12_DEBUG=warp), as on a VM with no D3D12 driver.
if ($Mesa -and (Test-Path "$Mesa\d3d12\opengl32.dll")) { $cases += @{ name = 'Mesa d3d12 on WARP'; dll = "$Mesa\d3d12"; env = 'warp' } }
foreach ($c in $cases) {
	$d = Join-Path $Out ("gl-" + ($c.name -replace '\W', ''))
	New-Item -ItemType Directory -Force $d | Out-Null
	Copy-Item "$Probes\glprobe.exe" $d
	if ($c.dll) { Copy-Item "$($c.dll)\*.dll" $d }
	if ($c.env) { $env:D3D12_DEBUG = $c.env }
	$rc = Run-Probe "$d\glprobe.exe" @() "$d\glprobe.txt"
	Remove-Item Env:D3D12_DEBUG -ErrorAction SilentlyContinue
	$txt = Get-Content "$d\glprobe.txt" -ErrorAction SilentlyContinue
	$gl[$c.name] = ($rc -eq 0)
	foreach ($l in $txt) { Say 'info' "$($c.name): $l" }
	Say $(if ($rc -eq 0) { 'ok' } else { 'info' }) "$($c.name): OpenGL 4.3 core $(if ($rc -eq 0) { 'yes' } else { "no (exit $rc)" })"
}

# --- 3. ConPTY
Section '3. ConPTY (conpty-probe: 25 sequences; PASS = passed through unchanged)'
$pkgRoot = Join-Path $Out 'pkg'
Expand-Archive -Path $Zip -DestinationPath $pkgRoot -Force
$exe = Get-ChildItem -Path $pkgRoot -Recurse -Filter ghostty.exe | Select-Object -First 1
$pkg = $exe.DirectoryName
Say 'info' "package: $(Split-Path $Zip -Leaf), files: $((Get-ChildItem $pkg -File | ForEach-Object Name) -join ', ')"
$haveSide = (Test-Path "$pkg\conpty.dll") -and (Test-Path "$pkg\OpenConsole.exe")
Check $haveSide 'the package has conpty.dll and OpenConsole.exe'
function Machine([string] $f) {  # the PE header's machine: what the file was built for
	$b = [System.IO.File]::ReadAllBytes($f)
	$pe = [BitConverter]::ToInt32($b, 0x3C)
	switch ([BitConverter]::ToUInt16($b, $pe + 4)) { 0x8664 { 'x64' } 0xAA64 { 'arm64' } 0x14C { 'x86' } default { 'other' } }
}
foreach ($f in 'ghostty.exe', 'conpty.dll', 'OpenConsole.exe') {
	if (Test-Path "$pkg\$f") { Say 'info' "$f : built for $(Machine "$pkg\$f"), file version $((Get-Item "$pkg\$f").VersionInfo.FileVersion)" }
}
Say 'info' "in-box conhost.exe $((Get-Item "$env:SystemRoot\System32\conhost.exe").VersionInfo.FileVersion)"
Copy-Item "$Probes\conpty-probe.exe" $pkg
foreach ($c in @(@{ n = 'inbox-0'; a = @() }, @{ n = 'inbox-8'; a = @('--flags', '8') },
		@{ n = 'sideload-0'; a = @('--dll', "$pkg\conpty.dll") }, @{ n = 'sideload-8'; a = @('--dll', "$pkg\conpty.dll", '--flags', '8') })) {
	if ($c.n -like 'sideload*' -and -not $haveSide) { continue }
	$f = Join-Path $Out "conpty-$($c.n).txt"
	$p = Start-Process -FilePath "$pkg\conpty-probe.exe" -ArgumentList ($c.a + @('--out', $f)) -NoNewWindow -PassThru -RedirectStandardOutput "$f.stdout"
	if (-not $p.WaitForExit(60000)) { $p.Kill(); Say 'FAIL' "conpty $($c.n): no exit in 60 s"; continue }
	$lines = @(Get-Content $f -ErrorAction SilentlyContinue)
	$pass = @($lines | Where-Object { $_ -match '^PASS' }).Count
	$all = @($lines | Where-Object { $_ -match '^(PASS|CHANGED|DROPPED)' }).Count
	Say 'info' "conpty $($c.n): $pass/$all PASS (exit $($p.ExitCode))"
	if ($c.n -eq 'sideload-0') { Check ($pass -ge 24) "side-loaded ConPTY passes at least 24 sequences unchanged, as on the owner's box ($pass/$all)" }
	$lines | Where-Object { $_ -match '^(CHANGED|DROPPED)' } | Select-Object -First 30 | ForEach-Object { Say 'info' "  $($c.n): $_" }
}
# OpenConsole.exe ends a moment after its pseudoconsole is closed: wait up to 5 s.
for ($i = 0; $i -lt 10; $i++) { $left = @(Get-Process OpenConsole -ErrorAction SilentlyContinue); if (-not $left.Count) { break }; Start-Sleep -Milliseconds 500 }
Check ($left.Count -eq 0) "no OpenConsole.exe left running 5 s after the probes ($($left.Count))"

# --- 4. Ghostty starts and draws
Section '4. Ghostty: start, window, OpenGL, drawing'
# The package brings Mesa in opengl\ when its source falls back to it (wgl.zig). Without it
# (an older build) and with the in-box OpenGL below 4.3, Mesa's llvmpipe is put there for the test.
if (Test-Path "$pkg\opengl\opengl32.dll") {
	Say 'info' "the package has Mesa's opengl\opengl32.dll ($(Machine "$pkg\opengl\opengl32.dll"), $((Get-Item "$pkg\opengl\opengl32.dll").Length) bytes)"
} elseif (-not $gl['in-box'] -and $gl['Mesa llvmpipe']) {
	Copy-Item "$Mesa\llvmpipe\opengl32.dll" $pkg
	Say 'info' "the in-box OpenGL is below 4.3 and the package has no opengl\: Mesa's llvmpipe opengl32.dll put beside ghostty.exe (an older build)"
}
Copy-Item "$Probes\emit.exe" $pkg
$log = Join-Path $Out 'ghostty.log'
$env:GHOSTTY_LOG = 'stderr'; $env:GHOSTTY_WHATSNEW = 'off'
$started = Get-Date
$g = Start-Process -FilePath $exe.FullName -WorkingDirectory $pkg -PassThru -RedirectStandardError $log -RedirectStandardOutput "$log.stdout"
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 60 -and $hwnd -eq [IntPtr]::Zero -and -not $g.HasExited; $i++) {
	Start-Sleep -Milliseconds 500
	$wins = [W]::TopWindows([uint32]$g.Id)
	if ($wins.Count) { $hwnd = $wins[0] }
}
Check ($hwnd -ne [IntPtr]::Zero) "a window within 30 s ($([int]((Get-Date) - $started).TotalMilliseconds) ms$(if ($g.HasExited) { ", the process exited $($g.ExitCode)" }))"
if ($hwnd -ne [IntPtr]::Zero) {
	Say 'info' "window class $([W]::Class($hwnd)), title '$([W]::Text($hwnd))'"
	Start-Sleep -Seconds 6
	$logText = Get-Content $log -Raw -ErrorAction SilentlyContinue
	$m = [regex]::Match("$logText", 'loaded OpenGL \d+\.\d+')
	Check $m.Success "the renderer loaded OpenGL ($(if ($m.Success) { $m.Value } else { 'no "loaded OpenGL" line' }))"
	$which = [regex]::Match("$logText", 'OpenGL: (the system.s|Mesa.s) opengl32\.dll[^\r\n]*')
	Say 'info' "which opengl32.dll: $(if ($which.Success) { $which.Value } else { 'not logged (a build without the fallback)' })"
	$cp = [regex]::Matches("$logText", 'conpty\): [^\r\n]*') | Select-Object -First 2 | ForEach-Object Value
	Say 'info' "ConPTY: $($cp -join ' / ')"
	$h1 = [uint64]0; $grab1 = [W]::Grab($hwnd, [ref] $h1)
	Say 'info' "after start: $grab1"
	Check ([W]::Colours($grab1) -ge 3) 'the window drew something (at least 3 colours: background, text, cursor)'

	# --- 5. typing
	Section '5. Typing: real keys run a command in the shell'
	# Windows of other programs that may hold the foreground: listed, and the runner image's
	# pop-ups closed (run 1 on windows-11-arm: a "Microsoft account" window took the keys
	# and the clicks).
	foreach ($o in [W]::OtherTopWindows([uint32]$g.Id)) {
		$pid2 = [uint32]0; [void][W]::GetWindowThreadProcessId($o, [ref] $pid2)
		$pn = (Get-Process -Id $pid2 -ErrorAction SilentlyContinue).ProcessName
		$t = [W]::Text($o)
		Say 'info' "another window: '$t' ($([W]::Class($o)), $pn)"
		if ($t -match '^(Microsoft account|Windows Security|Get started|Welcome)') {
			[void][W]::PostMessageW($o, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
			Say 'info' "  closed it (WM_CLOSE)"
		}
	}
	Start-Sleep -Seconds 1
	$fg = $false
	for ($i = 0; $i -lt 5 -and -not $fg; $i++) { $fg = [W]::Front($hwnd); if (-not $fg) { Start-Sleep -Milliseconds 500 } }
	Check $fg "Ghostty's window is the foreground window (foreground now: '$([W]::Text([W]::GetForegroundWindow()))')"
	$mark = Join-Path $Out 'typed.txt'
	$n = [W]::Type("echo typed-in-ghostty> $mark")
	Say 'info' "SendInput took $n of the key events"
	for ($i = 0; $i -lt 20 -and -not (Test-Path $mark); $i++) { Start-Sleep -Milliseconds 500 }
	Check ((Test-Path $mark) -and ((Get-Content $mark -Raw) -match 'typed-in-ghostty')) 'keys reached the shell through ConPTY: the command wrote its file'
	Start-Sleep -Seconds 1
	$h2 = [uint64]0; $grab2 = [W]::Grab($hwnd, [ref] $h2)
	Say 'info' "after typing: $grab2"
	Check ($h2 -ne $h1) 'the window changed after typing (it redraws)'

	# --- 6. caption buttons on the maximized window, real mouse input
	Section '6. Caption buttons of the maximized window (WM_NCHITTEST, then SendInput clicks)'
	[void][W]::ShowWindow($hwnd, 3)  # SW_MAXIMIZE
	Start-Sleep -Seconds 2
	$r = New-Object W+RECT; [void][W]::GetWindowRect($hwnd, [ref] $r)
	Say 'info' "maximized: $([W]::IsZoomed($hwnd)), window rect $($r.L),$($r.T) - $($r.R),$($r.B)"
	# Scan the top 60 px of the visible part, right to left, every 2 px, at a few heights.
	$found = @{}
	$y0 = [Math]::Max($r.T, 0)
	foreach ($dy in 2, 8, 14, 20, 26) {
		for ($x = [Math]::Min($r.R, [W]::GetSystemMetrics(0)) - 2; $x -gt $r.R - 400; $x -= 2) {
			$ht = [W]::Hit($hwnd, $x, $y0 + $dy)
			if ($ht -in 8, 9, 20) { if (-not $found[$ht]) { $found[$ht] = [System.Collections.ArrayList]@() }; [void]$found[$ht].Add(@($x, $y0 + $dy)) }
		}
	}
	$names = @{ 8 = 'minimize (HTMINBUTTON)'; 9 = 'maximize (HTMAXBUTTON)'; 20 = 'close (HTCLOSE)' }
	$centre = @{}
	foreach ($k in 8, 9, 20) {
		$pts = $found[$k]
		if ($pts) {
			$xs = $pts | ForEach-Object { $_[0] }; $ys = $pts | ForEach-Object { $_[1] }
			$centre[$k] = @([int](($xs | Measure-Object -Average).Average), [int](($ys | Measure-Object -Average).Average))
			Say 'ok' "$($names[$k]) found: x $(($xs | Measure-Object -Minimum).Minimum)-$(($xs | Measure-Object -Maximum).Maximum), y $(($ys | Measure-Object -Minimum).Minimum)-$(($ys | Measure-Object -Maximum).Maximum)"
		} else { Say 'FAIL' "$($names[$k]) not found by WM_NCHITTEST along the top edge" }
	}
	$row = (1..60 | ForEach-Object { [W]::Hit($hwnd, [Math]::Min($r.R, [W]::GetSystemMetrics(0)) - 20, $y0 + $_ - 1) }) -join ','
	Say 'info' "hit test going down, 20 px from the right edge (y $y0..$($y0 + 59)): $row"
	if ($centre[9]) {
		[void][W]::Front($hwnd)
		$n = [W]::Click($centre[9][0], $centre[9][1]); Start-Sleep -Seconds 2
		Check (-not [W]::IsZoomed($hwnd)) "a real click on maximize restores the window (SendInput $n/3, zoomed now $([W]::IsZoomed($hwnd)))"
		[void][W]::ShowWindow($hwnd, 3); Start-Sleep -Seconds 2
	}
	if ($centre[8]) {
		[void][W]::Front($hwnd)
		$n = [W]::Click($centre[8][0], $centre[8][1]); Start-Sleep -Seconds 2
		Check ([W]::IsIconic($hwnd)) "a real click on minimize minimizes it (SendInput $n/3)"
		[void][W]::ShowWindow($hwnd, 9); Start-Sleep -Seconds 2  # SW_RESTORE
		[void][W]::ShowWindow($hwnd, 3); Start-Sleep -Seconds 2
	}
	if ($centre[20]) {
		[void][W]::Front($hwnd)
		$n = [W]::Click($centre[20][0], $centre[20][1]); Start-Sleep -Seconds 3
		$gone = -not [W]::IsWindow($hwnd)
		$others = [W]::TopWindows([uint32]$g.Id) | ForEach-Object { "'$([W]::Text($_))' ($([W]::Class($_)))" }
		Check ($gone -or $others) "a real click on close closes the window or asks first (SendInput $n/3; window gone $gone; now: $($others -join ', '))"
	}
}
if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue }
Get-Process OpenConsole -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# --- 8. End to end through the test-control pipe (a build that has it: GHOSTTY_TEST_CONTROL)
Section '8. End to end (e2e.exe through the test-control pipe)'
$bytes = [System.IO.File]::ReadAllBytes($exe.FullName)
$hasPipe = ([System.Text.Encoding]::Unicode.GetString($bytes)).Contains('GHOSTTY_TEST_CONTROL') -or
	([System.Text.Encoding]::ASCII.GetString($bytes)).Contains('GHOSTTY_TEST_CONTROL')
if (-not $hasPipe -or -not (Test-Path "$Probes\e2e.exe")) {
	Say 'info' "not tried: $(if (-not $hasPipe) { 'this ghostty.exe has no test-control pipe' } else { 'no e2e.exe' })"
} else {
	Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
	$e2eOut = Join-Path $Out 'e2e'
	$p = Start-Process -FilePath "$Probes\e2e.exe" -ArgumentList @($exe.FullName, $e2eOut, "$pkg\emit.exe") -NoNewWindow -PassThru -RedirectStandardOutput "$Out\e2e.stdout"
	if (-not $p.WaitForExit(240000)) { $p.Kill(); Say 'FAIL' 'e2e: no exit in 240 s' }
	foreach ($l in @(Get-Content "$Out\e2e.stdout" -ErrorAction SilentlyContinue)) {
		if ($l -match '^(ok|FAIL|#)\s+(.*)$') { Say $(if ($Matches[1] -eq '#') { 'info' } else { $Matches[1] }) "e2e: $($Matches[2])" }
	}
	Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# --- 9. Fonts: which face Windows' own fonts give Ghostty for Chinese, Japanese and emoji
# (ci/fonts-test.sh, lane A's: types a line of Chinese, Japanese and emoji through the test pipe, reads the
# log's "found codepoint ... in fallback face=" lines and counts coloured pixels in a pane
# screenshot). Natively under Git Bash (RUN= : no Wine; --ctl, since MSYS rewrites a leading /);
# it needs a ghostty.exe whose --ctl takes the request from the wide command line. A
# measurement for now: its lines are info.
Section '9. Fonts (ci/fonts-test.sh: CJK and emoji with Windows'' own fonts)'
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $hasPipe -or -not $bash -or -not $py) {
	Say 'info' "not tried: $(if (-not $hasPipe) { 'no test-control pipe' } elseif (-not $bash) { 'no Git Bash' } else { 'no python' })"
} else {
	Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
	$fontsOut = Join-Path $Out 'fonts'
	$script = (Resolve-Path (Join-Path $PSScriptRoot 'fonts-test.sh')).Path -replace '\\', '/'
	$env:RUN = ''; $env:PY = 'python'; $env:PYTHONUTF8 = '1'
	$p = Start-Process -FilePath $bash -ArgumentList @($script, ($exe.FullName -replace '\\', '/'), ($fontsOut -replace '\\', '/')) -NoNewWindow -PassThru -RedirectStandardOutput "$Out\fonts.stdout" -RedirectStandardError "$Out\fonts.stderr"
	if (-not $p.WaitForExit(240000)) { $p.Kill(); Say 'info' 'fonts: no exit in 240 s' }
	Remove-Item Env:RUN, Env:PY -ErrorAction SilentlyContinue
	foreach ($l in @(Get-Content "$Out\fonts.stdout" -Encoding utf8 -ErrorAction SilentlyContinue)) { if ($l.Trim()) { Say 'info' "fonts: $l" } }
	Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# --- 7. Microsoft's Compatibility Pack (GL on D3D12), last: it changes the machine
if ($CompatPack) {
	Section "7. Microsoft's OpenCL, OpenGL and Vulkan Compatibility Pack (Store 9NQPSL29BFFF, by winget)"
	$wg = Get-Command winget -ErrorAction SilentlyContinue
	if (-not $wg) { Say 'info' 'no winget on this machine: not tried' } else {
		$t = Get-Date
		$o = (& winget install --id 9NQPSL29BFFF --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
		Say 'info' "winget exit $LASTEXITCODE in $([int]((Get-Date) - $t).TotalSeconds) s: $(($o -split "`r?`n" | Where-Object { $_ -match '\w' } | Select-Object -Last 3) -join ' | ')"
		$appx = @(Get-AppxPackage -Name '*D3DMappingLayers*' -ErrorAction SilentlyContinue)
		Say 'info' "Compatibility Pack now: $(if ($appx.Count) { "$($appx[0].Name) $($appx[0].Version)" } else { 'not installed' })"
		$d = Join-Path $Out 'gl-compatpack'
		New-Item -ItemType Directory -Force $d | Out-Null
		Copy-Item "$Probes\glprobe.exe" $d
		$rc = Run-Probe "$d\glprobe.exe" @() "$d\glprobe.txt"
		Get-Content "$d\glprobe.txt" -ErrorAction SilentlyContinue | ForEach-Object { Say 'info' "with the pack: $_" }
		Say 'info' "with the pack: OpenGL 4.3 core $(if ($rc -eq 0) { 'yes' } else { "no (exit $rc)" })"
	}
}

$logLines = @(Get-Content $log -ErrorAction SilentlyContinue)
Section "Ghostty's log (warnings, errors; $($logLines.Count) lines)"
$logLines | Where-Object { $_ -match 'warn|err|fail|OpenGL|opengl|conpty|glcheck' } | Select-Object -First 60 | ForEach-Object { Add-Content -Path $results -Value "    $_" -Encoding utf8 }

$secs = [int]((Get-Date) - $script:t0).TotalSeconds
Add-Content -Path $results -Value "`n**$(if ($script:fails) { "FAIL ($($script:fails))" } else { 'PASS' })** in $secs s" -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) { Get-Content $results -Raw | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($script:fails) { exit 1 }
