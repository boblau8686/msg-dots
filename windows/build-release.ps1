param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",

    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",

    [string]$Version = "0.3.0",
    [switch]$Installer
)

$ErrorActionPreference = "Stop"

$BuildRoot = Join-Path $PSScriptRoot ".build"
$BuildDir = Join-Path $BuildRoot "obj-$Runtime-$Configuration"
$PublishDir = Join-Path $BuildRoot "publish-$Runtime"
$AssetsDir = Join-Path $PSScriptRoot "release"
$ZipPath = Join-Path $AssetsDir "MsgDots-$Version-$Runtime-native.zip"
$Source = Join-Path $PSScriptRoot "native\main.cpp"
$Resource = Join-Path $PSScriptRoot "native\MsgDots.rc"
$NativeDir = Join-Path $PSScriptRoot "native"
$ResOut = Join-Path $BuildDir "MsgDots.res"
$ObjOut = Join-Path $BuildDir "main.obj"
$ExeOut = Join-Path $PublishDir "MsgDots.exe"
$CmdPath = Join-Path $BuildDir "build.cmd"

function Find-VsDevCmd {
    $candidates = @()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installPath) {
            $candidates += (Join-Path $installPath "VC\Auxiliary\Build\vcvarsall.bat")
        }
    }
    $candidates += @(
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"),
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"),
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"),
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat")
    )
    $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

New-Item -ItemType Directory -Force -Path $BuildDir, $PublishDir, $AssetsDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $ExeOut, $ZipPath, $ResOut, $ObjOut

$arch = if ($Runtime -eq "win-arm64") { "arm64" } else { "x64" }
$optFlags = if ($Configuration -eq "Release") {
    "/O1 /GL /GS- /Gw /Gy /DNDEBUG"
} else {
    "/Od /Zi"
}

$devCmd = Find-VsDevCmd
if (-not $devCmd) {
    throw "MSVC C++ build tools were not found. Install Visual Studio Build Tools with the 'Desktop development with C++' workload."
}

$compile = @"
@echo off
call "$devCmd" $arch || exit /b 1
rc /nologo /i "$NativeDir" /fo "$ResOut" "$Resource" || exit /b 1
cl /nologo /utf-8 /std:c++17 /W4 /EHsc /DUNICODE /D_UNICODE $optFlags /Fo"$ObjOut" /Fe"$ExeOut" "$Source" "$ResOut" /link /SUBSYSTEM:WINDOWS /OPT:REF /OPT:ICF /LTCG user32.lib gdi32.lib gdiplus.lib shell32.lib || exit /b 1
"@

Write-Host "Building MsgDots native C++ ($Runtime, $Configuration)..."
Set-Content -Encoding ASCII -Path $CmdPath -Value $compile
cmd /d /s /c "`"$CmdPath`""

if (-not (Test-Path $ExeOut)) {
    throw "Build did not produce $ExeOut"
}

Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $ZipPath

$exeSizeKb = [Math]::Round((Get-Item $ExeOut).Length / 1KB, 1)
$zipSizeKb = [Math]::Round((Get-Item $ZipPath).Length / 1KB, 1)
Write-Host "MsgDots.exe: $exeSizeKb KB"
Write-Host "Portable zip: $ZipPath ($zipSizeKb KB)"

if ($Installer) {
    $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $isccCandidates = @(
            (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
            (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
            (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
        )
        $iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $iscc) {
        throw "ISCC.exe was not found. Install Inno Setup 6 or make sure ISCC.exe is in PATH."
    }

    $env:MSGDOTS_VERSION = $Version
    $env:MSGDOTS_SOURCE_DIR = $PublishDir
    $env:MSGDOTS_OUTPUT_DIR = $AssetsDir
    $env:MSGDOTS_ICON_FILE = Join-Path $PSScriptRoot "MsgDots\Resources\AppIcon.ico"
    $isccPath = if ($iscc.Source) { $iscc.Source } else { $iscc }
    & $isccPath (Join-Path $PSScriptRoot "installer\MsgDots.iss")
}
