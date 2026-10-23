; Per-user, self-contained Windows setup for the SyncPlay canary build.
; /DBuildRevision=<commit> is supplied by GitHub Actions.
#ifndef BuildRevision
  #define BuildRevision "local"
#endif

[Setup]
AppId={{62927B1B-E55D-4CA0-8E76-60B2C92F702B}
AppName=Kazumi SyncPlay Canary
AppVersion=2.3.9
AppVerName=Kazumi SyncPlay Canary 2.3.9 ({#BuildRevision})
AppPublisher=Kazumi Community
DefaultDirName={localappdata}\Programs\Kazumi SyncPlay Canary
DefaultGroupName=Kazumi SyncPlay Canary
UninstallDisplayIcon={app}\kazumi.exe
OutputDir=..\..\build\windows\installer
OutputBaseFilename=Kazumi_SyncPlay_{#BuildRevision}_Windows_Setup
SetupIconFile=..\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kazumi SyncPlay Canary"; Filename: "{app}\kazumi.exe"
Name: "{autodesktop}\Kazumi SyncPlay Canary"; Filename: "{app}\kazumi.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\kazumi.exe"; Description: "Launch Kazumi SyncPlay Canary"; Flags: nowait postinstall skipifsilent
