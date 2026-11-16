$p = $args[0]
$b = [System.IO.File]::ReadAllBytes($p)
$frames = [BitConverter]::ToUInt16($b, 6)
$w = [BitConverter]::ToUInt16($b, 8)
$h = [BitConverter]::ToUInt16($b, 10)
$depth = [BitConverter]::ToUInt16($b, 12)
Write-Output ("FILE: {0}" -f $p)
Write-Output ("canvas {0}x{1}  frames={2}  depth={3}" -f $w, $h, $frames, $depth)

$off = 128
$layers = @()
$tags = @()
$celCount = 0
while ($off -lt ($b.Length - 8)) {
  $csize = [BitConverter]::ToUInt32($b, $off)
  $ctype = [BitConverter]::ToUInt16($b, $off + 4)
  if ($csize -le 0) { break }
  $q = $off + 6
  if ($ctype -eq 0x2004) {
    # layer chunk
    $flags = [BitConverter]::ToUInt16($b, $q)
    $ltype = [BitConverter]::ToUInt16($b, $q + 2)
    $child = [BitConverter]::ToUInt16($b, $q + 4)
    $len = [BitConverter]::ToUInt16($b, $q + 16)
    $name = [System.Text.Encoding]::UTF8.GetString($b, $q + 18, $len)
    $layers += ("layer name='{0}' flags={1} type={2} childLevel={3}" -f $name, $flags, $ltype, $child)
  }
  elseif ($ctype -eq 0x2018) {
    $n = [BitConverter]::ToUInt16($b, $q)
    $t = $q + 2
    for ($i = 0; $i -lt $n; $i++) {
      $from = [BitConverter]::ToUInt16($b, $t)
      $to = [BitConverter]::ToUInt16($b, $t + 2)
      $len = [BitConverter]::ToUInt16($b, $t + 17)
      $name = [System.Text.Encoding]::UTF8.GetString($b, $t + 19, $len)
      $tags += ("tag '{0}' frames {1}..{2}" -f $name, $from, $to)
      $t = $t + 19 + $len
    }
  }
  elseif ($ctype -eq 0x2005) { $celCount++ }
  $off += 4 + $csize
}
Write-Output ("LAYERS ({0}):" -f $layers.Count)
$layers | ForEach-Object { "  $_" }
Write-Output ("TAGS ({0}):" -f $tags.Count)
$tags | ForEach-Object { "  $_" }
Write-Output ("cels: {0}" -f $celCount)
