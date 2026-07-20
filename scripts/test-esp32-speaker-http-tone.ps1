param(
  [string]$BoardBaseUrl = "",
  [string]$ApiLogPath = ".\assets\demo\local-api-8723.out.log",
  [ValidateRange(1, 3)]
  [int]$Seconds = 1,
  [ValidateSet("all", "both", "left", "right", "sweep")]
  [string]$ToneMode = "all",
  [ValidateRange(0, 32)]
  [int]$Volume = 18,
  [ValidateRange(0, 5000)]
  [int]$Amplitude = 1800,
  [ValidateSet("buffer", "sample")]
  [string]$WriteMode = "buffer",
  [string]$ResultJsonPath = ".\assets\demo\esp32-speaker-http-tone-check.json",
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

function Get-RecentBoardBaseUrl {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return ""
  }

  $Text = Get-Content -Raw -LiteralPath $Path
  $Matches = [regex]::Matches($Text, "INFO:\s+(\d+\.\d+\.\d+\.\d+):\d+\s+-\s+`"(?:GET|POST|WebSocket) /(?:health|voice-chat)")
  if ($Matches.Count -eq 0) {
    return ""
  }
  $Ip = $Matches[$Matches.Count - 1].Groups[1].Value
  return "http://$Ip"
}

New-ParentDirectory -Path $ResultJsonPath

if (-not $BoardBaseUrl) {
  $BoardBaseUrl = Get-RecentBoardBaseUrl -Path $ApiLogPath
}
if (-not $BoardBaseUrl) {
  throw "BoardBaseUrl is required when no ESP32 IP can be inferred from $ApiLogPath."
}

$BoardBaseUrl = $BoardBaseUrl.TrimEnd("/")
$Health = $null
$Tone = $null
$HealthOk = $false
$ToneOk = $false
$ErrorMessage = ""
$SpeakerOutputEnabled = $null

Write-Host "HomeCue Edge ESP32 HTTP speaker tone test"
Write-Host ("Board : {0}" -f $BoardBaseUrl)
Write-Host ("Tone  : {0}s / {1} / volume={2} / amplitude={3} / write={4}" -f $Seconds, $ToneMode, $Volume, $Amplitude, $WriteMode)

try {
  $Health = Invoke-RestMethod -Uri "$BoardBaseUrl/health" -TimeoutSec 10
  $HealthOk = $Health.status -eq "ok"
  $SpeakerOutputEnabled = $Health.speaker_output_enabled
  $ToneUri = "{0}/speaker-test?seconds={1}&mode={2}&volume={3}&amplitude={4}&write={5}" -f $BoardBaseUrl, $Seconds, $ToneMode, $Volume, $Amplitude, $WriteMode
  $Tone = Invoke-RestMethod -Uri $ToneUri -TimeoutSec ([Math]::Max(20, $Seconds + 15))
  $ToneOk = [bool]$Tone.ok
} catch {
  $ErrorMessage = $_.Exception.Message
}

Write-Host ("health: {0}" -f $(if ($HealthOk) { "ok" } else { "failed" }))
Write-Host ("tone  : {0}" -f $(if ($ToneOk) { "ok" } else { "failed" }))
if ($ErrorMessage) {
  Write-Host ("error : {0}" -f $ErrorMessage) -ForegroundColor Yellow
}

$Result = [pscustomobject]@{
  checkedAt = (Get-Date).ToString("o")
  boardBaseUrl = $BoardBaseUrl
  seconds = $Seconds
  toneMode = $ToneMode
  volume = $Volume
  amplitude = $Amplitude
  writeMode = $WriteMode
  healthOk = [bool]$HealthOk
  toneOk = [bool]$ToneOk
  health = $Health
  tone = $Tone
  speakerOutputEnabled = $SpeakerOutputEnabled
  error = $ErrorMessage
  humanAudibleConfirmationRequired = $true
  requiredMode = [bool]$Required
}
$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result: {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and (-not $HealthOk -or -not $ToneOk)) {
  exit 1
}

exit 0
