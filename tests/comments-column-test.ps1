# Tests comments-column.ps1 (install.ps1 -AddCommentsColumn) against a SCRATCH registry key,
# HKCU\Software\SizeLensTest\FolderTypes, never the real Explorer key. HKLM and the real
# Streams\Defaults are only read. The scratch key is deleted at the end.
$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
$script = Join-Path $proj 'comments-column.ps1'
$scratch = 'HKCU:\Software\SizeLensTest'
$key = "$scratch\FolderTypes"
$state = Join-Path $proj 'test-home-columns'
$src = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes'
$pass = 0; $fail = 0
$out = New-Object System.Collections.Generic.List[string]
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; $s = "PASS  $name" } else { $script:fail++; $s = "FAIL  $name" }
  if ($detail) { $s += "  ($detail)" }
  $script:out.Add($s); Write-Host $s
}
function Dump([string]$k) {
  # every key, value name and value under $k, sorted: a byte-for-byte comparable snapshot
  if (-not (Test-Path -LiteralPath $k)) { return '<missing>' }
  $lines = foreach ($i in @(Get-Item -LiteralPath $k) + @(Get-ChildItem -LiteralPath $k -Recurse)) {
    $rel = $i.Name.Substring((Get-Item -LiteralPath $k).Name.Length)
    "[$rel]"
    foreach ($n in ($i.Property | Sort-Object)) { "  $n = $($i.GetValue($n, $null, 'DoNotExpandEnvironmentNames') -join ',') ($($i.GetValueKind($n)))" }
  }
  ($lines | Sort-Object) -join "`n"
}
$gen = '{5c4f28b5-f869-4e84-8e60-f11db97c5cc7}'; $docs = '{7d49d726-3c21-4f05-99aa-fdc2c9474656}'; $pics = '{b3690e58-e961-423b-b687-386ebfd83239}'
if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
if (Test-Path $state) { Remove-Item $state -Recurse -Force }
try {
  # Starting state like this PC's HKCU: an unrelated per-user type (DefaultView only), plus a
  # per-user Documents copy with its own ColumnList, to check existing values are backed up and restored.
  New-Item "$key\{36011842-DCCC-40FE-AA3D-6177EA401788}" -Force | Out-Null
  Set-ItemProperty "$key\{36011842-DCCC-40FE-AA3D-6177EA401788}" -Name DefaultView -Value '{424C81AB-7A7B-4FC1-A848-DDBADC10CDF5}'
  New-Item "$key\$docs\TopViews\{00000000-0000-0000-0000-000000000000}" -Force | Out-Null
  Set-ItemProperty "$key\$docs\TopViews\{00000000-0000-0000-0000-000000000000}" -Name ColumnList -Value 'prop:0(34)System.ItemNameDisplay;0System.Size;1System.Title'
  Set-ItemProperty "$key\$docs\TopViews\{00000000-0000-0000-0000-000000000000}" -Name LogicalViewMode -Value 1 -Type DWord
  $before = Dump $key

  $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Key $key -StateDir $state 2>&1 | Out-String
  $out.Add("first run output:`n$($o1.TrimEnd())")
  $g = (Get-ItemProperty "$key\$gen\TopViews\{00000000-0000-0000-0000-000000000000}").ColumnList
  $gHk = (Get-ItemProperty "$src\$gen\TopViews\{00000000-0000-0000-0000-000000000000}").ColumnList
  Check 'General items: Windows default copied, Comments added as a shown column right after Size' ($g -eq ($gHk -replace ';0System\.Size;', ';0System.Size;0System.Comment;')) $g
  $copyOk = $true
  foreach ($sub in @(Get-ChildItem "$src\$gen" -Recurse)) {
    $rel = $sub.Name.Substring((Get-Item "$src\$gen").Name.Length)
    $d = Get-Item -LiteralPath ("$key\$gen" + $rel)
    foreach ($n in $sub.Property) { if ($n -ne 'ColumnList' -and "$($d.GetValue($n))" -ne "$($sub.GetValue($n))") { $copyOk = $false } }
  }
  foreach ($n in (Get-Item "$src\$gen").Property) { if ("$((Get-Item "$key\$gen").GetValue($n))" -ne "$((Get-Item "$src\$gen").GetValue($n))") { $copyOk = $false } }
  Check 'General items: every other key and value is an exact copy of the Windows default' $copyOk
  $p = (Get-ItemProperty "$key\$pics\TopViews\{00000000-0000-0000-0000-000000000000}").ColumnList
  Check 'Pictures: Comments added' ($p -match ';0System\.Comment;') $p
  $d = (Get-ItemProperty "$key\$docs\TopViews\{00000000-0000-0000-0000-000000000000}").ColumnList
  Check 'Documents (already had a per-user copy): its own list kept, Comments added' ($d -eq 'prop:0(34)System.ItemNameDisplay;0System.Size;0System.Comment;1System.Title') $d
  Check 'unrelated per-user type untouched' ((Get-ItemProperty "$key\{36011842-DCCC-40FE-AA3D-6177EA401788}").DefaultView -eq '{424C81AB-7A7B-4FC1-A848-DDBADC10CDF5}')
  $bak = @(Get-ChildItem (Join-Path $state 'backups') -Filter 'foldertypes-before-*.reg')
  $bakText = if ($bak.Count) { [IO.File]::ReadAllText($bak[0].FullName) } else { '' }
  Check 'backup .reg of the key written before any change, holding the old Documents ColumnList' ($bak.Count -eq 1 -and $bakText.Contains('prop:0(34)System.ItemNameDisplay;0System.Size;1System.Title') -and -not $bakText.Contains('System.Comment')) "$($bak.Count) file(s)"
  Check 'HKLM default unchanged' (-not ((Get-ItemProperty "$src\$gen\TopViews\{00000000-0000-0000-0000-000000000000}").ColumnList -match 'System\.Comment'))

  $mid = Dump $key
  $recLines = @(Get-Content (Join-Path $state 'comments-column.tsv')).Count
  $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Key $key -StateDir $state 2>&1 | Out-String
  Check 'second run changes nothing' ((Dump $key) -eq $mid -and @(Get-Content (Join-Path $state 'comments-column.tsv')).Count -eq $recLines)

  $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Remove -Key $key -StateDir $state 2>&1 | Out-String
  $out.Add("remove output:`n$($o3.TrimEnd())")
  $after = Dump $key
  Check '-Remove puts the key back exactly as it was' ($after -eq $before)
  Check '-Remove deletes its record' (-not (Test-Path (Join-Path $state 'comments-column.tsv')))
  $o4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Remove -Key $key -StateDir $state 2>&1 | Out-String
  Check '-Remove again: nothing to undo' ($o4 -match 'nothing to undo')

  # Fresh user: no per-user FolderTypes key at all.
  Remove-Item $scratch -Recurse -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Key $key -StateDir $state 2>&1 | Out-Null
  Check 'no per-user key before: all 6 types added' (@(Get-ChildItem $key).Count -eq 6)
  & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Remove -Key $key -StateDir $state 2>&1 | Out-Null
  Check '...and -Remove leaves no type keys behind' (@(Get-ChildItem $key).Count -eq 0)
} finally {
  if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
  if (Test-Path $state) { Remove-Item $state -Recurse -Force }
}
$out.Add("comments-column: $pass passed, $fail failed")
Write-Host "comments-column: $pass passed, $fail failed"
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'comments-column-results.txt'), ($out -join "`r`n"), (New-Object Text.UTF8Encoding $false))
if ($fail) { exit 1 }
