param(
    [string]$OutputPath,
    [string]$Title = 'UPCOMING CHAMPIONS LEAGUE DRAFT FIXTURES',
    [string]$Subtitle = 'Next 24 hours - UK and Las Vegas kickoff times',
    [string]$FixturesJsonPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

$draft = Get-Content (Join-Path $scriptRoot 'draft.json') -Raw | ConvertFrom-Json

$owners = @{}
foreach ($owner in $draft.owners.PSObject.Properties.Name) {
    foreach ($team in @($draft.owners.$owner)) {
        $owners[$team] = $owner
    }
}

$picks = @{}
$ownerNames = @($draft.owners.PSObject.Properties.Name)
$roundCount = ($draft.owners.PSObject.Properties | ForEach-Object { @($_.Value).Count } | Measure-Object -Maximum).Maximum
$pickNumber = 0
for ($round = 0; $round -lt $roundCount; $round++) {
    $roundOwners = @($ownerNames)
    if ($round % 2) {
        [array]::Reverse($roundOwners)
    }

    foreach ($owner in $roundOwners) {
        $teams = @($draft.owners.$owner)
        if ($round -lt $teams.Count) {
            $pickNumber++
            $picks[$teams[$round]] = $pickNumber
        }
    }
}

function ConvertTo-FixtureRows([object]$Value) {
    $rows = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }
        if ($item -is [array]) {
            $rows += ConvertTo-FixtureRows $item
            continue
        }

        $fields = @('Stage', 'HomeTeam', 'AwayTeam', 'UK', 'LasVegas')
        $rowCount = 1
        foreach ($field in $fields) {
            $property = $item.PSObject.Properties[$field]
            if ($property -and $property.Value -is [array]) {
                $rowCount = [Math]::Max($rowCount, @($property.Value).Count)
            }
        }

        for ($index = 0; $index -lt $rowCount; $index++) {
            $homeProperty = $item.PSObject.Properties['HomeTeam']
            $awayProperty = $item.PSObject.Properties['AwayTeam']
            if (-not $homeProperty -and -not $awayProperty) {
                continue
            }

            $row = [ordered]@{}
            foreach ($field in $fields) {
                $property = $item.PSObject.Properties[$field]
                $value = if ($property) { $property.Value } else { '' }
                if ($value -is [array]) {
                    $values = @($value)
                    $row[$field] = if ($index -lt $values.Count) { [string]$values[$index] } else { '' }
                } else {
                    $row[$field] = [string]$value
                }
            }
            $rows += [pscustomobject]$row
        }
    }
    $rows
}

$rawFixtures = if ($FixturesJsonPath -and (Test-Path -LiteralPath $FixturesJsonPath)) {
    Get-Content -LiteralPath $FixturesJsonPath -Raw | ConvertFrom-Json
} else {
    @([pscustomobject]@{
        Stage = 'LP'
        HomeTeam = 'AEK Athens'
        AwayTeam = 'LASK'
        UK = 'Today, 5:45 PM'
        LasVegas = 'Today, 9:45 AM'
    })
}

$fixtures = @(ConvertTo-FixtureRows $rawFixtures)
if ($fixtures.Count -eq 0) {
    throw 'No fixtures to draw'
}

function New-Brush([int]$R, [int]$G, [int]$B) {
    [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($R, $G, $B))
}

function Get-TeamLabel([string]$Team) {
    if ($picks.ContainsKey($Team)) {
        "$Team ($($picks[$Team]))"
    } else {
        $Team
    }
}

function Get-Owner([string]$Team) {
    if ($owners.ContainsKey($Team)) {
        $owners[$Team]
    } else {
        '?'
    }
}

$tagFill = @{
    Jack = New-Brush 92 149 255
    Thomas = New-Brush 78 190 131
    Mark = New-Brush 246 196 83
    Rory = New-Brush 235 99 99
}
$tagText = @{
    Jack = [System.Drawing.Brushes]::White
    Thomas = [System.Drawing.Brushes]::White
    Mark = New-Brush 30 39 51
    Rory = [System.Drawing.Brushes]::White
}

$width = 1120
$rowHeight = 148
$headerHeight = 170
$rowGap = 20
$height = $headerHeight + ($fixtures.Count * $rowHeight) + ([Math]::Max(0, $fixtures.Count - 1) * $rowGap) + 72

$bitmap = [System.Drawing.Bitmap]::new($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = 'AntiAlias'
$graphics.TextRenderingHint = 'AntiAliasGridFit'

$background = [System.Drawing.Color]::FromArgb(17, 22, 30)
$panelBrush = New-Brush 30 39 51
$fixtureBrush = New-Brush 39 50 65
$timeBrush = New-Brush 25 33 44
$whiteBrush = [System.Drawing.Brushes]::White
$mutedBrush = New-Brush 135 148 164
$blueBrush = New-Brush 102 157 255
$borderPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(79, 96, 119), 2)

$titleFont = [System.Drawing.Font]::new('Segoe UI', 31, [System.Drawing.FontStyle]::Bold)
$subtitleFont = [System.Drawing.Font]::new('Segoe UI', 15)
$stageFont = [System.Drawing.Font]::new('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$teamFont = [System.Drawing.Font]::new('Segoe UI', 24, [System.Drawing.FontStyle]::Bold)
$smallFont = [System.Drawing.Font]::new('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$timeFont = [System.Drawing.Font]::new('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)

function Draw-OwnerTag([string]$Owner, [float]$X, [float]$Y) {
    if ($tagFill.ContainsKey($Owner)) {
        $graphics.FillRectangle($tagFill[$Owner], $X, $Y, 100, 27)
        $size = $graphics.MeasureString($Owner, $smallFont)
        $graphics.DrawString($Owner, $smallFont, $tagText[$Owner], $X + ((100 - $size.Width) / 2), $Y + ((27 - $size.Height) / 2) - 1)
    } else {
        $graphics.DrawString($Owner, $smallFont, $mutedBrush, $X, $Y)
    }
}

function Draw-FitText([string]$Text, [float]$X, [float]$Y, [float]$MaxWidth, [float]$MaxHeight, [System.Drawing.Brush]$Brush) {
    $font = $null
    for ($size = 24; $size -ge 15; $size--) {
        $candidate = [System.Drawing.Font]::new('Segoe UI', $size, [System.Drawing.FontStyle]::Bold)
        $measured = $graphics.MeasureString($Text, $candidate)
        if ($measured.Width -le $MaxWidth -and $measured.Height -le $MaxHeight) {
            $font = $candidate
            break
        }
        $candidate.Dispose()
    }

    if ($null -eq $font) {
        $font = [System.Drawing.Font]::new('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    }

    $format = [System.Drawing.StringFormat]::new()
    $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $graphics.DrawString($Text, $font, $Brush, [System.Drawing.RectangleF]::new($X, $Y, $MaxWidth, $MaxHeight), $format)
    $format.Dispose()
    $font.Dispose()
}

$graphics.Clear($background)
$graphics.FillRectangle($panelBrush, 38, 34, $width - 76, $height - 68)
$graphics.DrawRectangle($borderPen, 38, 34, $width - 76, $height - 68)
$graphics.DrawString($Title, $titleFont, $whiteBrush, 72, 70)
$graphics.DrawString($Subtitle, $subtitleFont, $mutedBrush, 75, 112)

$y = $headerHeight
foreach ($fixture in $fixtures) {
    $graphics.FillRectangle($fixtureBrush, 72, $y, 976, $rowHeight)

    $stage = switch ([string]$fixture.Stage) {
        'LP' { 'League phase' }
        'PO' { 'Play-off' }
        'FINAL' { 'Final' }
        default { [string]$fixture.Stage }
    }

    $graphics.DrawString($stage, $stageFont, $mutedBrush, 96, $y + 18)
    $graphics.FillRectangle($timeBrush, 96, $y + 42, 224, 88)
    $graphics.DrawString('UK', $smallFont, $mutedBrush, 116, $y + 48)
    $graphics.DrawString([string]$fixture.UK, $timeFont, $whiteBrush, 116, $y + 63)
    $graphics.DrawString('LAS VEGAS', $smallFont, $mutedBrush, 116, $y + 88)
    $graphics.DrawString([string]$fixture.LasVegas, $timeFont, $whiteBrush, 116, $y + 103)

    Draw-FitText (Get-TeamLabel ([string]$fixture.HomeTeam)) 370 ($y + 49) 245 34 $whiteBrush
    Draw-OwnerTag (Get-Owner ([string]$fixture.HomeTeam)) 372 ($y + 90)

    $graphics.DrawString('vs', $teamFont, $blueBrush, 635, $y + 63)

    Draw-FitText (Get-TeamLabel ([string]$fixture.AwayTeam)) 706 ($y + 49) 305 34 $whiteBrush
    Draw-OwnerTag (Get-Owner ([string]$fixture.AwayTeam)) 708 ($y + 90)

    $y += $rowHeight + $rowGap
}

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()

"Generated $OutputPath"
