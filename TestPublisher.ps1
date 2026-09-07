$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

$testRequests = Join-Path $scriptRoot 'tests\requests'
$workingDir = Join-Path $scriptRoot 'publisher-tests'
$publisher = Join-Path $scriptRoot 'PublishRequests.ps1'
$draftPath = Join-Path $scriptRoot 'draft.json'
$statePath = Join-Path $scriptRoot 'tracker-state.json'

$originalDraft = Get-Content -LiteralPath $draftPath -Raw
$originalState = Get-Content -LiteralPath $statePath -Raw

try {
    $testDraft = [ordered]@{
        owners = [ordered]@{
            Jack = @('Arsenal')
            Thomas = @('Napoli')
            Mark = @('AEK Athens')
            Rory = @('LASK')
        }
        aliases = [ordered]@{
            'AEK' = 'AEK Athens'
        }
    }

    $zeroOwners = [ordered]@{
        Jack = 0
        Thomas = 0
        Mark = 0
        Rory = 0
    }

    $testState = [ordered]@{
        balancesGBP = $zeroOwners
        sideBets = [ordered]@{
            pots = [ordered]@{
                goalsGBP = 40
                redCardsGBP = 40
                last16GBP = 40
                championsLeagueWinnerGBP = 100
            }
            stakesPerOwnerGBP = [ordered]@{
                goals = 10
                redCards = 10
                last16 = 10
                championsLeagueWinner = 25
            }
            settlementMode = 'Track match-bet balances during the tournament; add side-bet payouts to the final total balance only at the end.'
            championsLeagueWinnerTeam = $null
            championsLeagueWinnerOwner = $null
            settledPayoutsGBP = [ordered]@{
                goals = [ordered]@{}
                redCards = [ordered]@{}
                last16 = [ordered]@{}
                championsLeagueWinner = [ordered]@{}
            }
            goals = $zeroOwners
            goalsConceded = $zeroOwners
            redCards = $zeroOwners
            yellowCards = $zeroOwners
            last16 = $zeroOwners
        }
        leaguePoints = [ordered]@{}
        teamGoalsFor = [ordered]@{}
        teamGoalsAgainst = [ordered]@{}
        last16Teams = @()
        eliminatedTeams = @()
        postedMatches = @()
    }

    $testDraft | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $draftPath -Encoding UTF8
    $testState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding UTF8

    $output = & $publisher `
        -RequestsDir $testRequests `
        -WorkingDir $workingDir `
        -DryRun

    $result = ($output | Out-String).Trim() | ConvertFrom-Json
    if ($result.Status -ne 'validated') {
        throw "Unexpected publisher status: $($result.Status)"
    }

    $processed = @($result.Processed)
    if ($processed.Count -ne 3) {
        throw "Expected three validated requests, got $($processed.Count)."
    }

    foreach ($item in $processed) {
        if ($item.Status -ne 'validated') {
            throw "Request '$($item.Id)' was not validated: $($item.Status)"
        }
        if ([string]::IsNullOrWhiteSpace([string]$item.GraphicPath) -or -not (Test-Path -LiteralPath $item.GraphicPath)) {
            throw "Request '$($item.Id)' did not render a graphic."
        }
    }

    $finalRequest = @($processed | Where-Object { $_.Id -like '2099-06-05|F|*' })
    if ($finalRequest.Count -ne 1) {
        throw 'Final request was not normalized to the F stage.'
    }
} finally {
    Set-Content -LiteralPath $draftPath -Value $originalDraft.TrimEnd() -Encoding UTF8
    Set-Content -LiteralPath $statePath -Value $originalState.TrimEnd() -Encoding UTF8
}

Write-Output 'Champions League publisher dry-run tests passed.'
