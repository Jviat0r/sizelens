# Round 3: do already-open Explorer windows show new sizes by themselves now (the follow-up rewrite)?
# Scratch tree test-tree\r3 with its own SIZELENS_HOME (test-home-r3). Opens TWO Explorer windows
# (closed at the end): W1 on r3 (shows bravo's size) and W2 on r3\bravo (shows inner's size), turns
# Comments on in both through IColumnManager. Then, with no F5 and no other action, it times how long
# each window takes to show the value in desktop.ini after a change deep down (bravo\inner):
#   A. with the watcher running (debounce 2 s), changes 15-30 s apart (inside Explorer's ~60 s blind spot)
#   B. without a watcher: a one-off `sizelens scan`, whose hidden helper does the follow-up
# Read-only on the windows (UI Automation). Results: tests\followup-results.txt.
param([int]$Trials = 4, [int]$Max = 100, [string]$Exe = '', [string]$Label = '')
$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $proj 'target\release\sizelens.exe' }
$tree = Join-Path $proj 'test-tree\r3'
$env:SIZELENS_HOME = Join-Path $proj 'test-home-r3'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not ('SizeLensTest.ExplorerView' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ExplorerView.cs') }
$out = New-Object System.Collections.Generic.List[string]
$pass = 0; $fail = 0
function Note([string]$s) { $script:out.Add($s); Write-Host $s }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; $s = "PASS  $name" } else { $script:fail++; $s = "FAIL  $name" }
  if ($detail) { $s += "  ($detail)" }
  Note $s
}
function MkFile([string]$p, [long]$len) { $fs = [IO.File]::Create($p); $fs.SetLength($len); $fs.Close() }
function SetLen([string]$p, [long]$len) { $fs = [IO.File]::Open($p, 'Open', 'ReadWrite'); $fs.SetLength($len); $fs.Close() }
function Tip([string]$folder) { $b = [IO.File]::ReadAllBytes("$folder\desktop.ini"); [regex]::Match([Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2), '(?m)^InfoTip=(.*?)\r?$').Groups[1].Value }

if (Test-Path -LiteralPath $tree) { & $Exe clean $tree | Out-Null; Remove-Item -LiteralPath $tree -Recurse -Force }
if (Test-Path $env:SIZELENS_HOME) { Remove-Item $env:SIZELENS_HOME -Recurse -Force }
New-Item -ItemType Directory -Force "$tree\alpha", "$tree\bravo\inner", "$tree\charlie" | Out-Null
MkFile "$tree\alpha\a.bin" 1024; MkFile "$tree\bravo\big.bin" 1MB; MkFile "$tree\bravo\inner\x.bin" 2048
& $Exe add $tree | Out-Null
$cfgPath = Join-Path $env:SIZELENS_HOME 'config.txt'
[IO.File]::WriteAllText($cfgPath, ([IO.File]::ReadAllText($cfgPath) -replace 'debounce_seconds = \d+', 'debounce_seconds = 2'), (New-Object Text.UTF8Encoding $false))
& $Exe scan $tree | Out-Null

$shell = New-Object -ComObject Shell.Application
function ByHwnd([long]$h) { foreach ($w in $shell.Windows()) { try { if ($w.HWND -eq $h) { return $w } } catch {} } }
function OpenWin([string]$path) {
  $old = @($shell.Windows() | ForEach-Object { $_.HWND })
  Start-Process explorer.exe $path
  $t0 = Get-Date
  while ($true) {
    $new = @($shell.Windows() | Where-Object { $old -notcontains $_.HWND } | Where-Object { try { $_.Document.Folder.Self.Path -eq $path } catch { $false } })
    if ($new.Count) { Start-Sleep -Milliseconds 1500; [void][SizeLensTest.ExplorerView]::ShowComments($new[0]); Start-Sleep -Milliseconds 500; return $new[0].HWND }
    if (((Get-Date) - $t0).TotalSeconds -gt 15) { throw "Explorer window on $path did not open" }
    Start-Sleep -Milliseconds 250
  }
}
$liCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
$cmCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'System.Comment')
function Cell([long]$h, [string]$name) {
  try {
    $el = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
    $it = $el.FindAll('Descendants', $liCond) | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
    if (-not $it) { return '<no item>' }
    $it.FindFirst('Children', $cmCond).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
  } catch { '<error>' }
}
# Wait until both windows show what desktop.ini says; returns the seconds each took (-1 = never).
function WaitBoth([datetime]$t0) {
  $w1 = "$tree\bravo"; $w2 = "$tree\bravo\inner"
  $r = @{ w1 = -1.0; w2 = -1.0 }
  while (((Get-Date) - $t0).TotalSeconds -lt $Max -and ($r.w1 -lt 0 -or $r.w2 -lt 0)) {
    $el = ((Get-Date) - $t0).TotalSeconds
    if ($r.w1 -lt 0 -and (Cell $script:h1 'bravo') -eq (Tip $w1)) { $r.w1 = $el }
    if ($r.w2 -lt 0 -and (Cell $script:h2 'inner') -eq (Tip $w2)) { $r.w2 = $el }
    Start-Sleep -Milliseconds 250
  }
  $r
}
function Fmt($s) { if ($s -ge 0) { '{0,5:N1} s' -f $s } else { 'never' } }

$h1 = OpenWin $tree
$h2 = OpenWin "$tree\bravo"
$inner = "$tree\bravo\inner\x.bin"
$n = 0
$watch = $null
try {
  Note ("windows: W1 {0} on r3 (bravo = '{1}'), W2 {2} on r3\bravo (inner = '{3}')" -f $h1, (Cell $h1 'bravo'), $h2, (Cell $h2 'inner'))
  $bravoTime = (Get-Item -LiteralPath "$tree\bravo").LastWriteTimeUtc
  $innerTime = (Get-Item -LiteralPath "$tree\bravo\inner").LastWriteTimeUtc

  # ---------- A. watcher ----------
  $watch = Start-Process -FilePath $Exe -ArgumentList 'watch' -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $env:SIZELENS_HOME 'watch-followup.out')
  Start-Sleep -Seconds 3
  $timesA = @()
  foreach ($i in 1..$Trials) {
    $prev = Tip "$tree\bravo\inner"
    $n++; SetLen $inner (2048 + $n * 3MB)
    $t0 = Get-Date
    while ((Tip "$tree\bravo\inner") -eq $prev) { if (((Get-Date) - $t0).TotalSeconds -gt 20) { break }; Start-Sleep -Milliseconds 200 }
    $wrote = ((Get-Date) - $t0).TotalSeconds
    $r = WaitBoth $t0
    $timesA += $r.w1, $r.w2
    Note ("A{0} watcher: label written after {1:N1} s; W1 shows bravo {2}, W2 shows inner {3} (from the change)" -f $i, $wrote, (Fmt $r.w1), (Fmt $r.w2))
    Start-Sleep -Seconds (15 + 5 * ($i % 3))
  }
  Check 'A: with the watcher, both open windows showed every new size without F5' (@($timesA | Where-Object { $_ -lt 0 }).Count -eq 0) (($timesA | ForEach-Object { Fmt $_ }) -join ', ')
  Check 'A: never later than follow_up_seconds (65) + debounce + 5 s' (@($timesA | Where-Object { $_ -gt 75 }).Count -eq 0)
  & $Exe stop | Out-Null
  $t0 = Get-Date; while (-not $watch.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 200 }
  Check 'watcher stopped' $watch.HasExited
  Note ("watch log:`n" + (Get-Content (Join-Path $env:SIZELENS_HOME 'watch-followup.out') -Raw).TrimEnd())
  $watch = $null
  Start-Sleep -Seconds 2

  # ---------- B. one-off scan + hidden helper ----------
  $timesB = @()
  foreach ($i in 1..2) {
    $n++; SetLen $inner (2048 + $n * 3MB)
    $t0 = Get-Date
    & $Exe scan $tree | Out-Null
    $helper = @(Get-Process -Name sizelensw -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path (Split-Path $Exe) 'sizelensw.exe') })
    $r = WaitBoth $t0
    $timesB += $r.w1, $r.w2
    Note ("B{0} one-off scan: helper running after the scan: {1}; W1 shows bravo {2}, W2 shows inner {3}" -f $i, ($helper.Count -gt 0), (Fmt $r.w1), (Fmt $r.w2))
    $t1 = Get-Date; while ((Test-Path (Join-Path $env:SIZELENS_HOME 'followup.tsv')) -and ((Get-Date) - $t1).TotalSeconds -lt 80) { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Seconds 2
    $left = @(Get-Process -Name sizelensw -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path (Split-Path $Exe) 'sizelensw.exe') })
    Check "B${i}: helper did its follow-ups and exited" ((-not (Test-Path (Join-Path $env:SIZELENS_HOME 'followup.tsv'))) -and $left.Count -eq 0) "$($left.Count) left"
    Start-Sleep -Seconds 10
  }
  Check 'B: without a watcher, both open windows showed every new size without F5' (@($timesB | Where-Object { $_ -lt 0 }).Count -eq 0) (($timesB | ForEach-Object { Fmt $_ }) -join ', ')

  # ---------- side effects ----------
  $again = & $Exe scan $tree
  Check 'a re-scan after the follow-ups rewrites nothing' (($again -join "`n") -match '; 0 updated, 0 errors') (($again | Select-Object -First 1))
  Check 'follow-ups kept the folders'' Date modified' ((Get-Item -LiteralPath "$tree\bravo").LastWriteTimeUtc -eq $bravoTime -and (Get-Item -LiteralPath "$tree\bravo\inner").LastWriteTimeUtc -eq $innerTime)

  # ---------- C. clean (labels removed): what do the open windows show? (measured, not required) ----------
  Start-Sleep -Seconds 5
  $t0 = Get-Date
  & $Exe clean $tree | Out-Null
  $c1 = -1; $c2 = -1
  while (((Get-Date) - $t0).TotalSeconds -lt $Max -and ($c1 -lt 0 -or $c2 -lt 0)) {
    $el = ((Get-Date) - $t0).TotalSeconds
    if ($c1 -lt 0 -and (Cell $h1 'bravo') -eq '') { $c1 = $el }
    if ($c2 -lt 0 -and (Cell $h2 'inner') -eq '') { $c2 = $el }
    Start-Sleep -Milliseconds 250
  }
  Note ("C  after clean: W1's bravo label gone {0}, W2's inner label gone {1} (still showing: '{2}' / '{3}')" -f (Fmt $c1), (Fmt $c2), (Cell $h1 'bravo'), (Cell $h2 'inner'))
} finally {
  if ($watch -and -not $watch.HasExited) { & $Exe stop | Out-Null; Start-Sleep -Seconds 3; if (-not $watch.HasExited) { $watch.Kill() } }
  # close the two test windows (and any other window left on the scratch tree); retry, then check
  foreach ($try in 1..3) {
    $mine = @($shell.Windows() | Where-Object { try { $_.HWND -eq $h1 -or $_.HWND -eq $h2 -or $_.Document.Folder.Self.Path -like "$tree*" } catch { $false } })
    if (-not $mine.Count) { break }
    foreach ($w in $mine) { try { $w.Quit() } catch {} }
    Start-Sleep -Seconds 1
  }
}
& $Exe clean $tree | Out-Null
Remove-Item -LiteralPath $tree -Recurse -Force
Note "followup: $pass passed, $fail failed"
$file = Join-Path $PSScriptRoot 'followup-results.txt'
[IO.File]::WriteAllText($file, ("# {0} {1}`r`n" -f (Get-Date -Format s), $Label) + ($out -join "`r`n"), (New-Object Text.UTF8Encoding $false))
if ($fail) { exit 1 }
