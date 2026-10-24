# Probe: does the shell report a folder's desktop.ini InfoTip as System.Comment ("Comments" column)?
# Scratch only: works inside test-tree\probe in the project folder.
$ErrorActionPreference = 'Stop'
$base = Join-Path (Split-Path $PSScriptRoot -Parent) 'test-tree\probe'
if (Test-Path $base) {
  Get-ChildItem $base -Force -Recurse | ForEach-Object { $_.Attributes = 'Normal' }
  Remove-Item $base -Recurse -Force
}
New-Item -ItemType Directory -Force $base | Out-Null

function New-Probe($name, $bytes, $attr) {
  $d = Join-Path $base $name
  New-Item -ItemType Directory $d | Out-Null
  $ini = Join-Path $d 'desktop.ini'
  [IO.File]::WriteAllBytes($ini, $bytes)
  (Get-Item $ini -Force).Attributes = 'Hidden, System'
  if ($attr) { (Get-Item $d).Attributes = $attr }
  $d
}
$ascii = [Text.Encoding]::ASCII.GetBytes("[.ShellClassInfo]`r`nInfoTip=ansi tip`r`n")
$u16 = [byte[]](0xFF,0xFE) + [Text.Encoding]::Unicode.GetBytes("[.ShellClassInfo]`r`nInfoTip=utf16 tip`r`n")
$u8 = [byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes("[.ShellClassInfo]`r`nInfoTip=utf8bom tip`r`n")
New-Probe 'ansi-ro' $ascii 'Directory, ReadOnly' | Out-Null
New-Probe 'utf16-ro' $u16 'Directory, ReadOnly' | Out-Null
New-Probe 'utf8bom-ro' $u8 'Directory, ReadOnly' | Out-Null
New-Probe 'ansi-sys' $ascii 'Directory, System' | Out-Null
New-Probe 'ansi-noattr' $ascii $null | Out-Null

$shell = New-Object -ComObject Shell.Application
$ns = $shell.NameSpace($base)
$idx = -1
for ($i = 0; $i -lt 400; $i++) { if ($ns.GetDetailsOf($null, $i) -eq 'Comments') { $idx = $i; break } }
"Comments column index: $idx"
foreach ($it in $ns.Items()) {
  [pscustomobject]@{
    Name = $it.Name
    Comments = $ns.GetDetailsOf($it, $idx)
    SystemComment = $it.ExtendedProperty('System.Comment')
    InfoTip = $it.ExtendedProperty('System.InfoTipText')
  }
}
