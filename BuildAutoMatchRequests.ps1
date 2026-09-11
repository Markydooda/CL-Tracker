[CmdletBinding()]
param(
    [int]$LookbackHours = 30,
    [string]$Until = '',
    [string]$CalendarPath = '',
    [string]$OutputDir = '',
    [string]$MatchesApiUrl = 'https://match.uefa.com/v5/matches?competitionId=1&seasonYear=2027&phase=TOURNAMENT&order=ASC&offset=0&limit=200',
    [switch]$DryRun
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

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $scriptRoot 'requests\inbox'
}

$draftPath = Join-Path $scriptRoot 'draft.json'
$statePath = Join-Path $scriptRoot 'tracker-state.json'
$processedDir = Join-Path $scriptRoot 'requests\processed'
$ledgerPath = Join-Path $scriptRoot 'requests\delivery-ledger.jsonl'

foreach ($requiredPath in @($CalendarPath, $draftPath, $statePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required file not found: $requiredPath"
    }
}

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$untilUtc = if ([string]::IsNullOrWhiteSpace($Until)) {
    [DateTimeOffset]::UtcNow
} else {
    [DateTimeOffset]::Parse(
        $Until,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}
$sinceUtc = $untilUtc.AddHours(-1 * $LookbackHours)

$calendar = Get-Content -LiteralPath $CalendarPath -Raw | ConvertFrom-Json
$draft = Get-Content -LiteralPath $draftPath -Raw | ConvertFrom-Json
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

$teamAliases = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($owner in $draft.owners.PSObject.Properties.Name) {
    foreach ($team in @($draft.owners.$owner)) {
        $teamAliases[$team] = [string]$team
    }
}
foreach ($alias in $draft.aliases.PSObject.Properties) {
    $teamAliases[[string]$alias.Name] = [string]$alias.Value
}

$uefaTeamIdAliases = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
if ($null -ne $draft.PSObject.Properties['uefaTeamIds']) {
    foreach ($alias in $draft.uefaTeamIds.PSObject.Properties) {
        $uefaTeamIdAliases[[string]$alias.Name] = [string]$alias.Value
    }
}

function Resolve-TeamName([string]$TeamName) {
    if ([string]::IsNullOrWhiteSpace($TeamName)) {
        return ''
    }

    if ($teamAliases.ContainsKey($TeamName)) {
        return [string]$teamAliases[$TeamName]
    }

    ''
}

function Get-UefaTeamCandidateValues([object]$Team) {
    $values = @()
    if ($null -eq $Team) {
        return $values
    }

    $propertyPaths = @(
        ,@('internationalName'),
        ,@('translations', 'displayName', 'EN'),
        ,@('translations', 'displayOfficialName', 'EN'),
        ,@('translations', 'shortName', 'EN')
    )

    foreach ($propertyPath in $propertyPaths) {
        $current = $Team
        foreach ($segment in $propertyPath) {
            $propertyName = [string]$segment
            $properties = @($current.PSObject.Properties | Where-Object { $_.Name -eq $propertyName } | Select-Object -First 1)
            if ($properties.Count -eq 0) {
                $current = $null
                break
            }
            $current = $properties[0].Value
        }

        if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace([string]$current)) {
            $values += [string]$current
        }
    }

    @($values | Select-Object -Unique)
}

function Resolve-UefaTeam([object]$Team) {
    $teamId = if ($null -ne $Team -and $null -ne $Team.PSObject.Properties['id']) {
        [string]$Team.id
    } else {
        ''
    }

    if (-not [string]::IsNullOrWhiteSpace($teamId) -and $uefaTeamIdAliases.ContainsKey($teamId)) {
        return [string]$uefaTeamIdAliases[$teamId]
    }

    foreach ($candidate in Get-UefaTeamCandidateValues $Team) {
        $resolved = Resolve-TeamName $candidate
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            return $resolved
        }
    }

    ''
}

function Test-ObjectProperty([object]$Object, [string]$Name) {
    $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Convert-NullableInt([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    [int]$Value
}

function Get-MatchScore([object]$Match, [string]$Side) {
    if (-not (Test-ObjectProperty $Match 'score')) {
        return $null
    }

    if (Test-ObjectProperty $Match.score 'total' -and Test-ObjectProperty $Match.score.total $Side) {
        return Convert-NullableInt $Match.score.total.$Side
    }

    if (Test-ObjectProperty $Match.score 'regular' -and Test-ObjectProperty $Match.score.regular $Side) {
        return Convert-NullableInt $Match.score.regular.$Side
    }

    $null
}

function Get-PenaltyScore([object]$Match, [string]$Side) {
    if (-not (Test-ObjectProperty $Match 'score')) {
        return $null
    }

    if (-not (Test-ObjectProperty $Match.score 'penalty')) {
        return $null
    }

    $penalty = $Match.score.PSObject.Properties['penalty'].Value
    if (Test-ObjectProperty $penalty $Side) {
        return Convert-NullableInt $penalty.PSObject.Properties[$Side].Value
    }

    $null
}

function Get-StatisticInt([object[]]$Stats, [string]$TeamId, [string]$Name) {
    $teamStats = @($Stats | Where-Object { [string]$_.teamId -eq [string]$TeamId })
    if ($teamStats.Count -eq 0) {
        return $null
    }

    $stat = @($teamStats[0].statistics | Where-Object { [string]$_.name -eq $Name } | Select-Object -First 1)
    if ($stat.Count -eq 0) {
        return $null
    }

    Convert-NullableInt $stat[0].value
}

function Get-RequestFileName([string]$MatchId) {
    "auto-match-$MatchId.json"
}

function Test-MatchAlreadyDelivered([string]$MatchKey, [string]$FileName) {
    if (@($state.postedMatches) -contains $MatchKey) {
        return $true
    }

    $processedPath = Join-Path $processedDir $FileName
    if (Test-Path -LiteralPath $processedPath) {
        return $true
    }

    $inboxPath = Join-Path $OutputDir $FileName
    if (Test-Path -LiteralPath $inboxPath) {
        return $true
    }

    if (Test-Path -LiteralPath $ledgerPath) {
        foreach ($line in Get-Content -LiteralPath $ledgerPath) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
                if ([string]$entry.id -eq $MatchKey -or [string]$entry.requestFile -eq $FileName) {
                    return $true
                }
            } catch {
                # PublishRequests performs strict ledger validation; this monitor stays conservative.
            }
        }
    }

    $false
}

function Invoke-UefaJson([string]$Uri) {
    Invoke-RestMethod -Uri $Uri -Headers @{
        'User-Agent' = 'Mozilla/5.0 (compatible; CL-Tracker/1.0)'
        'Accept' = 'application/json'
    }
}

function ConvertTo-FlatArray([object]$Value) {
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [array]) {
        return @($Value)
    }

    @($Value)
}

function Get-DateKey([object]$Value) {
    if ($Value -is [DateTime]) {
        return $Value.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    }

    [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

$calendarMatches = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($fixture in @($calendar.fixtures)) {
    $key = '{0}|{1}|{2}' -f (Get-DateKey $fixture.kickoff), [string]$fixture.homeTeam, [string]$fixture.awayTeam
    $calendarMatches[$key] = $true
}

$matches = ConvertTo-FlatArray (Invoke-UefaJson $MatchesApiUrl)
$created = @()
$skipped = @()

foreach ($match in @($matches | Sort-Object @{ Expression = { $_.kickOffTime.dateTime } }, id)) {
    if ([string]$match.status -ne 'FINISHED') {
        continue
    }

    $kickoff = [DateTimeOffset]::Parse(
        [string]$match.kickOffTime.dateTime,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()

    if ($kickoff -lt $sinceUtc -or $kickoff -gt $untilUtc) {
        continue
    }

    $homeTeam = Resolve-UefaTeam $match.homeTeam
    $awayTeam = Resolve-UefaTeam $match.awayTeam
    if ([string]::IsNullOrWhiteSpace($homeTeam) -or [string]::IsNullOrWhiteSpace($awayTeam)) {
        $skipped += [pscustomobject]@{
            MatchId = [string]$match.id
            Reason = 'team-not-in-draft'
            Home = [string]$match.homeTeam.internationalName
            Away = [string]$match.awayTeam.internationalName
        }
        continue
    }

    $calendarKey = '{0}|{1}|{2}' -f [string]$match.kickOffTime.date, $homeTeam, $awayTeam
    if (-not $calendarMatches.ContainsKey($calendarKey)) {
        $skipped += [pscustomobject]@{
            MatchId = [string]$match.id
            Reason = 'not-in-tracker-calendar'
            Home = $homeTeam
            Away = $awayTeam
        }
        continue
    }

    $homeScore = Get-MatchScore $match 'home'
    $awayScore = Get-MatchScore $match 'away'
    if ($null -eq $homeScore -or $null -eq $awayScore) {
        $skipped += [pscustomobject]@{
            MatchId = [string]$match.id
            Reason = 'score-missing'
            Home = $homeTeam
            Away = $awayTeam
        }
        continue
    }

    $fileName = Get-RequestFileName ([string]$match.id)
    $matchKey = '{0}|LP|{1}|{2}|{3}-{4}' -f [string]$match.kickOffTime.date, $homeTeam, $awayTeam, [int]$homeScore, [int]$awayScore
    if (Test-MatchAlreadyDelivered $matchKey $fileName) {
        $skipped += [pscustomobject]@{
            MatchId = [string]$match.id
            Reason = 'already-requested-or-posted'
            Home = $homeTeam
            Away = $awayTeam
        }
        continue
    }

    $statsUrl = "https://matchstats.uefa.com/v1/team-statistics/$($match.id)"
    $stats = ConvertTo-FlatArray (Invoke-UefaJson $statsUrl)
    $homeYellowCards = Get-StatisticInt $stats ([string]$match.homeTeam.id) 'yellow_cards'
    $awayYellowCards = Get-StatisticInt $stats ([string]$match.awayTeam.id) 'yellow_cards'
    $homeRedCards = Get-StatisticInt $stats ([string]$match.homeTeam.id) 'red_cards'
    $awayRedCards = Get-StatisticInt $stats ([string]$match.awayTeam.id) 'red_cards'

    if ($null -eq $homeYellowCards -or $null -eq $awayYellowCards -or $null -eq $homeRedCards -or $null -eq $awayRedCards) {
        $skipped += [pscustomobject]@{
            MatchId = [string]$match.id
            Reason = 'card-statistics-missing'
            Home = $homeTeam
            Away = $awayTeam
        }
        continue
    }

    $homeShootoutScore = Get-PenaltyScore $match 'home'
    $awayShootoutScore = Get-PenaltyScore $match 'away'

    $request = [ordered]@{
        kind = 'match'
        kickoff = $kickoff.ToString('o')
        matchDate = [string]$match.kickOffTime.date
        stage = 'LP'
        homeTeam = $homeTeam
        homeScore = [int]$homeScore
        awayTeam = $awayTeam
        awayScore = [int]$awayScore
        homeYellowCards = [int]$homeYellowCards
        awayYellowCards = [int]$awayYellowCards
        homeRedCards = [int]$homeRedCards
        awayRedCards = [int]$awayRedCards
        homeShootoutScore = $homeShootoutScore
        awayShootoutScore = $awayShootoutScore
        last16Teams = @()
        eliminatedTeams = @()
        sources = @(
            [ordered]@{
                url = "https://match.uefa.com/v5/matches?matchId=$($match.id)&order=ASC"
                supports = @('final score', 'status', 'kickoff')
            }
            [ordered]@{
                url = $statsUrl
                supports = @('yellow cards', 'red cards')
            }
        )
    }

    $requestPath = Join-Path $OutputDir $fileName
    if (-not $DryRun) {
        $request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    }

    $created += [pscustomobject]@{
        MatchId = [string]$match.id
        RequestPath = [System.IO.Path]::GetFullPath($requestPath)
        MatchKey = $matchKey
        Home = $homeTeam
        Away = $awayTeam
        Score = ('{0}-{1}' -f [int]$homeScore, [int]$awayScore)
        HomeYellowCards = [int]$homeYellowCards
        AwayYellowCards = [int]$awayYellowCards
        HomeRedCards = [int]$homeRedCards
        AwayRedCards = [int]$awayRedCards
    }
}

[pscustomobject]@{
    Status = if ($created.Count -gt 0) { 'created' } else { 'nothing-to-do' }
    DryRun = [bool]$DryRun
    Since = $sinceUtc.ToString('o')
    Until = $untilUtc.ToString('o')
    CreatedCount = $created.Count
    Created = $created
    Skipped = $skipped
} | ConvertTo-Json -Depth 8
