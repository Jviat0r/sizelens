<#
Makes File Explorer show the Comments column (where SizeLens puts folder sizes) by default, for the
current user only (no admin). Run through install.ps1 -AddCommentsColumn; undone by uninstall.ps1, or
run this with -Remove.

How: Explorer's column defaults per folder type live in
  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes\{type}\TopViews\{view}\ColumnList
and a per-user copy under HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes wins
over it. For the folder types General items, Documents, Pictures, Music, Videos and Downloads this
copies the Windows default into HKCU (if there is no per-user copy yet) and adds System.Comment to its
ColumnList as a shown column. HKLM is only read.

Before it writes anything it exports the current HKCU FolderTypes key to
%LOCALAPPDATA%\SizeLens\backups\foldertypes-before-<time>.reg, and it records every key it created
and every value it changed (with the old value) in %LOCALAPPDATA%\SizeLens\comments-column.tsv,
which -Remove reads to put things back.

What still wins over these defaults:
  - a folder's own saved view (you changed its columns, sort or layout before), and
  - "Apply to Folders" settings you made for a folder type (HKCU\...\Explorer\Streams\Defaults).
This script tells you which folder types have Apply to Folders settings and whether they already
include Comments. It changes neither.

Explorer reads these defaults when it starts: restart Explorer (or sign out and in) to see them.

  -Remove     undo what an earlier run did
  -Key, -SourceKey, -DefaultsKey, -StateDir   for tests only (point it at scratch keys/folders)
#>
param(
  [switch]$Remove,
  [string]$Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes',
  [string]$SourceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes',
  [string]$DefaultsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Defaults',
  [string]$StateDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $StateDir) { $StateDir = if ($env:SIZELENS_HOME) { $env:SIZELENS_HOME } else { Join-Path $env:LOCALAPPDATA 'SizeLens' } }
$record = Join-Path $StateDir 'comments-column.tsv'
$utf8 = New-Object Text.UTF8Encoding $false

$types = [ordered]@{
  '{5c4f28b5-f869-4e84-8e60-f11db97c5cc7}' = 'General items'
  '{7d49d726-3c21-4f05-99aa-fdc2c9474656}' = 'Documents'
  '{b3690e58-e961-423b-b687-386ebfd83239}' = 'Pictures'
  '{94d6ddcc-4a68-4175-a374-bd584a510b78}' = 'Music'
  '{5fa96407-7e77-483c-ac93-691d05850de8}' = 'Videos'
  '{885a186e-a440-4ada-812b-db871b942259}' = 'Downloads'
}

function RegPath([string]$psPath) { $psPath -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\' }

# "prop:0(34)System.ItemNameDisplay;0System.DateModified;...;1System.Title" -> Comments added as a
# shown column (prefix 0) right after the last shown one. Returns $null when it is already there.
function WithComments([string]$list) {
  if (-not $list.StartsWith('prop:')) { return $null }
  $cols = @($list.Substring(5).Split(';') | Where-Object { $_ -ne '' })
  if (@($cols | Where-Object { $_ -match '^\d(\(\d+\))?System\.Comment$' }).Count) { return $null }
  $lastShown = -1
  for ($i = 0; $i -lt $cols.Count; $i++) { if ($cols[$i].StartsWith('0')) { $lastShown = $i } }
  $new = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $cols.Count; $i++) { $new.Add($cols[$i]); if ($i -eq $lastShown) { $new.Add('0System.Comment') } }
  if ($lastShown -lt 0) { $new.Insert(0, '0System.Comment') }
  'prop:' + ($new -join ';')
}

# Does a saved "Apply to Folders" stream mention the Comments property key {F29F85E0-...},6 ?
function HasCommentKey([byte[]]$b) {
  $pk = [byte[]](0xE0, 0x85, 0x9F, 0xF2, 0xF9, 0x4F, 0x68, 0x10, 0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9)
  for ($i = 0; $i -le $b.Length - 16; $i++) {
    $ok = $true
    for ($j = 0; $j -lt 16; $j++) { if ($b[$i + $j] -ne $pk[$j]) { $ok = $false; break } }
    if ($ok) { return $true }
  }
  $false
}

if ($Remove) {
  if (-not (Test-Path -LiteralPath $record)) { Write-Host "Comments column defaults: nothing to undo (no $record)."; return }
  $lines = @([IO.File]::ReadAllLines($record, $utf8) | Where-Object { $_ -and -not $_.StartsWith('#') })
  $base = ($lines | Where-Object { $_.StartsWith("key`t") } | Select-Object -First 1)
  $base = if ($base) { $base.Split("`t")[1] } else { $Key }
  [array]::Reverse($lines)
  foreach ($l in $lines) {
    $f = $l.Split("`t")
    switch ($f[0]) {
      'created' {
        $p = Join-Path $base $f[1]
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Host "removed  $(RegPath $p)" }
      }
      'changed' {
        $p = Join-Path $base $f[1]
        if (Test-Path -LiteralPath $p) { Set-ItemProperty -LiteralPath $p -Name $f[2] -Value $f[3]; Write-Host "restored $(RegPath $p)  $($f[2])" }
      }
    }
  }
  Remove-Item -LiteralPath $record -Force
  Write-Host "Comments column defaults removed. Restart Explorer (or sign out and in) for it to take effect."
  return
}

# ---------- add ----------
New-Item -ItemType Directory -Force (Join-Path $StateDir 'backups') | Out-Null
if (Test-Path -LiteralPath $Key) {
  $bak = Join-Path $StateDir ('backups\foldertypes-before-{0}.reg' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  & reg.exe export (RegPath $Key) $bak /y | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bak)) { throw "could not back up $(RegPath $Key); nothing was changed" }
  Write-Host "backup   $bak"
} else {
  New-Item -Path $Key -Force | Out-Null
}
$log = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath $record)) { $log.Add("# SizeLens: what comments-column.ps1 changed (read by -Remove). kind`tsubkey`tvalue`told value"); $log.Add("key`t$Key") }

foreach ($id in $types.Keys) {
  $name = $types[$id]
  $src = Join-Path $SourceKey $id
  if (-not (Test-Path -LiteralPath $src)) { Write-Host "skipped  $name (no Windows default for it on this PC)"; continue }
  $dst = Join-Path $Key $id
  if (-not (Test-Path -LiteralPath $dst)) {
    Copy-Item -LiteralPath $src -Destination $Key -Recurse
    $log.Add("created`t$id")
    $created = $true
  } else {
    $created = $false
    if (-not (Test-Path -LiteralPath (Join-Path $dst 'TopViews')) -and (Test-Path -LiteralPath (Join-Path $src 'TopViews'))) {
      Copy-Item -LiteralPath (Join-Path $src 'TopViews') -Destination $dst -Recurse
      $log.Add("created`t$id\TopViews")
      $created = $true   # the whole TopViews subkey goes on -Remove
    }
  }
  $n = 0
  foreach ($view in @(Get-ChildItem -LiteralPath (Join-Path $dst 'TopViews') -ErrorAction SilentlyContinue)) {
    $old = (Get-ItemProperty -LiteralPath $view.PSPath -Name ColumnList -ErrorAction SilentlyContinue).ColumnList
    if (-not $old) { continue }
    $new = WithComments $old
    if (-not $new) { continue }
    if (-not $created) { $log.Add("changed`t$id\TopViews\$($view.PSChildName)`tColumnList`t$old") }
    Set-ItemProperty -LiteralPath $view.PSPath -Name ColumnList -Value $new
    $n++
  }
  Write-Host ("{0,-8} {1}: Comments added to {2} view(s)" -f $(if ($created) { 'added' } else { 'updated' }), $name, $n)
}
if ($log.Count) { [IO.File]::AppendAllText($record, (($log -join "`r`n") + "`r`n"), $utf8) }

# ---------- what still overrides it ----------
$own = @()
if (Test-Path -LiteralPath $DefaultsKey) {
  $d = Get-Item -LiteralPath $DefaultsKey
  foreach ($id in $types.Keys) {
    $v = $d.GetValue($id.ToUpper()); if ($null -eq $v) { $v = $d.GetValue($id) }
    if ($v -is [byte[]]) { $own += [pscustomobject]@{ Name = $types[$id]; HasComments = (HasCommentKey $v) } }
  }
}
Write-Host ""
foreach ($o in $own) {
  if ($o.HasComments) { Write-Host "note     $($o.Name): you used Apply to Folders for this type before; that setting wins and it already shows Comments." }
  else { Write-Host "note     $($o.Name): you used Apply to Folders for this type before and that setting (no Comments) wins. Open a folder of this type, tick Comments, then View > Options > View > Apply to Folders." }
}
Write-Host "Restart Explorer to pick this up: Task Manager > Windows Explorer > Restart (open folder windows close), or sign out and back in."
Write-Host "Folders whose view you saved before (changed columns or sort there) keep that view: tick Comments there once."
