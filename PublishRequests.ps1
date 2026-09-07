[CmdletBinding()]
param(
    [string]$RequestsDir = '',
    [string]$ProcessedDir = '',
    [string]$StatePath = '',
    [string]$WebhookPath = '',
    [string]$WorkingDir = '',
    [int]$MaxRequests = 0,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Resolve-TrackerPath([string]$Path, [string]$DefaultRelativePath) {
    $candidate = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path $scriptRoot $DefaultRelativePath
    } elseif ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $scriptRoot $Path
    }

    [System.IO.Path]::GetFullPath($candidate)
}

$RequestsDir = Resolve-TrackerPath $RequestsDir 'requests\inbox'
$ProcessedDir = Resolve-TrackerPath $ProcessedDir 'requests\processed'
$StatePath = Resolve-TrackerPath $StatePath 'tracker-state.json'
$WorkingDir = Resolve-TrackerPath $WorkingDir 'github-publisher-temp'
$outboxDir = Join-Path $WorkingDir 'discord-outbox'
$ledgerPath = Join-Path $scriptRoot 'requests\delivery-ledger.jsonl'
$builderPath = Join-Path $scriptRoot 'BuildMatchUpdate.ps1'
$fixturesGraphicPath = Join-Path $scriptRoot 'NewFixturesGraphic.ps1'
$queuePath = Join-Path $scriptRoot 'QueueDiscordPost.ps1'
$senderPath = Join-Path $scriptRoot 'SendDiscordOutbox.ps1'
$outboxLogPath = Join-Path $scriptRoot 'discord-outbox-log.jsonl'

foreach ($requiredPath in @($StatePath, $builderPath, $fixturesGraphicPath, $queuePath, $senderPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required file not found: $requiredPath"
    }
}

if (-not $DryRun) {
    if ([string]::IsNullOrWhiteSpace($WebhookPath)) {
        throw 'WebhookPath is required unless DryRun is used.'
    }

    $WebhookPath = Resolve-TrackerPath $WebhookPath ''
    if (-not (Test-Path -LiteralPath $WebhookPath)) {
        throw "Webhook file not found: $WebhookPath"
    }
}

New-Item -ItemType Directory -Path $RequestsDir -Force | Out-Null
New-Item -ItemType Directory -Path $ProcessedDir -Force | Out-Null
New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null
New-Item -ItemType Directory -Path $outboxDir -Force | Out-Null

function Assert-OnlyProperties([object]$Object, [string[]]$Allowed, [string]$Context) {
    $unknown = @($Object.PSObject.Properties.Name | Where-Object { $Allowed -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw "$Context contains unsupported field(s): $($unknown -join ', ')"
    }
}

function Get-RequiredString([object]$Object, [string]$Name, [string]$Context) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "$Context requires a non-empty '$Name' value."
    }

    [string]$property.Value
}

function Get-OptionalValue([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    $property.Value
}

function Convert-RequestInt(
    [object]$Value,
    [string]$Name,
    [int]$Minimum,
    [int]$Maximum,
    [string]$Context
) {
    $parsed = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$Context requires integer '$Name'."
    }

    if ($parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "$Context field '$Name' must be between $Minimum and $Maximum."
    }

    $parsed
}

function Convert-RequestTimestamp([string]$Value, [string]$Name, [string]$Context) {
    try {
        [DateTimeOffset]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        throw "$Context field '$Name' must be an ISO-8601 timestamp with an explicit UTC offset."
    }
}

function Assert-Sources([object]$Request, [string]$Context) {
    $sourcesProperty = $Request.PSObject.Properties['sources']
    $sources = if ($null -eq $sourcesProperty) { @() } else { @($sourcesProperty.Value) }
    if ($sources.Count -lt 2) {
        throw "$Context requires at least two opened source records."
    }

    foreach ($source in $sources) {
        if ($null -eq $source) {
            throw "$Context contains an empty source record."
        }

        Assert-OnlyProperties $source @('url', 'supports') "$Context source"
        $urlText = Get-RequiredString $source 'url' "$Context source"
        $uri = $null
        if (-not [Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
            throw "$Context source URL must be an absolute HTTPS URL: $urlText"
        }

        $supportsProperty = $source.PSObject.Properties['supports']
        $supports = if ($null -eq $supportsProperty) { @() } else { @($supportsProperty.Value) }
        if ($supports.Count -eq 0) {
            throw "$Context source '$urlText' must say what it supports."
        }
    }
}

function Convert-StringArray([object]$Value, [string]$Name, [string]$Context) {
    if ($null -eq $Value) {
        return
    }

    $result = @()
    foreach ($item in @($Value)) {
        if ([string]::IsNullOrWhiteSpace([string]$item)) {
            throw "$Context field '$Name' contains an empty value."
        }
        $result += [string]$item
    }
    $result
}

function Get-MatchRequestRecord([System.IO.FileInfo]$File, [object]$Request) {
    $context = "Match request '$($File.Name)'"
    Assert-OnlyProperties $Request @(
        'kind',
        'kickoff',
        'matchDate',
        'stage',
        'homeTeam',
        'homeScore',
        'awayTeam',
        'awayScore',
        'homeYellowCards',
        'awayYellowCards',
        'homeRedCards',
        'awayRedCards',
        'homeShootoutScore',
        'awayShootoutScore',
        'last16Teams',
        'eliminatedTeams',
        'sources'
    ) $context

    $kickoffText = Get-RequiredString $Request 'kickoff' $context
    $kickoff = Convert-RequestTimestamp $kickoffText 'kickoff' $context
    $matchDate = Get-RequiredString $Request 'matchDate' $context
    if ($matchDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
        throw "$context field 'matchDate' must use YYYY-MM-DD."
    }

    $stageInput = Get-RequiredString $Request 'stage' $context
    $stage = $stageInput.ToUpperInvariant()
    $validStages = @('LP', 'PO', 'R16', 'QF', 'SF', 'F', 'FINAL')
    if ($validStages -notcontains $stage) {
        throw "$context has unsupported stage '$stage'."
    }

    $homeTeam = Get-RequiredString $Request 'homeTeam' $context
    $awayTeam = Get-RequiredString $Request 'awayTeam' $context
    if ($homeTeam -eq $awayTeam) {
        throw "$context cannot use the same team twice."
    }

    $homeScore = Convert-RequestInt (Get-OptionalValue $Request 'homeScore') 'homeScore' 0 30 $context
    $awayScore = Convert-RequestInt (Get-OptionalValue $Request 'awayScore') 'awayScore' 0 30 $context
    $homeYellowCards = Convert-RequestInt (Get-OptionalValue $Request 'homeYellowCards') 'homeYellowCards' 0 20 $context
    $awayYellowCards = Convert-RequestInt (Get-OptionalValue $Request 'awayYellowCards') 'awayYellowCards' 0 20 $context
    $homeRedCards = Convert-RequestInt (Get-OptionalValue $Request 'homeRedCards') 'homeRedCards' 0 10 $context
    $awayRedCards = Convert-RequestInt (Get-OptionalValue $Request 'awayRedCards') 'awayRedCards' 0 10 $context

    $homeShootoutValue = Get-OptionalValue $Request 'homeShootoutScore'
    $awayShootoutValue = Get-OptionalValue $Request 'awayShootoutScore'
    $hasHomeShootout = $null -ne $homeShootoutValue
    $hasAwayShootout = $null -ne $awayShootoutValue
    if ($hasHomeShootout -ne $hasAwayShootout) {
        throw "$context must provide both shootout scores or neither."
    }

    $homeShootoutScore = $null
    $awayShootoutScore = $null
    if ($hasHomeShootout) {
        $homeShootoutScore = Convert-RequestInt $homeShootoutValue 'homeShootoutScore' 0 30 $context
        $awayShootoutScore = Convert-RequestInt $awayShootoutValue 'awayShootoutScore' 0 30 $context
        if ($stage -eq 'LP') {
            throw "$context cannot use shootout scores in a league-phase match."
        }
        if ($homeScore -ne $awayScore) {
            throw "$context shootout requires a tied normal/extra-time score."
        }
        if ($homeShootoutScore -eq $awayShootoutScore) {
            throw "$context shootout scores must identify a winner."
        }
    }

    $last16Teams = @(Convert-StringArray (Get-OptionalValue $Request 'last16Teams') 'last16Teams' $context)
    $eliminatedTeams = @(Convert-StringArray (Get-OptionalValue $Request 'eliminatedTeams') 'eliminatedTeams' $context)

    foreach ($team in $eliminatedTeams) {
        if ($stage -ne 'LP' -and @($homeTeam, $awayTeam) -notcontains $team) {
            throw "$context eliminated team '$team' must be one of the two teams outside the league phase."
        }
    }

    Assert-Sources $Request $context

    $builderStage = if ($stage -eq 'FINAL') { 'Final' } else { $stage }
    $stageLabel = if ($stage -eq 'FINAL') {
        'F'
    } else {
        $stage
    }
    $id = "$matchDate|$stageLabel|$homeTeam|$awayTeam|$homeScore-$awayScore"

    [pscustomobject]@{
        File = $File
        Kind = 'match'
        Id = $id
        SortInstant = $kickoff.UtcDateTime
        SortKey = "$kickoffText|$id"
        Data = [pscustomobject]@{
            MatchDate = $matchDate
            Stage = $builderStage
            HomeTeam = $homeTeam
            HomeScore = $homeScore
            AwayTeam = $awayTeam
            AwayScore = $awayScore
            HomeYellowCards = $homeYellowCards
            AwayYellowCards = $awayYellowCards
            HomeRedCards = $homeRedCards
            AwayRedCards = $awayRedCards
            HomeShootoutScore = $homeShootoutScore
            AwayShootoutScore = $awayShootoutScore
            HasShootout = $hasHomeShootout
            Last16Teams = $last16Teams
            EliminatedTeams = $eliminatedTeams
        }
    }
}

function Get-FixturesRequestRecord([System.IO.FileInfo]$File, [object]$Request) {
    $context = "Fixtures request '$($File.Name)'"
    Assert-OnlyProperties $Request @('kind', 'id', 'windowStart', 'subtitle', 'fixtures', 'sources') $context

    $id = Get-RequiredString $Request 'id' $context
    if ($id -notmatch '^fixtures-\d{4}-\d{2}-\d{2}$') {
        throw "$context id must use fixtures-YYYY-MM-DD."
    }

    $windowStartText = Get-RequiredString $Request 'windowStart' $context
    $windowStart = Convert-RequestTimestamp $windowStartText 'windowStart' $context
    $subtitle = Get-RequiredString $Request 'subtitle' $context
    $fixturesProperty = $Request.PSObject.Properties['fixtures']
    $fixtures = if ($null -eq $fixturesProperty) { @() } else { @($fixturesProperty.Value) }

    foreach ($fixture in $fixtures) {
        if ($null -eq $fixture) {
            throw "$context contains an empty fixture."
        }
        Assert-OnlyProperties $fixture @('Stage', 'HomeTeam', 'AwayTeam', 'UK', 'LasVegas') "$context fixture"
        foreach ($field in @('Stage', 'HomeTeam', 'AwayTeam', 'UK', 'LasVegas')) {
            [void](Get-RequiredString $fixture $field "$context fixture")
        }
    }

    Assert-Sources $Request $context

    [pscustomobject]@{
        File = $File
        Kind = 'fixtures'
        Id = $id
        SortInstant = $windowStart.UtcDateTime
        SortKey = "$windowStartText|$id"
        Data = [pscustomobject]@{
            Subtitle = $subtitle
            Fixtures = $fixtures
        }
    }
}

function Get-RequestRecord([System.IO.FileInfo]$File) {
    try {
        $request = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
    } catch {
        throw "Request '$($File.Name)' is not valid JSON: $($_.Exception.Message)"
    }

    $kind = (Get-RequiredString $request 'kind' "Request '$($File.Name)'").ToLowerInvariant()
    switch ($kind) {
        'match' { Get-MatchRequestRecord $File $request }
        'fixtures' { Get-FixturesRequestRecord $File $request }
        default { throw "Request '$($File.Name)' has unsupported kind '$kind'." }
    }
}

function Get-CurrentState() {
    Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
}

function Test-MatchAlreadyPosted([string]$Id) {
    $state = Get-CurrentState
    @($state.postedMatches) -contains $Id
}

function Get-LedgerEntries() {
    if (-not (Test-Path -LiteralPath $ledgerPath)) {
        return @()
    }

    $entries = @()
    foreach ($line in Get-Content -LiteralPath $ledgerPath) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try {
                $entries += $line | ConvertFrom-Json
            } catch {
                throw "Delivery ledger contains invalid JSON: $ledgerPath"
            }
        }
    }
    $entries
}

function Test-LedgerContains([string]$Id) {
    @((Get-LedgerEntries) | Where-Object { [string]$_.id -eq $Id }).Count -gt 0
}

function Get-DeliveryResult([string]$Id) {
    if (-not (Test-Path -LiteralPath $outboxLogPath)) {
        throw "Discord outbox log was not created for '$Id'."
    }

    $matches = @()
    foreach ($line in Get-Content -LiteralPath $outboxLogPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $entry = $line | ConvertFrom-Json
            if ([string]$entry.id -eq $Id -and [string]$entry.event -eq 'sent') {
                $matches += $entry
            }
        } catch {
            # Local legacy log damage must not hide a new confirmed delivery.
        }
    }

    if ($matches.Count -eq 0) {
        throw "Discord delivery was not confirmed for '$Id'."
    }

    $entry = $matches[-1]
    $messageId = ''
    if ([string]$entry.output -match 'Message id:\s*(\d+)') {
        $messageId = $Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($messageId)) {
        throw "Discord delivery log for '$Id' did not contain a message id."
    }

    [pscustomobject]@{
        MessageId = $messageId
        Timestamp = [string]$entry.timestamp
    }
}

function Complete-Request([object]$Record, [object]$Delivery) {
    $destination = Join-Path $ProcessedDir $Record.File.Name
    if (Test-Path -LiteralPath $destination) {
        throw "Processed request already exists: $destination"
    }

    Move-Item -LiteralPath $Record.File.FullName -Destination $destination

    $ledgerEntry = [ordered]@{
        id = $Record.Id
        kind = $Record.Kind
        discordMessageId = [string]$Delivery.MessageId
        deliveredAt = [string]$Delivery.Timestamp
        requestFile = $Record.File.Name
    }
    Add-Content -LiteralPath $ledgerPath -Value ($ledgerEntry | ConvertTo-Json -Compress) -Encoding UTF8
}

function Complete-AlreadyDeliveredRequest([object]$Record) {
    $destination = Join-Path $ProcessedDir $Record.File.Name
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $Record.File.FullName -Force
    } else {
        Move-Item -LiteralPath $Record.File.FullName -Destination $destination
    }
}

function Publish-MatchRequest([object]$Record, [string]$BaseStatePath) {
    if (Test-MatchAlreadyPosted $Record.Id) {
        if (-not $DryRun) {
            Complete-AlreadyDeliveredRequest $Record
        }
        return [pscustomobject]@{
            Id = $Record.Id
            Status = 'already-posted'
            NextStatePath = $BaseStatePath
            GraphicPath = ''
            DiscordMessageId = ''
        }
    }

    $data = $Record.Data
    $builderArgs = @{
        MatchDate = $data.MatchDate
        Stage = $data.Stage
        HomeTeam = $data.HomeTeam
        HomeScore = $data.HomeScore
        AwayTeam = $data.AwayTeam
        AwayScore = $data.AwayScore
        HomeYellowCards = $data.HomeYellowCards
        AwayYellowCards = $data.AwayYellowCards
        HomeRedCards = $data.HomeRedCards
        AwayRedCards = $data.AwayRedCards
        Last16Teams = $data.Last16Teams
        EliminatedTeams = $data.EliminatedTeams
        BaseStatePath = $BaseStatePath
        ApplyStateTo = $StatePath
        OutputDir = $WorkingDir
        OutboxDir = $outboxDir
        SortKey = $Record.SortKey
    }

    if ($data.HasShootout) {
        $builderArgs.HomeShootoutScore = $data.HomeShootoutScore
        $builderArgs.AwayShootoutScore = $data.AwayShootoutScore
    }
    if (-not $DryRun) {
        $builderArgs.QueuePost = $true
    }

    $builderOutput = & $builderPath @builderArgs
    $builderResult = ($builderOutput | Out-String).Trim() | ConvertFrom-Json

    if ($DryRun) {
        return [pscustomobject]@{
            Id = $Record.Id
            Status = 'validated'
            NextStatePath = [string]$builderResult.NextStatePath
            GraphicPath = [string]$builderResult.GraphicPath
            DiscordMessageId = ''
        }
    }

    & $senderPath -OutboxDir $outboxDir -MaxItems 1 -WebhookPath $WebhookPath
    if (-not (Test-MatchAlreadyPosted $Record.Id)) {
        throw "Tracker state did not advance after confirmed delivery of '$($Record.Id)'."
    }

    $delivery = Get-DeliveryResult $Record.Id
    Complete-Request $Record $delivery

    [pscustomobject]@{
        Id = $Record.Id
        Status = 'posted'
        NextStatePath = $StatePath
        GraphicPath = [string]$builderResult.GraphicPath
        DiscordMessageId = $delivery.MessageId
    }
}

function Publish-FixturesRequest([object]$Record) {
    if (Test-LedgerContains $Record.Id) {
        if (-not $DryRun) {
            Complete-AlreadyDeliveredRequest $Record
        }
        return [pscustomobject]@{
            Id = $Record.Id
            Status = 'already-posted'
            NextStatePath = ''
            GraphicPath = ''
            DiscordMessageId = ''
        }
    }

    $fixtures = @($Record.Data.Fixtures)
    $graphicPath = ''
    $message = ''

    if ($fixtures.Count -eq 0) {
        $message = 'There are no Champions League Draft fixtures in the next 24 hours.'
    } else {
        $fixturesJsonPath = Join-Path $WorkingDir "$($Record.Id).json"
        $graphicPath = Join-Path $WorkingDir "$($Record.Id).png"
        ConvertTo-Json -InputObject $fixtures -Depth 6 | Set-Content -LiteralPath $fixturesJsonPath -Encoding UTF8
        & $fixturesGraphicPath `
            -FixturesJsonPath $fixturesJsonPath `
            -OutputPath $graphicPath `
            -Subtitle $Record.Data.Subtitle | Out-Null

        if (-not (Test-Path -LiteralPath $graphicPath)) {
            throw "Fixtures graphic was not created: $graphicPath"
        }
        $message = 'Upcoming Champions League Draft Fixtures'
    }

    if ($DryRun) {
        return [pscustomobject]@{
            Id = $Record.Id
            Status = 'validated'
            NextStatePath = ''
            GraphicPath = $graphicPath
            DiscordMessageId = ''
        }
    }

    $queueArgs = @{
        Id = $Record.Id
        SortKey = $Record.SortKey
        Message = $message
        OutboxDir = $outboxDir
    }
    if (-not [string]::IsNullOrWhiteSpace($graphicPath)) {
        $queueArgs.FilePath = $graphicPath
    }
    & $queuePath @queueArgs | Out-Null

    & $senderPath -OutboxDir $outboxDir -MaxItems 1 -WebhookPath $WebhookPath
    $delivery = Get-DeliveryResult $Record.Id
    Complete-Request $Record $delivery

    [pscustomobject]@{
        Id = $Record.Id
        Status = 'posted'
        NextStatePath = ''
        GraphicPath = $graphicPath
        DiscordMessageId = $delivery.MessageId
    }
}

$requestFiles = @(Get-ChildItem -LiteralPath $RequestsDir -Filter '*.json' -File)
if ($requestFiles.Count -eq 0) {
    [pscustomobject]@{
        Status = 'nothing-to-do'
        DryRun = [bool]$DryRun
        Processed = @()
    } | ConvertTo-Json -Depth 6
    return
}

$records = @($requestFiles | ForEach-Object { Get-RequestRecord $_ } | Sort-Object SortInstant, Id)
if ($MaxRequests -gt 0) {
    $records = @($records | Select-Object -First $MaxRequests)
}

$results = @()
$baseStatePath = $StatePath
foreach ($record in $records) {
    if ($record.Kind -eq 'match') {
        $result = Publish-MatchRequest $record $baseStatePath
        if ($DryRun -and -not [string]::IsNullOrWhiteSpace([string]$result.NextStatePath)) {
            $baseStatePath = [string]$result.NextStatePath
        }
        $results += $result
    } elseif ($record.Kind -eq 'fixtures') {
        $results += Publish-FixturesRequest $record
    }
}

[pscustomobject]@{
    Status = if ($DryRun) { 'validated' } else { 'published' }
    DryRun = [bool]$DryRun
    Processed = $results
} | ConvertTo-Json -Depth 8
