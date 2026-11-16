$p = $args[0]
$b = [System.IO.File]::ReadAllBytes($p)
Write-Output ("FILE: {0}" -f $p)
$off = 128
$frameIdx = 0
while ($off -lt ($b.Length - 8) -and $frameIdx -lt 3) {
  $csize = [BitConverter]::ToUInt32($b, $off)
  $ctype = [BitConverter]::ToUInt16($b, $off + 4)
  if ($ctype -ne 0xF1FA) { Write-Output ("  not a frame chunk at {0}: 0x{1:X4}" -f $off, $ctype); break }
  $oldNum = [BitConverter]::ToUInt16($b, $off + 6)
  $dur = [BitConverter]::ToUInt16($b, $off + 8)
  $newNum = [BitConverter]::ToUInt32($b, $off + 12)
  Write-Output ("FRAME {0} at off={1} size={2} oldNumChunks={3} duration={4} newNumChunks={5}" -f $frameIdx, $off, $csize, $oldNum, $dur, $newNum)
  $sub = $off + 16
  $end = $off + $csize
  $k = 0
  while ($sub -lt ($end - 6) -and $k -lt 60) {
    $ssize = [BitConverter]::ToUInt32($b, $sub)
    $stype = [BitConverter]::ToUInt16($b, $sub + 4)
    $q = $sub + 6
    $desc = ""
    if ($stype -eq 0x2004) {
      $len = [BitConverter]::ToUInt16($b, $q + 16)
      $name = ""
      if ($len -gt 0 -and $len -lt 300) { $name = [System.Text.Encoding]::UTF8.GetString($b, $q + 18, $len) }
      $desc = "LAYER flags={0} type={1} child={2} name='{3}'" -f [BitConverter]::ToUInt16($b, $q), [BitConverter]::ToUInt16($b, $q + 2), [BitConverter]::ToUInt16($b, $q + 4), $name
    }
    elseif ($stype -eq 0x2018) {
      $cnt = [BitConverter]::ToUInt16($b, $q)
      $desc = "TAGS n=$cnt"
      $t = $q + 2
      for ($i = 0; $i -lt $cnt; $i++) {
        $from = [BitConverter]::ToUInt16($b, $t); $to = [BitConverter]::ToUInt16($b, $t + 2)
        $len = [BitConverter]::ToUInt16($b, $t + 17)
        $name = [System.Text.Encoding]::UTF8.GetString($b, $t + 19, $len)
        $desc += " ['$name' {0}..{1}]" -f $from, $to
        $t = $t + 19 + $len
      }
    }
    elseif ($stype -eq 0x2005) {
      $layerIdx = [BitConverter]::ToUInt16($b, $q)
      $x = [BitConverter]::ToInt16($b, $q + 2); $y = [BitConverter]::ToInt16($b, $q + 4)
      $desc = "CEL layer={0} pos=({1},{2})" -f $layerIdx, $x, $y
    }
    if ($desc) { Write-Output ("   sub off={0} size={1} type=0x{2:X4} {3}" -f $sub, $ssize, $stype, $desc) }
    if ($ssize -le 0) { break }
    $sub += $ssize
    $k++
  }
  $off += $csize
  $frameIdx++
}
