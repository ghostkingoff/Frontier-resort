Add-Type -AssemblyName System.Drawing
$p = $args[0]
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

function Grid($c, $r) {
  $rows = @()
  for ($y = 0; $y -lt 32; $y++) {
    $sb = New-Object System.Text.StringBuilder
    for ($x = 0; $x -lt 32; $x++) { [void]$sb.Append((Sym $bmp.GetPixel($c * 32 + $x, $r * 32 + $y))) }
    $rows += $sb.ToString()
  }
  return $rows
}

$mode = $args[1]
if ($mode -eq 'col0allrows') {
  $g = @{}
  for ($r = 0; $r -lt 5; $r++) { $g[$r] = Grid 0 $r }
  Write-Output "===== col0 of rows 0..4 side by side ====="
  for ($y = 0; $y -lt 32; $y++) {
    Write-Output ("{0} {1} {2} {3} {4}" -f $g[0][$y], $g[1][$y], $g[2][$y], $g[3][$y], $g[4][$y])
  }
}
elseif ($mode -eq 'allcols') {
  $r = [int]$args[2]
  $g = @{}
  for ($c = 0; $c -lt 4; $c++) { $g[$c] = Grid $c $r }
  Write-Output ("===== row {0}: col0..col3 =====" -f $r)
  for ($y = 0; $y -lt 32; $y++) {
    Write-Output ("{0} {1} {2} {3}" -f $g[0][$y], $g[1][$y], $g[2][$y], $g[3][$y])
  }
}
elseif ($mode -eq 'mirsame') {
  # for every frame, report whether it equals the mirror of col0 of the same row, and diff-count vs col0
  Write-Output "row col | identical-to-col0 | mirror-of-col0 | diffpx-vs-col0 | diffpx-vs-mirror(col0)"
  for ($r = 0; $r -lt 5; $r++) {
    $base = Grid 0 $r
    $mirror = @()
    foreach ($row in $base) {
      $ch = $row.ToCharArray()
      [array]::Reverse($ch)
      $mirror += (-join $ch)
    }
    for ($c = 0; $c -lt 4; $c++) {
      $g = Grid $c $r
      $same = 0; $mirsame = 0
      for ($y = 0; $y -lt 32; $y++) {
        for ($x = 0; $x -lt 32; $x++) {
          if ($g[$y][$x] -eq $base[$y][$x]) { $same++ }
          if ($g[$y][$x] -eq $mirror[$y][$x]) { $mirsame++ }
        }
      }
      Write-Output ("{0,3} {1,3} | {2,5}/1024        | {3,5}/1024     | {4,4} px        | {5,4} px" -f $r, $c, $same, $mirsame, (1024 - $same), (1024 - $mirsame))
    }
  }
}
$bmp.Dispose()
