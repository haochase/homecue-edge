param(
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$UserId = "home-user",
  [string]$DeviceId = "esp32-audio-board",
  [int]$WaitSeconds = 75,
  [string]$ApiLogPath = "",
  [string]$ResultJsonPath = ".\assets\demo\esp32-speaker-network-due-audio-probe.json",
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

function Read-FileTailFromOffset {
  param(
    [string]$Path,
    [long]$Offset
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return ""
  }

  $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    [void]$Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $Reader = New-Object System.IO.StreamReader($Stream)
    return $Reader.ReadToEnd()
  } finally {
    $Stream.Dispose()
  }
}

function Resolve-ApiLogPath {
  param([string]$BaseUrl)

  $Port = ""
  try {
    $Uri = [Uri]$BaseUrl
    if ($Uri.Port -gt 0) {
      $Port = [string]$Uri.Port
    }
  } catch {
    $Port = ""
  }

  $Candidates = @()
  if ($Port) {
    $Candidates += ".\assets\demo\api-$Port-after-reset-current.out.log"
    $Candidates += ".\assets\demo\local-api-$Port.out.log"
    $Candidates += ".\assets\demo\api-$Port.out.log"
    $Candidates += ".\assets\demo\api-$Port-session.out.log"
  }
  $Candidates += ".\assets\demo\local-api-8723.out.log"

  foreach ($Candidate in $Candidates) {
    if (Test-Path -LiteralPath $Candidate) {
      return $Candidate
    }
  }

  if ($Port) {
    return ".\assets\demo\api-$Port-after-reset-current.out.log"
  }
  return ".\assets\demo\local-api-8723.out.log"
}

New-ParentDirectory -Path $ResultJsonPath
if (-not $ApiLogPath) {
  $ApiLogPath = Resolve-ApiLogPath -BaseUrl $ApiBase
}

$StartedAt = Get-Date
$BeforeBytes = if (Test-Path -LiteralPath $ApiLogPath) { (Get-Item -LiteralPath $ApiLogPath).Length } else { 0 }
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$TaskBody = @{
  title = "Board speaker network due-audio probe"
  detail = "If the ESP32 is online, it should poll due-audio, download this TTS WAV, and play it through ES8311."
  due_text = "now"
  due_at = [double]($Now - 5)
  user_id = $UserId
  device_id = $DeviceId
} | ConvertTo-Json -Compress

Write-Host "HomeCue Edge ESP32 network due-audio speaker probe"
Write-Host ("API     : {0}" -f $ApiBase)
Write-Host ("User    : {0}" -f $UserId)
Write-Host ("Wait    : {0}s" -f $WaitSeconds)
Write-Host ("API log : {0}" -f $ApiLogPath)
Write-Host ""

$Created = Invoke-RestMethod -Uri "$ApiBase/voice-chat/tasks" -Method Post -ContentType "application/json; charset=utf-8" -Body $TaskBody
Write-Host ("Created task: {0}" -f $Created.task.task_id)

if ($WaitSeconds -gt 0) {
  Start-Sleep -Seconds $WaitSeconds
}

$AfterBytes = if (Test-Path -LiteralPath $ApiLogPath) { (Get-Item -LiteralPath $ApiLogPath).Length } else { 0 }
$NewLogText = Read-FileTailFromOffset -Path $ApiLogPath -Offset $BeforeBytes
$DueAudioMatches = [regex]::Matches($NewLogText, "GET /voice-chat/tasks/due-audio\?user_id=$([regex]::Escape($UserId))")
$AudioGetMatches = [regex]::Matches($NewLogText, "GET /voice-chat/audio/[^ ]+\.wav")
$BoardIpMatches = [regex]::Matches($NewLogText, "INFO:\s+(\d+\.\d+\.\d+\.\d+):\d+\s+-")
$BoardIps = @($BoardIpMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$Ok = $DueAudioMatches.Count -gt 0 -and $AudioGetMatches.Count -gt 0

Write-Host ("Log bytes: {0} -> {1}" -f $BeforeBytes, $AfterBytes)
Write-Host ("due-audio requests: {0}" -f $DueAudioMatches.Count)
Write-Host ("audio WAV requests : {0}" -f $AudioGetMatches.Count)
Write-Host ("client IPs        : {0}" -f $(if ($BoardIps.Count -gt 0) { $BoardIps -join ", " } else { "(none)" }))

$Result = [pscustomobject]@{
  checkedAt = (Get-Date).ToString("o")
  startedAt = $StartedAt.ToString("o")
  apiBase = $ApiBase
  userId = $UserId
  deviceId = $DeviceId
  waitSeconds = $WaitSeconds
  taskId = $Created.task.task_id
  apiLogPath = if (Test-Path -LiteralPath $ApiLogPath) { (Resolve-Path -LiteralPath $ApiLogPath).Path } else { $ApiLogPath }
  logBytesBefore = $BeforeBytes
  logBytesAfter = $AfterBytes
  dueAudioRequestCount = $DueAudioMatches.Count
  audioWavRequestCount = $AudioGetMatches.Count
  clientIps = [string[]]$BoardIps
  ok = [bool]$Ok
  newLogText = $NewLogText
}
$Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result: {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and -not $Ok) {
  exit 1
}

exit 0
