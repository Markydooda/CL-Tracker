param(
    [string]$OutboxDir = '',

    [int]$MaxItems = 10,

    [string]$WebhookPath = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($OutboxDir)) {
    $OutboxDir = Join-Path $scriptRoot 'discord-outbox'
}

$sentDir = Join-Path $OutboxDir 'sent'
$logPath = Join-Path $scriptRoot 'discord-outbox-log.jsonl'
$lockPath = Join-Path $OutboxDir '.send.lock'
$postScript = Join-Path $scriptRoot 'PostDiscordUpdate.ps1'
$editScript = Join-Path $scriptRoot 'EditDiscordWebhookMessage.ps1'

function Write-OutboxLog([hashtable]$Entry) {
    $Entry.timestamp = (Get-Date).ToString('o')
    $line = $Entry | ConvertTo-Json -Compress
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Resolve-OptionalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    Join-Path $scriptRoot $Path
}

function Get-PostedMatches([object]$State) {
    if ($null -eq $State -or $null -eq $State.postedMatches) {
        return @()
    }

    @($State.postedMatches)
}

function Read-StateFile([string]$Path) {
    $resolvedPath = Resolve-OptionalPath $Path
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "State file not found: $resolvedPath"
    }

    Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
}

function Assert-StateCanAdvance([string]$SourcePath, [string]$TargetPath) {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        return
    }

    $sourceState = Read-StateFile $SourcePath
    $sourceMatches = Get-PostedMatches $sourceState

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return
    }

    $resolvedTarget = Resolve-OptionalPath $TargetPath
    if (-not (Test-Path -LiteralPath $resolvedTarget)) {
        return
    }

    $targetState = Get-Content -LiteralPath $resolvedTarget -Raw | ConvertFrom-Json
    $targetMatches = Get-PostedMatches $targetState

    $missing = @($targetMatches | Where-Object { $sourceMatches -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Refusing to apply stale state. Source is missing already-posted match(es): $($missing -join '; ')"
    }

    if ($sourceMatches.Count -lt $targetMatches.Count) {
        throw "Refusing to apply stale state. Source has fewer posted matches ($($sourceMatches.Count)) than current state ($($targetMatches.Count))."
    }
}

function Get-QueueSortRecord([System.IO.FileInfo]$ItemFile) {
    $item = Get-Content -LiteralPath $ItemFile.FullName -Raw | ConvertFrom-Json
    $createdAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$item.createdAt, [ref]$createdAt)) {
        $createdAt = $ItemFile.LastWriteTime
    }

    $hasState = -not [string]::IsNullOrWhiteSpace([string]$item.applyStateFrom)
    $stateMatchCount = -1
    if ($hasState) {
        try {
            $state = Read-StateFile $item.applyStateFrom
            $stateMatchCount = (Get-PostedMatches $state).Count
        } catch {
            $stateMatchCount = [int]::MaxValue
        }
    }

    [pscustomobject]@{
        File = $ItemFile
        Item = $item
        Bucket = if ($hasState) { 1 } else { 0 }
        StateMatchCount = $stateMatchCount
        SortKey = if ([string]::IsNullOrWhiteSpace([string]$item.sortKey)) { [string]$item.id } else { [string]$item.sortKey }
        CreatedAt = $createdAt
        Name = $ItemFile.Name
    }
}

function Set-StateFile([string]$SourcePath, [string]$TargetPath) {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        return
    }

    $resolvedSource = Resolve-OptionalPath $SourcePath
    $resolvedTarget = Resolve-OptionalPath $TargetPath

    if (-not (Test-Path -LiteralPath $resolvedSource)) {
        throw "State source not found: $resolvedSource"
    }

    $targetDir = Split-Path -Parent $resolvedTarget
    if (-not [string]::IsNullOrWhiteSpace($targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $tmpTarget = "$resolvedTarget.tmp"
    Copy-Item -LiteralPath $resolvedSource -Destination $tmpTarget -Force
    Move-Item -LiteralPath $tmpTarget -Destination $resolvedTarget -Force
}

New-Item -ItemType Directory -Path $OutboxDir -Force | Out-Null
New-Item -ItemType Directory -Path $sentDir -Force | Out-Null

$lockStream = $null
try {
    if (Test-Path -LiteralPath $lockPath) {
        $lockAge = (Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime
        if ($lockAge.TotalMinutes -gt 30) {
            Remove-Item -LiteralPath $lockPath -Force
        }
    }

    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

    $items = @(Get-ChildItem -LiteralPath $OutboxDir -Filter '*.json' -File |
        ForEach-Object { Get-QueueSortRecord $_ } |
        Sort-Object Bucket, StateMatchCount, SortKey, CreatedAt, Name |
        Select-Object -First $MaxItems)

    foreach ($queueRecord in $items) {
        $itemFile = $queueRecord.File
        try {
            $item = $queueRecord.Item
            $filePath = Resolve-OptionalPath $item.filePath
            $payloadPath = Resolve-OptionalPath $item.payloadPath
            $editMessageId = [string]$item.editMessageId

            Assert-StateCanAdvance -SourcePath $item.applyStateFrom -TargetPath $item.applyStateTo

            if (-not [string]::IsNullOrWhiteSpace($editMessageId)) {
                if ([string]::IsNullOrWhiteSpace($filePath)) {
                    throw 'Discord edits require a filePath.'
                }

                $editArgs = @{
                    MessageId = $editMessageId
                    Message = [string]$item.message
                    FilePath = $filePath
                }

                if (-not [string]::IsNullOrWhiteSpace($WebhookPath)) {
                    $editArgs.WebhookPath = $WebhookPath
                }

                $deliveryOutput = & $editScript @editArgs
                $deliveryText = ($deliveryOutput | Out-String).Trim()
                if ($deliveryText -notmatch 'Message id:') {
                    throw "Discord edit did not return a message id. Output: $deliveryText"
                }
            } else {
                $postArgs = @{
                    Message = [string]$item.message
                }

                if (-not [string]::IsNullOrWhiteSpace($filePath)) {
                    $postArgs.FilePath = $filePath
                }

                if (-not [string]::IsNullOrWhiteSpace($payloadPath)) {
                    $postArgs.PayloadPath = $payloadPath
                }

                if (-not [string]::IsNullOrWhiteSpace($WebhookPath)) {
                    $postArgs.WebhookPath = $WebhookPath
                }

                $deliveryOutput = & $postScript @postArgs
                $deliveryText = ($deliveryOutput | Out-String).Trim()
                if ($deliveryText -notmatch 'Message id:') {
                    throw "Discord post did not return a message id. Output: $deliveryText"
                }
            }

            Set-StateFile -SourcePath $item.applyStateFrom -TargetPath $item.applyStateTo

            $sentPath = Join-Path $sentDir $itemFile.Name
            Move-Item -LiteralPath $itemFile.FullName -Destination $sentPath -Force

            Write-OutboxLog @{
                event = if ([string]::IsNullOrWhiteSpace($editMessageId)) { 'sent' } else { 'edited' }
                id = $item.id
                queuePath = $itemFile.FullName
                sentPath = $sentPath
                output = $deliveryText
            }
        } catch {
            Write-OutboxLog @{
                event = 'failed'
                queuePath = $itemFile.FullName
                message = $_.Exception.Message
            }
        }
    }
} finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }

    if (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force
    }
}
