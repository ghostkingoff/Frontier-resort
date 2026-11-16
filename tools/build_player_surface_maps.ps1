param(
    [string]$SourceDir = (Join-Path $PSScriptRoot "..\art\source\characters\star2a"),
    [string]$DestDir = (Join-Path $PSScriptRoot "..\art\characters\player\star2a")
)

Add-Type -AssemblyName System.Drawing

$frameSize = 48
$sourceWidth = 192
$sourceHeight = 288
$gameDirections = @(0, 2, 1, 3)
$standFrames = @(16, 22, 18, 20)

function New-TransparentBitmap([int]$width, [int]$height) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.Dispose()
    return $bitmap
}

function Copy-Frame(
    [System.Drawing.Bitmap]$source,
    [System.Drawing.Bitmap]$target,
    [int]$sourceFrame,
    [int]$targetColumn,
    [int]$targetRow,
    [int]$targetColumns
) {
    $sourceX = ($sourceFrame % 4) * $frameSize
    $sourceY = [Math]::Floor($sourceFrame / 4) * $frameSize
    $targetX = $targetColumn * $frameSize
    $targetY = $targetRow * $frameSize
    $graphics = [System.Drawing.Graphics]::FromImage($target)
    $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $graphics.DrawImage(
        $source,
        (New-Object System.Drawing.Rectangle $targetX, $targetY, $frameSize, $frameSize),
        (New-Object System.Drawing.Rectangle $sourceX, $sourceY, $frameSize, $frameSize),
        [System.Drawing.GraphicsUnit]::Pixel
    )
    $graphics.Dispose()
}

$mapSpecs = @(
    @{ SourceName = "star2a.png"; OutputSuffix = "" },
    @{ SourceName = "star2a_n.png"; OutputSuffix = "n" },
    @{ SourceName = "star2a_s.png"; OutputSuffix = "s" },
    @{ SourceName = "star2a_o.png"; OutputSuffix = "o" }
)

foreach ($mapSpec in $mapSpecs) {
    $sourcePath = Join-Path $SourceDir $mapSpec.SourceName
    $source = [System.Drawing.Bitmap]::FromFile($sourcePath)
    if ($source.Width -ne $sourceWidth -or $source.Height -ne $sourceHeight) {
        $source.Dispose()
        throw "Unexpected atlas size for $sourcePath"
    }

    $walk = New-TransparentBitmap ($sourceWidth) ($frameSize * 4)
    foreach ($gameDirection in 0..3) {
        $sourceRow = $gameDirections[$gameDirection]
        foreach ($step in 0..3) {
            $sourceFrame = if ($gameDirection -eq 0) {
                @(1, 2, 3, 2)[$step]
            } else {
                $sourceRow * 4 + $step
            }
            Copy-Frame $source $walk $sourceFrame $gameDirection $step 4
        }
    }
    $walkName = if ($mapSpec.OutputSuffix) {
        "walk_{0}.png" -f $mapSpec.OutputSuffix
    } else {
        "walk.png"
    }
    $walk.Save(
        (Join-Path $DestDir $walkName),
        [System.Drawing.Imaging.ImageFormat]::Png
    )
    $walk.Dispose()

    $idle = New-TransparentBitmap ($sourceWidth) ($frameSize * 2)
    foreach ($gameDirection in 0..3) {
        $sourceFrame = $standFrames[$gameDirection]
        Copy-Frame $source $idle $sourceFrame $gameDirection 0 4
        $idleFrame = $sourceFrame + 1
        Copy-Frame $source $idle $idleFrame $gameDirection 1 4
    }
    $idleName = if ($mapSpec.OutputSuffix) {
        "idle_{0}.png" -f $mapSpec.OutputSuffix
    } else {
        "idle.png"
    }
    $idle.Save(
        (Join-Path $DestDir $idleName),
        [System.Drawing.Imaging.ImageFormat]::Png
    )
    $idle.Dispose()
    $source.Dispose()
}

Write-Output "Player surface maps generated in $DestDir"
