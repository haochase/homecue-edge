param(
  [string]$BoardBaseUrl = "http://192.0.2.107",
  [string]$WaveshareAbSummaryPath = ".\assets\demo\waveshare-speaker-ab-safe-20260618-rerun.summary.json",
  [string]$ReminderCheckPath = ".\assets\demo\esp32-check-door-lock-reproduce-20260618.check.json",
  [string]$ResultJsonPath = ".\assets\demo\speaker-physical-evidence-current.json",
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

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Test-JsonOk {
  param([object]$Object)
  if (-not $Object) {
    return $false
  }
  if ($null -ne $Object.ok) {
    return [bool]$Object.ok
  }
  if ($null -ne $Object.failures) {
    return $Object.failures.Count -eq 0
  }
  return $true
}

New-ParentDirectory -Path $ResultJsonPath

$BoardHealth = $null
$BoardHealthError = ""
try {
  $BoardHealth = Invoke-RestMethod -Uri "$($BoardBaseUrl.TrimEnd('/'))/health" -TimeoutSec 5
} catch {
  $BoardHealthError = $_.Exception.Message
}

$WaveshareAb = Read-JsonFile -Path $WaveshareAbSummaryPath
$ReminderCheck = Read-JsonFile -Path $ReminderCheckPath

$BoardHealthOk = $BoardHealth -and
  $BoardHealth.status -eq "ok" -and
  $BoardHealth.speaker_output_enabled -eq $true -and
  $BoardHealth.speaker_pa_enabled -eq $false -and
  $BoardHealth.i2s_ready -eq $true -and
  $BoardHealth.es8311_ready -eq $true
$WaveshareAbOk = Test-JsonOk -Object $WaveshareAb
$ReminderOk = Test-JsonOk -Object $ReminderCheck

$Result = [pscustomobject]@{
  checkedAt = (Get-Date).ToString("o")
  boardBaseUrl = $BoardBaseUrl
  boardHealthOk = [bool]$BoardHealthOk
  boardHealth = $BoardHealth
  boardHealthError = $BoardHealthError
  reminderCheckPath = $ReminderCheckPath
  reminderOk = [bool]$ReminderOk
  reminderCheck = $ReminderCheck
  waveshareAbSummaryPath = $WaveshareAbSummaryPath
  waveshareAbOk = [bool]$WaveshareAbOk
  waveshareAb = $WaveshareAb
  physicalEvidenceRequired = @{
    speakerHeaderConnector = "missing"
    speakerCableReplacementOrRework = "missing"
    knownGoodSpeakerReplacement = "missing"
    speakerHeaderAcMeasurement = "missing"
    humanAudibleConfirmation = "missing"
  }
  nextDecision = "Continue physical checks before changing firmware volume or switching hardware."
  okForSoftwareBoundary = [bool]($BoardHealthOk -and $WaveshareAbOk -and $ReminderOk)
  complete = $false
}

$Result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result: {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
Write-Host ("software boundary ok: {0}" -f $Result.okForSoftwareBoundary)
Write-Host "physical evidence required: speaker cable, known-good speaker, speaker-header AC measurement, human audible confirmation"

if ($Required -and -not $Result.okForSoftwareBoundary) {
  exit 1
}

exit 0
