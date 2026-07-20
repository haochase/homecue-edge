param(
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$WsUrl = "",
  [string]$ApiToken = "",
  [string]$UserId = "home-user",
  [string]$DeviceId = "readiness-script",
  [string]$Text = "Hello XiaoQian readiness check.",
  [string]$ResultJsonPath = ".\assets\demo\voice-system-readiness-check.json",
  [string]$WsResultJsonPath = ".\assets\demo\voice-system-readiness-ws-check.json",
  [string]$PcmWsResultJsonPath = ".\assets\demo\voice-system-readiness-ws-pcm-check.json",
  [string]$TtsWsResultJsonPath = ".\assets\demo\voice-system-readiness-ws-tts-stream-check.json",
  [string]$UbuntuApiBase = "",
  [string]$UbuntuApiToken = "",
  [switch]$SkipDueAudio,
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

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $true
  )

  $Status = if ($Ok) { "OK" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)
  $script:Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      required = [bool]$RequiredCheck
      detail = $Detail
    })
  if ($Required -and $RequiredCheck -and -not $Ok) {
    $script:Failures.Add($Name)
  }
}

function Invoke-JsonRequest {
  param(
    [ValidateSet("GET", "POST", "PATCH")]
    [string]$Method,
    [string]$Uri,
    [string]$ApiToken = "",
    [object]$Body = $null
  )

  $Client = New-Object System.Net.WebClient
  $Client.Encoding = [System.Text.Encoding]::UTF8
  if ($ApiToken) {
    $Client.Headers["Authorization"] = "Bearer $ApiToken"
  }
  try {
    if ($null -ne $Body) {
      $Client.Headers["Content-Type"] = "application/json; charset=utf-8"
      $Json = $Body | ConvertTo-Json -Depth 6
      $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
      $ResponseText = [System.Text.Encoding]::UTF8.GetString($Client.UploadData($Uri, $Method, $Bytes))
    } else {
      $ResponseText = $Client.DownloadString($Uri)
    }
    return $ResponseText | ConvertFrom-Json
  } finally {
    $Client.Dispose()
  }
}

function Convert-ToWsUrl {
  param([string]$Base)
  $Uri = [Uri]$Base.TrimEnd("/")
  $Builder = [System.UriBuilder]::new($Uri)
  $Builder.Scheme = if ($Uri.Scheme -eq "https") { "wss" } else { "ws" }
  $Builder.Path = ($Builder.Path.TrimEnd("/") + "/voice-chat/ws").TrimStart("/")
  $Builder.Query = ""
  return $Builder.Uri.AbsoluteUri
}

function Get-PropertyCount {
  param(
    [object]$Object,
    [string]$Name
  )
  if ($null -eq $Object) {
    return 0
  }
  $Value = $Object.$Name
  if ($null -eq $Value) {
    return 0
  }
  return @($Value).Count
}

function Redact-ReadinessArtifact {
  param([object]$Value)

  if ($null -eq $Value) {
    return $null
  }
  if ($Value -is [string]) {
    return [regex]::Replace($Value, "(access_token|token)=([^&\s]+)", '$1=REDACTED')
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $Redacted = [ordered]@{}
    foreach ($Key in $Value.Keys) {
      $Name = [string]$Key
      if ($Name -match "(?i)provided$") {
        $Redacted[$Name] = Redact-ReadinessArtifact -Value $Value[$Key]
      } elseif ($Name -match "(?i)authorization|access_token|api_token|token") {
        $Redacted[$Name] = "REDACTED"
      } else {
        $Redacted[$Name] = Redact-ReadinessArtifact -Value $Value[$Key]
      }
    }
    return $Redacted
  }
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $Items = @()
    foreach ($Item in $Value) {
      $Items += Redact-ReadinessArtifact -Value $Item
    }
    return $Items
  }
  if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
    $Redacted = [ordered]@{}
    foreach ($Property in $Value.PSObject.Properties) {
      if ($Property.Name -match "(?i)provided$") {
        $Redacted[$Property.Name] = Redact-ReadinessArtifact -Value $Property.Value
      } elseif ($Property.Name -match "(?i)authorization|access_token|api_token|token") {
        $Redacted[$Property.Name] = "REDACTED"
      } else {
        $Redacted[$Property.Name] = Redact-ReadinessArtifact -Value $Property.Value
      }
    }
    return $Redacted
  }
  return $Value
}

New-ParentDirectory -Path $ResultJsonPath
New-ParentDirectory -Path $WsResultJsonPath
New-ParentDirectory -Path $PcmWsResultJsonPath
New-ParentDirectory -Path $TtsWsResultJsonPath

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$StartedAt = Get-Date
$Base = $ApiBase.TrimEnd("/")
if (-not $WsUrl) {
  $WsUrl = Convert-ToWsUrl -Base $Base
}

$Payload = [ordered]@{
  startedAt = $StartedAt.ToString("o")
  apiBase = $Base
  wsUrl = $WsUrl
  userId = $UserId
  deviceId = $DeviceId
  text = $Text
  apiTokenProvided = [bool]$ApiToken
  ubuntuApiTokenProvided = [bool]$UbuntuApiToken
  status = "unknown"
  checks = @()
  artifacts = [ordered]@{
    wsResultJsonPath = $WsResultJsonPath
    pcmWsResultJsonPath = $PcmWsResultJsonPath
    ttsWsResultJsonPath = $TtsWsResultJsonPath
  }
}

Write-Host "HomeCue Edge voice-system readiness"
Write-Host ("API : {0}" -f $Base)
Write-Host ("WS  : {0}" -f $WsUrl)
Write-Host ("Auth: {0}" -f $(if ($ApiToken) { "token provided" } else { "none" }))
Write-Host ("User: {0} device={1}" -f $UserId, $DeviceId)
Write-Host ""

try {
  $Health = Invoke-JsonRequest -Method GET -Uri ("{0}/health" -f $Base) -ApiToken $ApiToken
  $Payload["health"] = $Health
  Add-Check "health endpoint" ($Health.status -eq "ok") ("status={0} provider={1}" -f $Health.status, $Health.active_provider)
} catch {
  $Payload["healthError"] = $_.Exception.Message
  Add-Check "health endpoint" $false $_.Exception.Message
}

try {
  $Runtime = Invoke-JsonRequest -Method GET -Uri ("{0}/voice-chat/status" -f $Base) -ApiToken $ApiToken
  $Payload["runtime"] = $Runtime
  Add-Check "runtime provider" ($Runtime.provider -eq "mimo") ("provider={0} model={1}" -f $Runtime.provider, $Runtime.model)
  Add-Check "runtime tts" ($Runtime.tts.provider -eq "mimo" -and $Runtime.tts.configured) (
    "tts={0}/{1}/{2}" -f $Runtime.tts.provider, $Runtime.tts.model, $Runtime.tts.voice
  )
  Add-Check "runtime memory sqlite" ([bool]$Runtime.memory.sqlite_enabled) "sqlite_enabled=true"
  Add-Check "runtime asr available" ($Runtime.asr.effective_provider -ne "unavailable" -and $Runtime.asr.effective_provider -ne "disabled") (
    "effective={0}" -f $Runtime.asr.effective_provider
  )
  Add-Check "runtime websocket pcm" ([bool]$Runtime.realtime.websocket -and [bool]$Runtime.realtime.pcm_s16le) "websocket+pcm_s16le"
  Add-Check "runtime half-duplex gap declared" (-not [bool]$Runtime.realtime.full_duplex) "full_duplex=false"
  Add-Check "runtime opus gap declared" (-not [bool]$Runtime.realtime.opus_stream) "opus_stream=false"
} catch {
  $Payload["runtimeError"] = $_.Exception.Message
  Add-Check "runtime status" $false $_.Exception.Message
}

$SessionId = ""
try {
  $VoicePayload = @{
    text = $Text
    speak = $false
    reply_audio = $false
    reset_session = $true
    user_id = $UserId
    device_id = $DeviceId
  }
  $Voice = Invoke-JsonRequest -Method POST -Uri ("{0}/voice-chat" -f $Base) -ApiToken $ApiToken -Body $VoicePayload
  $Payload["voiceChat"] = $Voice
  $SessionId = [string]$Voice.session_id
  Add-Check "voice-chat text turn" ($Voice.provider -eq "mimo" -and [string]$Voice.reply) (
    "provider={0} turn={1}" -f $Voice.provider, $Voice.turn_index
  )
  Add-Check "voice-chat session id" ([bool]$SessionId) $SessionId
} catch {
  $Payload["voiceChatError"] = $_.Exception.Message
  Add-Check "voice-chat text turn" $false $_.Exception.Message
}

try {
  $WsScript = Join-Path $PSScriptRoot "test-voice-chat-ws.ps1"
  $WsArgs = @(
    "-WsUrl", $WsUrl,
    "-Text", $Text,
    "-UserId", $UserId,
    "-DeviceId", $DeviceId,
    "-ResultJsonPath", $WsResultJsonPath,
    "-Required"
  )
  if ($ApiToken) {
    $WsArgs += @("-ApiToken", $ApiToken)
  }
  & (Join-Path $PSHOME "powershell.exe") -NoProfile -ExecutionPolicy Bypass -File $WsScript @WsArgs
  $WsExitCode = $LASTEXITCODE
  $Payload["websocket"] = Get-Content -Raw -LiteralPath $WsResultJsonPath | ConvertFrom-Json
  Add-Check "websocket protocol" ($WsExitCode -eq 0 -and $Payload["websocket"].status -eq "passed") (
    "provider={0} turn={1}" -f $Payload["websocket"].provider, $Payload["websocket"].turnIndex
  )
} catch {
  $Payload["websocketError"] = $_.Exception.Message
  Add-Check "websocket protocol" $false $_.Exception.Message
}

try {
  $WsScript = Join-Path $PSScriptRoot "test-voice-chat-ws.ps1"
  $PcmText = [System.Text.RegularExpressions.Regex]::Unescape(
    "\u4f60\u597d\u5c0f\u5343\uff0c\u73b0\u5728\u6d4b\u8bd5\u4e8c\u8fdb\u5236 PCM \u8bed\u97f3\u94fe\u8def\u3002"
  )
  $PcmWsArgs = @(
    "-WsUrl", $WsUrl,
    "-Text", $PcmText,
    "-TurnMode", "pcm_s16le",
    "-AudioText", $PcmText,
    "-UserId", $UserId,
    "-DeviceId", "readiness-pcm",
    "-ResultJsonPath", $PcmWsResultJsonPath,
    "-RequireRecognizedAudio",
    "-Required"
  )
  if ($ApiToken) {
    $PcmWsArgs += @("-ApiToken", $ApiToken)
  }
  & (Join-Path $PSHOME "powershell.exe") -NoProfile -ExecutionPolicy Bypass -File $WsScript @PcmWsArgs
  $PcmWsExitCode = $LASTEXITCODE
  $Payload["websocketPcm"] = Get-Content -Raw -LiteralPath $PcmWsResultJsonPath | ConvertFrom-Json
  Add-Check "websocket binary pcm turn" (
    $PcmWsExitCode -eq 0 -and
    $Payload["websocketPcm"].status -eq "passed" -and
    $Payload["websocketPcm"].audioResult -eq "recognized" -and
    $Payload["websocketPcm"].binaryAudioBytes -gt 0
  ) (
    "bytes={0} frames={1} result={2}" -f
    $Payload["websocketPcm"].binaryAudioBytes,
    $Payload["websocketPcm"].binaryFrameCount,
    $Payload["websocketPcm"].audioResult
  )
} catch {
  $Payload["websocketPcmError"] = $_.Exception.Message
  Add-Check "websocket binary pcm turn" $false $_.Exception.Message
}

try {
  $WsScript = Join-Path $PSScriptRoot "test-voice-chat-ws.ps1"
  $TtsWsArgs = @(
    "-WsUrl", $WsUrl,
    "-Text", "Hello XiaoQian, stream TTS audio.",
    "-UserId", $UserId,
    "-DeviceId", "readiness-tts-stream",
    "-ReplyAudio",
    "-RequireReplyAudio",
    "-ResultJsonPath", $TtsWsResultJsonPath,
    "-Required"
  )
  if ($ApiToken) {
    $TtsWsArgs += @("-ApiToken", $ApiToken)
  }
  & (Join-Path $PSHOME "powershell.exe") -NoProfile -ExecutionPolicy Bypass -File $WsScript @TtsWsArgs
  $TtsWsExitCode = $LASTEXITCODE
  $Payload["websocketTtsStream"] = Get-Content -Raw -LiteralPath $TtsWsResultJsonPath | ConvertFrom-Json
  Add-Check "websocket tts stream downlink" (
    $TtsWsExitCode -eq 0 -and
    $Payload["websocketTtsStream"].status -eq "passed" -and
    $Payload["websocketTtsStream"].replyAudioProvider -eq "mimo" -and
    $Payload["websocketTtsStream"].replyAudioVoice -eq "Mia" -and
    $Payload["websocketTtsStream"].downlinkBinaryBytes -gt 0
  ) (
    "tts={0}/{1}/{2} bytes={3} frames={4}" -f
    $Payload["websocketTtsStream"].replyAudioProvider,
    $Payload["websocketTtsStream"].replyAudioModel,
    $Payload["websocketTtsStream"].replyAudioVoice,
    $Payload["websocketTtsStream"].downlinkBinaryBytes,
    $Payload["websocketTtsStream"].downlinkBinaryFrameCount
  )
} catch {
  $Payload["websocketTtsStreamError"] = $_.Exception.Message
  Add-Check "websocket tts stream downlink" $false $_.Exception.Message
}

try {
  $InsightText = [System.Text.RegularExpressions.Regex]::Unescape(
    "\u8bb0\u4f4f\u6211\u559c\u6b22\u5b89\u9759\u7684\u706f\u5149\uff0c\u4eca\u665a\u63d0\u9192\u6211\u68c0\u67e5\u95e8\u9501\uff0c\u6211\u4eca\u5929\u6709\u70b9\u7126\u8651\u3002"
  )
  $InsightPayload = @{
    text = $InsightText
    speak = $false
    reply_audio = $false
    reset_session = $false
    session_id = $SessionId
    user_id = $UserId
    device_id = $DeviceId
  }
  $Insight = Invoke-JsonRequest -Method POST -Uri ("{0}/voice-chat" -f $Base) -ApiToken $ApiToken -Body $InsightPayload
  $Payload["insightTurn"] = $Insight

  $EncodedUserId = [uri]::EscapeDataString($UserId)
  $Memories = Invoke-JsonRequest -Method GET -Uri ("{0}/voice-chat/memories?user_id={1}&limit=20" -f $Base, $EncodedUserId) -ApiToken $ApiToken
  $Tasks = Invoke-JsonRequest -Method GET -Uri ("{0}/voice-chat/tasks?user_id={1}&status=open&limit=20" -f $Base, $EncodedUserId) -ApiToken $ApiToken
  $Moods = Invoke-JsonRequest -Method GET -Uri ("{0}/voice-chat/moods?user_id={1}&limit=20" -f $Base, $EncodedUserId) -ApiToken $ApiToken
  $Payload["memoryState"] = @{
    memories = $Memories.memories
    tasks = $Tasks.tasks
    moods = $Moods.moods
  }

  $MemoryCount = Get-PropertyCount -Object $Memories -Name "memories"
  $TaskCount = Get-PropertyCount -Object $Tasks -Name "tasks"
  $MoodCount = Get-PropertyCount -Object $Moods -Name "moods"
  Add-Check "memory extraction" ($MemoryCount -gt 0) ("memories={0}" -f $MemoryCount)
  Add-Check "task extraction" ($TaskCount -gt 0) ("tasks={0}" -f $TaskCount)
  Add-Check "mood extraction" ($MoodCount -gt 0) ("moods={0}" -f $MoodCount)
} catch {
  $Payload["memoryError"] = $_.Exception.Message
  Add-Check "memory task mood extraction" $false $_.Exception.Message
}

if (-not $SkipDueAudio) {
  try {
    $DueAt = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 10
    $TaskPayload = @{
      title = "Readiness reminder"
      detail = "Generated by voice-system readiness."
      due_text = "now"
      due_at = $DueAt
      recurrence = ""
      user_id = $UserId
      device_id = $DeviceId
    }
    $EncodedUserId = [uri]::EscapeDataString($UserId)
    $CreatedTask = Invoke-JsonRequest -Method POST -Uri ("{0}/voice-chat/tasks" -f $Base) -ApiToken $ApiToken -Body $TaskPayload
    $DueAudio = Invoke-JsonRequest -Method GET -Uri ("{0}/voice-chat/tasks/due-audio?user_id={1}&now={2}" -f $Base, $EncodedUserId, $DueAt) -ApiToken $ApiToken
    $Payload["dueAudio"] = @{
      createdTask = $CreatedTask.task
      response = $DueAudio
    }
    Add-Check "due-audio ready" ($DueAudio.status -eq "ready" -and $DueAudio.reply_audio.status -eq "ready") (
      "tts={0}/{1}/{2}" -f $DueAudio.reply_audio.provider, $DueAudio.reply_audio.model, $DueAudio.reply_audio.voice
    )
  } catch {
    $Payload["dueAudioError"] = $_.Exception.Message
    Add-Check "due-audio ready" $false $_.Exception.Message
  }
} else {
  Add-Check "due-audio skipped" $true "explicitly skipped" $false
}

if ($UbuntuApiBase) {
  $UbuntuBase = $UbuntuApiBase.TrimEnd("/")
  try {
    $UbuntuRuntime = Invoke-JsonRequest -Method GET -Uri ("{0}/voice-chat/status" -f $UbuntuBase) -ApiToken $UbuntuApiToken
    $Payload["ubuntu"] = @{
      apiBase = $UbuntuBase
      runtime = $UbuntuRuntime
    }
    Add-Check "ubuntu lan status" ($UbuntuRuntime.realtime.websocket -eq $true) ("provider={0}" -f $UbuntuRuntime.provider) $false
  } catch {
    $Payload["ubuntu"] = @{
      apiBase = $UbuntuBase
      error = $_.Exception.Message
    }
    Add-Check "ubuntu lan status" $false $_.Exception.Message $false
  }
}

$Payload["finishedAt"] = (Get-Date).ToString("o")
$Payload["checks"] = [object[]]$Checks.ToArray()
$Payload["failures"] = [string[]]$Failures.ToArray()
$Payload["status"] = if ($Failures.Count -eq 0) { "passed" } else { "failed" }
$RedactedPayload = Redact-ReadinessArtifact -Value $Payload
$RedactedPayload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8

Write-Host ""
Write-Host ("Status : {0}" -f $Payload["status"])
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Voice-system readiness failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

exit 0
