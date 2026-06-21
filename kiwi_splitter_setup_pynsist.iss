; ============================================================
; Kiwi-Splitter — Inno Setup Script (para Pynsist)
; Gerado para usar com saida Pynsist
; Requer: Inno Setup 6+  (https://jrsoftware.org/isinfo.php)
; ============================================================

#define AppName      "Kiwi-Splitter"
#define AppVersion   "1.1.5"
#define AppPublisher "fgbkiwi"
#define AppExeName   "Kiwi-Splitter.exe"
#define SourceDir    "build_pynsist\Kiwi-Splitter"
#define IconFile     "kiwi-splitter.ico"

[Setup]
AppId={{E3A7F2C1-84BD-4D9A-B6F0-1C2D3E4F5A6C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/fgbkiwi/kiwi-splitter
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=dist_installer
OutputBaseFilename={#AppName}-Setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Toda a pasta build do Pynsist (Python + DLLs + apps)
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";                    Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#AppName}";            Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; \
  Description: "{cm:LaunchProgram,{#AppName}}"; \
  Flags: nowait postinstall skipifsilent
