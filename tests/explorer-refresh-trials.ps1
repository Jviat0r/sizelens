# Repeated trials: change bravo's size, run `sizelens scan`, and time how long the already-open
# Explorer window takes to show the new Comments value (read through UI Automation, no input sent).
param([int]$Trials = 6, [int]$Gap = 3)
$ErrorActionPreference = 'Continue'
$proj = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $proj 'target\release\sizelens.exe'
$root = Join-Path $proj 'test-tree\root'
$env:SIZELENS_HOME = Join-Path $proj 'test-home'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$shell = New-Object -ComObject Shell.Application
foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $root) { $win = $w } } catch {} }
$el = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$win.HWND)
$liCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
function Cell([string]$name) {
  $it = $el.FindAll('Descendants', $liCond) | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
  $c = $it.FindFirst('Children', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'System.Comment')))
  $c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
}
function Tip { $b = [IO.File]::ReadAllBytes("$root\bravo\desktop.ini"); [regex]::Match([Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2), '(?m)^InfoTip=(.*?)\r?$').Groups[1].Value }
$big = "$root\bravo\big.bin"
$origLen = (Get-Item -LiteralPath $big).Length; $origTime = (Get-Item -LiteralPath $big).LastWriteTimeUtc
$results = @()
for ($i = 1; $i -le $Trials; $i++) {
  $fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); $fs.SetLength($origLen + $i * 1MB); $fs.Close()
  & $exe scan $root | Out-Null
  $want = Tip; $t0 = Get-Date; $seen = -1
  while (((Get-Date) - $t0).TotalSeconds -lt 10) { if ((Cell 'bravo') -eq $want) { $seen = ((Get-Date) - $t0).TotalSeconds; break }; Start-Sleep -Milliseconds 200 }
  $line = "trial $i  ini '$want'  window " + $(if ($seen -ge 0) { "updated after {0:N1} s" -f $seen } else { "still '$(Cell 'bravo')' after 10 s" })
  Write-Host $line; $results += $line
  Start-Sleep -Seconds $Gap
}
$fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); $fs.SetLength($origLen); $fs.Close(); (Get-Item -LiteralPath $big).LastWriteTimeUtc = $origTime
& $exe scan $root | Out-Null
$results
