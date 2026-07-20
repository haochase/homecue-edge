param(
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$Text = "Hello XiaoQian, let's chat.",
  [string]$AudioPath = "",
  [string]$ApiToken = "",
  [string]$ResultJsonPath = ".\assets\demo\voice-chat-test.json",
  [switch]$Speak,
  [switch]$ReplyAudio,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

function New-ParentDirectory {
  param([string]$Path)
  $Parent = Split-Path -Parent $Path
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent | Out-Null
  }
}

New-ParentDirectory -Path $ResultJsonPath

$Uri = "{0}/voice-chat" -f $ApiBase.TrimEnd("/")
$Query = @()
if ($Speak) {
  $Query += "speak=1"
}
if ($ReplyAudio) {
  $Query += "reply_audio=1"
}
if ($Query.Count -gt 0) {
  $Uri = "{0}?{1}" -f $Uri, ($Query -join "&")
}

Write-Host "HomeCue Edge voice-chat test"
Write-Host ("API    : {0}" -f $Uri)

try {
  $Client = New-Object System.Net.WebClient
  $Client.Encoding = [System.Text.Encoding]::UTF8
  if ($AudioPath) {
    if (-not (Test-Path -LiteralPath $AudioPath)) {
      throw "Audio file not found: $AudioPath"
    }

    Write-Host ("Audio  : {0}" -f (Resolve-Path -LiteralPath $AudioPath).Path)
    $Bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $AudioPath).Path)
    $Client.Headers["Content-Type"] = "audio/wav"
    if ($ApiToken) {
      $Client.Headers["Authorization"] = "Bearer $ApiToken"
    }
    $ResponseText = [System.Text.Encoding]::UTF8.GetString($Client.UploadData($Uri, "POST", $Bytes))
    $Response = $ResponseText | ConvertFrom-Json
  } else {
    Write-Host ("Text   : {0}" -f $Text)
    $Body = @{
      text = $Text
      speak = [bool]$Speak
      reply_audio = [bool]$ReplyAudio
    } | ConvertTo-Json -Depth 4
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Client.Headers["Content-Type"] = "application/json; charset=utf-8"
    if ($ApiToken) {
      $Client.Headers["Authorization"] = "Bearer $ApiToken"
    }
    $ResponseText = [System.Text.Encoding]::UTF8.GetString($Client.UploadData($Uri, "POST", $Bytes))
    $Response = $ResponseText | ConvertFrom-Json
  }

  $Result = @{
    status = "passed"
    apiBase = $ApiBase
    mode = if ($AudioPath) { "audio" } else { "text" }
    inputText = $Text
    audioPath = $AudioPath
    apiTokenProvided = [bool]$ApiToken
    provider = $Response.provider
    recognizedText = $Response.text
    reply = $Response.reply
    tts = $Response.tts
    replyAudio = $Response.reply_audio
  }
} catch {
  $Result = @{
    status = "failed"
    apiBase = $ApiBase
    mode = if ($AudioPath) { "audio" } else { "text" }
    inputText = $Text
    audioPath = $AudioPath
    apiTokenProvided = [bool]$ApiToken
    error = $_.Exception.Message
  }
}

$Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Result.status -eq "passed") {
  Write-Host ("Provider: {0}" -f $Result.provider)
  Write-Host ("Heard   : {0}" -f $Result.recognizedText)
  Write-Host ("Reply   : {0}" -f $Result.reply)
  Write-Host ("TTS     : {0}" -f $Result.tts.status)
  if ($Result.replyAudio) {
    Write-Host ("Audio   : {0} {1}" -f $Result.replyAudio.status, $Result.replyAudio.url)
  }
  exit 0
}

Write-Host ("Voice-chat test failed: {0}" -f $Result.error) -ForegroundColor Red
if ($Required) {
  exit 1
}
exit 0
