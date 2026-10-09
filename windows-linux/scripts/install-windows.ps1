# Installs a Mouthy build (mouthy.exe + DLLs in the current folder) for the current user:
# %LOCALAPPDATA%\Programs\Mouthy and a Start menu shortcut.
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $MyInvocation.MyCommand.Path
if (Test-Path (Join-Path $source 'mouthy.exe')) { } else { $source = Get-Location }
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Mouthy'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Get-Process mouthy -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item -Force (Join-Path $source 'mouthy.exe'), (Join-Path $source '*.dll') $dest
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Mouthy.lnk'))
$link.TargetPath = Join-Path $dest 'mouthy.exe'
$link.WorkingDirectory = $dest
$link.Description = 'Local dictation with Parakeet and Whisper'
$link.Save()
Write-Output "Installed Mouthy to $dest"
