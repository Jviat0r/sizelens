# SizeLens integration tests. Touches ONLY test-tree\ and test-home\ in the project folder.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$proj = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $proj 'target\release\sizelens.exe'
$tree = Join-Path $proj 'test-tree'
$root = Join-Path $tree 'root'
$outside = Join-Path $tree 'outside'
$env:SIZELENS_HOME = Join-Path $proj 'test-home'
$me = "$env:USERDOMAIN\$env:USERNAME"
$results = New-Object System.Collections.Generic.List[string]
$fails = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
  $line = ('{0}  {1}{2}' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { " -- $detail" } else { '' }))
  $script:results.Add($line); Write-Host $line
  if (-not $ok) { $script:fails++ }
}
function Note([string]$s) { $script:results.Add($s); Write-Host $s }
function ToLongPath([string]$p) { if ($p.StartsWith('\\?\')) { $p } else { '\\?\' + $p } }
function Run([string[]]$a) {
  $out = & $exe @a 2>&1 | Out-String
  return @{ code = $LASTEXITCODE; out = $out }
}

# ---------- fresh scratch tree ----------
if (Test-Path $tree) {
  & icacls (Join-Path $root 'golf-denied\locked') /remove:d $me 2>$null | Out-Null
  & icacls (Join-Path $tree 'deeproot\L1a\L2\locked') /remove:d $me 2>$null | Out-Null
  & cmd /c "rmdir /s /q `"$tree`"" 2>$null
  if (Test-Path $tree) {
    Get-ChildItem -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
    & cmd /c "rmdir /s /q `"$tree`""
  }
}
if (Test-Path $env:SIZELENS_HOME) { Remove-Item $env:SIZELENS_HOME -Recurse -Force }
New-Item -ItemType Directory -Force $root, $outside | Out-Null

function MkFile([string]$path, [long]$len) {
  $p = ToLongPath $path
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)) | Out-Null
  $fs = [IO.File]::Open($p, 'Create')
  try {
    $buf = New-Object byte[] ([Math]::Min($len, 65536))
    (New-Object Random 7).NextBytes($buf)
    $left = $len
    while ($left -gt 0) { $n = [Math]::Min($left, $buf.Length); $fs.Write($buf, 0, $n); $left -= $n }
  } finally { $fs.Close() }
}

# alpha: small files, nesting, a hidden file and a dotfile
MkFile "$root\alpha\a.bin" 1000
MkFile "$root\alpha\b.bin" 2500
MkFile "$root\alpha\sub1\c.bin" 4096
MkFile "$root\alpha\sub1\sub2\d.bin" 123457
MkFile "$root\alpha\h.bin" 777; (Get-Item -LiteralPath "$root\alpha\h.bin" -Force).Attributes = 'Hidden'
MkFile "$root\alpha\.dotfile" 10
# bravo: 12 MB
MkFile "$root\bravo\big.bin" (12 * 1MB + 3)
# charlie: empty
New-Item -ItemType Directory "$root\charlie" | Out-Null
# delta-icon: pre-existing UTF-16LE desktop.ini with an icon (what Explorer's Customize tab makes), folder already Read-only
MkFile "$root\delta-icon\x.bin" 50000
$deltaIni = "$root\delta-icon\desktop.ini"
$u16 = [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("[.ShellClassInfo]`r`nIconResource=C:\Windows\System32\SHELL32.dll,3`r`n[ViewState]`r`nMode=`r`nVid=`r`nFolderType=Generic`r`n")
[IO.File]::WriteAllBytes($deltaIni, $u16)
(Get-Item -LiteralPath $deltaIni -Force).Attributes = 'Hidden, System, Archive'
(Get-Item -LiteralPath "$root\delta-icon").Attributes = 'Directory, ReadOnly'
# echo-ansi: pre-existing ANSI desktop.ini, LF endings, its own InfoTip, no final newline, Hidden only; folder not RO
MkFile "$root\echo-ansi\e.bin" 3072
$echoIni = "$root\echo-ansi\desktop.ini"
[IO.File]::WriteAllBytes($echoIni, [Text.Encoding]::ASCII.GetBytes("[.ShellClassInfo]`nConfirmFileOp=0`nInfoTip=my own note`n[Other]`nKey=Value"))
(Get-Item -LiteralPath $echoIni -Force).Attributes = 'Hidden'
# foxtrot: a junction inside (must not be followed)
MkFile "$root\foxtrot-junction\f.bin" 5000
& cmd /c "mklink /J `"$root\foxtrot-junction\to-bravo`" `"$root\bravo`"" | Out-Null
# golf: an access-denied subfolder (deny List Folder to me; removed at the end)
MkFile "$root\golf-denied\g.bin" 1234
MkFile "$root\golf-denied\locked\secret.bin" 999999
& icacls "$root\golf-denied\locked" /deny "${me}:(OI)(CI)(RD)" | Out-Null
# hotel: a 3 GB sparse file (logical size 3 GB, ~0 on disk) to exercise GB formatting
$sparseOk = $false
try {
  $sp = "$root\hotel-sparse\three-gb.bin"
  New-Item -ItemType Directory "$root\hotel-sparse" | Out-Null
  [IO.File]::WriteAllBytes($sp, [byte[]]@())
  & fsutil sparse setflag $sp | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $fs = [IO.File]::Open($sp, 'Open'); $fs.SetLength(3GB); $fs.Close(); $sparseOk = $true
  }
} catch { }
# india: a path longer than 260 characters
$deep = "$root\india-long"
foreach ($i in 1..6) { $deep += '\' + ('segment-{0}-' -f $i) + ('x' * 40) }
MkFile "$deep\deep.bin" 4321
# juliet: non-ASCII name
MkFile "$root\juliet-$([char]0xFC)nic$([char]0xF6)de\j.bin" 100
# kilo: hidden+system subfolder (must be skipped)
MkFile "$root\kilo-protected\k.bin" 10
(Get-Item -LiteralPath "$root\kilo-protected").Attributes = 'Directory, Hidden, System'
# a junction at the root level pointing outside the root (must be skipped, target untouched)
MkFile "$outside\target\t.bin" 64
& cmd /c "mklink /J `"$root\link-outside`" `"$outside\target`"" | Out-Null
# a loose file at the root (ignored)
MkFile "$root\loose.txt" 42

Note "Tree built. Long path length: $(("$deep\deep.bin").Length) chars. Sparse 3 GB file: $sparseOk"

# ---------- helpers: reference sizes and snapshots ----------
function RefSize([string]$dir) {
  # Same rule as SizeLens: every file (hidden too), don't follow junctions/symlinks,
  # and no file named desktop.ini (they hold the labels).
  $sum = [long]0; $files = 0; $denied = 0
  $stack = New-Object System.Collections.Stack
  $top = New-Object IO.DirectoryInfo (ToLongPath $dir)
  $stack.Push($top)
  while ($stack.Count) {
    $d = $stack.Pop()
    try { $items = $d.GetFileSystemInfos() } catch { $denied++; continue }
    foreach ($i in $items) {
      if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      if ($i.Name -eq 'desktop.ini' -and -not ($i -is [IO.DirectoryInfo])) { continue }
      if ($i -is [IO.DirectoryInfo]) { $stack.Push($i) } else { $sum += $i.Length; $files++ }
    }
  }
  [pscustomobject]@{ Bytes = $sum; Files = $files; Denied = $denied }
}

function Snapshot([string]$base) {
  $lines = New-Object System.Collections.Generic.List[string]
  $sha = [Security.Cryptography.SHA256]::Create()
  $stack = New-Object System.Collections.Stack
  $stack.Push((New-Object IO.DirectoryInfo (ToLongPath $base)))
  $baseLen = (ToLongPath $base).Length
  while ($stack.Count) {
    $d = $stack.Pop()
    try { $items = $d.GetFileSystemInfos() } catch { $lines.Add("$($d.FullName.Substring($baseLen))|<unreadable>"); continue }
    foreach ($i in $items) {
      $rel = $i.FullName.Substring($baseLen)
      if ($i -is [IO.DirectoryInfo]) {
        $lines.Add("D|$rel|$($i.Attributes)|$($i.LastWriteTimeUtc.Ticks)")
        if (-not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($i) }
      } else {
        $fs = [IO.File]::OpenRead($i.FullName)
        try {
          if ($fs.Length -gt 64MB) {
            # the 3 GB sparse file: hash the first and last 1 MB (its length and time are recorded too)
            $buf = New-Object byte[] (2MB); [void]$fs.Read($buf, 0, 1MB); [void]$fs.Seek(-1MB, 'End'); [void]$fs.Read($buf, 1MB, 1MB)
            $h = [BitConverter]::ToString($sha.ComputeHash($buf)).Replace('-', '')
          } else { $h = [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') }
        } finally { $fs.Close() }
        $lines.Add("F|$rel|$($i.Attributes)|$($i.Length)|$($i.LastWriteTimeUtc.Ticks)|$h")
      }
    }
  }
  ($lines | Sort-Object) -join "`n"
}

function ShellComments([string]$dir) {
  # In a fresh process each time, so no shell cache from an earlier read can answer.
  $cmd = "`$ns = (New-Object -ComObject Shell.Application).NameSpace('$($dir.Replace("'", "''"))'); foreach (`$it in `$ns.Items()) { `$it.Name + [char]9 + `$it.ExtendedProperty('System.Comment') }"
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = [Text.Encoding]::UTF8; $cmd"))
  $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', "-NoProfile -EncodedCommand $enc"
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $pr = [Diagnostics.Process]::Start($psi); $text = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
  $map = @{}
  foreach ($l in ($text -split "`r?`n")) { if ($l) { $f = $l -split "`t", 2; $map[$f[0]] = $f[1] } }
  $map
}

function IniTip([string]$folder) {
  $p = Join-Path $folder 'desktop.ini'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  $b = [IO.File]::ReadAllBytes($p)
  if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $t = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
  elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF) { $t = [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
  else { $t = [Text.Encoding]::Default.GetString($b) }
  $m = [regex]::Match($t, '(?im)^\s*InfoTip\s*=(.*?)\r?$')
  if ($m.Success) { $m.Groups[1].Value.Trim() } else { '' }
}

# NTFS updates folder timestamps lazily; let them settle before the baseline snapshot.
Start-Sleep -Seconds 3
# A folder's times as listed by its parent are refreshed only after the folder itself is opened, so walk once first.
$null = Snapshot $tree

function SameTree([string]$name, [string]$a, [string]$b) {
  Check $name ($a -eq $b) ''
  if ($a -ne $b) { Compare-Object ($a -split "`n") ($b -split "`n") | Select-Object -First 12 | ForEach-Object { Note "   diff: $($_.SideIndicator) $($_.InputObject)" } }
}
$before = Snapshot $tree
$outsideBefore = Snapshot $outside
# reference totals on the original contents (before SizeLens adds any desktop.ini)
$refs = @{}; $gcis = @{}
foreach ($s in (Get-ChildItem -LiteralPath $root -Directory -Force)) {
  $refs[$s.Name] = RefSize $s.FullName
  $gcis[$s.Name] = (Get-ChildItem -LiteralPath $s.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

# ---------- 1. safety refusals (nothing may be added) ----------
Note "`n== Safety refusals =="
$refuse = @('C:\Windows', 'C:\Windows\System32', $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, (Split-Path $env:USERPROFILE -Parent), "$env:LOCALAPPDATA\Temp", 'D:\', 'C:\', '\\localhost\c$', "$root\link-outside")
if ($env:OneDrive -and (Test-Path $env:OneDrive)) { $refuse += $env:OneDrive }
foreach ($r in $refuse) {
  $res = Run @('add', $r)
  $why = ($res.out -split "`r?`n" | Where-Object { $_ -match 'refused|error' } | Select-Object -First 1)
  Check "refuses add '$r'" ($res.code -ne 0 -and $res.out -notmatch 'opted in:') $why
}
$res = Run @('scan', $root)
Check 'scan of a folder that is not opted in is refused' ($res.code -eq 2) ($res.out.Trim() -split "`r?`n")[0]
$cfg = Get-Content (Join-Path $env:SIZELENS_HOME 'config.txt') -Raw
Check 'config.txt still has no roots after the refusals' (-not ($cfg -match '(?m)^\s*root\s*=')) ''
SameTree 'tree untouched by the refused commands' $before (Snapshot $tree)
# Follow-up rewrites (a second write of each changed label ~1 min later, for open Explorer windows)
# would change desktop.ini times under the snapshots below: off here, tested in section 13.
$cfgPath = Join-Path $env:SIZELENS_HOME 'config.txt'
[IO.File]::WriteAllText($cfgPath, ([IO.File]::ReadAllText($cfgPath) -replace '(?m)^follow_up_seconds = \d+', 'follow_up_seconds = 0'), (New-Object Text.UTF8Encoding $false))

# ---------- 2. dry run writes nothing ----------
Note "`n== Opt in + dry run =="
$res = Run @('add', $root); Check 'add the test root' ($res.code -eq 0) ($res.out.Trim())
$res = Run @('scan', $root, '--dry-run'); Check 'dry run exits 0' ($res.code -eq 0) ''
SameTree 'dry run changed nothing' $before (Snapshot $tree)

# ---------- 3. real scan ----------
Note "`n== Scan =="
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Run @('scan', $root)
$sw.Stop()
Note $res.out.TrimEnd()
Check 'scan exits 0' ($res.code -eq 0) "exit $($res.code), $($sw.ElapsedMilliseconds) ms"

$rows = @{}
Get-Content -Encoding UTF8 (Join-Path $env:SIZELENS_HOME 'sizes.tsv') | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
  $f = $_ -split "`t"; if ((Split-Path $f[0] -Parent) -eq $root) { $rows[(Split-Path $f[0] -Leaf)] = [pscustomobject]@{ Bytes = [long]$f[1]; Files = [long]$f[2]; Unreadable = [long]$f[4]; Links = [long]$f[5] } }
}
$subs = Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (($_.Attributes -band 'Hidden') -and ($_.Attributes -band 'System')) }
Note "`n== Totals vs PowerShell =="
Note ('{0,-22} {1,14} {2,14} {3,16}  {4}' -f 'folder', 'SizeLens', 'reference', 'GCI -Recurse', 'notes')
foreach ($s in $subs) {
  $ref = $refs[$s.Name]
  $gci = $gcis[$s.Name]
  $row = $rows[$s.Name]
  $ok = $row -and $row.Bytes -eq $ref.Bytes -and $row.Files -eq $ref.Files
  $notes = @()
  if ($ref.Denied) { $notes += "$($ref.Denied) unreadable" }
  if ($gci -ne $ref.Bytes) { $notes += 'GCI differs (it follows junctions / skips >260-char paths / stops at denied)' }
  Note ('{0,-22} {1,14} {2,14} {3,16}  {4}' -f $s.Name, $row.Bytes, $ref.Bytes, $gci, ($notes -join '; '))
  Check "total matches reference: $($s.Name)" $ok "SizeLens $($row.Bytes) bytes/$($row.Files) files vs $($ref.Bytes)/$($ref.Files)"
}
Check 'kilo-protected (hidden+system) skipped' (-not $rows.ContainsKey('kilo-protected') -and -not (Test-Path -LiteralPath "$root\kilo-protected\desktop.ini")) ''
Check 'root-level junction skipped, its target untouched' (-not $rows.ContainsKey('link-outside') -and ((Snapshot $outside) -eq $outsideBefore)) ''
Check 'junction inside foxtrot not followed (1 link counted, bravo bytes not included)' ($rows['foxtrot-junction'].Links -eq 1 -and $rows['foxtrot-junction'].Bytes -eq 5000) ''
Check 'golf-denied marked partial' ($rows['golf-denied'].Unreadable -ge 1 -and (IniTip "$root\golf-denied") -match 'partial') (IniTip "$root\golf-denied")

# ---------- 4. desktop.ini format and attributes ----------
Note "`n== desktop.ini files =="
foreach ($s in $subs) {
  $ini = Join-Path $s.FullName 'desktop.ini'
  $a = (Get-Item -LiteralPath $ini -Force).Attributes
  $fa = (Get-Item -LiteralPath $s.FullName -Force).Attributes
  $b = [IO.File]::ReadAllBytes($ini)
  $enc = if ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) { 'UTF-16LE+BOM' } elseif ($b[0] -eq 0xEF) { 'UTF-8+BOM' } else { 'ANSI' }
  Note ("{0,-22} ini attrs: {1,-28} folder attrs: {2,-28} {3}  InfoTip={4}" -f $s.Name, $a, $fa, $enc, (IniTip $s.FullName))
  Check "desktop.ini Hidden+System: $($s.Name)" ((($a -band 'Hidden') -ne 0) -and (($a -band 'System') -ne 0)) "$a"
  Check "folder Read-only or System: $($s.Name)" ((($fa -band 'ReadOnly') -ne 0) -or (($fa -band 'System') -ne 0)) "$fa"
}
$deltaText = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($deltaIni), 2, [IO.File]::ReadAllBytes($deltaIni).Length - 2)
Check 'delta-icon kept UTF-16LE and IconResource/ViewState lines' ($deltaText -match 'IconResource=C:\\Windows\\System32\\SHELL32.dll,3' -and $deltaText -match 'FolderType=Generic' -and ([IO.File]::ReadAllBytes($deltaIni)[0] -eq 0xFF)) ($deltaText -replace "`r`n", ' | ')
$echoText = [IO.File]::ReadAllText($echoIni)
Check 'echo-ansi stayed ANSI with LF endings and other keys' ($echoText -notmatch "`r" -and $echoText -match 'ConfirmFileOp=0' -and $echoText -match '\[Other\]\nKey=Value' -and ($echoText.Split("`n") | Where-Object { $_ -match '^InfoTip=' }).Count -eq 1) ($echoText -replace "`n", ' | ')
$charlieBytes = [IO.File]::ReadAllBytes("$root\charlie\desktop.ini")
Check 'new desktop.ini is UTF-16LE with BOM' ($charlieBytes[0] -eq 0xFF -and $charlieBytes[1] -eq 0xFE) ''

# ---------- 5. what the shell reports (System.Comment = the Comments column) ----------
Note "`n== Shell property System.Comment (the Comments column) =="
$sc = ShellComments $root
foreach ($s in $subs) {
  $want = IniTip $s.FullName
  Note ("{0,-22} {1}" -f $s.Name, $sc[$s.Name])
  Check "shell shows the InfoTip as Comments: $($s.Name)" ($sc[$s.Name] -eq $want) "shell='$($sc[$s.Name])' ini='$want'"
}

# ---------- 6. sort order ----------
Note "`n== Sort order =="
Add-Type -Path (Join-Path $PSScriptRoot 'Comparers.cs')
function SortViolations([object[]]$pairs, [scriptblock]$cmp) {
  # pairs: @{Bytes; Text} sorted by bytes ascending. Count adjacent pairs the comparer orders wrongly.
  $bad = 0; $example = ''
  for ($i = 0; $i -lt $pairs.Count - 1; $i++) {
    $a = $pairs[$i]; $b = $pairs[$i + 1]
    if ($a.Bytes -eq $b.Bytes) { continue }
    if ((& $cmp $a.Text $b.Text) -gt 0) { $bad++; if (-not $example) { $example = "'$($a.Text)' ($($a.Bytes)) sorts after '$($b.Text)' ($($b.Bytes))" } }
  }
  @{ Bad = $bad; Example = $example }
}
$comparers = [ordered]@{
  'ordinal'                               = { param($a, $b) [SizeLensComparers]::Ordinal($a, $b) }
  'ordinal ignore case'                   = { param($a, $b) [SizeLensComparers]::OrdinalIgnoreCase($a, $b) }
  'StrCmpLogicalW (Explorer name sort)'   = { param($a, $b) [SizeLensComparers]::StrCmpLogicalW($a, $b) }
  'CompareStringEx user locale'           = { param($a, $b) [SizeLensComparers]::Linguistic($a, $b, 0) }
  'CompareStringEx ignore case'           = { param($a, $b) [SizeLensComparers]::Linguistic($a, $b, 1) }
  'CompareStringEx digits-as-numbers'     = { param($a, $b) [SizeLensComparers]::Linguistic($a, $b, 8) }
  'PropVariantCompareEx default'          = { param($a, $b) [SizeLensComparers]::PropVariant($a, $b, 0) }
  'PropVariantCompareEx STRCMPI'          = { param($a, $b) [SizeLensComparers]::PropVariant($a, $b, 8) }
  'PropVariantCompareEx DIGITSASNUMBERS'  = { param($a, $b) [SizeLensComparers]::PropVariant($a, $b, 0x20) }
}
# sample sizes: class boundaries + a spread from bytes to TB
$rnd = New-Object Random 42
$sizes = New-Object System.Collections.Generic.List[long]
foreach ($r in 0..4) { $u = [long][Math]::Pow(1024, $r); foreach ($k in 1, 2, 9, 10, 99, 100, 999, 1000, 1023) { $sizes.Add($u * $k); $sizes.Add($u * $k + 1) }; $sizes.Add([long][Math]::Pow(1024, $r + 1) - 1) }
foreach ($i in 1..400) { $sizes.Add([long]([Math]::Pow(10, $rnd.NextDouble() * 13.5))) }
$sizes.Add(0)
$sorted = $sizes | Sort-Object -Unique
$fmtOut = & $exe fmt @($sorted | ForEach-Object { "$_" })
$fmtRows = $fmtOut | ForEach-Object { $f = $_ -split "`t"; [pscustomobject]@{ Bytes = [long]$f[0]; Sortable = $f[1]; Exact = $f[2]; Readable = $f[3] } }
Note "sample of $($fmtRows.Count) sizes from 0 B to ~30 TB:"
foreach ($fmtName in 'Sortable', 'Exact', 'Readable') {
  $pairs = $fmtRows | Where-Object { $fmtName -ne 'Exact' -or $_.Bytes -lt 1000000000000000 } | ForEach-Object { [pscustomobject]@{ Bytes = $_.Bytes; Text = $_.$fmtName } }
  foreach ($c in $comparers.Keys) {
    $v = SortViolations $pairs $comparers[$c]
    $line = "{0,-9} {1,-38} wrong adjacent pairs: {2}" -f $fmtName, $c, $v.Bad
    if ($v.Example) { $line += "  e.g. $($v.Example)" }
    if ($fmtName -eq 'Readable') { Note "info  $line" } else { Check $line ($v.Bad -eq 0) }
  }
}
# and the real InfoTips from the scan
$tipPairs = $subs | ForEach-Object { [pscustomobject]@{ Bytes = $rows[$_.Name].Bytes; Text = (IniTip $_.FullName) } } | Sort-Object Bytes
foreach ($c in $comparers.Keys) {
  $v = SortViolations $tipPairs $comparers[$c]
  Check "scanned InfoTips sort by size under $c" ($v.Bad -eq 0) $v.Example
}
Note ("InfoTips by size: " + (($tipPairs | ForEach-Object { $_.Text }) -join '  <  '))

# ---------- 7. re-scan is a no-op; a change updates only that folder ----------
Note "`n== Re-scan =="
$snapA = Snapshot $tree
$res = Run @('scan', $root)
Check 'second scan: everything unchanged' ($res.out -match '; 0 updated, 0 errors' -and ((Snapshot $tree) -eq $snapA)) (($res.out -split "`r?`n")[0])
$alphaTime = (Get-Item -LiteralPath "$root\alpha").LastWriteTimeUtc
MkFile "$root\alpha\new.bin" 2MB
$res = Run @('scan', $root)
Check 'after adding 2 MB to alpha: exactly 1 folder updated' ($res.out -match '; 1 updated, 0 errors') (($res.out -split "`r?`n")[0])
$wantAlpha = ((& $exe fmt ($rows['alpha'].Bytes + 2MB)) -split "`t")[1]
Check "alpha InfoTip now $wantAlpha" ((IniTip "$root\alpha") -eq $wantAlpha) (IniTip "$root\alpha")
Remove-Item -LiteralPath "$root\alpha\new.bin"
(Get-Item -LiteralPath "$root\alpha").LastWriteTimeUtc = $alphaTime   # undo the test's own change to alpha's time
$res = Run @('scan', $root)
Check 'after removing it: alpha back to its first value' ((IniTip "$root\alpha") -eq ($tipPairs | Where-Object { $_.Bytes -eq $rows['alpha'].Bytes }).Text) (IniTip "$root\alpha")

# ---------- 8. status ----------
$res = Run @('status')
Note "`n== status ==`n$($res.out.TrimEnd())"
Check 'status exits 0 and lists the root' ($res.code -eq 0 -and $res.out -match [regex]::Escape($root)) ''

# ---------- 9. clean restores everything ----------
Note "`n== Clean =="
$res = Run @('clean', $root)
Note $res.out.TrimEnd()
Check 'clean exits 0' ($res.code -eq 0) ''
$after = Snapshot $tree
Check 'tree is byte-for-byte identical after clean (content hashes, attributes, sizes, modified times)' ($after -eq $before) ''
if ($after -ne $before) {
  $b1 = $before -split "`n"; $a1 = $after -split "`n"
  Compare-Object $b1 $a1 | Select-Object -First 20 | ForEach-Object { Note "   diff: $($_.SideIndicator) $($_.InputObject)" }
}
$cfg = Get-Content (Join-Path $env:SIZELENS_HOME 'config.txt') -Raw
Check 'clean opted the root out of config.txt' (-not ($cfg -match '(?m)^\s*root\s*=')) ''
$man = @(Get-Content (Join-Path $env:SIZELENS_HOME 'managed.tsv') | Where-Object { $_ -and -not $_.StartsWith('#') })
Check 'undo log empty, backups removed' ($man.Count -eq 0 -and @(Get-ChildItem (Join-Path $env:SIZELENS_HOME 'backups') -ErrorAction SilentlyContinue).Count -eq 0) ''
$sc = ShellComments $root
Check 'shell shows no Comments after clean (echo-ansi''s own InfoTip is back in its file but, as before, its folder is not Read-only so Explorer ignores it)' (@($sc.GetEnumerator() | Where-Object { $_.Value }).Count -eq 0) ''

# ---------- 10. clean after the user edited desktop.ini ----------
Note "`n== Clean after user edits =="
Run @('add', $root) | Out-Null
Run @('scan', $root) | Out-Null
# user changes the icon in delta-icon, and customizes charlie (whose desktop.ini SizeLens created)
$p = $deltaIni; (Get-Item -LiteralPath $p -Force).Attributes = 'Normal'
$t = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($p), 2, [IO.File]::ReadAllBytes($p).Length - 2).Replace('SHELL32.dll,3', 'SHELL32.dll,7')
[IO.File]::WriteAllBytes($p, [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($t)); (Get-Item -LiteralPath $p -Force).Attributes = 'Hidden, System'
$p = "$root\charlie\desktop.ini"; (Get-Item -LiteralPath $p -Force).Attributes = 'Normal'
$t = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($p), 2, [IO.File]::ReadAllBytes($p).Length - 2) + "IconResource=C:\Windows\System32\imageres.dll,5`r`n"
[IO.File]::WriteAllBytes($p, [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($t)); (Get-Item -LiteralPath $p -Force).Attributes = 'Hidden, System'
$res = Run @('clean', $root)
Note $res.out.TrimEnd()
$dt = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($deltaIni), 2, [IO.File]::ReadAllBytes($deltaIni).Length - 2)
$expectDelta = "[.ShellClassInfo]`r`nIconResource=C:\Windows\System32\SHELL32.dll,7`r`n[ViewState]`r`nMode=`r`nVid=`r`nFolderType=Generic`r`n"
Check 'delta-icon: InfoTip removed, the user''s new icon kept' ($dt -eq $expectDelta) ($dt -replace "`r`n", ' | ')
$ct = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes("$root\charlie\desktop.ini"), 2, [IO.File]::ReadAllBytes("$root\charlie\desktop.ini").Length - 2)
Check 'charlie: file kept with only the user''s IconResource, folder stays Read-only' ($ct -eq "[.ShellClassInfo]`r`nIconResource=C:\Windows\System32\imageres.dll,5`r`n" -and ((Get-Item -LiteralPath "$root\charlie").Attributes -band 'ReadOnly')) ($ct -replace "`r`n", ' | ')

# ---------- 11. watch mode ----------
Note "`n== Watch mode =="
# put the tree back to the original state for this part
$p = "$root\charlie\desktop.ini"; (Get-Item -LiteralPath $p -Force).Attributes = 'Normal'; Remove-Item -LiteralPath $p
(Get-Item -LiteralPath "$root\charlie").Attributes = 'Directory'
Start-Sleep -Seconds 2
$null = Snapshot $tree
$before2 = Snapshot $tree
$bravoTime = (Get-Item -LiteralPath "$root\bravo").LastWriteTimeUtc; $rootTime = (Get-Item -LiteralPath $root).LastWriteTimeUtc
$cfgPath = Join-Path $env:SIZELENS_HOME 'config.txt'
$c = [IO.File]::ReadAllText($cfgPath) -replace '(?m)^debounce_seconds = \d+', 'debounce_seconds = 2'
[IO.File]::WriteAllText($cfgPath, $c, (New-Object Text.UTF8Encoding $false))
Run @('add', $root) | Out-Null
$proc = Start-Process -FilePath $exe -ArgumentList 'watch' -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $env:SIZELENS_HOME 'watch-test.out')
Start-Sleep -Seconds 4
Check 'watcher reports running' ((Run @('status')).out -match 'watcher\s+: running') ''
$second = Start-Process -FilePath $exe -ArgumentList 'watch' -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $env:SIZELENS_HOME 'watch-second.out')
$secondExited = $second.WaitForExit(5000)
if (-not $secondExited) { Stop-Process -Id $second.Id -Force }
Check 'second watcher refuses to start' ($secondExited -and ((Get-Content (Join-Path $env:SIZELENS_HOME 'watch-second.out') -Raw) -match 'already running')) ''
Check 'initial full scan by watcher wrote bravo''s tip' ((IniTip "$root\bravo") -eq '[2] 0012.00 MB') (IniTip "$root\bravo")
$cpu0 = (Get-Process -Id $proc.Id).TotalProcessorTime.TotalMilliseconds
Start-Sleep -Seconds 10
$cpu1 = (Get-Process -Id $proc.Id).TotalProcessorTime.TotalMilliseconds
Check 'idle watcher CPU over 10 s is under 100 ms' (($cpu1 - $cpu0) -lt 100) ("{0:N0} ms CPU in 10 s idle" -f ($cpu1 - $cpu0))
$t0 = Get-Date
MkFile "$root\bravo\more.bin" (5MB)
$deadline = (Get-Date).AddSeconds(30); $tip = ''
while ((Get-Date) -lt $deadline) { $tip = IniTip "$root\bravo"; if ($tip -eq '[2] 0017.00 MB') { break }; Start-Sleep -Milliseconds 250 }
Check 'watcher updated bravo after a 5 MB file was added' ($tip -eq '[2] 0017.00 MB') ("tip '$tip' after {0:N1} s (debounce 2 s)" -f ((Get-Date) - $t0).TotalSeconds)
MkFile "$root\november-new\n.bin" 2048
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) { if ((IniTip "$root\november-new") -eq '[1] 0002.00 KB') { break }; Start-Sleep -Milliseconds 250 }
Check 'watcher sized a newly created subfolder' ((IniTip "$root\november-new") -eq '[1] 0002.00 KB') (IniTip "$root\november-new")
Run @('stop') | Out-Null
$exited = $proc.WaitForExit(10000)
Check 'sizelens stop ends the watcher' $exited ''
if (-not $exited) { Stop-Process -Id $proc.Id -Force }
Note ("watch log:`n" + ((Get-Content (Join-Path $env:SIZELENS_HOME 'watch-test.out') -Raw).TrimEnd()))
Remove-Item -LiteralPath "$root\bravo\more.bin"
$res = Run @('clean', $root)
Remove-Item -LiteralPath "$root\november-new" -Recurse
# the test itself added/removed files in bravo and the root: put those two folder times back
Start-Sleep -Seconds 2
(Get-Item -LiteralPath "$root\bravo").LastWriteTimeUtc = $bravoTime; (Get-Item -LiteralPath $root).LastWriteTimeUtc = $rootTime
$after2 = Snapshot $tree
Check 'tree identical to its pre-watch state after watch test + clean' ($after2 -eq $before2) ''
if ($after2 -ne $before2) { Compare-Object ($before2 -split "`n") ($after2 -split "`n") | Select-Object -First 20 | ForEach-Object { Note "   diff: $($_.SideIndicator) $($_.InputObject)" } }

# ---------- 12. every level (a 6-level tree) ----------
Note "`n== Every level =="
$deep = Join-Path $tree 'deeproot'
MkFile "$deep\L1a\a.bin" 1000
MkFile "$deep\L1a\L2\b.bin" 2000
MkFile "$deep\L1a\L2\L3\c.bin" 3000
MkFile "$deep\L1a\L2\L3\L4\d.bin" 4000
MkFile "$deep\L1a\L2\L3\L4\L5\e.bin" 5000
MkFile "$deep\L1a\L2\L3\L4\L5\L6\f.bin" 70
MkFile "$deep\L1a\L2\L3\sibling\s.bin" 600
MkFile "$deep\L1b\x.bin" 10
New-Item -ItemType Directory "$deep\L1b\empty" | Out-Null
MkFile "$deep\L1a\repo\.git\HEAD" 23
MkFile "$deep\L1a\repo\src\main.rs" 500
MkFile "$deep\L1a\node_modules\pkg\index.js" 300
MkFile "$deep\L1a\.cache\c.bin" 50
MkFile "$deep\L1a\hiddenattr\h.bin" 40; (Get-Item -LiteralPath "$deep\L1a\hiddenattr").Attributes = 'Directory, Hidden'
MkFile "$deep\L1a\L2\locked\secret.bin" 77
& icacls "$deep\L1a\L2\locked" /deny "${me}:(OI)(CI)(RD)" | Out-Null
$labelled = 'L1a', 'L1a\L2', 'L1a\L2\L3', 'L1a\L2\L3\L4', 'L1a\L2\L3\L4\L5', 'L1a\L2\L3\L4\L5\L6', 'L1a\L2\L3\sibling', 'L1b', 'L1b\empty'
$unlabelled = 'L1a\repo', 'L1a\repo\src', 'L1a\repo\.git', 'L1a\node_modules', 'L1a\node_modules\pkg', 'L1a\.cache', 'L1a\hiddenattr', 'L1a\L2\locked'
Start-Sleep -Seconds 2
$null = Snapshot $deep
$deepBefore = Snapshot $deep
$eTime = (Get-Item -LiteralPath "$deep\L1a\L2\L3\L4\L5\e.bin").LastWriteTimeUtc
$fTime = (Get-Item -LiteralPath "$deep\L1a\L2\L3\L4\L5\L6\f.bin").LastWriteTimeUtc
function ExpectTip([string]$folder) {
  $r = RefSize $folder
  $tip = ((& $exe fmt $r.Bytes) -split "`t")[1]
  if ($r.Denied) { $tip += ' (partial: some folders unreadable)' }
  $tip
}
function CheckLevels([string]$label) {
  $bad = @()
  foreach ($l in $labelled) { $want = ExpectTip "$deep\$l"; $got = IniTip "$deep\$l"; if ($got -ne $want) { $bad += "$l got '$got' want '$want'" } }
  Check "$label every labelled folder (6 levels deep) has the right size" ($bad.Count -eq 0) ($bad -join '; ')
}
Run @('add', $deep) | Out-Null
$res = Run @('scan', $deep, '--verbose')
Note $res.out.TrimEnd()
Check 'deep scan exits 0' ($res.code -eq 0) ''
CheckLevels 'first scan:'
$wrong = @($unlabelled | Where-Object { Test-Path -LiteralPath "$deep\$_\desktop.ini" })
Check 'no label in git repo, node_modules, dot folder, hidden folder, unreadable folder (or inside them)' ($wrong.Count -eq 0) ($wrong -join ', ')
Check 'L1a total includes the unlabelled folders inside it' ((RefSize "$deep\L1a").Bytes -eq 1000 + 2000 + 3000 + 4000 + 5000 + 70 + 600 + 23 + 500 + 300 + 50 + 40) ''
$sc = ShellComments "$deep\L1a\L2\L3"
Check 'shell Comments at level 4 (L4, sibling) match' ($sc['L4'] -eq (IniTip "$deep\L1a\L2\L3\L4") -and $sc['sibling'] -eq (IniTip "$deep\L1a\L2\L3\sibling")) "L4='$($sc['L4'])' sibling='$($sc['sibling'])'"
$sc = ShellComments "$deep\L1a\L2\L3\L4\L5"
Check 'shell Comments at level 6 (L6) match' ($sc['L6'] -eq (IniTip "$deep\L1a\L2\L3\L4\L5\L6")) "L6='$($sc['L6'])'"

$res = Run @('scan', $deep)
Check 'deep re-scan rewrites nothing' ($res.out -match '; 0 updated, 0 errors') (($res.out -split "`r?`n")[0])
MkFile "$deep\L1a\L2\L3\L4\L5\e.bin" (1MB)
$res = Run @('scan', $deep, '--verbose')
$upd = @(($res.out -split "`r?`n") | Where-Object { $_ -match '\(updated\)' } | ForEach-Object { ($_ -split '\s{2,}')[3] })
Check 'a deep change rewrites exactly its parent chain (L5, L4, L3, L2, L1a)' ($res.out -match '; 5 updated, 0 errors' -and ($upd | Sort-Object) -join ',' -eq 'L1a,L1a\L2,L1a\L2\L3,L1a\L2\L3\L4,L1a\L2\L3\L4\L5') ($upd -join ', ')
CheckLevels 'after the deep change:'

$cfgPath = Join-Path $env:SIZELENS_HOME 'config.txt'
$c = [IO.File]::ReadAllText($cfgPath) -replace '(?m)^depth = \w+', 'depth = 2'
[IO.File]::WriteAllText($cfgPath, $c, (New-Object Text.UTF8Encoding $false))
$res = Run @('scan', $deep)
Note $res.out.TrimEnd()
$gone = @('L1a\L2\L3', 'L1a\L2\L3\L4', 'L1a\L2\L3\L4\L5', 'L1a\L2\L3\L4\L5\L6', 'L1a\L2\L3\sibling') | Where-Object { (Test-Path -LiteralPath "$deep\$_\desktop.ini") -or ((Get-Item -LiteralPath "$deep\$_").Attributes -band 'ReadOnly') }
Check 'depth = 2 removes labels (and Read-only) below level 2' (@($gone).Count -eq 0 -and (Test-Path -LiteralPath "$deep\L1a\L2\desktop.ini") -and (Test-Path -LiteralPath "$deep\L1b\empty\desktop.ini")) ($gone -join ', ')
$c = [IO.File]::ReadAllText($cfgPath) -replace '(?m)^depth = \w+', 'depth = all'
[IO.File]::WriteAllText($cfgPath, $c, (New-Object Text.UTF8Encoding $false))
$res = Run @('scan', $deep)
CheckLevels 'depth back to all:'

Note "`n== Watcher, deep change =="
$proc = Start-Process -FilePath $exe -ArgumentList 'watch' -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $env:SIZELENS_HOME 'watch-deep.out')
Start-Sleep -Seconds 4
$t0 = Get-Date
MkFile "$deep\L1a\L2\L3\L4\L5\L6\f.bin" (3MB)
$want = ExpectTip "$deep\L1a"
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) { if ((IniTip "$deep\L1a") -eq $want) { break }; Start-Sleep -Milliseconds 250 }
Note ("watcher reached L1a after {0:N1} s" -f ((Get-Date) - $t0).TotalSeconds)
CheckLevels 'watcher, after a change 6 levels down:'
Run @('stop') | Out-Null
if (-not $proc.WaitForExit(10000)) { Stop-Process -Id $proc.Id -Force }
Note ("watch log:`n" + ((Get-Content (Join-Path $env:SIZELENS_HOME 'watch-deep.out') -Raw).TrimEnd()))

# put the two test files back exactly (content and time), then clean
MkFile "$deep\L1a\L2\L3\L4\L5\e.bin" 5000; (Get-Item -LiteralPath "$deep\L1a\L2\L3\L4\L5\e.bin").LastWriteTimeUtc = $eTime
MkFile "$deep\L1a\L2\L3\L4\L5\L6\f.bin" 70; (Get-Item -LiteralPath "$deep\L1a\L2\L3\L4\L5\L6\f.bin").LastWriteTimeUtc = $fTime
$res = Run @('clean', $deep)
Check 'deep clean exits 0' ($res.code -eq 0) (($res.out -split "`r?`n") | Select-Object -Last 1)
Start-Sleep -Seconds 1
SameTree 'deep tree byte-for-byte identical after scan / depth change / watcher / clean' $deepBefore (Snapshot $deep)

Note "`n== folder_type = generic =="
$gen = Join-Path $tree 'genroot'
MkFile "$gen\one\o.bin" 123
Start-Sleep -Seconds 2
$null = Snapshot $gen
$genBefore = Snapshot $gen
$c = [IO.File]::ReadAllText($cfgPath) -replace '(?m)^folder_type = \w+', 'folder_type = generic'
[IO.File]::WriteAllText($cfgPath, $c, (New-Object Text.UTF8Encoding $false))
Run @('add', $gen) | Out-Null
Run @('scan', $gen) | Out-Null
$gb = [IO.File]::ReadAllBytes("$gen\one\desktop.ini")
$gt = [Text.Encoding]::Unicode.GetString($gb, 2, $gb.Length - 2)
Check 'folder_type = generic writes [ViewState] FolderType=Generic' ($gt -match '\[ViewState\]\r\nMode=\r\nVid=\r\nFolderType=Generic') ($gt -replace "`r`n", ' | ')
$sc = ShellComments $gen
Check 'Comments still shown with FolderType=Generic' ($sc['one'] -eq '[0] 0123 B') "'$($sc['one'])'"
Run @('clean', $gen) | Out-Null
Start-Sleep -Seconds 1
SameTree 'genroot identical after clean' $genBefore (Snapshot $gen)
$c = [IO.File]::ReadAllText($cfgPath) -replace '(?m)^folder_type = \w+', 'folder_type = keep'
[IO.File]::WriteAllText($cfgPath, $c, (New-Object Text.UTF8Encoding $false))
& icacls "$deep\L1a\L2\locked" /remove:d $me | Out-Null

# ---------- 13. follow-up rewrites (no Explorer needed; tests\explorer-followup.ps1 checks real windows) ----------
Note "`n== Follow-up rewrites =="
$fu = Join-Path $tree 'fuproot'
MkFile "$fu\one\o.bin" 1000
MkFile "$fu\one\deeper\d.bin" 500
MkFile "$fu\two\t.bin" 2000
Start-Sleep -Seconds 2
$null = Snapshot $fu
$fuBefore = Snapshot $fu
$fuFileT = @{}; foreach ($f in 'one\o.bin', 'one\deeper\d.bin') { $fuFileT[$f] = (Get-Item -LiteralPath "$fu\$f").LastWriteTimeUtc }
$fuDirT = @{ two = (Get-Item -LiteralPath "$fu\two").LastWriteTimeUtc }
$fuPending = Join-Path $env:SIZELENS_HOME 'followup.tsv'
$helperExe = Join-Path (Split-Path $exe) 'sizelensw.exe'
function Helpers { @(Get-Process -Name sizelensw -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $helperExe }) }
function WaitNoPending([int]$sec) { $t = Get-Date; while ((Test-Path $fuPending) -and ((Get-Date) - $t).TotalSeconds -lt $sec) { Start-Sleep -Milliseconds 250 }; -not (Test-Path $fuPending) }
[IO.File]::WriteAllText($cfgPath, ([IO.File]::ReadAllText($cfgPath) -replace '(?m)^follow_up_seconds = \d+', 'follow_up_seconds = 4'), (New-Object Text.UTF8Encoding $false))
Run @('add', $fu) | Out-Null
$res = Run @('scan', $fu)
Note $res.out.TrimEnd()
$pend = @(Get-Content $fuPending -ErrorAction SilentlyContinue | Where-Object { $_ -and -not $_.StartsWith('#') })
Check 'a scan that changed 3 labels schedules 3 follow-ups' ($pend.Count -eq 3) ($pend -join ' | ')
Check 'no watcher running: the scan started the hidden helper (sizelensw.exe follow-up)' ((Helpers).Count -eq 1) "$((Helpers).Count) helper(s)"
Check 'status lists them' ((Run @('status')).out -match 'follow-ups\s+: 3 pending') ''
$iniB = @{}; $iniT = @{}; $dirT = @{}
foreach ($f in 'one', 'one\deeper', 'two') { $iniB[$f] = [IO.File]::ReadAllBytes("$fu\$f\desktop.ini"); $iniT[$f] = (Get-Item -LiteralPath "$fu\$f\desktop.ini" -Force).LastWriteTimeUtc; $dirT[$f] = (Get-Item -LiteralPath "$fu\$f").LastWriteTimeUtc }
Start-Sleep -Seconds 1
# a second change to `two` before its follow-up is due moves that follow-up back (one per folder)
MkFile "$fu\two\t2.bin" 100
$res = Run @('scan', $fu)
Note $res.out.TrimEnd()
$pend = @(Get-Content $fuPending -ErrorAction SilentlyContinue | Where-Object { $_ -and -not $_.StartsWith('#') })
Check 'a second change before the follow-up keeps one follow-up per folder' ($pend.Count -eq 3) ($pend -join ' | ')
$iniB['two'] = [IO.File]::ReadAllBytes("$fu\two\desktop.ini"); $iniT['two'] = (Get-Item -LiteralPath "$fu\two\desktop.ini" -Force).LastWriteTimeUtc; $dirT['two'] = (Get-Item -LiteralPath "$fu\two").LastWriteTimeUtc
$done = WaitNoPending 20
Start-Sleep -Seconds 1
Check 'helper did the follow-ups (followup.tsv gone) and exited' ($done -and (Helpers).Count -eq 0) "$((Helpers).Count) helper(s) left"
$same = $true; $rewritten = $true; $kept = $true
foreach ($f in 'one', 'one\deeper', 'two') {
  $i = Get-Item -LiteralPath "$fu\$f\desktop.ini" -Force
  if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($i.FullName)) -ne [Convert]::ToBase64String($iniB[$f])) { $same = $false }
  if ($i.LastWriteTimeUtc -le $iniT[$f]) { $rewritten = $false }
  if ($i.Attributes -ne 'Hidden, System, Archive' -and $i.Attributes -ne 'Hidden, System') { $kept = $false }
  if ((Get-Item -LiteralPath "$fu\$f").LastWriteTimeUtc -ne $dirT[$f]) { $kept = $false }
}
Check 'each desktop.ini was written again later with the same bytes' ($same -and $rewritten) "same bytes: $same, newer time: $rewritten"
Check 'follow-ups kept desktop.ini Hidden+System and each folder''s Date modified' $kept ''
$res = Run @('scan', $fu)
Check 're-scan after follow-ups rewrites nothing and schedules nothing' ($res.out -match '; 0 updated, 0 errors' -and -not (Test-Path $fuPending)) (($res.out -split "`r?`n")[0])
# with a watcher running, the watcher does the follow-ups and no helper starts
$proc = Start-Process -FilePath $exe -ArgumentList 'watch' -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $env:SIZELENS_HOME 'watch-fu.out')
Start-Sleep -Seconds 3
MkFile "$fu\one\o.bin" 3000
$res = Run @('scan', $fu)
Check 'watcher running: a one-off scan starts no helper' ((Helpers).Count -eq 0) "$((Helpers).Count) helper(s)"
$done = WaitNoPending 20
Run @('stop') | Out-Null
if (-not $proc.WaitForExit(10000)) { Stop-Process -Id $proc.Id -Force }
$wlog = Get-Content (Join-Path $env:SIZELENS_HOME 'watch-fu.out') -Raw
Check 'the watcher did those follow-ups' ($done -and $wlog -match 'follow-up: rewrote 1 label') (($wlog -split "`r?`n" | Where-Object { $_ -match 'follow-up' }) -join ' | ')
# `here` on a folder inside an opted-in folder re-measures it instead of opting it in again
$roots0 = @((Get-Content $cfgPath) -match '^root = ').Count
MkFile "$fu\one\deeper\d.bin" 9000
$res = Run @('here', "$fu\one\deeper")
$roots1 = @((Get-Content $cfgPath) -match '^root = ').Count
Check '`here` inside an opted-in folder re-measures it, no nested root' ($res.code -eq 0 -and $roots1 -eq $roots0 -and $res.out -match 're-measuring' -and (IniTip "$fu\one\deeper") -eq '[1] 0008.79 KB') ("roots $roots0 -> $roots1; deeper = '$(IniTip "$fu\one\deeper")'")
[IO.File]::WriteAllText($cfgPath, ([IO.File]::ReadAllText($cfgPath) -replace '(?m)^follow_up_seconds = \d+', 'follow_up_seconds = 0'), (New-Object Text.UTF8Encoding $false))
Remove-Item -LiteralPath $fuPending -ErrorAction SilentlyContinue
# put the test's own file changes back (content and times), then clean: the tree must be identical
MkFile "$fu\one\o.bin" 1000; (Get-Item -LiteralPath "$fu\one\o.bin").LastWriteTimeUtc = $fuFileT['one\o.bin']
MkFile "$fu\one\deeper\d.bin" 500; (Get-Item -LiteralPath "$fu\one\deeper\d.bin").LastWriteTimeUtc = $fuFileT['one\deeper\d.bin']
Remove-Item -LiteralPath "$fu\two\t2.bin"
$res = Run @('clean', $fu)
Check 'fuproot clean exits 0' ($res.code -eq 0) (($res.out -split "`r?`n") | Select-Object -Last 1)
Start-Sleep -Seconds 2
(Get-Item -LiteralPath "$fu\two").LastWriteTimeUtc = $fuDirT['two']
SameTree 'fuproot byte-for-byte identical after scans, follow-ups, watcher, here and clean' $fuBefore (Snapshot $fu)

# ---------- done ----------
& icacls "$root\golf-denied\locked" /remove:d $me | Out-Null
Note "`nRESULT: $fails failure(s)"
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'results.txt'), ($results -join "`r`n"), (New-Object Text.UTF8Encoding $false))
exit $fails
