# Round 3: what makes an already-open Explorer window show a folder's new size?
# Builds a small scratch tree (test-tree\r3), opens ONE Explorer window on it (closed at the end), turns
# its Comments column on through the view's own IColumnManager, sorts it by Comments, then for each
# method and round: grows a file, runs `sizelens scan` (with SizeLens's normal notifications), applies
# the method and reads the window through UI Automation until bravo's cell equals the InfoTip in
# bravo\desktop.ini (or times out). It also checks the window kept its columns, sort and view mode.
# No clicks or keystrokes are sent. Results: tests\renavigate-results.txt.
param(
  [string[]]$Methods = @('none', 'refresh', 'browse-same', 'parent-and-back', 'new-window', 'mtime-plus2', 'mtime-plus2-refresh', 'mtime-bounce'),
  [int]$Rounds = 5, [int]$Wait = 6, [int]$Gap = 1,
  [string]$Exe = '', [string]$Home3 = '', [string]$Label = ''
)
$ErrorActionPreference = 'Stop'
$Methods = @($Methods | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # -File passes a,b as one string
$proj = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $proj 'target\release\sizelens.exe' }
$tree = Join-Path $proj 'test-tree\r3'
if (-not $Home3) { $Home3 = Join-Path $proj 'test-home-r3' }
$env:SIZELENS_HOME = $Home3
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not ('SizeLensTest.ExplorerView' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ExplorerView.cs') }
Add-Type -Namespace SL -Name N -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern void SHChangeNotify(int e, uint f, string a, string b); [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool MoveFileEx(string a, string b, int f);'
$out = New-Object System.Collections.Generic.List[string]
function Note([string]$s) { $script:out.Add($s); Write-Host $s }

# ---------- scratch tree ----------
function MkFile([string]$p, [long]$len) { $fs = [IO.File]::Create($p); $fs.SetLength($len); $fs.Close() }
if (Test-Path -LiteralPath $tree) { & $Exe clean $tree | Out-Null; Remove-Item -LiteralPath $tree -Recurse -Force }
if (Test-Path -LiteralPath $Home3) { Remove-Item -LiteralPath $Home3 -Recurse -Force }
New-Item -ItemType Directory -Force "$tree\alpha", "$tree\bravo\inner", "$tree\charlie" | Out-Null
MkFile "$tree\alpha\a.bin" 1024
MkFile "$tree\bravo\big.bin" 1MB
MkFile "$tree\bravo\inner\x.bin" 2048
& $Exe add $tree | Out-Null
& $Exe scan $tree | Out-Null

# ---------- the window ----------
$shell = New-Object -ComObject Shell.Application
function WinsOn([string]$path) { foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $path) { $w } } catch {} } }
function ByHwnd([long]$h) { foreach ($w in $shell.Windows()) { try { if ($w.HWND -eq $h) { return $w } } catch {} } }
function OpenWin([string]$path) {
  $old = @($shell.Windows() | ForEach-Object { $_.HWND })
  Start-Process explorer.exe $path
  $t0 = Get-Date
  while ($true) {
    $new = @(WinsOn $path | Where-Object { $old -notcontains $_.HWND })
    if ($new.Count) { Start-Sleep -Milliseconds 1500; return $new[0] }
    if (((Get-Date) - $t0).TotalSeconds -gt 15) { throw "Explorer window on $path did not open" }
    Start-Sleep -Milliseconds 250
  }
}
$main = OpenWin $tree
try {
$hwnd = $main.HWND
$hr = [SizeLensTest.ExplorerView]::ShowComments($main)
Start-Sleep -Milliseconds 500
$main.Document.SortColumns = 'prop:-System.Comment;'
Start-Sleep -Milliseconds 500
$viewMode = $main.Document.CurrentViewMode
function Cols($w) { ([SizeLensTest.ExplorerView]::VisibleColumns($w)) -join ',' }
$cols0 = Cols $main
Note ("{0}window HWND {1}; ShowComments hr={2}; columns: {3}; sort: {4}; view mode {5}" -f $(if ($Label) { "[$Label] " } else { '' }), $hwnd, $hr, $cols0, $main.Document.SortColumns, $viewMode)

$liCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
$cmCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'System.Comment')
function Cell([long]$h, [string]$name) {
  try {
    $el = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
    $it = $el.FindAll('Descendants', $liCond) | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
    if (-not $it) { return $null }
    $c = $it.FindFirst('Children', $cmCond)
    if (-not $c) { return '(no Comments cell)' }
    $c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
  } catch { $null }
}
function Tip([string]$folder) { $b = [IO.File]::ReadAllBytes("$folder\desktop.ini"); [regex]::Match([Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2), '(?m)^InfoTip=(.*?)\r?$').Groups[1].Value }
function WaitCell([long]$h, [string]$want) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $Wait) { if ((Cell $h 'bravo') -eq $want) { return ((Get-Date) - $t0).TotalSeconds }; Start-Sleep -Milliseconds 150 }
  -1
}

$SAME = 0x1; $NOHIST = 0x08000000
$UPDATEITEM = 0x2000; $PATHW_FLUSH = 0x1005
$parent = Split-Path $tree -Parent
$bravo = "$tree\bravo"
$results = [ordered]@{}
$big = "$bravo\big.bin"
$n = 0
foreach ($r in 1..$Rounds) {
  foreach ($m in $Methods) {
    $n++
    $fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); $fs.SetLength(1MB + $n * 64KB); $fs.Close()
    if ($m -like 'fs-*') { $env:SIZELENS_NO_NOTIFY = '1' }
    & $Exe scan $tree | Out-Null
    Remove-Item Env:\SIZELENS_NO_NOTIFY -ErrorAction SilentlyContinue
    $want = Tip $bravo
    $win = ByHwnd $hwnd
    $check = $hwnd
    $extra = $null
    switch ($m) {
      'none'                { }
      'refresh'             { $win.Refresh() }
      'browse-same'         { [void][SizeLensTest.ExplorerView]::Browse($win, $tree, $SAME) }
      'navigate2-same'      { $win.Navigate2($tree) }
      'parent-and-back'     { [void][SizeLensTest.ExplorerView]::Browse($win, $parent, $SAME -bor $NOHIST); Start-Sleep -Milliseconds 400; [void][SizeLensTest.ExplorerView]::Browse($win, $tree, $SAME -bor $NOHIST) }
      'new-window'          { $extra = OpenWin $tree; $check = $extra.HWND }
      'mtime-plus2'         { $d = Get-Item -LiteralPath $bravo; $d.LastWriteTimeUtc = $d.LastWriteTimeUtc.AddSeconds(2); [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null) }
      'mtime-plus2-refresh' { $d = Get-Item -LiteralPath $bravo; $d.LastWriteTimeUtc = $d.LastWriteTimeUtc.AddSeconds(2); $win.Refresh() }
      'fs-replace'          {
        # desktop.ini swapped in by rename (a new file, new file ID), then UPDATEITEM on the folder
        $ini = "$bravo\desktop.ini"; $tmp = "$bravo\desktop.ini.new"; $d = Get-Item -LiteralPath $bravo; $mt = $d.LastWriteTimeUtc
        [IO.File]::WriteAllBytes($tmp, [IO.File]::ReadAllBytes($ini)); (Get-Item -LiteralPath $ini -Force).Attributes = 'Normal'
        if (-not [SL.N]::MoveFileEx($tmp, $ini, 1)) { throw "MoveFileEx failed" }; (Get-Item -LiteralPath $ini -Force).Attributes = 'Hidden, System'
        (Get-Item -LiteralPath $bravo).LastWriteTimeUtc = $mt
        [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null)
      }
      'fs-delete-recreate'  {
        $ini = "$bravo\desktop.ini"; $bytes = [IO.File]::ReadAllBytes($ini); $d = Get-Item -LiteralPath $bravo; $mt = $d.LastWriteTimeUtc
        (Get-Item -LiteralPath $ini -Force).Attributes = 'Normal'; Remove-Item -LiteralPath $ini -Force
        [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null); Start-Sleep -Milliseconds 300
        [IO.File]::WriteAllBytes($ini, $bytes); (Get-Item -LiteralPath $ini -Force).Attributes = 'Hidden, System'
        (Get-Item -LiteralPath $bravo).LastWriteTimeUtc = $mt
        [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null)
      }
      'fs-ini-mtime-jump'   {
        # desktop.ini's own modified time moved at least 61 s past the previous version's
        $ini = "$bravo\desktop.ini"; $f = Get-Item -LiteralPath $ini -Force
        $t = [DateTime]::UtcNow; if ($script:lastIni -and $t -lt $script:lastIni.AddSeconds(61)) { $t = $script:lastIni.AddSeconds(61) }
        $f.LastWriteTimeUtc = $t; $script:lastIni = $t
        [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null)
      }
      'fs-ini-notify'       {
        # the file-level events Explorer would get if it watched the subfolder: desktop.ini changed, then the folder
        [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, "$bravo\desktop.ini", $null)
        [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null)
      }
      'mtime-bounce'        {
        $d = Get-Item -LiteralPath $bravo; $orig = $d.LastWriteTimeUtc
        $d.LastWriteTimeUtc = $orig.AddSeconds(2); [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null)
        Start-Sleep -Milliseconds 700
        (Get-Item -LiteralPath $bravo).LastWriteTimeUtc = $orig; [SL.N]::SHChangeNotify($UPDATEITEM, $PATHW_FLUSH, $bravo, $null)
      }
    }
    $seen = WaitCell $check $want
    $shown = Cell $check 'bravo'
    if ($extra) { $extra.Quit(); Start-Sleep -Milliseconds 500 }
    Start-Sleep -Milliseconds 300
    $w2 = ByHwnd $hwnd
    $kept = $w2 -and ($w2.Document.Folder.Self.Path -eq $tree) -and ((Cols $w2) -eq $cols0) -and ($w2.Document.SortColumns -eq 'prop:-System.Comment;') -and ($w2.Document.CurrentViewMode -eq $viewMode)
    if (-not $results.Contains($m)) { $results[$m] = @{ ok = 0; n = 0; t = @(); kept = 0 } }
    $results[$m].n++; if ($seen -ge 0) { $results[$m].ok++; $results[$m].t += $seen }; if ($kept) { $results[$m].kept++ }
    Note ("{0,-20} round {1}: want {2} -> {3}; view kept: {4}" -f $m, $r, $want, $(if ($seen -ge 0) { "SHOWN after {0:N1} s" -f $seen } else { "STALE ('$shown')" }), $kept)
    Start-Sleep -Seconds $Gap
  }
}
Note ''
Note ("summary (shown within {0} s / trials, median time, window kept its folder, columns, sort and view):" -f $Wait)
foreach ($m in $results.Keys) {
  $x = $results[$m]; $med = if ($x.t.Count) { ($x.t | Sort-Object)[[int][Math]::Floor($x.t.Count / 2)] } else { $null }
  Note ("  {0,-20} {1}/{2}  {3,6}  kept {4}/{2}" -f $m, $x.ok, $x.n, $(if ($null -ne $med) { "{0:N1} s" -f $med } else { '-' }), $x.kept)
}
} finally { $w = ByHwnd $hwnd; if ($w) { $w.Quit() } }
& $Exe clean $tree | Out-Null
Remove-Item -LiteralPath $tree -Recurse -Force
$file = Join-Path $PSScriptRoot 'renavigate-results.txt'
$prev = if (Test-Path $file) { [IO.File]::ReadAllText($file) + "`r`n`r`n" } else { '' }
[IO.File]::WriteAllText($file, $prev + ("# {0} {1}`r`n" -f (Get-Date -Format s), $Label) + ($out -join "`r`n"), (New-Object Text.UTF8Encoding $false))
