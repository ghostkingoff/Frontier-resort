$p = $args[0]
$b = [System.IO.File]::ReadAllBytes($p)
Write-Output ("FILE: {0}" -f $p)
Write-Output ("frames={0} canvas={1}x{2} depth={3}" -f [BitConverter]::ToUInt16($b,6), [BitConverter]::ToUInt16($b,8), [BitConverter]::ToUInt16($b,10), [BitConverter]::ToUInt16($b,12))

foreach ($nextMode in @('plusSize', 'plusSizePlus4')) {
  Write-Output ("--- interpretation: {0} ---" -f $nextMode)
  $off = 128
  $n = 0
  while ($off -lt ($b.Length - 8) -and $n -lt 30) {
    $csize = [BitConverter]::ToUInt32($b, $off)
    $ctype = [BitConverter]::ToUInt16($b, $off + 4)
    $q = $off + 6
    $desc = ""
    if ($ctype -eq 0x2004) {
      $len = [BitConverter]::ToUInt16($b, $q + 16)
      if ($len -gt 0 -and $len -lt 200 -and ($q + 18 + $len) -lt $b.Length) {
        $name = [System.Text.Encoding]::UTF8.GetString($b, $q + 18, $len)
        $desc = "LAYER name='$name'"
      } else { $desc = "LAYER (bad len)" }
    }
    elseif ($ctype -eq 0x2018) {
      $cnt = [BitConverter]::ToUInt16($b, $q)
      $desc = "TAGS n=$cnt"
      $t = $q + 2
      for ($i = 0; $i -lt $cnt; $i++) {
        $from = [BitConverter]::ToUInt16($b, $t); $to = [BitConverter]::ToUInt16($b, $t + 2)
        $len = [BitConverter]::ToUInt16($b, $t + 17)
        $name = [System.Text.Encoding]::UTF8.GetString($b, $t + 19, $len)
        $desc += " ['$name' $from..$to]"
        $t = $t + 19 + $len
      }
    }
    elseif ($ctype -eq 0x2005) { $desc = "CEL" }
    Write-Output ("  off={0,6} size={1,6} type=0x{2:X4} {3}" -f $off, $csize, $ctype, $desc)
    if ($csize -le 0) { break }
    if ($nextMode -eq 'plusSize') { $off += $csize } else { $off += 4 + $csize }
    $n++
  }
  Write-Output ""
}
