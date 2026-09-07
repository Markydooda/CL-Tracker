param(
    [Parameter(Mandatory = $true)]
    [string]$MatchDate,

    [Parameter(Mandatory = $true)]
    [Alias('Group')]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [string]$HomeTeam,

    [Parameter(Mandatory = $true)]
    [int]$HomeScore,

    [Parameter(Mandatory = $true)]
    [string]$AwayTeam,

    [Parameter(Mandatory = $true)]
    [int]$AwayScore,

    [int]$HomeYellowCards = 0,
    [int]$AwayYellowCards = 0,
    [int]$HomeRedCards = 0,
    [int]$AwayRedCards = 0,

    [Nullable[int]]$HomeShootoutScore = $null,
    [Nullable[int]]$AwayShootoutScore = $null,

    [string[]]$Last16Teams = @(),
    [string[]]$EliminatedTeams = @(),

    [string]$BaseStatePath = '',
    [string]$ApplyStateTo = '',
    [string]$OutputDir = '',
    [string]$OutboxDir = '',
    [string]$SortKey = '',
    [string]$Message = 'Champions League Draft Update',
    [switch]$QueuePost
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($BaseStatePath)) {
    $BaseStatePath = Join-Path $scriptRoot 'tracker-state.json'
}

if ([string]::IsNullOrWhiteSpace($ApplyStateTo)) {
    $ApplyStateTo = Join-Path $scriptRoot 'tracker-state.json'
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $scriptRoot 'automation-temp'
}

$draftPath = Join-Path $scriptRoot 'draft.json'
$graphicScript = Join-Path $scriptRoot 'NewMatchUpdateGraphic.ps1'
$queueScript = Join-Path $scriptRoot 'QueueDiscordPost.ps1'

foreach ($requiredPath in @($BaseStatePath, $draftPath, $graphicScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required file not found: $requiredPath"
    }
}

if ($QueuePost -and -not (Test-Path -LiteralPath $queueScript)) {
    throw "Queue script not found: $queueScript"
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$state = Get-Content -LiteralPath $BaseStatePath -Raw | ConvertFrom-Json
$draft = Get-Content -LiteralPath $draftPath -Raw | ConvertFrom-Json

function Resolve-TeamName([string]$TeamName) {
    if ($null -ne $draft.aliases -and $null -ne $draft.aliases.PSObject.Properties[$TeamName]) {
        return [string]$draft.aliases.PSObject.Properties[$TeamName].Value
    }

    $TeamName
}

function Get-TeamOwner([string]$TeamName) {
    $canonical = Resolve-TeamName $TeamName
    foreach ($owner in $draft.owners.PSObject.Properties.Name) {
        if (@($draft.owners.$owner) -contains $canonical) {
            return $owner
        }
    }

    throw "No draft owner found for team '$TeamName' (resolved as '$canonical')."
}

function Assert-Last16Tracker([object]$TrackerState) {
    $expected = @{}
    foreach ($owner in $draft.owners.PSObject.Properties.Name) {
        $expected[$owner] = 0
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($team in @($TrackerState.last16Teams)) {
        $canonical = Resolve-TeamName ([string]$team)
        if (-not $seen.Add($canonical)) {
            throw "Last-16 tracker contains duplicate team '$canonical'."
        }

        $owner = Get-TeamOwner $canonical
        $expected[$owner] = [int]$expected[$owner] + 1
    }

    foreach ($owner in $draft.owners.PSObject.Properties.Name) {
        if ($null -eq $TrackerState.sideBets.last16.PSObject.Properties[$owner]) {
            throw "Last-16 tracker is missing owner '$owner'."
        }

        $actual = [int]$TrackerState.sideBets.last16.$owner
        if ($actual -ne [int]$expected[$owner]) {
            throw "Last-16 tracker mismatch for '$owner': count is $actual but last16Teams implies $($expected[$owner])."
        }
    }
}

function Add-IntProperty([object]$Object, [string]$Name, [int]$Delta) {
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value 0
    }

    $property = $Object.PSObject.Properties[$Name]
    $property.Value = [int]$property.Value + $Delta
}

function Get-SafeName([string]$Value) {
    ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

$rawStage = $Stage.Trim()
$isFinal = $rawStage -match '^(Final|Finals)$'
$stageKey = if ($isFinal) {
    'F'
} else {
    ($rawStage -replace '^Stage\s+', '').Trim()
}
$isLeaguePhase = (-not $isFinal) -and ($stageKey.ToUpperInvariant() -eq 'LP')
$knockoutStages = @('PO', 'R16', 'QF', 'SF', 'F')

if ($isLeaguePhase) {
    $stageLabel = 'LP'
} elseif ($knockoutStages -contains $stageKey.ToUpperInvariant()) {
    $stageKey = $stageKey.ToUpperInvariant()
    $stageLabel = $stageKey
} else {
    throw "Unknown Champions League stage '$Stage'. Expected LP, PO, R16, QF, SF, or Final."
}

$resolvedHomeTeam = Resolve-TeamName $HomeTeam
$resolvedAwayTeam = Resolve-TeamName $AwayTeam

$homeOwner = Get-TeamOwner $resolvedHomeTeam
$awayOwner = Get-TeamOwner $resolvedAwayTeam

$hasHomeShootoutScore = $null -ne $HomeShootoutScore
$hasAwayShootoutScore = $null -ne $AwayShootoutScore
if ($hasHomeShootoutScore -ne $hasAwayShootoutScore) {
    throw 'HomeShootoutScore and AwayShootoutScore must be provided together.'
}

$hasShootout = $hasHomeShootoutScore -and $hasAwayShootoutScore
if ($hasShootout) {
    if ($isLeaguePhase) {
        throw 'Shootout scores are only valid after the league phase.'
    }

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

$matchKey = "$MatchDate|$stageLabel|$resolvedHomeTeam|$resolvedAwayTeam|$HomeScore-$AwayScore"
if (@($state.postedMatches) -contains $matchKey) {
    Write-Output "Match already present in base state: $matchKey"
    return
}

$creditOwner = ''
$debitOwner = ''
$settlement = ''
if ($HomeScore -eq $AwayScore -and -not $hasShootout) {
    $settlement = 'Draw: void'
} elseif ($homeOwner -eq $awayOwner) {
    $settlement = "Same-owner void for $homeOwner"
} else {
    $homeWon = if ($hasShootout) {
        [int]$HomeShootoutScore -gt [int]$AwayShootoutScore
    } else {
        $HomeScore -gt $AwayScore
    }

    if ($homeWon) {
        $creditOwner = $homeOwner
        $debitOwner = $awayOwner
    } else {
        $creditOwner = $awayOwner
        $debitOwner = $homeOwner
    }

    Add-IntProperty $state.balancesGBP $creditOwner 5
    Add-IntProperty $state.balancesGBP $debitOwner -5
    $settlement = "$creditOwner beats $debitOwner"
}

Add-IntProperty $state.sideBets.goals $homeOwner $HomeScore
Add-IntProperty $state.sideBets.goals $awayOwner $AwayScore
Add-IntProperty $state.sideBets.goalsConceded $homeOwner $AwayScore
Add-IntProperty $state.sideBets.goalsConceded $awayOwner $HomeScore
Add-IntProperty $state.sideBets.redCards $homeOwner $HomeRedCards
Add-IntProperty $state.sideBets.redCards $awayOwner $AwayRedCards
Add-IntProperty $state.sideBets.yellowCards $homeOwner $HomeYellowCards
Add-IntProperty $state.sideBets.yellowCards $awayOwner $AwayYellowCards

if ($isLeaguePhase) {
    if ($HomeScore -gt $AwayScore) {
        Add-IntProperty $state.leaguePoints $resolvedHomeTeam 3
    } elseif ($AwayScore -gt $HomeScore) {
        Add-IntProperty $state.leaguePoints $resolvedAwayTeam 3
    } else {
        Add-IntProperty $state.leaguePoints $resolvedHomeTeam 1
        Add-IntProperty $state.leaguePoints $resolvedAwayTeam 1
    }

    Add-IntProperty $state.teamGoalsFor $resolvedHomeTeam $HomeScore
    Add-IntProperty $state.teamGoalsFor $resolvedAwayTeam $AwayScore
    Add-IntProperty $state.teamGoalsAgainst $resolvedHomeTeam $AwayScore
    Add-IntProperty $state.teamGoalsAgainst $resolvedAwayTeam $HomeScore
}

if ($null -eq $state.PSObject.Properties['last16Teams']) {
    $state | Add-Member -MemberType NoteProperty -Name last16Teams -Value @()
}

if ($null -eq $state.PSObject.Properties['eliminatedTeams']) {
    $state | Add-Member -MemberType NoteProperty -Name eliminatedTeams -Value @()
}

$qualificationNotes = @()
foreach ($team in $Last16Teams) {
    $last16Team = Resolve-TeamName $team
    if (@($state.last16Teams) -notcontains $last16Team) {
        $state.last16Teams = @(@($state.last16Teams) + $last16Team)
        $last16Owner = Get-TeamOwner $last16Team
        Add-IntProperty $state.sideBets.last16 $last16Owner 1
        $qualificationNotes += "$last16Team reached the last 16"
    }
}

foreach ($team in $EliminatedTeams) {
    $eliminatedTeam = Resolve-TeamName $team
    if (@($state.eliminatedTeams) -notcontains $eliminatedTeam) {
        $state.eliminatedTeams = @(@($state.eliminatedTeams) + $eliminatedTeam)
        $qualificationNotes += "$eliminatedTeam eliminated"
    }
}

Assert-Last16Tracker $state

$groupQualificationText = if ($qualificationNotes.Count -gt 0) {
    $qualificationNotes -join '; '
} else {
    'Last-16 status: no change'
}

$state.postedMatches = @(@($state.postedMatches) + $matchKey)

$fileStem = '{0}-{1}-{2}-{3}-{4}-{5}' -f $MatchDate, (Get-SafeName $stageLabel), (Get-SafeName $resolvedHomeTeam), (Get-SafeName $resolvedAwayTeam), $HomeScore, $AwayScore
$nextStatePath = Join-Path $OutputDir "next-state-$fileStem.json"
$graphicPath = Join-Path $OutputDir "match-update-$fileStem.png"

$state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $nextStatePath -Encoding UTF8

if (Test-Path -LiteralPath $graphicPath) {
    Remove-Item -LiteralPath $graphicPath -Force
}

$graphicArgs = @{
    OutputPath = $graphicPath
    HomeTeam = $resolvedHomeTeam
    HomeOwner = $homeOwner
    HomeScore = $HomeScore
    AwayTeam = $resolvedAwayTeam
    AwayOwner = $awayOwner
    AwayScore = $AwayScore
    Settlement = $settlement
    GroupQualification = $groupQualificationText
    StatePath = $nextStatePath
}

if ($hasShootout) {
    $graphicArgs.HomeShootoutScore = [int]$HomeShootoutScore
    $graphicArgs.AwayShootoutScore = [int]$AwayShootoutScore
}

if (-not [string]::IsNullOrWhiteSpace($creditOwner) -and -not [string]::IsNullOrWhiteSpace($debitOwner)) {
    $graphicArgs.CreditOwner = $creditOwner
    $graphicArgs.DebitOwner = $debitOwner
    $graphicArgs.TransferGBP = 5
}

& $graphicScript @graphicArgs | Out-Null

if (-not (Test-Path -LiteralPath $graphicPath)) {
    throw "Graphic was not created: $graphicPath"
}

$queuePath = ''
if ($QueuePost) {
    if ([string]::IsNullOrWhiteSpace($SortKey)) {
        $SortKey = $matchKey
    }

    $queueArgs = @{
        Id = $matchKey
        SortKey = $SortKey
        Message = $Message
        FilePath = $graphicPath
        ApplyStateFrom = $nextStatePath
        ApplyStateTo = $ApplyStateTo
    }

    if (-not [string]::IsNullOrWhiteSpace($OutboxDir)) {
        $queueArgs.OutboxDir = $OutboxDir
    }

    $queueOutput = & $queueScript @queueArgs

    $queuePath = ($queueOutput | Out-String).Trim()
}

[pscustomobject]@{
    MatchKey = $matchKey
    HomeOwner = $homeOwner
    AwayOwner = $awayOwner
    Settlement = $settlement
    GroupQualification = $groupQualificationText
    NextStatePath = $nextStatePath
    GraphicPath = $graphicPath
    QueueResult = $queuePath
} | ConvertTo-Json -Depth 4
