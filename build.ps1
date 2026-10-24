# Builds SizeLens and copies the two programs into bin\ (what install.ps1 points at).
# Stop a running watcher first (`bin\sizelens.exe stop`), or Windows won't let the exe be replaced.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
  & cargo build --release
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
  New-Item -ItemType Directory -Force (Join-Path $here 'bin') | Out-Null
  Copy-Item (Join-Path $here 'target\release\sizelens.exe')  (Join-Path $here 'bin\sizelens.exe')  -Force
  Copy-Item (Join-Path $here 'target\release\sizelensw.exe') (Join-Path $here 'bin\sizelensw.exe') -Force
  Write-Host "bin\sizelens.exe and bin\sizelensw.exe are up to date."
} finally { Pop-Location }
