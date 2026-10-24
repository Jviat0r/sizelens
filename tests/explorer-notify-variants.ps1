# Which change notification makes an open Explorer window re-read a folder's desktop.ini?
# For each variant: change bravo's size, scan with SizeLens's own notifications OFF, send only that
# variant, then time how long the window takes to show the new Comments value (UI Automation, read only).
param([string[]]$Variants = @('none', 'updateitem', 'updatedir-self', 'updatedir-parent', 'attributes', 'renamefolder', 'attr-bounce', 'updateitem-ini'), [int]$Rounds = 2, [int]$Gap = 2, [int]$Wait = 8)
$ErrorActionPreference = 'Continue'
$proj = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $proj 'target\release\sizelens.exe'
$root = Join-Path $proj 'test-tree\root'
$bravo = Join-Path $root 'bravo'
$env:SIZELENS_HOME = Join-Path $proj 'test-home'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace SL -Name N -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern void SHChangeNotify(int e, uint f, string a, string b);
'@
$SHCNE = @{ updateitem = 0x2000; updatedir = 0x1000; attributes = 0x800; renamefolder = 0x20000 }
$PATHW_FLUSH = 0x0005 -bor 0x1000
$shell = New-Object -ComObject Shell.Application
foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $root) { $win = $w } } catch {} }
$el = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$win.HWND)
$liCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
function Cell {
  $it = $el.FindAll('Descendants', $liCond) | Where-Object { $_.Current.Name -eq 'bravo' } | Select-Object -First 1
  $c = $it.FindFirst('Children', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'System.Comment')))
  $c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
}
function Tip { $b = [IO.File]::ReadAllBytes("$bravo\desktop.ini"); [regex]::Match([Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2), '(?m)^InfoTip=(.*?)\r?$').Groups[1].Value }
$big = "$bravo\big.bin"
$origLen = (Get-Item -LiteralPath $big).Length; $origTime = (Get-Item -LiteralPath $big).LastWriteTimeUtc
$n = 0
$out = @()
foreach ($r in 1..$Rounds) {
  foreach ($v in $Variants) {
    $n++
    $fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); $fs.SetLength($origLen + $n * 1MB); $fs.Close()
    if ($v -eq 'sizelens') { & $exe scan $root | Out-Null } else { $env:SIZELENS_NO_NOTIFY = '1'; & $exe scan $root | Out-Null; Remove-Item Env:\SIZELENS_NO_NOTIFY }
    switch ($v) {
      'updateitem'       { [SL.N]::SHChangeNotify($SHCNE.updateitem, $PATHW_FLUSH, $bravo, $null) }
      'mtime-tick'       { $d = Get-Item -LiteralPath $bravo; $m = $d.LastWriteTimeUtc; $d.LastWriteTimeUtc = $(if ($m.Ticks % 2) { $m.AddTicks(-1) } else { $m.AddTicks(1) }); [SL.N]::SHChangeNotify($SHCNE.updateitem, $PATHW_FLUSH, $bravo, $null) }
      'refresh'          { $win.Refresh() }
      'size-bounce'      {
        $ini = "$bravo\desktop.ini"; $f = Get-Item -LiteralPath $ini -Force; $a = $f.Attributes; $f.Attributes = 'Normal'
        $b = [IO.File]::ReadAllBytes($ini); $s = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2)
        if ($s.EndsWith("`r`n`r`n")) { $s = $s.Substring(0, $s.Length - 2) } else { $s += "`r`n" }
        [IO.File]::WriteAllBytes($ini, [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($s)); (Get-Item -LiteralPath $ini -Force).Attributes = $a
        [SL.N]::SHChangeNotify($SHCNE.updateitem, $PATHW_FLUSH, $bravo, $null)
      }      'two-items'        { [SL.N]::SHChangeNotify($SHCNE.updateitem, $PATHW_FLUSH, (Join-Path $root 'alpha'), $null); Start-Sleep -Milliseconds 300; [SL.N]::SHChangeNotify($SHCNE.updateitem, $PATHW_FLUSH, $bravo, $null) }
      'updatedir-self'   { [SL.N]::SHChangeNotify($SHCNE.updatedir, $PATHW_FLUSH, $bravo, $null) }
      'updatedir-parent' { [SL.N]::SHChangeNotify($SHCNE.updatedir, $PATHW_FLUSH, $root, $null) }
      'attributes'       { [SL.N]::SHChangeNotify($SHCNE.attributes, $PATHW_FLUSH, $bravo, $null) }
      'renamefolder'     { [SL.N]::SHChangeNotify($SHCNE.renamefolder, $PATHW_FLUSH, $bravo, $bravo) }
      'updateitem-ini'   { [SL.N]::SHChangeNotify($SHCNE.updateitem, $PATHW_FLUSH, "$bravo\desktop.ini", $null); [SL.N]::SHChangeNotify($SHCNE.updateitem, $PATHW_FLUSH, $bravo, $null) }
      'attr-bounce'      {
        # a real file-system change on the folder entry: clear Read-only and set it again
        $d = Get-Item -LiteralPath $bravo; $a = $d.Attributes
        $d.Attributes = ($a -band (-bnot [IO.FileAttributes]::ReadOnly)); $d.Attributes = $a
      }
    }
    $want = Tip; $t0 = Get-Date; $seen = -1
    while (((Get-Date) - $t0).TotalSeconds -lt $Wait) { if ((Cell) -eq $want) { $seen = ((Get-Date) - $t0).TotalSeconds; break }; Start-Sleep -Milliseconds 200 }
    $line = "{0,-17} want {1}  -> {2}" -f $v, $want, $(if ($seen -ge 0) { "SHOWN after {0:N1} s" -f $seen } else { "stale ('$(Cell)')" })
    Write-Host $line; $out += $line
    Start-Sleep -Seconds $Gap
  }
}
$fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); $fs.SetLength($origLen); $fs.Close(); (Get-Item -LiteralPath $big).LastWriteTimeUtc = $origTime
& $exe scan $root | Out-Null
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'notify-variants.txt'), ($out -join "`r`n"), (New-Object Text.UTF8Encoding $false))
