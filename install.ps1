<#
SizeLens installer: for the current user only, no admin needed.

What it does:
  - Adds two right-click entries for folders (and for the empty space inside a folder):
        "Show or refresh folder sizes"  ->  bin\sizelens.exe here  "<folder>"
        "Remove folder sizes"     ->  bin\sizelens.exe clean "<folder>"
    They are written under HKCU\Software\Classes\Directory\shell and
    HKCU\Software\Classes\Directory\Background\shell (keys named SizeLens.Show / SizeLens.Remove).
  - With -Startup: also starts the watcher at logon, so sizes stay current
    (HKCU\Software\Microsoft\Windows\CurrentVersion\Run, value "SizeLens"), and starts it now.
  - With -AddCommentsColumn: makes Comments a default column in Explorer for General items, Documents,
    Pictures, Music, Videos and Downloads folders (per-user copy of the column defaults under
    HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes; backup + undo record in
    %LOCALAPPDATA%\SizeLens). See comments-column.ps1. Restart Explorer afterwards.

Nothing is copied anywhere: the entries point at the bin\ folder next to this script,
so keep the SizeLens folder where it is (or run install.ps1 again after moving it).
Undo with uninstall.ps1.

Usage:
  powershell -ExecutionPolicy Bypass -File install.ps1            # right-click entries only
  powershell -ExecutionPolicy Bypass -File install.ps1 -Startup   # + watcher at logon
  powershell -ExecutionPolicy Bypass -File install.ps1 -AddCommentsColumn   # + Comments column by default
#>
param([switch]$Startup, [switch]$AddCommentsColumn)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $here 'bin\sizelens.exe'
$exew = Join-Path $here 'bin\sizelensw.exe'
foreach ($f in $exe, $exew) {
  if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f. Run build.ps1 first." }
}

$classes = 'HKCU:\Software\Classes'
$entries = @(
  @{ Key = 'Directory\shell\SizeLens.Show';              Label = 'Show or refresh folder sizes'; Args = 'here "%V" --pause' },
  @{ Key = 'Directory\shell\SizeLens.Remove';            Label = 'Remove folder sizes';    Args = 'clean "%V" --pause' },
  @{ Key = 'Directory\Background\shell\SizeLens.Show';   Label = 'Show or refresh folder sizes'; Args = 'here "%V" --pause' },
  @{ Key = 'Directory\Background\shell\SizeLens.Remove'; Label = 'Remove folder sizes';    Args = 'clean "%V" --pause' }
)
foreach ($e in $entries) {
  $k = Join-Path $classes $e.Key
  New-Item -Path $k -Force | Out-Null
  Set-Item -LiteralPath $k -Value $e.Label
  New-Item -Path "$k\command" -Force | Out-Null
  Set-Item -LiteralPath "$k\command" -Value ('"{0}" {1}' -f $exe, $e.Args)
  Write-Host "added  HKCU\Software\Classes\$($e.Key)"
}

if ($Startup) {
  $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  New-ItemProperty -LiteralPath $run -Name 'SizeLens' -Value ('"{0}" watch' -f $exew) -PropertyType String -Force | Out-Null
  Write-Host "added  HKCU\...\CurrentVersion\Run  SizeLens = sizelensw.exe watch"
  Start-Process -FilePath $exew -ArgumentList 'watch' -WindowStyle Hidden
  Write-Host "started the watcher (log: $env:LOCALAPPDATA\SizeLens\sizelens.log)"
}

if ($AddCommentsColumn) {
  Write-Host ""
  & (Join-Path $here 'comments-column.ps1')
}

Write-Host ""
Write-Host "Done. Right-click a folder (or the empty space inside one) > Show or refresh folder sizes."
if (-not $AddCommentsColumn) { Write-Host "Then in Explorer: right-click any column header > More... > tick 'Comments' > OK, and sort by it (or run this again with -AddCommentsColumn)." }
Write-Host "Settings: $env:LOCALAPPDATA\SizeLens\config.txt   Undo: uninstall.ps1 -CleanFolders"
