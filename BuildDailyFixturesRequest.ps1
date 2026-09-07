[CmdletBinding()]
param(
    [string]$WindowStart = '',
    [int]$WindowHours = 24,
    [string]$CalendarPath = '',
    [string]$OutputPath = '',
    [switch]$CreateEmptyRequest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($CalendarPath)) {
    $CalendarPath = Join-Path $scriptRoot 'fixtures-calendar.json'
}

if (-not (Test-Path -LiteralPath $CalendarPath)) {
    throw "Fixture calendar not found: $CalendarPath"
}

function Get-TimeZoneByAnyId([string[]]$Ids) {
    foreach ($id in $Ids) {
        try {
            return [TimeZoneInfo]::FindSystemTimeZoneById($id)
        } catch {
            # Try the next platform-specific id.
        }
    }

    throw "Could not resolve any time zone id: $($Ids -join ', ')"
}

$londonZone = Get-TimeZoneByAnyId @('GMT Standard Time', 'Europe/London')
$vegasZone = Get-TimeZoneByAnyId @('Pacific Standard Time', 'America/Los_Angeles')

if ([string]::IsNullOrWhiteSpace($WindowStart)) {
    $nowUtc = [DateTimeOffset]::UtcNow
    $windowStartDateTime = [TimeZoneInfo]::ConvertTime($nowUtc, $londonZone)
} else {
    $windowStartDateTime = [DateTimeOffset]::Parse(
        $WindowStart,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}

$windowEndDateTime = $windowStartDateTime.AddHours($WindowHours)
$postDate = $windowStartDateTime.ToString('yyyy-MM-dd')
$requestId = "fixtures-$postDate"

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $scriptRoot "requests\inbox\$requestId.json"
}

$processedPath = Join-Path $scriptRoot "requests\processed\$requestId.json"
$ledgerPath = Join-Path $scriptRoot 'requests\delivery-ledger.jsonl'

if (Test-Path -LiteralPath $processedPath) {
    [pscustomobject]@{
        Status = 'already-processed'
        RequestId = $requestId
        RequestPath = ''
        FixtureCount = 0
    } | ConvertTo-Json -Depth 6
    return
}

if (Test-Path -LiteralPath $ledgerPath) {
    foreach ($line in Get-Content -LiteralPath $ledgerPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json
            if ([string]$entry.id -eq $requestId) {
                [pscustomobject]@{
                    Status = 'already-delivered'
                    RequestId = $requestId
                    RequestPath = ''
                    FixtureCount = 0
                } | ConvertTo-Json -Depth 6
                return
            }
        } catch {
            # Ignore legacy/local log damage here; PublishRequests validates the ledger before publishing.
        }
    }
}

$calendar = Get-Content -LiteralPath $CalendarPath -Raw | ConvertFrom-Json

function Format-KickoffLabel([DateTimeOffset]$Kickoff, [TimeZoneInfo]$Zone, [DateTimeOffset]$ReferenceLondon) {
    $local = [TimeZoneInfo]::ConvertTime($Kickoff, $Zone)
    $referenceLocal = [TimeZoneInfo]::ConvertTime($ReferenceLondon, $Zone)
    $dayOffset = ($local.Date - $referenceLocal.Date).Days
    $dayLabel = switch ($dayOffset) {
        0 { 'Today' }
        1 { 'Tomorrow' }
        -1 { 'Yesterday' }
        default { $local.ToString('ddd d MMM', [Globalization.CultureInfo]::InvariantCulture) }
    }

    '{0}, {1}' -f $dayLabel, $local.ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture)
}

$windowStartUtc = $windowStartDateTime.UtcDateTime
$windowEndUtc = $windowEndDateTime.UtcDateTime

$selected = @(
    foreach ($fixture in @($calendar.fixtures)) {
        $kickoff = [DateTimeOffset]::Parse(
            [string]$fixture.kickoff,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )

        if ($kickoff.UtcDateTime -ge $windowStartUtc -and $kickoff.UtcDateTime -lt $windowEndUtc) {
            [pscustomobject]@{
                Kickoff = $kickoff
                Matchday = [int]$fixture.matchday
                Stage = [string]$fixture.stage
                HomeTeam = [string]$fixture.homeTeam
                AwayTeam = [string]$fixture.awayTeam
            }
        }
    }
)

$selected = @($selected | Sort-Object @{ Expression = { $_.Kickoff.UtcDateTime } }, HomeTeam, AwayTeam)

if ($selected.Count -eq 0 -and -not $CreateEmptyRequest) {
    [pscustomobject]@{
        Status = 'no-fixtures'
        RequestId = $requestId
        RequestPath = ''
        FixtureCount = 0
        WindowStart = $windowStartDateTime.ToString('o')
        WindowEnd = $windowEndDateTime.ToString('o')
    } | ConvertTo-Json -Depth 6
    return
}

$fixtureRows = @(
    foreach ($fixture in $selected) {
        [ordered]@{
            Stage = $fixture.Stage
            HomeTeam = $fixture.HomeTeam
            AwayTeam = $fixture.AwayTeam
            UK = Format-KickoffLabel $fixture.Kickoff $londonZone $windowStartDateTime
            LasVegas = Format-KickoffLabel $fixture.Kickoff $vegasZone $windowStartDateTime
        }
    }
)

$selectedMatchdays = @($selected | Select-Object -ExpandProperty Matchday -Unique)

$subtitle = if ($fixtureRows.Count -eq 0) {
    'Next 24 hours - no Champions League fixtures'
} elseif ($selectedMatchdays.Count -eq 1) {
    'Matchday {0} - UK and Las Vegas kickoff times' -f $selected[0].Matchday
} else {
    'Next 24 hours - UK and Las Vegas kickoff times'
}

$request = [ordered]@{
    kind = 'fixtures'
    id = $requestId
    windowStart = $windowStartDateTime.ToString('o')
    subtitle = $subtitle
    fixtures = $fixtureRows
    sources = @(
        [ordered]@{
            url = [string]$calendar.source
            supports = @('fixtures', 'kickoff times', 'league phase')
        }
        [ordered]@{
            url = 'https://www.uefa.com/uefachampionsleague/fixtures-results/'
            supports = @('fixtures', 'kickoff times')
        }
    )
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

[pscustomobject]@{
    Status = 'created'
    RequestId = $requestId
    RequestPath = [System.IO.Path]::GetFullPath($OutputPath)
    FixtureCount = $fixtureRows.Count
    WindowStart = $windowStartDateTime.ToString('o')
    WindowEnd = $windowEndDateTime.ToString('o')
} | ConvertTo-Json -Depth 6
