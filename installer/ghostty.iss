; ghostty.iss (lane B, 2026-11-23): the per-user installer of Ghostty for Windows, one per
; architecture, made by Inno Setup (6.7.4, pinned in the workflow) from the release's zip.
;
;   ISCC.exe /DVersion=<release tag> /DArch=x86_64|aarch64 /DSrc=<the zip's package folder>
;            /DOut=<output folder> installer\ghostty.iss
;
; Why Inno Setup, not WiX: a per-user install with no admin rights is its plain mode
; (PrivilegesRequired=lowest), a Start-menu shortcut takes an AppUserModelID in one line, Arm64
; is a first-class architecture, and it is one script for both; an MSI per user needs
; ALLUSERS/MSIINSTALLPERUSER care and WiX a .NET toolchain. The setup program itself is 32-bit
; x86: Windows 11 on Arm runs it by its x86 emulation; what it installs is native arm64.
;
; What it does, all per user (HKCU, %LOCALAPPDATA%), nothing for the machine:
;   - the zip's whole package in %LOCALAPPDATA%\Programs\Ghostty; an upgrade installs over it
;     (the same AppId), first emptying share\ and opengl\ so no file of an older release stays;
;   - Ghostty in the Start menu, with the AppUserModelID GhosttyForWindows.Ghostty: Windows
;     shows the app's own notifications (WinRT toasts) under that name;
;   - "Open Ghostty here" on a folder and a folder's background in Explorer;
;   - an entry in Settings > Apps (Apps & features), whose uninstaller removes all of the above.
;     It leaves the user's own files: the config and logs in %LOCALAPPDATA%\ghostty.
; Unsigned for now: SmartScreen shows "Windows protected your PC" (unknown publisher) on the
; first run of a downloaded setup; "More info" then "Run anyway" installs it.

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef Arch
  #define Arch "x86_64"
#endif
#ifndef Src
  #error Src: the folder with ghostty.exe (the release zip's package)
#endif
#ifndef Out
  #define Out "."
#endif
; The file version: numbers up to 65535 each, so 20261123.4 is given as 2026.11.23.4.
#ifndef FileVersion
  #define FileVersion "0.0.0.0"
#endif
#define AUMID "GhosttyForWindows.Ghostty"

[Setup]
; One AppId for both architectures: installing the other one replaces it.
AppId={{B571D04E-49C4-4A35-8733-ABF73170E79D}
AppName=Ghostty
AppVersion={#Version}
AppVerName=Ghostty {#Version} (unofficial Windows build)
AppPublisher=ghostty-release-kit (unofficial build)
AppPublisherURL=https://github.com/congzhangzh/ghostty-release-kit
AppSupportURL=https://github.com/congzhangzh/ghostty-release-kit/issues
AppUpdatesURL=https://github.com/congzhangzh/ghostty-release-kit/releases
AppComments=Ghostty, the terminal emulator, built for Windows. Not made by the Ghostty project.
VersionInfoVersion={#FileVersion}
VersionInfoProductTextVersion={#Version}
PrivilegesRequired=lowest
DefaultDirName={autopf}\Ghostty
DisableDirPage=auto
DisableProgramGroupPage=yes
DisableReadyPage=yes
UninstallDisplayName=Ghostty (unofficial Windows build)
UninstallDisplayIcon={app}\ghostty.exe
OutputDir={#Out}
OutputBaseFilename=ghostty-{#Version}-windows-{#Arch}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
; A running Ghostty is closed for an upgrade (the Restart Manager), not left holding files:
; force, as the macOS app's updater quits it to update. (Run 45189238400: with "yes", a silent
; upgrade over a running Ghostty stopped with exit code 5; Ghostty does not answer the Restart
; Manager's polite request on its own.)
CloseApplications=force
RestartApplications=no
#if Arch == "aarch64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[InstallDelete]
; An upgrade: the resources and Mesa of the release before go first.
Type: filesandordirs; Name: "{app}\share"
Type: filesandordirs; Name: "{app}\opengl"

[Files]
Source: "{#Src}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Ghostty"; Filename: "{app}\ghostty.exe"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#AUMID}"; Comment: "Ghostty terminal (unofficial Windows build)"

[Registry]
; "Open Ghostty here": a folder, and the empty space of an open folder. %V is the folder; the
; "\." after it keeps a drive root ("C:\") from ending in \" (which the command line would read
; as an escaped quote), and changes nothing else.
Root: HKCU; Subkey: "Software\Classes\Directory\shell\GhosttyHere"; ValueType: string; ValueName: ""; ValueData: "Open Ghostty here"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\GhosttyHere"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\ghostty.exe"""
Root: HKCU; Subkey: "Software\Classes\Directory\shell\GhosttyHere\command"; ValueType: string; ValueName: ""; ValueData: """{app}\ghostty.exe"" --working-directory=""%V\."""
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\GhosttyHere"; ValueType: string; ValueName: ""; ValueData: "Open Ghostty here"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\GhosttyHere"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\ghostty.exe"""
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\GhosttyHere\command"; ValueType: string; ValueName: ""; ValueData: """{app}\ghostty.exe"" --working-directory=""%V\."""
Root: HKCU; Subkey: "Software\Classes\Drive\shell\GhosttyHere"; ValueType: string; ValueName: ""; ValueData: "Open Ghostty here"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Drive\shell\GhosttyHere"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\ghostty.exe"""
Root: HKCU; Subkey: "Software\Classes\Drive\shell\GhosttyHere\command"; ValueType: string; ValueName: ""; ValueData: """{app}\ghostty.exe"" --working-directory=""%V\."""

[Run]
Filename: "{app}\ghostty.exe"; Description: "Start Ghostty"; Flags: nowait postinstall skipifsilent
