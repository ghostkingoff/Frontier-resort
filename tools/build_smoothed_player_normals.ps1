param(
    [string]$AssetDir = (Join-Path $PSScriptRoot "..\art\characters\player\star2a"),
    [double]$Blend = 0.90
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$frameSize = 48
$kernel = @(1.0, 4.0, 6.0, 4.0, 1.0)
$kernelRadius = 2
$kernelSum = 16.0
$neutral = [System.Drawing.Color]::FromArgb(255, 128, 128, 255)

function New-SurfaceBitmap(
    [int]$width,
    [int]$height
) {
    $bitmap = New-Object System.Drawing.Bitmap(
        $width,
        $height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear($neutral)
    $graphics.Dispose()
    return $bitmap
}

function Get-AlphaMask(
    [System.Drawing.Bitmap]$base,
    [int]$direction,
    [int]$row
) {
    $mask = New-Object 'bool[,]' $frameSize, $frameSize
    for ($y = 0; $y -lt $frameSize; $y++) {
        for ($x = 0; $x -lt $frameSize; $x++) {
            $pixel = $base.GetPixel(
                $direction * $frameSize + $x,
                $row * $frameSize + $y)
            if ($pixel.A -gt 0) {
                $mask[$x, $y] = $true
            }
        }
    }

    $dilated = New-Object 'bool[,]' $frameSize, $frameSize
    for ($y = 0; $y -lt $frameSize; $y++) {
        for ($x = 0; $x -lt $frameSize; $x++) {
            if (-not $mask[$x, $y]) {
                continue
            }
            for ($dy = -1; $dy -le 1; $dy++) {
                for ($dx = -1; $dx -le 1; $dx++) {
                    $sampleX = $x + $dx
                    $sampleY = $y + $dy
                    if ($sampleX -ge 0 -and $sampleX -lt $frameSize `
                            -and $sampleY -ge 0 -and $sampleY -lt $frameSize) {
                        $dilated[$sampleX, $sampleY] = $true
                    }
                }
            }
        }
    }
    return $dilated
}

function Decode-Normal([System.Drawing.Color]$pixel) {
    $x = $pixel.R / 127.5 - 1.0
    $y = $pixel.G / 127.5 - 1.0
    $z = $pixel.B / 127.5 - 1.0
    $length = [Math]::Sqrt($x * $x + $y * $y + $z * $z)
    if ($length -le 0.00001) {
        return @(0.0, 0.0, 1.0)
    }
    return @(
        ($x / $length),
        ($y / $length),
        ($z / $length))
}

function Encode-Normal([double]$x, [double]$y, [double]$z) {
    $red = [Math]::Round(($x * 0.5 + 0.5) * 255.0)
    $green = [Math]::Round(($y * 0.5 + 0.5) * 255.0)
    $blue = [Math]::Round(($z * 0.5 + 0.5) * 255.0)
    return [System.Drawing.Color]::FromArgb(
        255,
        [Math]::Max(0, [Math]::Min(255, [int]$red)),
        [Math]::Max(0, [Math]::Min(255, [int]$green)),
        [Math]::Max(0, [Math]::Min(255, [int]$blue)))
}

function Build-SmoothedAtlas(
    [string]$basePath,
    [string]$normalPath,
    [string]$outputPath,
    [int]$rowCount
) {
    $base = [System.Drawing.Bitmap]::FromFile($basePath)
    $normal = [System.Drawing.Bitmap]::FromFile($normalPath)
    $output = New-SurfaceBitmap $normal.Width $normal.Height
    try {
        for ($direction = 0; $direction -lt 4; $direction++) {
            for ($row = 0; $row -lt $rowCount; $row++) {
                $mask = Get-AlphaMask $base $direction $row
                for ($y = 0; $y -lt $frameSize; $y++) {
                    for ($x = 0; $x -lt $frameSize; $x++) {
                        if (-not $mask[$x, $y]) {
                            continue
                        }

                        $sourcePixel = $normal.GetPixel(
                            $direction * $frameSize + $x,
                            $row * $frameSize + $y)
                        $original = Decode-Normal $sourcePixel
                        [double]$sumX = 0.0
                        [double]$sumY = 0.0
                        [double]$sumZ = 0.0
                        [double]$weightSum = 0.0

                        for ($offsetY = -$kernelRadius; $offsetY -le $kernelRadius; $offsetY++) {
                            for ($offsetX = -$kernelRadius; $offsetX -le $kernelRadius; $offsetX++) {
                                $sampleX = $x + $offsetX
                                $sampleY = $y + $offsetY
                                if ($sampleX -lt 0 -or $sampleX -ge $frameSize `
                                        -or $sampleY -lt 0 -or $sampleY -ge $frameSize `
                                        -or -not $mask[$sampleX, $sampleY]) {
                                    continue
                                }
                                $weight = $kernel[$offsetX + $kernelRadius] `
                                    * $kernel[$offsetY + $kernelRadius]
                                $sample = Decode-Normal ($normal.GetPixel(
                                    $direction * $frameSize + $sampleX,
                                    $row * $frameSize + $sampleY))
                                $sumX += $sample[0] * $weight
                                $sumY += $sample[1] * $weight
                                $sumZ += $sample[2] * $weight
                                $weightSum += $weight
                            }
                        }

                        if ($weightSum -le 0.0) {
                            continue
                        }
                        $smoothLength = [Math]::Sqrt(
                            $sumX * $sumX + $sumY * $sumY + $sumZ * $sumZ)
                        if ($smoothLength -le 0.00001) {
                            continue
                        }
                        $smoothX = $sumX / $smoothLength
                        $smoothY = $sumY / $smoothLength
                        $smoothZ = $sumZ / $smoothLength
                        $mixedX = $original[0] * (1.0 - $Blend) + $smoothX * $Blend
                        $mixedY = $original[1] * (1.0 - $Blend) + $smoothY * $Blend
                        $mixedZ = $original[2] * (1.0 - $Blend) + $smoothZ * $Blend
                        $mixedLength = [Math]::Sqrt(
                            $mixedX * $mixedX + $mixedY * $mixedY + $mixedZ * $mixedZ)
                        if ($mixedLength -le 0.00001) {
                            continue
                        }
                        $encoded = Encode-Normal (
                            $mixedX / $mixedLength) (
                            $mixedY / $mixedLength) (
                            $mixedZ / $mixedLength)
                        $output.SetPixel(
                            $direction * $frameSize + $x,
                            $row * $frameSize + $y,
                            $encoded)
                    }
                }
            }
        }
        $output.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $output.Dispose()
        $normal.Dispose()
        $base.Dispose()
    }
}

$walkBase = Join-Path $AssetDir "walk.png"
$walkNormal = Join-Path $AssetDir "walk_n.png"
$idleBase = Join-Path $AssetDir "idle.png"
$idleNormal = Join-Path $AssetDir "idle_n.png"

Build-SmoothedAtlas $walkBase $walkNormal `
    (Join-Path $AssetDir "walk_n_smooth.png") 4
Build-SmoothedAtlas $idleBase $idleNormal `
    (Join-Path $AssetDir "idle_n_smooth.png") 2

Write-Output "Smoothed player normal maps generated in $AssetDir"
