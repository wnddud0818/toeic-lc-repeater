# Build after FFmpeg and whisper-cli have been prepared (see windows.yml).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot

if (-not (Test-Path '.venv-windows/Scripts/python.exe')) {
    python -m venv .venv-windows
    if ($LASTEXITCODE -ne 0) { throw 'Could not create Python environment' }
}
$Python = Join-Path $PSScriptRoot '.venv-windows/Scripts/python.exe'
& $Python -m pip install -r requirements-build.txt
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed' }

$Tools = Join-Path $PSScriptRoot 'build/windows-tools'
foreach ($Name in @('ffmpeg.exe', 'whisper-cli.exe')) {
    if (-not (Test-Path (Join-Path $Tools $Name))) { throw "Missing $Name; run the Windows workflow build steps first" }
}

# Reuse the existing app artwork through Windows' built-in image APIs.
Add-Type -AssemblyName System.Drawing
$Image = [System.Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'ios/LCRepeater/Assets.xcassets/AppIcon.appiconset/AppIcon.png'))
$Bitmap = [System.Drawing.Bitmap]::new($Image, 256, 256)
$Icon = [System.Drawing.Icon]::FromHandle($Bitmap.GetHicon())
$Stream = [System.IO.File]::Create((Join-Path $PSScriptRoot 'build/AppIcon.ico'))
try { $Icon.Save($Stream) } finally { $Stream.Dispose(); $Icon.Dispose(); $Bitmap.Dispose(); $Image.Dispose() }

& $Python -m PyInstaller --noconfirm --clean --windowed --onedir --log-level WARN `
    --name 'LC Repeater' --icon build/AppIcon.ico `
    --add-data "${PSScriptRoot}/static:static" `
    --add-data "${Tools}/licenses:licenses" `
    --add-binary "${Tools}/ffmpeg.exe:bin" `
    --add-binary "${Tools}/whisper-cli.exe:bin" `
    --collect-all webview --collect-all pythonnet --collect-all clr_loader `
    --exclude-module PyQt5 --exclude-module PyQt6 --exclude-module PySide2 --exclude-module PySide6 `
    --distpath dist --workpath build/pyinstaller-windows --specpath build app.py
if ($LASTEXITCODE -ne 0) { throw 'App packaging failed' }
Write-Host 'Built dist/LC Repeater/LC Repeater.exe'
