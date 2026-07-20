param(
  [string]$SrModelsBin = "",
  [string]$RequiredWakeKeyword = "hiesp",
  [string]$RequiredMultinetKeyword = "english",
  [string[]]$ProbeWakeKeyword = @("xiaoqian", "nihaoxiaozhi", "nihaoxiaoxin"),
  [string[]]$BlockedModelName = @("wn9s_nihaoxiaozhi"),
  [string]$ResultJsonPath = ".\assets\demo\esp32-sr-models-check.json",
  [switch]$AllowBlockedModel,
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

function Find-DefaultSrModelsBin {
  $Candidates = @(
    (Join-Path $env:LOCALAPPDATA "Arduino15\packages\esp32\tools\esp32-arduino-libs\idf-release_v5.1-632e0c2a\esp32s3\esp_sr\srmodels.bin"),
    (Join-Path $env:TEMP "homecue-edge-esp32-sr-build\srmodels.bin")
  )

  foreach ($Candidate in $Candidates) {
    if (Test-Path -LiteralPath $Candidate) {
      return $Candidate
    }
  }

  $Found = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Arduino15\packages\esp32") -Recurse -File -Filter srmodels.bin -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($Found) {
    return $Found.FullName
  }

  return ""
}

function Test-Keyword {
  param(
    [string]$Text,
    [string]$Keyword
  )
  if (-not $Keyword) {
    return $true
  }
  return $Text.IndexOf($Keyword, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

New-ParentDirectory -Path $ResultJsonPath

if (-not $SrModelsBin) {
  $SrModelsBin = Find-DefaultSrModelsBin
}
if (-not $SrModelsBin -or -not (Test-Path -LiteralPath $SrModelsBin)) {
  throw "srmodels.bin not found. Pass -SrModelsBin explicitly."
}

$ResolvedPath = (Resolve-Path -LiteralPath $SrModelsBin).Path
$Bytes = [IO.File]::ReadAllBytes($ResolvedPath)
$Text = [Text.Encoding]::ASCII.GetString($Bytes)

$ModelNames = [regex]::Matches($Text, "(wn[0-9a-z_]+|mn[0-9a-z_]+)") |
  ForEach-Object { $_.Value } |
  Select-Object -Unique

$InfoStrings = [regex]::Matches($Text, "(wakeNet[0-9A-Za-z_,.\-]+|MN[0-9A-Za-z_,.\-]+)") |
  ForEach-Object { $_.Value } |
  Select-Object -Unique

$ProbeResults = @()
foreach ($Keyword in $ProbeWakeKeyword) {
  $ProbeResults += [pscustomobject]@{
    keyword = $Keyword
    present = [bool](Test-Keyword -Text $Text -Keyword $Keyword)
  }
}

$BlockedModelsPresent = @()
foreach ($ModelName in $BlockedModelName) {
  if (Test-Keyword -Text $Text -Keyword $ModelName) {
    $BlockedModelsPresent += $ModelName
  }
}

$HasRequiredWake = Test-Keyword -Text $Text -Keyword $RequiredWakeKeyword
$HasRequiredMultinet = Test-Keyword -Text $Text -Keyword $RequiredMultinetKeyword
$HasBlockedModel = $BlockedModelsPresent.Count -gt 0
$BlockedOk = (-not $HasBlockedModel) -or $AllowBlockedModel
$Status = if ($HasRequiredWake -and $HasRequiredMultinet -and $BlockedOk) { "passed" } else { "failed" }

$Result = @{
  status = $Status
  path = $ResolvedPath
  length = $Bytes.Length
  requiredWakeKeyword = $RequiredWakeKeyword
  requiredWakePresent = [bool]$HasRequiredWake
  requiredMultinetKeyword = $RequiredMultinetKeyword
  requiredMultinetPresent = [bool]$HasRequiredMultinet
  probeWakeKeywords = $ProbeResults
  blockedModelNames = [string[]]$BlockedModelName
  blockedModelsPresent = [string[]]$BlockedModelsPresent
  blockedModelOverride = [bool]$AllowBlockedModel
  modelNames = [string[]]$ModelNames
  infoStrings = [string[]]$InfoStrings
}

$Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8

Write-Host "HomeCue Edge ESP-SR model check"
Write-Host ("Model  : {0}" -f $ResolvedPath)
Write-Host ("Size   : {0} bytes" -f $Bytes.Length)
Write-Host ("Wake   : {0} -> {1}" -f $RequiredWakeKeyword, $HasRequiredWake)
Write-Host ("Multi  : {0} -> {1}" -f $RequiredMultinetKeyword, $HasRequiredMultinet)
foreach ($Probe in $ProbeResults) {
  Write-Host ("Probe  : {0} -> {1}" -f $Probe.keyword, $Probe.present)
}
if ($BlockedModelsPresent.Count -gt 0) {
  $BlockedText = $BlockedModelsPresent -join ", "
  $Suffix = if ($AllowBlockedModel) { " (override enabled)" } else { "" }
  Write-Host ("Blocked: {0}{1}" -f $BlockedText, $Suffix)
} else {
  Write-Host "Blocked: none"
}
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Status -ne "passed") {
  Write-Host "ESP-SR model check failed required item(s)." -ForegroundColor Red
  exit 1
}

exit 0
