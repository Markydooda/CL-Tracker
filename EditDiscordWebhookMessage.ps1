param(
    [Parameter(Mandatory = $true)]
    [string]$MessageId,

    [string]$Message = '',

    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string]$WebhookPath = '',

    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($WebhookPath)) {
    $WebhookPath = Join-Path $scriptRoot 'discord-webhook.txt'
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $scriptRoot 'discord-post-log.jsonl'
}

if (-not (Test-Path -LiteralPath $WebhookPath)) {
    throw "Webhook file not found: $WebhookPath"
}

if (-not (Test-Path -LiteralPath $FilePath)) {
    throw "Attachment file not found: $FilePath"
}

$webhook = (Get-Content -LiteralPath $WebhookPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($webhook)) {
    throw "Webhook file is empty: $WebhookPath"
}

function Get-WebhookMessageUri([string]$WebhookUri, [string]$DiscordMessageId) {
    $builder = [System.UriBuilder]::new($WebhookUri)
    $builder.Query = ''
    $baseUri = $builder.Uri.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')
    "$baseUri/messages/${DiscordMessageId}?wait=true"
}

function Write-DeliveryLog([hashtable]$Entry) {
    try {
        $Entry.timestamp = (Get-Date).ToString('o')
        $line = $Entry | ConvertTo-Json -Compress
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        Write-Warning "Could not write Discord delivery log: $($_.Exception.Message)"
    }
}

try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Could not force TLS 1.2: $($_.Exception.Message)"
}

$fileName = [System.IO.Path]::GetFileName($FilePath)
$payload = @{
    content = $Message
    attachments = @(
        @{
            id = 0
            filename = $fileName
        }
    )
} | ConvertTo-Json -Depth 5

$boundary = [System.Guid]::NewGuid().ToString()
$fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
$encoding = [System.Text.Encoding]::UTF8

$prefix = "--$boundary`r`n" +
    "Content-Disposition: form-data; name=`"payload_json`"`r`n" +
    "Content-Type: application/json; charset=utf-8`r`n`r`n" +
    $payload +
    "`r`n--$boundary`r`n" +
    "Content-Disposition: form-data; name=`"files[0]`"; filename=`"$fileName`"`r`n" +
    "Content-Type: image/png`r`n`r`n"
$suffix = "`r`n--$boundary--`r`n"

$stream = [System.IO.MemoryStream]::new()
$prefixBytes = $encoding.GetBytes($prefix)
$suffixBytes = $encoding.GetBytes($suffix)
$stream.Write($prefixBytes, 0, $prefixBytes.Length)
$stream.Write($fileBytes, 0, $fileBytes.Length)
$stream.Write($suffixBytes, 0, $suffixBytes.Length)
$multipartBytes = $stream.ToArray()
$stream.Dispose()

$editUri = Get-WebhookMessageUri $webhook $MessageId
$response = Invoke-WebRequest -Uri $editUri -Method Patch -ContentType "multipart/form-data; boundary=$boundary" -Body $multipartBytes -UseBasicParsing -TimeoutSec 45
$message = $null
if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
    $message = $response.Content | ConvertFrom-Json
}

if ($null -ne $message -and -not [string]::IsNullOrWhiteSpace($message.id)) {
    $confirmedMessageId = $message.id
    $confirmedChannelId = $message.channel_id
    $attachmentCount = if ($null -ne $message.attachments) { @($message.attachments).Count } else { 0 }
} else {
    $confirmedMessageId = $MessageId
    $confirmedChannelId = $null
    $attachmentCount = $null
}

Write-DeliveryLog @{
    event = 'edit_success'
    kind = 'multipart'
    statusCode = $response.StatusCode
    discordMessageId = $confirmedMessageId
    discordChannelId = $confirmedChannelId
    attachmentCount = $attachmentCount
}

Write-Output "Edited Discord message. Message id: $confirmedMessageId"
