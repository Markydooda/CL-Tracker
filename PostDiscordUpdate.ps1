param(
    [string]$Message = '',

    [string]$PayloadPath = '',

    [string]$FilePath = '',

    [string]$WebhookPath = '',

    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WebhookPath)) {
    $scriptRoot = if ($PSScriptRoot) {
        $PSScriptRoot
    } else {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    $WebhookPath = Join-Path $scriptRoot 'discord-webhook.txt'
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logRoot = if ($PSScriptRoot) {
        $PSScriptRoot
    } else {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    $LogPath = Join-Path $logRoot 'discord-post-log.jsonl'
}

if (-not (Test-Path -LiteralPath $WebhookPath)) {
    throw "Webhook file not found: $WebhookPath"
}

$webhook = (Get-Content -LiteralPath $WebhookPath -Raw).Trim()

if ([string]::IsNullOrWhiteSpace($webhook)) {
    throw "Webhook file is empty: $WebhookPath"
}

if (-not [string]::IsNullOrWhiteSpace($PayloadPath)) {
    if (-not (Test-Path -LiteralPath $PayloadPath)) {
        throw "Payload file not found: $PayloadPath"
    }

    $body = Get-Content -LiteralPath $PayloadPath -Raw
} else {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw 'Either Message or PayloadPath is required.'
    }

    $body = @{
        content = $Message
    } | ConvertTo-Json
}

$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Could not force TLS 1.2: $($_.Exception.Message)"
}

function Get-ConfirmedWebhookUri([string]$Uri) {
    if ($Uri -match '(\?|&)wait=') {
        return $Uri
    }

    if ($Uri.Contains('?')) {
        "${Uri}&wait=true"
    } else {
        "${Uri}?wait=true"
    }
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

function Get-ErrorDetails($ErrorRecord) {
    $details = @{
        message = $ErrorRecord.Exception.Message
        statusCode = $null
        retryAfterSeconds = $null
    }

    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response) {
        try {
            if ($null -ne $response.StatusCode) {
                $details.statusCode = [int]$response.StatusCode
            }

            $retryAfter = $response.Headers['Retry-After']
            if (-not [string]::IsNullOrWhiteSpace($retryAfter)) {
                $parsed = 0.0
                if ([double]::TryParse($retryAfter, [ref]$parsed)) {
                    $details.retryAfterSeconds = [int][math]::Ceiling($parsed)
                }
            }
        } catch {
            # Keep the original error details if response metadata cannot be read.
        }
    }

    $details
}

function Get-RetryDelaySeconds([int]$Attempt, [hashtable]$ErrorDetails) {
    if ($null -ne $ErrorDetails.retryAfterSeconds -and $ErrorDetails.retryAfterSeconds -gt 0) {
        return [math]::Min(60, [math]::Max(1, $ErrorDetails.retryAfterSeconds))
    }

    [math]::Min(30, 3 * $Attempt)
}

function Invoke-WithRetry([scriptblock]$Action, [string]$PostKind) {
    $maxAttempts = 5
    $lastError = $null
    $lastDetails = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = & $Action
            $message = $response.Content | ConvertFrom-Json

            if ($null -eq $message -or [string]::IsNullOrWhiteSpace($message.id)) {
                throw "Discord did not return a message id, so delivery could not be confirmed."
            }

            Write-DeliveryLog @{
                event = 'success'
                kind = $PostKind
                attempt = $attempt
                statusCode = $response.StatusCode
                discordMessageId = $message.id
                discordChannelId = $message.channel_id
                attachmentCount = if ($null -ne $message.attachments) { @($message.attachments).Count } else { 0 }
            }

            return $message
        } catch {
            $lastError = $_
            $lastDetails = Get-ErrorDetails $_

            Write-DeliveryLog @{
                event = 'attempt_failed'
                kind = $PostKind
                attempt = $attempt
                statusCode = $lastDetails.statusCode
                message = $lastDetails.message
            }

            if ($attempt -eq $maxAttempts) {
                break
            }

            $delaySeconds = Get-RetryDelaySeconds $attempt $lastDetails
            Write-Warning "Discord post attempt $attempt failed: $($lastDetails.message). Retrying in $delaySeconds seconds..."
            Start-Sleep -Seconds $delaySeconds
        }
    }

    Write-DeliveryLog @{
        event = 'failed'
        kind = $PostKind
        statusCode = if ($null -ne $lastDetails) { $lastDetails.statusCode } else { $null }
        message = if ($null -ne $lastDetails) { $lastDetails.message } else { $lastError.Exception.Message }
    }

    throw $lastError
}

$confirmedWebhook = Get-ConfirmedWebhookUri $webhook
$postedMessage = $null

if ([string]::IsNullOrWhiteSpace($FilePath)) {
    $postedMessage = Invoke-WithRetry {
        Invoke-WebRequest -Uri $confirmedWebhook -Method Post -ContentType 'application/json; charset=utf-8' -Body $bodyBytes -UseBasicParsing -TimeoutSec 45
    } 'json'
} else {
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Attachment file not found: $FilePath"
    }

    $boundary = [System.Guid]::NewGuid().ToString()
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $encoding = [System.Text.Encoding]::UTF8

    $prefix = "--$boundary`r`n" +
        "Content-Disposition: form-data; name=`"payload_json`"`r`n" +
        "Content-Type: application/json; charset=utf-8`r`n`r`n" +
        $body +
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

    $postedMessage = Invoke-WithRetry {
        Invoke-WebRequest -Uri $confirmedWebhook -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $multipartBytes -UseBasicParsing -TimeoutSec 45
    } 'multipart'
}

Write-Output "Posted Discord update. Message id: $($postedMessage.id)"
