param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$FilePath = '',

    [string]$PayloadPath = '',

    [string]$ApplyStateFrom = '',

    [string]$ApplyStateTo = '',

    [string]$OutboxDir = '',

    [string]$Id = '',

    [string]$SortKey = '',

    [string]$EditMessageId = ''
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

if ([string]::IsNullOrWhiteSpace($ApplyStateTo) -and -not [string]::IsNullOrWhiteSpace($ApplyStateFrom)) {
    $ApplyStateTo = Join-Path $scriptRoot 'tracker-state.json'
}

if ([string]::IsNullOrWhiteSpace($Id)) {
    $Id = [System.Guid]::NewGuid().ToString()
}

New-Item -ItemType Directory -Path $OutboxDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutboxDir 'sent') -Force | Out-Null

$existing = Get-ChildItem -LiteralPath $OutboxDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
    try {
        $queued = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        $queued.id -eq $Id
    } catch {
        $false
    }
} | Select-Object -First 1

if ($null -ne $existing) {
    Write-Output "Discord post already queued or sent: $($existing.FullName)"
    return
}

$createdAt = Get-Date
$safeId = ($Id -replace '[^A-Za-z0-9_.-]', '-')
$fileName = '{0:yyyyMMdd-HHmmss}-{1}.json' -f $createdAt, $safeId
$queuePath = Join-Path $OutboxDir $fileName

$item = [ordered]@{
    id = $Id
    createdAt = $createdAt.ToString('o')
    message = $Message
    filePath = $FilePath
    payloadPath = $PayloadPath
    applyStateFrom = $ApplyStateFrom
    applyStateTo = $ApplyStateTo
    sortKey = $SortKey
    editMessageId = $EditMessageId
}

$json = $item | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($queuePath, $json, [System.Text.Encoding]::UTF8)

Write-Output "Queued Discord post: $queuePath"
