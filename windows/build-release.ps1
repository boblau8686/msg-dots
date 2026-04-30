param(
    [ValidateSet("framework", "self-contained")]
    [string]$Mode = "framework",

    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",

    [string]$Configuration = "Release",
    [string]$Version = "0.2.0",
    [switch]$Installer
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $PSScriptRoot "MsgDots\MsgDots.csproj"
$Dist = Join-Path $PSScriptRoot "dist"
$PublishDir = Join-Path $Dist "publish-$Mode-$Runtime"
$AssetsDir = Join-Path $PSScriptRoot "release-assets"
$ZipPath = Join-Path $AssetsDir "MsgDots-$Version-$Runtime-$Mode.zip"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found. Install the .NET 8 SDK before building Windows releases."
}

New-Item -ItemType Directory -Force -Path $Dist, $AssetsDir | Out-Null
if (Test-Path $PublishDir) {
    Remove-Item -Recurse -Force $PublishDir
}

$commonArgs = @(
    "publish", $Project,
    "-c", $Configuration,
    "-r", $Runtime,
    "-o", $PublishDir,
    "-p:PublishSingleFile=true",
    "-p:DebugType=none",
    "-p:DebugSymbols=false",
    "-p:SatelliteResourceLanguages=zh-Hans",
    "-p:IncludeNativeLibrariesForSelfExtract=true"
)

if ($Mode -eq "framework") {
    $publishArgs = $commonArgs + @("--self-contained", "false")
} else {
    $publishArgs = $commonArgs + @(
        "--self-contained", "true",
        "-p:EnableCompressionInSingleFile=true",
        "-p:InvariantGlobalization=true"
    )
}

Write-Host "Publishing MsgDots ($Mode, $Runtime)..."
& dotnet @publishArgs

if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
}
Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $ZipPath

$exe = Join-Path $PublishDir "MsgDots.exe"
if (Test-Path $exe) {
    $sizeMb = [Math]::Round((Get-Item $exe).Length / 1MB, 2)
    Write-Host "MsgDots.exe: $sizeMb MB"
}

$zipSizeMb = [Math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
Write-Host "Release zip: $ZipPath ($zipSizeMb MB)"

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
    if ($Mode -ne "framework") {
        throw "The installer script is intended for the framework-dependent build."
    }

    $env:MSGDOTS_VERSION = $Version
    $env:MSGDOTS_SOURCE_DIR = $PublishDir
    $env:MSGDOTS_OUTPUT_DIR = $AssetsDir
    $env:MSGDOTS_ICON_FILE = Join-Path $PSScriptRoot "MsgDots\Resources\AppIcon.ico"
    $isccPath = if ($iscc.Source) { $iscc.Source } else { $iscc }
    & $isccPath (Join-Path $PSScriptRoot "installer\MsgDots.iss")
}
