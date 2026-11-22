# Mechanical size/format conversion only. Original artwork is retained beside this script.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assetRoot = Join-Path $PSScriptRoot '..\Sources\Assets.xcassets'
$iconRoot = Join-Path $assetRoot 'AppIcon.appiconset'
$brandRoot = Join-Path $assetRoot 'BrandMark.imageset'
New-Item -ItemType Directory -Force -Path $iconRoot,$brandRoot | Out-Null
$sourceImage = [Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'app-icon-source.png'))
function Write-Icon([int]$pixels, [string]$path) {
    $bitmap = [Drawing.Bitmap]::new($pixels,$pixels,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($sourceImage,0,0,$pixels,$pixels)
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
try {
    $images = @()
    $specs = @(
        @{idiom='iphone';size=20;scales=@(2,3)},
        @{idiom='iphone';size=29;scales=@(2,3)},
        @{idiom='iphone';size=40;scales=@(2,3)},
        @{idiom='iphone';size=60;scales=@(2,3)},
        @{idiom='ipad';size=20;scales=@(1,2)},
        @{idiom='ipad';size=29;scales=@(1,2)},
        @{idiom='ipad';size=40;scales=@(1,2)},
        @{idiom='ipad';size=76;scales=@(1,2)},
        @{idiom='ipad';size=83.5;scales=@(2)},
        @{idiom='ios-marketing';size=1024;scales=@(1)}
    )
    foreach ($spec in $specs) {
        foreach ($scale in $spec.scales) {
            $pixels = [int]($spec.size*$scale)
            $filename = "icon-$pixels.png"
            Write-Icon $pixels (Join-Path $iconRoot $filename)
            $sizeText = $spec.size.ToString([Globalization.CultureInfo]::InvariantCulture)
            $images += @{idiom=$spec.idiom;size="${sizeText}x${sizeText}";scale="${scale}x";filename=$filename}
        }
    }
    @{images=$images;info=@{version=1;author='xcode'}} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $iconRoot 'Contents.json') -Encoding utf8
    Write-Icon 512 (Join-Path $brandRoot 'brand.png')
    @{images=@(@{idiom='universal';filename='brand.png'});info=@{version=1;author='xcode'}} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $brandRoot 'Contents.json') -Encoding utf8
    @{info=@{version=1;author='xcode'}} | ConvertTo-Json | Set-Content (Join-Path $assetRoot 'Contents.json') -Encoding utf8
} finally { $sourceImage.Dispose() }
