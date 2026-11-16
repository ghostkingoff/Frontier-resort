Add-Type -AssemblyName System.Drawing
$p = $args[0]
if (-not (Test-Path -LiteralPath $p)) { Write-Output "MISSING: $p"; exit 1 }
$bmp = New-Object System.Drawing.Bitmap $p

function Sym($px) {
  if ($px.A -eq 0) { return '.' }
  $k = "$($px.R),$($px.G),$($px.B)"
  switch ($k) {
    '47,37,34'    { '#' }
    '250,243,232' { 'o' }
    '185,179,161' { '+' }
    '231,213,198' { 's' }
    '209,157,167' { 'c' }
    default       { '?' }
  }
}

function FrameHash($c, $r) {
  $sb = New-Object System.Text.StringBuilder
  for ($y = 0; $y -lt 32; $y++) {
    for ($x = 0; $x -lt 32; $x++) {
      [void]$sb.Append((Sym $bmp.GetPixel($c * 32 + $x, $r * 32 + $y)))
    }
  }
  $sb.ToString()
}

$uniq = [ordered]@{}
for ($r = 0; $r -lt 5; $r++) {
  for ($c = 0; $c -lt 4; $c++) {
    $h = FrameHash $c $r
    if (-not $uniq.Contains($h)) { $uniq[$h] = @() }
    $uniq[$h] += "($c,$r)"
  }
}
Write-Output ("SHEET: {0}x{1}  UNIQUE FRAMES: {2} / 20" -f $bmp.Width, $bmp.Height, $uniq.Count)
$i = 0
foreach ($k in $uniq.Keys) {
  Write-Output ("  group {0}: {1}" -f $i, ($uniq[$k] -join ' '))
  $i++
}

function DumpRow($r, $label) {
  Write-Output ""
  Write-Output ("===== {0} (row index {1}): col0 | col1 | col2 | col3 =====" -f $label, $r)
  $rows = @{}
  for ($c = 0; $c -lt 4; $c++) {
    $h = FrameHash $c $r
    $rows[$c] = @()
    for ($y = 0; $y -lt 32; $y++) { $rows[$c] += $h.Substring($y * 32, 32) }
  }
  for ($y = 0; $y -lt 32; $y++) {
    Write-Output ("{0}  {1}  {2}  {3}" -f $rows[0][$y], $rows[1][$y], $rows[2][$y], $rows[3][$y])
  }
}

foreach ($r in $args[1..($args.Count - 1)]) { DumpRow ([int]$r) "row" }
$bmp.Dispose()
