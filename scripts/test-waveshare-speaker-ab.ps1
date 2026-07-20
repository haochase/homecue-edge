param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [ValidateRange(1, 3)]
  [int]$ToneSeconds = 1,
  [ValidateRange(0, 21)]
  [int]$Volume = 12,
  [ValidateRange(0, 5000)]
  [int]$Amplitude = 1200,
  [string]$OutputPrefix = ".\assets\demo\waveshare-speaker-ab-20260618",
  [switch]$SkipReset,
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

function Invoke-ToneCase {
  param(
    [string]$CaseName,
    [string]$WriteMode
  )

  $LogPath = "$OutputPrefix-$CaseName.log"
  $CheckPath = "$OutputPrefix-$CaseName.check.json"
  New-ParentDirectory -Path $LogPath
  New-ParentDirectory -Path $CheckPath

  $ScriptPath = Join-Path $PSScriptRoot "test-esp32-speaker-tone.ps1"
  if ($SkipReset) {
    & $ScriptPath `
      -Port $Port `
      -Baud $Baud `
      -Seconds 18 `
      -StartAfterSeconds 3 `
      -ToneSeconds $ToneSeconds `
      -ToneMode both `
      -Volume $Volume `
      -Amplitude $Amplitude `
      -WriteMode $WriteMode `
      -MicProbe `
      -SaveLogPath $LogPath `
      -ResultJsonPath $CheckPath `
      -SkipReset `
      -Required
  } else {
    & $ScriptPath `
      -Port $Port `
      -Baud $Baud `
      -Seconds 18 `
      -StartAfterSeconds 3 `
      -ToneSeconds $ToneSeconds `
      -ToneMode both `
      -Volume $Volume `
      -Amplitude $Amplitude `
      -WriteMode $WriteMode `
      -MicProbe `
      -SaveLogPath $LogPath `
      -ResultJsonPath $CheckPath `
      -Required
  }
  $CommandSucceeded = $?
  $Result = Read-JsonFile -Path $CheckPath
  $CaseOk = [bool]($CommandSucceeded -and $Result -and $Result.failures.Count -eq 0)
  return [pscustomobject]@{
    caseName = $CaseName
    writeMode = $WriteMode
    commandSucceeded = [bool]$CommandSucceeded
    ok = $CaseOk
    logPath = if (Test-Path -LiteralPath $LogPath) { (Resolve-Path -LiteralPath $LogPath).Path } else { $LogPath }
    checkPath = if (Test-Path -LiteralPath $CheckPath) { (Resolve-Path -LiteralPath $CheckPath).Path } else { $CheckPath }
    result = $Result
  }
}

New-ParentDirectory -Path "$OutputPrefix.summary.json"

Write-Host "HomeCue Edge Waveshare speaker A/B"
Write-Host ("Port      : {0} @ {1}" -f $Port, $Baud)
Write-Host ("Tone      : {0}s both, volume={1}, amplitude={2}" -f $ToneSeconds, $Volume, $Amplitude)
Write-Host ("Output    : {0}" -f $OutputPrefix)
Write-Host ""

$Cases = @(
  (Invoke-ToneCase -CaseName "official-mclk-sample32" -WriteMode "sample32"),
  (Invoke-ToneCase -CaseName "official-bclk-sample32bclk" -WriteMode "sample32bclk")
)

$Failures = @($Cases | Where-Object { -not $_.ok })
$Summary = [pscustomobject]@{
  checkedAt = (Get-Date).ToString("o")
  source = "waveshare-official-parameter-ab"
  port = $Port
  baud = $Baud
  toneSeconds = $ToneSeconds
  toneMode = "both"
  volume = $Volume
  amplitude = $Amplitude
  officialMapping = @{
    pa = "EXIO8 / GPIO_PWR_CTRL"
    dac = "ES8311"
    i2s = "I2S standard stereo"
    sample32 = "16-bit sample shifted into 32-bit slots"
    sample32bclk = "same 32-bit slots with ES8311 BCLK-derived internal clock"
  }
  cases = $Cases
  ok = [bool]($Failures.Count -eq 0)
  failures = @($Failures | ForEach-Object { $_.caseName })
  humanAudibleConfirmationRequired = $true
  notes = @(
    "This does not flash the unbounded Waveshare factory binary.",
    "It maps the official playback parameters onto the bounded HomeCue diagnostic firmware.",
    "If both cases pass but no sound is heard, continue with speaker header, cable, speaker unit, and PA output measurement."
  )
}

$SummaryPath = "$OutputPrefix.summary.json"
$Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
Write-Host ""
Write-Host ("Summary: {0}" -f (Resolve-Path -LiteralPath $SummaryPath).Path)

if ($Required -and -not $Summary.ok) {
  exit 1
}

exit 0
