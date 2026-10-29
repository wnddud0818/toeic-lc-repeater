#define AppVersion "0.2.1"
[Setup]
AppId={{77BB87F2-7E68-49BD-B1B8-DF5229983C89}
AppName=LC Repeater
AppVersion={#AppVersion}
AppPublisher=LC Repeater
DefaultDirName={localappdata}\Programs\LC Repeater
DefaultGroupName=LC Repeater
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
OutputDir=..\dist
OutputBaseFilename=LC-Repeater-Setup-x64
SetupIconFile=..\build\AppIcon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\LC Repeater.exe
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\dist\LC Repeater\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\build\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\LC Repeater"; Filename: "{app}\LC Repeater.exe"
Name: "{autodesktop}\LC Repeater"; Filename: "{app}\LC Repeater.exe"; Tasks: desktopicon

[Run]
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 Runtime..."; Flags: waituntilterminated; Check: NeedsWebView2
Filename: "{app}\LC Repeater.exe"; Description: "Launch LC Repeater"; Flags: nowait postinstall skipifsilent; Check: HasWebView2

[Code]
function HasWebView2: Boolean;
var
  Version: String;
  Key: String;
begin
  Key := 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  Result := (RegQueryStringValue(HKLM32, Key, 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0')) or
            (RegQueryStringValue(HKCU, Key, 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0'));
end;

function NeedsWebView2: Boolean;
begin
  Result := not HasWebView2;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssDone) and NeedsWebView2 then
    MsgBox('Microsoft Edge WebView2 Runtime is required. Connect to the internet and run this installer again, or install WebView2 from https://developer.microsoft.com/microsoft-edge/webview2/.', mbInformation, MB_OK);
end;
