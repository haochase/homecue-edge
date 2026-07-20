param(
  [string]$EspSrComponentRoot = "",
  [string]$WakeModelName = "wn9_nihaoxiaozhi",
  [string]$MultiNetModelName = "mn5q8_en",
  [string]$OutputPath = "",
  [string[]]$BlockedModelName = @("wn9s_nihaoxiaozhi"),
  [switch]$AllowBlockedModel,
  [string]$ResultJsonPath = ".\assets\demo\esp32-sr-model-pack.json",
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

function Resolve-EspSrComponentRoot {
  param([string]$RequestedRoot)

  if ($RequestedRoot) {
    if (-not (Test-Path -LiteralPath $RequestedRoot)) {
      throw "ESP-SR component root not found: $RequestedRoot"
    }
    return (Resolve-Path -LiteralPath $RequestedRoot).Path
  }

  $Candidate = Join-Path $env:TEMP "esp-sr-2.4.6-component\esp-sr"
  if (Test-Path -LiteralPath $Candidate) {
    return (Resolve-Path -LiteralPath $Candidate).Path
  }

  throw "ESP-SR component root not found. Pass -EspSrComponentRoot."
}

function Get-DirectorySize {
  param([string]$Path)

  $Files = Get-ChildItem -LiteralPath $Path -Recurse -File
  if (-not $Files) {
    return 0
  }
  return ($Files | Measure-Object Length -Sum).Sum
}

function Test-BinaryContainsKeyword {
  param(
    [string]$Path,
    [string]$Keyword
  )

  if (-not $Keyword) {
    return $true
  }
  $Bytes = [IO.File]::ReadAllBytes($Path)
  $Text = [Text.Encoding]::ASCII.GetString($Bytes)
  return $Text.IndexOf($Keyword, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Assert-ModelAllowed {
  param([string[]]$ModelNames)

  if ($AllowBlockedModel) {
    return
  }

  $Present = @()
  foreach ($ModelName in $ModelNames) {
    if ($BlockedModelName -contains $ModelName) {
      $Present += $ModelName
    }
  }

  if ($Present.Count -gt 0) {
    throw ("Refusing blocked ESP-SR model(s): {0}. Use -AllowBlockedModel only for a deliberate recovery-aware experiment." -f ($Present -join ", "))
  }
}

New-ParentDirectory -Path $ResultJsonPath

$Root = Resolve-Path "$PSScriptRoot\.."
$ComponentRoot = Resolve-EspSrComponentRoot -RequestedRoot $EspSrComponentRoot
$ModelRoot = Join-Path $ComponentRoot "model"
$PackTool = Join-Path $ModelRoot "pack_model.py"
if (-not (Test-Path -LiteralPath $PackTool)) {
  throw "ESP-SR pack_model.py not found: $PackTool"
}

Assert-ModelAllowed -ModelNames @($WakeModelName, $MultiNetModelName)

$WakeModelPath = Join-Path $ModelRoot ("wakenet_model\{0}" -f $WakeModelName)
$MultiNetModelPath = Join-Path $ModelRoot ("multinet_model\{0}" -f $MultiNetModelName)
if (-not (Test-Path -LiteralPath $WakeModelPath)) {
  throw "WakeNet model not found: $WakeModelPath"
}
if (-not (Test-Path -LiteralPath $MultiNetModelPath)) {
  throw "MultiNet model not found: $MultiNetModelPath"
}

if (-not $OutputPath) {
  $OutputPath = Join-Path $env:TEMP ("homecue-srmodels-{0}-{1}.bin" -f $WakeModelName, $MultiNetModelName)
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
New-ParentDirectory -Path $OutputPath

$WorkDir = Join-Path $env:TEMP ("homecue-srmodels-pack-{0}-{1}" -f $WakeModelName, $MultiNetModelName)
if (Test-Path -LiteralPath $WorkDir) {
  Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

Copy-Item -LiteralPath $WakeModelPath -Destination (Join-Path $WorkDir $WakeModelName) -Recurse -Force
Copy-Item -LiteralPath $MultiNetModelPath -Destination (Join-Path $WorkDir $MultiNetModelName) -Recurse -Force

Write-Host "HomeCue Edge ESP-SR model pack"
Write-Host ("ESP-SR : {0}" -f $ComponentRoot)
Write-Host ("Wake   : {0}" -f $WakeModelName)
Write-Host ("Multi  : {0}" -f $MultiNetModelName)
Write-Host ("Output : {0}" -f $OutputPath)
Write-Host ""

python $PackTool -m $WorkDir -o $OutputPath
if ($LASTEXITCODE -ne 0) {
  throw "pack_model.py failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
  throw "Model pack was not created: $OutputPath"
}

$Length = (Get-Item -LiteralPath $OutputPath).Length
$WakePresent = Test-BinaryContainsKeyword -Path $OutputPath -Keyword $WakeModelName
$MultiPresent = Test-BinaryContainsKeyword -Path $OutputPath -Keyword $MultiNetModelName
$Status = if ($WakePresent -and $MultiPresent) { "passed" } else { "failed" }

$Result = @{
  status = $Status
  componentRoot = $ComponentRoot
  workDir = $WorkDir
  outputPath = $OutputPath
  length = $Length
  wakeModelName = $WakeModelName
  wakeModelPresent = [bool]$WakePresent
  wakeModelBytes = [int64](Get-DirectorySize -Path (Join-Path $WorkDir $WakeModelName))
  multiNetModelName = $MultiNetModelName
  multiNetModelPresent = [bool]$MultiPresent
  multiNetModelBytes = [int64](Get-DirectorySize -Path (Join-Path $WorkDir $MultiNetModelName))
  blockedModelNames = [string[]]$BlockedModelName
  blockedModelOverride = [bool]$AllowBlockedModel
}

$Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8

Write-Host ("Size   : {0} bytes" -f $Length)
Write-Host ("WakeOk : {0}" -f $WakePresent)
Write-Host ("MultiOk: {0}" -f $MultiPresent)
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Status -ne "passed") {
  Write-Host "ESP-SR model pack failed required item(s)." -ForegroundColor Red
  exit 1
}

exit 0
