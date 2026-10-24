# Captures the scratch folder's Explorer window to a PNG (PrintWindow: a picture of the window, no input sent)
# and prints what UI Automation reports for bravo at the same moment.
param([string]$Out = (Join-Path $PSScriptRoot 'explorer-window.png'))
$root = Join-Path (Split-Path $PSScriptRoot -Parent) 'test-tree\root'
Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace SL -Name P -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr dc, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
'@
$shell = New-Object -ComObject Shell.Application
foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $root) { $win = $w } } catch {} }
$h = [IntPtr]$win.HWND
$r = New-Object SL.P+RECT; [void][SL.P]::GetWindowRect($h, [ref]$r)
$bmp = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
$g = [Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
[void][SL.P]::PrintWindow($h, $dc, 2)   # PW_RENDERFULLCONTENT
$g.ReleaseHdc($dc); $g.Dispose(); $bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
$el = [Windows.Automation.AutomationElement]::FromHandle($h)
$liCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
$it = $el.FindAll('Descendants', $liCond) | Where-Object { $_.Current.Name -eq 'bravo' } | Select-Object -First 1
$c = $it.FindFirst('Children', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'System.Comment')))
"UIA bravo: " + $c.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
$b = [IO.File]::ReadAllBytes("$root\bravo\desktop.ini"); "ini bravo: " + [regex]::Match([Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2), '(?m)^InfoTip=(.*?)\r?$').Groups[1].Value
"saved $Out"
