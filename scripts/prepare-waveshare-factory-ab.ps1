param(
  [string]$Port = "COM7",
  [string]$FactoryBinPath = "$env:TEMP\ESP32-S3-AUDIO-Board-Demo\ESP32-S3-AUDIO-Board-Demo\Firmware\ESP32-S3-AUDIO-Board.bin",
  [string]$EsptoolPython = "$env:USERPROFILE\miniconda3\python.exe",
  [string]$FlashAddress = "0x10000",
  [string]$RecoveryBuildPath = "",
  [string]$ApiHostOverride = "192.0.2.118",
  [string]$ApiPortOverride = "8723",
  [string]$ResultJsonPath = ".\assets\demo\waveshare-factory-ab-plan.json",
  [switch]$FlashFactory,
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

function Invoke-Capture {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )

  $Output = & $FilePath @Arguments 2>&1
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    output = [string]($Output -join "`n")
  }
}

New-ParentDirectory -Path $ResultJsonPath

if (-not $RecoveryBuildPath) {
  $RecoveryBuildPath = Join-Path $env:TEMP "homecue-edge-esp32-factory-ab-recovery-build"
}

$FactoryExists = Test-Path -LiteralPath $FactoryBinPath
$FactoryInfo = $null
$FactoryLength = $null
if ($FactoryExists) {
  $FactoryItem = Get-Item -LiteralPath $FactoryBinPath
  $FactoryLength = $FactoryItem.Length
  $FactoryInfo = Invoke-Capture -FilePath $EsptoolPython -Arguments @(
    "-m", "esptool",
    "--chip", "esp32s3",
    "image_info",
    $FactoryItem.FullName
  )
}

$FactoryCommand = @(
  $EsptoolPython,
  "-m", "esptool",
  "--chip", "esp32s3",
  "--port", $Port,
  "--baud", "115200",
  "write_flash",
  $FlashAddress,
  $FactoryBinPath
)

$RecoveryCommand = @(
  ".\scripts\flash-esp32.ps1",
  "-Port", $Port,
  "-Clean",
  "-Upload",
  "-EnableEspSr",
  "-EnableSpeakerOutput",
  "-DiagHttpServer",
  "-EspSrWakeKeyword", "jarvis",
  "-BuildPath", $RecoveryBuildPath,
  "-UploadSpeed", "115200",
  "-UploadMode", "cdc",
  "-ApiHostOverride", $ApiHostOverride,
  "-ApiPortOverride", $ApiPortOverride
)

$FlashResult = $null
if ($FlashFactory) {
  if (-not $FactoryExists) {
    throw "Factory binary not found: $FactoryBinPath"
  }

  Write-Host "Flashing Waveshare factory app image."
  Write-Host "This is intentionally not the default path. Keep the board in a safe acoustic setup."
  $FlashResult = Invoke-Capture -FilePath $EsptoolPython -Arguments @(
    "-m", "esptool",
    "--chip", "esp32s3",
    "--port", $Port,
    "--baud", "115200",
    "write_flash",
    $FlashAddress,
    (Resolve-Path -LiteralPath $FactoryBinPath).Path
  )
}

$Result = [pscustomobject]@{
  checkedAt = (Get-Date).ToString("o")
  port = $Port
  factoryBinPath = $FactoryBinPath
  factoryBinExists = [bool]$FactoryExists
  factoryBinLength = $FactoryLength
  flashAddress = $FlashAddress
  dryRun = -not [bool]$FlashFactory
  safety = @{
    unboundedFactoryAudio = $true
    requirePhysicalChecksFirst = $true
    requireSafeAcousticSetup = $true
    recoveryCommandPrepared = $true
  }
  factoryImageInfo = $FactoryInfo
  factoryFlashCommand = $FactoryCommand -join " "
  recoveryCommand = $RecoveryCommand -join " "
  flashResult = $FlashResult
  recommendation = if ($FlashFactory) {
    "After factory demo observation, run the recovery command to restore HomeCue firmware."
  } else {
    "Dry run only. Run with -FlashFactory only after cable, speaker, and AC-output checks justify factory A/B."
  }
}

$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result: {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
Write-Host ("dryRun: {0}" -f $Result.dryRun)
Write-Host ("factoryBinExists: {0}" -f $Result.factoryBinExists)
Write-Host ("factoryBinLength: {0}" -f $Result.factoryBinLength)
Write-Host ("factoryFlashCommand: {0}" -f $Result.factoryFlashCommand)
Write-Host ("recoveryCommand: {0}" -f $Result.recoveryCommand)

if ($Required -and (-not $FactoryExists -or ($FactoryInfo -and $FactoryInfo.exitCode -ne 0))) {
  exit 1
}

if ($FlashFactory -and $FlashResult -and $FlashResult.exitCode -ne 0) {
  exit $FlashResult.exitCode
}

exit 0
