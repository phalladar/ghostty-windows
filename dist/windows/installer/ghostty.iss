#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<staged ghostty folder containing bin\ and share\>
#endif
#ifndef OutputDir
  #define OutputDir "..\out"
#endif
#ifndef Arch
  #define Arch "x86_64"
#endif

#define AppName "Ghostty"
#define AppExe "ghostty.exe"
#define AppUserModelID "com.mitchellh.ghostty"

[Setup]
AppId={{6B3C1E0A-5F7D-4C43-9E0B-2B1D8A7F4C21}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Ghostty for Windows contributors
AppPublisherURL=https://github.com/phalladar/ghostty-windows
AppSupportURL=https://github.com/phalladar/ghostty-windows/issues
AppUpdatesURL=https://github.com/phalladar/ghostty-windows/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
LicenseFile={#SourceDir}\LICENSE
SetupIconFile={#SourcePath}\..\ghostty.ico
UninstallDisplayIcon={app}\bin\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename=ghostty-{#AppVersion}-windows-{#Arch}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "contextmenu"; Description: "Add ""Open Ghostty here"" to the folder context menu"; GroupDescription: "Explorer integration:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\share\*"; DestDir: "{app}\share"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README-windows.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD-PARTY-NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{app}\bin\conpty.dll"
Type: files; Name: "{app}\bin\OpenConsole.exe"
Type: filesandordirs; Name: "{app}\share\ghostty"
Type: filesandordirs; Name: "{app}\share\terminfo"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\bin\{#AppExe}"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#AppUserModelID}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\bin\{#AppExe}"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#AppUserModelID}"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Ghostty"; ValueType: string; ValueName: ""; ValueData: "Open Ghostty here"; Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Ghostty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\{#AppExe}"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Ghostty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\{#AppExe}"" ""--working-directory=%V\."""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Ghostty"; ValueType: string; ValueName: ""; ValueData: "Open Ghostty here"; Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\Ghostty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\{#AppExe}"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Ghostty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\{#AppExe}"" ""--working-directory=%V\."""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Drive\shell\Ghostty"; ValueType: string; ValueName: ""; ValueData: "Open Ghostty here"; Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Drive\shell\Ghostty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\{#AppExe}"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Drive\shell\Ghostty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\{#AppExe}"" ""--working-directory=%V\."""; Tasks: contextmenu

[Run]
Filename: "{app}\bin\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{%USERPROFILE}"; Flags: nowait postinstall skipifsilent
