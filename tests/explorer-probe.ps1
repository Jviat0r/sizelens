# Read-only look at an open Explorer window on a scratch folder through UI Automation:
# what columns it shows and what each row's cells say. Sends no clicks or keys.
param([string]$Folder = (Join-Path (Split-Path $PSScriptRoot -Parent) 'test-tree\root'))
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$shell = New-Object -ComObject Shell.Application
$win = $null
foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $Folder) { $win = $w } } catch {} }
if (-not $win) { Start-Process explorer.exe $Folder; Start-Sleep -Seconds 3; foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $Folder) { $win = $w } } catch {} } }
if (-not $win) { "no window"; exit 1 }
"HWND $($win.HWND)  view mode $($win.Document.CurrentViewMode)  sort '$($win.Document.SortColumns)'"
$el = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$win.HWND)
$hdr = $el.FindAll('Descendants', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::HeaderItem)))
"columns: " + (($hdr | ForEach-Object { $_.Current.Name }) -join ' | ')
$items = $el.FindAll('Descendants', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)))
foreach ($it in $items) {
  $cells = $it.FindAll('Children', [Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
    $v = ''; try { $v = $_.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value } catch {}
    "$($_.Current.AutomationId)=[$($_.Current.Name)|$v]"
  }
  "$($it.Current.Name): " + ($cells -join '  ')
}
