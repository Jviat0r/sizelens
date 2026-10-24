# Round 3: how long does an open Explorer window ignore desktop.ini changes after it last read one?
# One scratch window on test-tree\r3 (closed at the end). For each delay d: first get the window in
# sync (write + notify until it shows the current value; that moment is R), then at R + d write a new
# size with a normal `sizelens scan` and see whether the window shows it within 4 s.
# Read-only on the window (UI Automation); no clicks or keys. Results: tests\cache-window-results.txt.
param([string[]]$Delays = @('20', '40', '50', '55', '58', '62', '65', '70', '90'), [string]$Exe = '', [string]$Label = '')
$ErrorActionPreference = 'Stop'
$Delays = @($Delays | ForEach-Object { "$_" -split ',' } | Where-Object { $_ } | ForEach-Object { [int]$_ })
$proj = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $proj 'target\release\sizelens.exe' }
$tree = Join-Path $proj 'test-tree\r3'
$env:SIZELENS_HOME = Join-Path $proj 'test-home-r3'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Path (Join-Path $PSScriptRoot 'ExplorerView.cs')
$out = New-Object System.Collections.Generic.List[string]
function Note([string]$s) { $script:out.Add($s); Write-Host $s }
function MkFile([string]$p, [long]$len) { $fs = [IO.File]::Create($p); $fs.SetLength($len); $fs.Close() }
if (Test-Path -LiteralPath $tree) { & $Exe clean $tree | Out-Null; Remove-Item -LiteralPath $tree -Recurse -Force }
if (Test-Path $env:SIZELENS_HOME) { Remove-Item $env:SIZELENS_HOME -Recurse -Force }
New-Item -ItemType Directory -Force "$tree\alpha", "$tree\bravo\inner", "$tree\charlie" | Out-Null
MkFile "$tree\alpha\a.bin" 1024; MkFile "$tree\bravo\big.bin" 1MB; MkFile "$tree\bravo\inner\x.bin" 2048
& $Exe add $tree | Out-Null; & $Exe scan $tree | Out-Null
$shell = New-Object -ComObject Shell.Application
function ByHwnd([long]$h) { foreach ($w in $shell.Windows()) { try { if ($w.HWND -eq $h) { return $w } } catch {} } }
$old = @($shell.Windows() | ForEach-Object { $_.HWND })
Start-Process explorer.exe $tree
$t0 = Get-Date
do { Start-Sleep -Milliseconds 300; $main = @($shell.Windows() | Where-Object { $old -notcontains $_.HWND -and $_.Document.Folder.Self.Path -eq $tree })[0]; if (((Get-Date) - $t0).TotalSeconds -gt 15) { throw 'window did not open' } } until ($main)
$hwnd = $main.HWND
try {
  Start-Sleep 2
  [void][SizeLensTest.ExplorerView]::ShowComments($main)
  $liCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
  $cmCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'System.Comment')
  function Cell {
    try { $el = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
      $it = $el.FindAll('Descendants', $liCond) | Where-Object { $_.Current.Name -eq 'bravo' } | Select-Object -First 1
      $it.FindFirst('Children', $cmCond).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { $null }
  }
  function Tip { $b = [IO.File]::ReadAllBytes("$tree\bravo\desktop.ini"); [regex]::Match([Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2), '(?m)^InfoTip=(.*?)\r?$').Groups[1].Value }
  $script:n = 0
  function Bump { $script:n++; $fs = [IO.File]::Open("$tree\bravo\big.bin", 'Open', 'ReadWrite'); $fs.SetLength(1MB + $script:n * 64KB); $fs.Close(); & $Exe scan $tree | Out-Null; Tip }
  function Shown([double]$sec) { $want = Tip; $t = Get-Date; while (((Get-Date) - $t).TotalSeconds -lt $sec) { if ((Cell) -eq $want) { return $true }; Start-Sleep -Milliseconds 150 }; $false }
  foreach ($d in $Delays) {
    # sync: a new value every 10 s until the window shows it
    $ts = Get-Date
    do { [void](Bump); $ok = Shown 10; if (((Get-Date) - $ts).TotalSeconds -gt 150) { throw 'could not get the window in sync' } } until ($ok)
    $R = Get-Date
    $syncTook = ($R - $ts).TotalSeconds
    while (((Get-Date) - $R).TotalSeconds -lt $d) { Start-Sleep -Milliseconds 100 }
    $want = Bump
    $at = ((Get-Date) - $R).TotalSeconds
    $ok = Shown 4
    Note ("write {0,5:N1} s after the window last read it: {1}  (sync took {2:N0} s)" -f $at, $(if ($ok) { 'SHOWN' } else { "stale ('$(Cell)')" }), $syncTook)
  }
} finally { $w = ByHwnd $hwnd; if ($w) { $w.Quit() } }
& $Exe clean $tree | Out-Null; Remove-Item -LiteralPath $tree -Recurse -Force
$file = Join-Path $PSScriptRoot 'cache-window-results.txt'
$prev = if (Test-Path $file) { [IO.File]::ReadAllText($file) + "`r`n`r`n" } else { '' }
[IO.File]::WriteAllText($file, $prev + ("# {0} {1}`r`n" -f (Get-Date -Format s), $Label) + ($out -join "`r`n"), (New-Object Text.UTF8Encoding $false))
