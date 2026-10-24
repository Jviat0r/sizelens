# Checks against a real, already-open File Explorer window on the scratch folder test-tree\root:
#   1. does the window pick up a new size by itself (no F5), without and with SizeLens's notifications?
#   2. how does Explorer itself order the folders when sorted by Comments?
# It READS the window through UI Automation and sets the view's sort through the Shell COM object
# (then puts the sort back to Name). It sends no clicks or keystrokes.
# Needs: test-tree\root scanned (SIZELENS_HOME = test-home) and its window showing the Comments column.
$ErrorActionPreference = 'Continue'
$proj = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $proj 'target\release\sizelens.exe'
$root = Join-Path $proj 'test-tree\root'
$env:SIZELENS_HOME = Join-Path $proj 'test-home'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);'
$out = New-Object System.Collections.Generic.List[string]
function Note([string]$s) { $script:out.Add($s); Write-Host $s }

$shell = New-Object -ComObject Shell.Application
function FindWin { foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $root) { return $w } } catch {} } }
$win = FindWin
if (-not $win) { Start-Process explorer.exe $root; Start-Sleep -Seconds 3; $win = FindWin }
$h = [IntPtr]$win.HWND
$wasIconic = [W.U]::IsIconic($h)
if ($wasIconic) { [void][W.U]::ShowWindow($h, 4); Start-Sleep -Seconds 2 }   # restore without taking focus
$el = [Windows.Automation.AutomationElement]::FromHandle($h)
$liCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)

function Rows {
  $el.FindAll('Descendants', $liCond) | ForEach-Object {
    $c = $_.FindFirst('Children', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'System.Comment')))
    $v = ''; if ($c) { try { $v = $c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value } catch {} }
    [pscustomobject]@{ Name = $_.Current.Name; Comment = $v }
  }
}
function Cell([string]$name) { (Rows | Where-Object { $_.Name -eq $name }).Comment }
function IniTip([string]$folder) {
  $b = [IO.File]::ReadAllBytes((Join-Path $folder 'desktop.ini'))
  [regex]::Match([Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2), '(?m)^InfoTip=(.*?)\r?$').Groups[1].Value
}
function WaitCell([string]$name, [string]$want, [int]$seconds) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $seconds) { if ((Cell $name) -eq $want) { return ((Get-Date) - $t0).TotalSeconds }; Start-Sleep -Milliseconds 250 }
  return -1
}

$hasCol = @(Rows | Where-Object { $_.Comment }).Count -gt 0
Note "Window: $root  (Comments column visible: $hasCol)"
Note "Cells now:"
Rows | ForEach-Object { Note ("  {0,-20} {1}" -f $_.Name, $_.Comment) }
$mismatch = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'desktop.ini') -PathType Leaf } | Where-Object { (Cell $_.Name) -ne (IniTip $_.FullName) })
Note ("Cells equal desktop.ini InfoTip for every labelled folder: " + ($mismatch.Count -eq 0))

# --- 1. refresh without F5 ---
$big = Join-Path $root 'bravo\big.bin'
$origLen = (Get-Item -LiteralPath $big).Length; $origTime = (Get-Item -LiteralPath $big).LastWriteTimeUtc
function Grow([long]$by) { $fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); $fs.SetLength($fs.Length + $by); $fs.Close() }

Grow 1MB
$env:SIZELENS_NO_NOTIFY = '1'
& $exe scan $root | Out-Null
Remove-Item Env:\SIZELENS_NO_NOTIFY
$want = IniTip (Join-Path $root 'bravo')
$t = WaitCell 'bravo' $want 10
Note ("WITHOUT notifications: desktop.ini says '{0}', window {1}" -f $want, $(if ($t -ge 0) { "updated after $([Math]::Round($t,1)) s" } else { "still shows '$(Cell 'bravo')' after 10 s" }))

Grow 1MB
& $exe scan $root | Out-Null
$want = IniTip (Join-Path $root 'bravo')
$t = WaitCell 'bravo' $want 10
Note ("WITH notifications:    desktop.ini says '{0}', window {1}" -f $want, $(if ($t -ge 0) { "updated after $([Math]::Round($t,1)) s" } else { "still shows '$(Cell 'bravo')' after 10 s" }))

# put big.bin back and re-scan
$fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); $fs.SetLength($origLen); $fs.Close(); (Get-Item -LiteralPath $big).LastWriteTimeUtc = $origTime
& $exe scan $root | Out-Null
$t = WaitCell 'bravo' (IniTip (Join-Path $root 'bravo')) 10
Note ("back to original: window updated after $([Math]::Round($t,1)) s")

# --- 2. Explorer's own sort by Comments ---
$sizes = @{}
Get-Content -Encoding UTF8 (Join-Path $env:SIZELENS_HOME 'sizes.tsv') | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $f = $_ -split "`t"; if ((Split-Path $f[0] -Parent) -eq $root) { $sizes[(Split-Path $f[0] -Leaf)] = [long]$f[1] } }
foreach ($dir in @(@{ s = 'prop:System.Comment;'; d = 'ascending' }, @{ s = 'prop:-System.Comment;'; d = 'descending' })) {
  $win.Document.SortColumns = $dir.s
  Start-Sleep -Seconds 2
  $order = @(Rows | Where-Object { $sizes.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
  $bytes = $order | ForEach-Object { $sizes[$_] }
  $sortedOk = $true
  for ($i = 0; $i -lt $bytes.Count - 1; $i++) {
    if ($dir.d -eq 'ascending' -and $bytes[$i] -gt $bytes[$i + 1]) { $sortedOk = $false }
    if ($dir.d -eq 'descending' -and $bytes[$i] -lt $bytes[$i + 1]) { $sortedOk = $false }
  }
  Note ("Explorer sorted by Comments ({0}): {1}" -f $dir.d, ($order -join ' > '))
  Note ("  order matches size order: $sortedOk")
}
$win.Document.SortColumns = 'prop:System.ItemNameDisplay;'
Start-Sleep -Seconds 1
if ($wasIconic) { [void][W.U]::ShowWindow($h, 6) }   # minimize again, as it was
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'explorer-results.txt'), ($out -join "`r`n"), (New-Object Text.UTF8Encoding $false))
