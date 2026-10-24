<#
SizeLens uninstaller (current user only).

  -CleanFolders  First undo SizeLens in every folder it touched (`sizelens clean --all`):
                 restores backed-up desktop.ini files exactly, deletes the ones it created,
                 puts folder attributes back. Recommended.
  -RemoveData    Also delete %LOCALAPPDATA%\SizeLens (config, size index, undo log, backups).
                 Refused while the undo log still lists folders, so you can never lose the backups
                 needed to restore them.

Always: stops the watcher and removes the right-click entries and the logon entry install.ps1 added,
and undoes install.ps1 -AddCommentsColumn if it was used (comments-column.ps1 -Remove: deletes the
per-user column defaults it created and puts back any value it changed; restart Explorer afterwards).

Usage:
  powershell -ExecutionPolicy Bypass -File uninstall.ps1 -CleanFolders
  powershell -ExecutionPolicy Bypass -File uninstall.ps1 -CleanFolders -RemoveData
#>
param([switch]$CleanFolders, [switch]$RemoveData)
$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $here 'bin\sizelens.exe'
$data = Join-Path $env:LOCALAPPDATA 'SizeLens'
$haveExe = Test-Path -LiteralPath $exe

if ($haveExe) {
  & $exe stop | Out-Host
  Start-Sleep -Seconds 3
}
Get-Process -Name 'sizelensw' -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue

if ($CleanFolders) {
  if (-not $haveExe) { Write-Warning "bin\sizelens.exe is missing; can't clean folders. Run build.ps1, then this again." }
  else {
    & $exe clean --all | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning "clean reported problems (see above). The undo log was kept for those folders." }
  }
}

$classes = 'HKCU:\Software\Classes'
foreach ($k in 'Directory\shell\SizeLens.Show', 'Directory\shell\SizeLens.Remove',
               'Directory\Background\shell\SizeLens.Show', 'Directory\Background\shell\SizeLens.Remove') {
  $p = Join-Path $classes $k
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Host "removed HKCU\Software\Classes\$k" }
}
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Get-ItemProperty -LiteralPath $run -Name 'SizeLens' -ErrorAction SilentlyContinue) {
  Remove-ItemProperty -LiteralPath $run -Name 'SizeLens'
  Write-Host "removed HKCU\...\CurrentVersion\Run  SizeLens"
}

$cc = Join-Path $here 'comments-column.ps1'
if ((Test-Path -LiteralPath (Join-Path $data 'comments-column.tsv')) -and (Test-Path -LiteralPath $cc)) {
  & $cc -Remove
}

$managed = Join-Path $data 'managed.tsv'
$left = @()
if (Test-Path -LiteralPath $managed) {
  $left = @(Get-Content -LiteralPath $managed -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
}
if ($left.Count -gt 0) {
  Write-Warning "$($left.Count) folder(s) still show sizes. Undo them with:  `"$exe`" clean --all   (or run this with -CleanFolders)"
}
if ($RemoveData) {
  if ($left.Count -gt 0) { Write-Warning "Not deleting ${data}: its undo log is still needed for those folders." }
  elseif (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force; Write-Host "deleted $data" }
}
Write-Host "Uninstalled. The SizeLens folder itself ($here) can be deleted by hand."
