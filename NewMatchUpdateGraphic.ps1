param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'match-update-test.png'),
    [string]$Title = 'CHAMPIONS LEAGUE DRAFT UPDATE',
    [string]$Subtitle = '',
    [string]$HomeTeam = 'Arsenal',
    [string]$HomeOwner = 'Thomas',
    [int]$HomeScore = 2,
    [string]$AwayTeam = 'Napoli',
    [string]$AwayOwner = 'Jack',
    [int]$AwayScore = 1,
    [Nullable[int]]$HomeShootoutScore = $null,
    [Nullable[int]]$AwayShootoutScore = $null,
    [string]$Settlement = 'Thomas beats Jack',
    [string]$GroupQualification = 'Last-16 status: no change',
    [string]$StatePath = '',
    [string]$DraftPath = '',
    [string]$CreditOwner = '',
    [string]$DebitOwner = '',
    [int]$TransferGBP = 5
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$pound = [char]0x00A3
$ownerOrder = @('Jack', 'Thomas', 'Mark', 'Rory')

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $PSScriptRoot 'tracker-state.json'
}

if ([string]::IsNullOrWhiteSpace($DraftPath)) {
    $DraftPath = Join-Path $PSScriptRoot 'draft.json'
}

if (-not (Test-Path -LiteralPath $StatePath)) {
    throw "State file not found: $StatePath"
}

if (-not (Test-Path -LiteralPath $DraftPath)) {
    throw "Draft file not found: $DraftPath"
}

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$draft = Get-Content -LiteralPath $DraftPath -Raw | ConvertFrom-Json

foreach ($requiredSection in @('balancesGBP', 'sideBets')) {
    if ($null -eq $state.PSObject.Properties[$requiredSection]) {
        throw "State file is missing required section '$requiredSection': $StatePath"
    }
}

foreach ($requiredSideBetSection in @('goals', 'redCards', 'yellowCards', 'last16')) {
    if ($null -eq $state.sideBets.PSObject.Properties[$requiredSideBetSection]) {
        throw "State file is missing required side-bet section '$requiredSideBetSection': $StatePath"
    }
}

function Resolve-TeamName([string]$TeamName) {
    if ($null -ne $draft.aliases -and $null -ne $draft.aliases.PSObject.Properties[$TeamName]) {
        return [string]$draft.aliases.$TeamName
    }

    $TeamName
}

$teamPicks = @{}
$ownerNames = @($draft.owners.PSObject.Properties.Name)
$roundCount = ($draft.owners.PSObject.Properties | ForEach-Object { @($_.Value).Count } | Measure-Object -Maximum).Maximum
$pickNumber = 0

for ($round = 0; $round -lt $roundCount; $round++) {
    $roundOwners = @($ownerNames)
    if ($round % 2 -eq 1) {
        [array]::Reverse($roundOwners)
    }

    foreach ($owner in $roundOwners) {
        $ownerTeams = @($draft.owners.$owner)
        if ($round -lt $ownerTeams.Count) {
            $pickNumber += 1
            $teamPicks[$ownerTeams[$round]] = $pickNumber
        }
    }
}

foreach ($alias in $draft.aliases.PSObject.Properties) {
    if ($teamPicks.ContainsKey($alias.Value)) {
        $teamPicks[$alias.Name] = $teamPicks[$alias.Value]
    }
}

function Format-TeamLabel([string]$TeamName) {
    $canonicalTeam = Resolve-TeamName $TeamName
    if ($teamPicks.ContainsKey($canonicalTeam)) {
        return "$TeamName ($($teamPicks[$canonicalTeam]))"
    }

    $TeamName
}

function Get-DraftedOwner([string]$TeamName) {
    $canonicalTeam = Resolve-TeamName $TeamName

    foreach ($owner in $draft.owners.PSObject.Properties) {
        if (@($owner.Value) -contains $canonicalTeam) {
            return [string]$owner.Name
        }
    }

    throw "Team '$TeamName' is not assigned in draft file: $DraftPath"
}

function Assert-DraftedOwner([string]$TeamName, [string]$ExpectedOwner, [string]$Side) {
    $actualOwner = Get-DraftedOwner $TeamName
    if ($actualOwner -ne $ExpectedOwner) {
        throw "$Side team owner mismatch for '$TeamName': draft has '$actualOwner', renderer was given '$ExpectedOwner'."
    }
}

Assert-DraftedOwner $HomeTeam $HomeOwner 'Home'
Assert-DraftedOwner $AwayTeam $AwayOwner 'Away'

$hasHomeShootoutScore = $null -ne $HomeShootoutScore
$hasAwayShootoutScore = $null -ne $AwayShootoutScore
if ($hasHomeShootoutScore -ne $hasAwayShootoutScore) {
    throw 'HomeShootoutScore and AwayShootoutScore must be provided together.'
}

$hasShootout = $hasHomeShootoutScore -and $hasAwayShootoutScore
if ($hasShootout) {
    if ($HomeScore -ne $AwayScore) {
        throw 'Shootout scores require a tied normal/extra-time score.'
    }

    if ([int]$HomeShootoutScore -lt 0 -or [int]$AwayShootoutScore -lt 0) {
        throw 'Shootout scores cannot be negative.'
    }

    if ([int]$HomeShootoutScore -eq [int]$AwayShootoutScore) {
        throw 'Shootout scores must identify a winner.'
    }
}

if ($HomeScore -eq $AwayScore -and -not $hasShootout -and (-not [string]::IsNullOrWhiteSpace($CreditOwner) -or -not [string]::IsNullOrWhiteSpace($DebitOwner))) {
    throw "Drawn matches must not include CreditOwner or DebitOwner."
}

if ($HomeOwner -eq $AwayOwner -and (-not [string]::IsNullOrWhiteSpace($CreditOwner) -or -not [string]::IsNullOrWhiteSpace($DebitOwner))) {
    throw "Same-owner matches must not include CreditOwner or DebitOwner."
}

if ($hasShootout -and $HomeOwner -ne $AwayOwner) {
    $expectedCreditOwner = if ([int]$HomeShootoutScore -gt [int]$AwayShootoutScore) { $HomeOwner } else { $AwayOwner }
    $expectedDebitOwner = if ([int]$HomeShootoutScore -gt [int]$AwayShootoutScore) { $AwayOwner } else { $HomeOwner }
    if ($CreditOwner -ne $expectedCreditOwner -or $DebitOwner -ne $expectedDebitOwner) {
        throw "Shootout settlement must credit '$expectedCreditOwner' and debit '$expectedDebitOwner'."
    }
}

function Get-OwnerValue([object]$Section, [string]$Owner) {
    if ($null -ne $Section -and $null -ne $Section.PSObject.Properties[$Owner]) {
        [int]$Section.$Owner
    } else {
        0
    }
}

function Assert-Last16Tracker {
    if ($null -eq $state.PSObject.Properties['last16Teams']) {
        return
    }

    $expected = @{
        Jack = 0
        Thomas = 0
        Mark = 0
        Rory = 0
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($team in @($state.last16Teams)) {
        $canonicalTeam = Resolve-TeamName ([string]$team)
        if (-not $seen.Add($canonicalTeam)) {
            throw "Last-16 tracker contains duplicate team '$canonicalTeam': $StatePath"
        }

        $owner = Get-DraftedOwner $canonicalTeam
        $expected[$owner] = [int]$expected[$owner] + 1
    }

    foreach ($owner in $ownerOrder) {
        $actual = Get-OwnerValue $state.sideBets.last16 $owner
        if ($actual -ne [int]$expected[$owner]) {
            throw "Last-16 tracker mismatch for '$owner': count is $actual but last16Teams implies $($expected[$owner])."
        }
    }
}

Assert-Last16Tracker

function Format-CurrencyValue([int]$Value) {
    if ($Value -gt 0) {
        "+$pound$Value"
    } elseif ($Value -lt 0) {
        "-$pound$([math]::Abs($Value))"
    } else {
        "${pound}0"
    }
}

function New-OwnerRows([object]$Section, [switch]$Currency) {
    foreach ($owner in $ownerOrder) {
        $value = Get-OwnerValue $Section $owner
        $display = if ($Currency) {
            Format-CurrencyValue $value
        } else {
            $value.ToString()
        }

        ,@($owner, $display)
    }
}

function New-RedCardRows([object]$RedSection, [object]$YellowSection) {
    foreach ($owner in $ownerOrder) {
        $redValue = Get-OwnerValue $RedSection $owner
        $yellowValue = Get-OwnerValue $YellowSection $owner
        ,@($owner, ('{0} ({1}Y)' -f $redValue, $yellowValue), $redValue, $yellowValue)
    }
}

$balances = New-OwnerRows $state.balancesGBP -Currency
$goals = New-OwnerRows $state.sideBets.goals
$redCards = New-RedCardRows $state.sideBets.redCards $state.sideBets.yellowCards
$qualified = New-OwnerRows $state.sideBets.last16

function Get-NumericValue([string]$Value) {
    $normalized = $Value.Replace([string]$pound, '').Replace('+', '').Trim()
    [int]$normalized
}

function Sort-StandingRows([array]$Rows) {
    @($Rows | Sort-Object @{ Expression = {
        if ($_.Count -ge 3) {
            [int]$_[2]
        } else {
            Get-NumericValue $_[1]
        }
    }; Descending = $true }, @{ Expression = {
        if ($_.Count -ge 4) {
            [int]$_[3]
        } else {
            0
        }
    }; Descending = $true }, @{ Expression = { $_[0] }; Ascending = $true })
}

$balances = Sort-StandingRows $balances
$goals = Sort-StandingRows $goals
$redCards = Sort-StandingRows $redCards
$qualified = Sort-StandingRows $qualified

function New-Brush([int]$r, [int]$g, [int]$b) {
    [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($r, $g, $b))
}

function Draw-RoundedRectangle(
    [System.Drawing.Graphics]$Graphics,
    [System.Drawing.Brush]$Brush,
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height,
    [int]$Radius
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
    [single]$MaxWidth
) {
    $size = $StartSize
    $font = [System.Drawing.Font]::new($Family, $size, $FontStyle)

    while ($size -gt $MinSize -and $Graphics.MeasureString($Text, $font).Width -gt $MaxWidth) {
        $font.Dispose()
        $size -= 1
        $font = [System.Drawing.Font]::new($Family, $size, $FontStyle)
    }

    if ($Graphics.MeasureString($Text, $font).Width -gt $MaxWidth) {
        $format = [System.Drawing.StringFormat]::new()
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $height = $font.GetHeight($Graphics) + 6
        $bounds = [System.Drawing.RectangleF]::new($X, $Y, $MaxWidth, $height)
        $Graphics.DrawString($Text, $font, $Brush, $bounds, $format)
        $format.Dispose()
    } else {
        $Graphics.DrawString($Text, $font, $Brush, $X, $Y)
    }

    $font.Dispose()
}

function Draw-OwnerTag(
    [System.Drawing.Graphics]$Graphics,
    [string]$OwnerName,
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height,
    [System.Drawing.Font]$Font,
    [System.Drawing.Brush]$FallbackBrush
) {
    if ($ownerColors.ContainsKey($OwnerName)) {
        $owner = $ownerColors[$OwnerName]
        Draw-RoundedRectangle $Graphics $owner.Fill $X $Y $Width $Height 5
        $ownerSize = $Graphics.MeasureString($OwnerName, $Font)
        $textX = $X + (($Width - $ownerSize.Width) / 2)
        $textY = $Y + (($Height - $ownerSize.Height) / 2) - 1
        $Graphics.DrawString($OwnerName, $Font, $owner.Text, $textX, $textY)
    } else {
        $Graphics.DrawString($OwnerName, $Font, $FallbackBrush, $X, $Y)
    }
}

function Draw-Section(
    [System.Drawing.Graphics]$Graphics,
    [string]$Heading,
    [array]$Rows,
    [int]$X,
    [int]$Y,
    [int]$ValueX,
    [System.Drawing.Font]$HeadingFont,
    [System.Drawing.Font]$RowFont,
    [System.Drawing.Font]$ValueFont,
    [System.Drawing.Brush]$White,
    [System.Drawing.Brush]$Muted,
    [System.Drawing.Brush]$Green,
    [System.Drawing.Brush]$Red
) {
    $Graphics.DrawString($Heading, $HeadingFont, $White, $X, $Y)
    $rowY = $Y + 34

    foreach ($row in $Rows) {
        $name = $row[0]
        $value = $row[1]
        $brush = $Muted

        if ($value.StartsWith('+')) {
            $brush = $Green
        } elseif ($value.StartsWith('-')) {
            $brush = $Red
        }

        Draw-OwnerTag $Graphics $name $X ($rowY + 1) 94 24 $RowFont $Muted
        $valueSize = $Graphics.MeasureString($value, $ValueFont)
        $Graphics.DrawString($value, $ValueFont, $brush, $ValueX - $valueSize.Width, $rowY)
        $rowY += 30
    }
}

function Split-TextToLines(
    [System.Drawing.Graphics]$Graphics,
    [string]$Text,
    [System.Drawing.Font]$Font,
    [int]$MaxWidth
) {
    $words = $Text -split '\s+'
    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''

    foreach ($word in $words) {
        $candidate = if ([string]::IsNullOrWhiteSpace($current)) { $word } else { "$current $word" }
        $size = $Graphics.MeasureString($candidate, $Font)

        if ($size.Width -le $MaxWidth -or [string]::IsNullOrWhiteSpace($current)) {
            $current = $candidate
        } else {
            $lines.Add($current)
            $current = $word
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $lines.Add($current)
    }

    @($lines)
}

$bmp = [System.Drawing.Bitmap]::new(1120, 620)
$graphics = [System.Drawing.Graphics]::FromImage($bmp)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$bg = [System.Drawing.Color]::FromArgb(17, 22, 30)
$panel = New-Brush 30 39 51
$panelSoft = New-Brush 39 50 65
$line = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(79, 96, 119), 2)
$white = [System.Drawing.Brushes]::White
$muted = New-Brush 180 190 202
$mutedDark = New-Brush 135 148 164
$green = New-Brush 82 196 139
$red = New-Brush 235 99 99
$blue = New-Brush 102 157 255
$gold = New-Brush 246 199 88

$ownerColors = @{
    Jack = @{ Fill = (New-Brush 92 149 255); Text = [System.Drawing.Brushes]::White }
    Thomas = @{ Fill = (New-Brush 78 190 131); Text = [System.Drawing.Brushes]::White }
    Mark = @{ Fill = (New-Brush 246 196 83); Text = (New-Brush 30 39 51) }
    Rory = @{ Fill = (New-Brush 235 99 99); Text = [System.Drawing.Brushes]::White }
}
$homeScoreBrush = if ($ownerColors.ContainsKey($HomeOwner)) { $ownerColors[$HomeOwner].Fill } else { $gold }
$awayScoreBrush = if ($ownerColors.ContainsKey($AwayOwner)) { $ownerColors[$AwayOwner].Fill } else { $blue }

$fontTitle = [System.Drawing.Font]::new('Segoe UI', [single]31, [System.Drawing.FontStyle]::Bold)
$fontSub = [System.Drawing.Font]::new('Segoe UI', [single]14, [System.Drawing.FontStyle]::Regular)
$fontTeam = [System.Drawing.Font]::new('Segoe UI', [single]26, [System.Drawing.FontStyle]::Bold)
$fontOwner = [System.Drawing.Font]::new('Segoe UI', [single]14, [System.Drawing.FontStyle]::Regular)
$fontScore = [System.Drawing.Font]::new('Segoe UI', [single]62, [System.Drawing.FontStyle]::Bold)
$fontShootout = [System.Drawing.Font]::new('Segoe UI', [single]28, [System.Drawing.FontStyle]::Bold)
$fontDash = [System.Drawing.Font]::new('Segoe UI', [single]44, [System.Drawing.FontStyle]::Bold)
$fontHead = [System.Drawing.Font]::new('Segoe UI', [single]18, [System.Drawing.FontStyle]::Bold)
$fontRow = [System.Drawing.Font]::new('Segoe UI', [single]13, [System.Drawing.FontStyle]::Bold)
$fontValue = [System.Drawing.Font]::new('Segoe UI', [single]15, [System.Drawing.FontStyle]::Bold)
$fontSmallBold = [System.Drawing.Font]::new('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)

$graphics.Clear($bg)
Draw-RoundedRectangle $graphics $panel 38 34 1044 540 8
$graphics.DrawRectangle($line, 38, 34, 1044, 540)

$graphics.DrawString($Title, $fontTitle, $white, 72, 64)
if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
    $graphics.DrawString($Subtitle, $fontSub, $mutedDark, 75, 106)
}

$scoreY = 148
Draw-FitText $graphics (Format-TeamLabel $HomeTeam) 'Segoe UI' 26 17 ([System.Drawing.FontStyle]::Bold) $white 82 $scoreY 252
if ($ownerColors.ContainsKey($HomeOwner)) {
    Draw-OwnerTag $graphics $HomeOwner 86 ($scoreY + 40) 98 27 $fontOwner $muted
} else {
    $graphics.DrawString($HomeOwner, $fontOwner, $muted, 86, $scoreY + 38)
}
$homeScoreText = $HomeScore.ToString()
$awayScoreText = $AwayScore.ToString()
$graphics.DrawString($homeScoreText, $fontScore, $homeScoreBrush, 340, $scoreY - 12)
if ($hasShootout) {
    $homeScoreSize = $graphics.MeasureString($homeScoreText, $fontScore)
    $graphics.DrawString("($([int]$HomeShootoutScore))", $fontShootout, $homeScoreBrush, (340 + $homeScoreSize.Width - 5), $scoreY + 22)
}
$graphics.DrawString('-', $fontDash, $mutedDark, 486, $scoreY + 2)
$graphics.DrawString($awayScoreText, $fontScore, $awayScoreBrush, 570, $scoreY - 12)
if ($hasShootout) {
    $awayScoreSize = $graphics.MeasureString($awayScoreText, $fontScore)
    $graphics.DrawString("($([int]$AwayShootoutScore))", $fontShootout, $awayScoreBrush, (570 + $awayScoreSize.Width - 5), $scoreY + 22)
}
Draw-FitText $graphics (Format-TeamLabel $AwayTeam) 'Segoe UI' 26 17 ([System.Drawing.FontStyle]::Bold) $white 720 $scoreY 320
if ($ownerColors.ContainsKey($AwayOwner)) {
    Draw-OwnerTag $graphics $AwayOwner 724 ($scoreY + 40) 98 27 $fontOwner $muted
} else {
    $graphics.DrawString($AwayOwner, $fontOwner, $muted, 724, $scoreY + 38)
}

Draw-RoundedRectangle $graphics $panelSoft 72 254 976 102 6
$graphics.DrawString($Settlement, $fontHead, $white, 96, 270)
$hasGroupQualification = -not [string]::IsNullOrWhiteSpace($GroupQualification) -and $GroupQualification -ne 'Last-16 status: no change'
if (-not [string]::IsNullOrWhiteSpace($CreditOwner) -and -not [string]::IsNullOrWhiteSpace($DebitOwner)) {
    $creditText = "+$pound$TransferGBP $CreditOwner"
    $debitText = "-$pound$TransferGBP $DebitOwner"
    $graphics.DrawString($creditText, $fontSmallBold, $green, 96, 302)
    $creditSize = $graphics.MeasureString($creditText, $fontSmallBold)
    $graphics.DrawString($debitText, $fontSmallBold, $red, (116 + $creditSize.Width), 302)
    if ($hasGroupQualification) {
        Draw-FitText $graphics $GroupQualification 'Segoe UI' 16 11 ([System.Drawing.FontStyle]::Bold) $mutedDark 96 328 928
    }
} else {
    if ($hasGroupQualification) {
        Draw-FitText $graphics $GroupQualification 'Segoe UI' 16 11 ([System.Drawing.FontStyle]::Bold) $mutedDark 96 302 928
    }
}

Draw-Section $graphics 'Balances' $balances 86 386 245 $fontHead $fontRow $fontValue $white $muted $green $red
Draw-Section $graphics 'Goals' $goals 330 386 455 $fontHead $fontRow $fontValue $white $muted $green $red
Draw-Section $graphics 'Red cards' $redCards 555 386 755 $fontHead $fontRow $fontValue $white $muted $green $red
Draw-Section $graphics 'Last 16' $qualified 805 386 950 $fontHead $fontRow $fontValue $white $muted $green $red

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)

$graphics.Dispose()
$bmp.Dispose()

Write-Output "Generated $OutputPath"
