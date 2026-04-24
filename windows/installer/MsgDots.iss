#define MyAppName "消息点点"
#define MyAppExeName "MsgDots.exe"
#define MyAppPublisher "MsgDots"
#define MyAppVersion GetEnv("MSGDOTS_VERSION")
#define MySourceDir GetEnv("MSGDOTS_SOURCE_DIR")
#define MyOutputDir GetEnv("MSGDOTS_OUTPUT_DIR")
#define MyIconFile GetEnv("MSGDOTS_ICON_FILE")

[Setup]
AppId={{8D1E1D6E-ED18-4937-9E0A-9C7964FD7B17}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\MsgDots
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename=MsgDots-{#MyAppVersion}-win-x64-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
SetupIconFile={#MyIconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
const
  DotNetDesktopDownloadUrl = 'https://dotnet.microsoft.com/download/dotnet/8.0/runtime';

function IsDotNet8DesktopRuntimeInstalled(): Boolean;
var
  Subkeys: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if RegGetSubkeyNames(HKLM64, 'SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App', Subkeys) then
  begin
    for I := 0 to GetArrayLength(Subkeys) - 1 do
    begin
      if Pos('8.', Subkeys[I]) = 1 then
      begin
        Result := True;
        Exit;
      end;
    end;
  end;
end;

function InitializeSetup(): Boolean;
var
  ErrorCode: Integer;
begin
  Result := True;
  if not IsDotNet8DesktopRuntimeInstalled() then
  begin
    MsgBox(
      '消息点点 Windows 版需要 Microsoft .NET 8 Desktop Runtime x64。' + #13#10#13#10 +
      '当前电脑未检测到该运行时。安装程序将打开官方下载页面，请先安装 ".NET Desktop Runtime"，然后重新运行本安装程序。',
      mbInformation,
      MB_OK
    );
    ShellExec('open', DotNetDesktopDownloadUrl, '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
    Result := False;
  end;
end;
