param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'champions-league-draft-board.png'),
    [string]$DraftPath = (Join-Path $PSScriptRoot 'draft.json'),
    [string]$BoardPath = (Join-Path $PSScriptRoot 'DRAFT_BOARD.md')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

foreach ($requiredPath in @($DraftPath, $BoardPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required file not found: $requiredPath"
    }
}

$draft = Get-Content -LiteralPath $DraftPath -Raw | ConvertFrom-Json
$ownerOrder = @('Jack', 'Thomas', 'Mark', 'Rory')
$pound = [char]0x00A3

$potByTeam = @{}
foreach ($line in Get-Content -LiteralPath $BoardPath) {
    if ($line -match '^\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]*?)\s*\|') {
        $potByTeam[$Matches[2].Trim()] = [int]$Matches[1]
    }
}

function New-Brush([int]$r, [int]$g, [int]$b) {
    [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($r, $g, $b))
}

function Draw-RoundedRectangle(
    [System.Drawing.Graphics]$Graphics,
    [System.Drawing.Brush]$Brush,
    [single]$X,
    [single]$Y,
    [single]$Width,
    [single]$Height,
    [single]$Radius
) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = $Radius * 2
    $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
    $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
    $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    $Graphics.FillPath($Brush, $path)
    $path.Dispose()
}

function Draw-Text(
    [System.Drawing.Graphics]$Graphics,
    [string]$Text,
    [System.Drawing.Font]$Font,
    [System.Drawing.Brush]$Brush,
    [single]$X,
    [single]$Y,
    [single]$W,
    [single]$H,
    [System.Drawing.StringAlignment]$Align = [System.Drawing.StringAlignment]::Near
) {
    $format = [System.Drawing.StringFormat]::new()
    $format.Alignment = $Align
    $format.LineAlignment = [System.Drawing.StringAlignment]::Near
    $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoClip
    $rect = [System.Drawing.RectangleF]::new($X, $Y, $W, $H)
    $Graphics.DrawString($Text, $Font, $Brush, $rect, $format)
    $format.Dispose()
}

function Draw-FitText(
    [System.Drawing.Graphics]$Graphics,
    [string]$Text,
    [string]$Family,
    [single]$StartSize,
    [single]$MinSize,
    [System.Drawing.FontStyle]$FontStyle,
    [System.Drawing.Brush]$Brush,
    [single]$X,
    [single]$Y,
    [single]$W,
    [single]$H
) {
    $size = $StartSize
    $font = [System.Drawing.Font]::new($Family, $size, $FontStyle)
    while ($size -gt $MinSize -and $Graphics.MeasureString($Text, $font).Width -gt $W) {
        $font.Dispose()
        $size -= 1
        $font = [System.Drawing.Font]::new($Family, $size, $FontStyle)
    }

    Draw-Text $Graphics $Text $font $Brush $X $Y $W $H
    $font.Dispose()
}

function Draw-PotChip(
    [System.Drawing.Graphics]$Graphics,
    [int]$Pot,
    [single]$X,
    [single]$Y
) {
    $fill = switch ($Pot) {
        1 { $script:brushGold }
        2 { $script:brushBlue }
        3 { $script:brushGreen }
        4 { $script:brushMutedPanel }
        default { $script:brushMutedPanel }
    }
    Draw-RoundedRectangle $Graphics $fill $X $Y 72 34 10
    Draw-Text $Graphics "P$Pot" $script:fontChip $script:brushDarkText ($X + 1) ($Y + 5) 70 25 ([System.Drawing.StringAlignment]::Center)
}

function Draw-OwnerPanel(
    [System.Drawing.Graphics]$Graphics,
    [string]$Owner,
    [array]$Teams,
    [single]$X,
    [single]$Y,
    [System.Drawing.Brush]$AccentBrush
) {
    Draw-RoundedRectangle $Graphics $script:brushPanel $X $Y 690 550 26
    $Graphics.DrawRectangle($script:penSubtle, $X, $Y, 690, 550)
    Draw-Text $Graphics $Owner $script:fontOwner $AccentBrush ($X + 36) ($Y + 30) 340 60
    Draw-Text $Graphics ('{0} clubs' -f $Teams.Count) $script:fontSmall $script:brushMuted ($X + 500) ($Y + 42) 130 36 ([System.Drawing.StringAlignment]::Far)

    $rowY = $Y + 112
    for ($i = 0; $i -lt $Teams.Count; $i++) {
        $team = [string]$Teams[$i]
        $pot = if ($script:potByTeam.ContainsKey($team)) { [int]$script:potByTeam[$team] } else { 0 }
        Draw-RoundedRectangle $Graphics $script:brushRow ($X + 30) $rowY 630 39 10
        Draw-Text $Graphics ('{0}.' -f ($i + 1)) $script:fontIndex $script:brushMuted ($X + 52) ($rowY + 7) 48 30
        Draw-PotChip $Graphics $pot ($X + 106) ($rowY + 3)
        Draw-FitText $Graphics $team 'Segoe UI' 22 15 ([System.Drawing.FontStyle]::Bold) $script:brushWhite ($X + 198) ($rowY + 5) 420 32
        $rowY += 45
    }
}

$script:potByTeam = $potByTeam

$width = 1600
$height = 1800
$bmp = [System.Drawing.Bitmap]::new($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bmp)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$bg = [System.Drawing.Color]::FromArgb(16, 23, 34)
$script:brushBg = New-Brush 16 23 34
$script:brushPanel = New-Brush 24 36 53
$script:brushRow = New-Brush 31 46 66
$script:brushPanel2 = New-Brush 29 43 62
$script:brushWhite = New-Brush 247 250 252
$script:brushMuted = New-Brush 170 184 202
$script:brushMutedPanel = New-Brush 170 184 202
$script:brushGold = New-Brush 243 201 105
$script:brushGreen = New-Brush 125 220 145
$script:brushBlue = New-Brush 126 182 255
$script:brushRed = New-Brush 255 122 122
$script:brushDarkText = New-Brush 18 26 38
$script:penSubtle = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(49, 68, 95), 2)

$script:fontEyebrow = [System.Drawing.Font]::new('Segoe UI', 25, [System.Drawing.FontStyle]::Regular)
$script:fontTitle = [System.Drawing.Font]::new('Segoe UI', 54, [System.Drawing.FontStyle]::Bold)
$script:fontSub = [System.Drawing.Font]::new('Segoe UI', 23, [System.Drawing.FontStyle]::Regular)
$script:fontOwner = [System.Drawing.Font]::new('Segoe UI', 36, [System.Drawing.FontStyle]::Bold)
$script:fontSmall = [System.Drawing.Font]::new('Segoe UI', 19, [System.Drawing.FontStyle]::Regular)
$script:fontIndex = [System.Drawing.Font]::new('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$script:fontChip = [System.Drawing.Font]::new('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$script:fontRule = [System.Drawing.Font]::new('Segoe UI', 22, [System.Drawing.FontStyle]::Regular)
$script:fontRuleBold = [System.Drawing.Font]::new('Segoe UI', 24, [System.Drawing.FontStyle]::Bold)

$graphics.Clear($bg)
Draw-Text $graphics 'CHAMPIONS LEAGUE DRAFT' $script:fontEyebrow $script:brushGold 80 58 1440 42 ([System.Drawing.StringAlignment]::Center)
Draw-Text $graphics 'Draft Complete' $script:fontTitle $script:brushWhite 80 104 1440 78 ([System.Drawing.StringAlignment]::Center)
Draw-Text $graphics '36 clubs - 4 owners - 9 apiece - one extremely confident September group chat' $script:fontSub $script:brushMuted 80 190 1440 46 ([System.Drawing.StringAlignment]::Center)

$ownerBrushes = @{
    Jack = $script:brushBlue
    Thomas = $script:brushGreen
    Mark = $script:brushGold
    Rory = $script:brushRed
}

Draw-OwnerPanel $graphics 'Jack' @($draft.owners.Jack) 80 280 $ownerBrushes.Jack
Draw-OwnerPanel $graphics 'Thomas' @($draft.owners.Thomas) 830 280 $ownerBrushes.Thomas
Draw-OwnerPanel $graphics 'Mark' @($draft.owners.Mark) 80 875 $ownerBrushes.Mark
Draw-OwnerPanel $graphics 'Rory' @($draft.owners.Rory) 830 875 $ownerBrushes.Rory

Draw-RoundedRectangle $graphics $script:brushPanel 80 1480 1440 210 24
Draw-Text $graphics 'Rules of engagement' $script:fontRuleBold $script:brushWhite 120 1515 500 40
Draw-Text $graphics ('{0}5 per result. Draws and same-owner matches are void.' -f $pound) $script:fontRule $script:brushMuted 120 1570 1180 34
Draw-Text $graphics 'Side pots: goals, red cards, most teams reaching the last 16, and the overall winner.' $script:fontRule $script:brushMuted 120 1610 1180 34
Draw-Text $graphics 'The anthem is playing. Someone is already regretting Pot 4.' $script:fontRuleBold $script:brushGold 120 1650 1180 40

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
}

$bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)

$graphics.Dispose()
$bmp.Dispose()

foreach ($object in @(
    $script:brushBg,
    $script:brushPanel,
    $script:brushRow,
    $script:brushPanel2,
    $script:brushWhite,
    $script:brushMuted,
    $script:brushMutedPanel,
    $script:brushGold,
    $script:brushGreen,
    $script:brushBlue,
    $script:brushRed,
    $script:brushDarkText,
    $script:penSubtle,
    $script:fontEyebrow,
    $script:fontTitle,
    $script:fontSub,
    $script:fontOwner,
    $script:fontSmall,
    $script:fontIndex,
    $script:fontChip,
    $script:fontRule,
    $script:fontRuleBold
)) {
    if ($null -ne $object) {
        $object.Dispose()
    }
}

Write-Output "Generated $OutputPath"
