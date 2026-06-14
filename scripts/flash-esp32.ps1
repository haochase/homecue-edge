param(
  [string]$Port = "COM7",
  [string]$CliPath = "",
  [string]$BuildPath = "",
  [ValidateSet("921600", "115200", "256000", "230400", "512000")]
  [string]$UploadSpeed = "921600",
  [switch]$Upload,
  [switch]$Clean,
  [switch]$VerifyUpload
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$SketchDir = Join-Path $Root "firmware\esp32-audio"
$SketchPath = Join-Path $SketchDir "esp32-audio.ino"
$SecretsPath = Join-Path $SketchDir "secrets.h"
$DefaultToolPath = Join-Path $env:USERPROFILE ".codex\tools\arduino-cli\arduino-cli.exe"

function Resolve-ArduinoCli {
  param([string]$RequestedPath)

  if ($RequestedPath) {
    if (-not (Test-Path -LiteralPath $RequestedPath)) {
      throw "arduino-cli not found at -CliPath '$RequestedPath'"
    }
    return (Resolve-Path -LiteralPath $RequestedPath).Path
  }

  $FromPath = Get-Command "arduino-cli" -ErrorAction SilentlyContinue
  if ($FromPath) {
    return $FromPath.Source
  }

  if (Test-Path -LiteralPath $DefaultToolPath) {
    return $DefaultToolPath
  }

  throw "arduino-cli not found. Install it or pass -CliPath."
}

function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )

  Write-Host ("> {0} {1}" -f $FilePath, ($Arguments -join " "))
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
  }
}

function Test-SerialPortAvailable {
  param([string]$Name)

  try {
    $SerialPort = New-Object System.IO.Ports.SerialPort $Name, 115200
    $SerialPort.Open()
    $SerialPort.Close()
    return $true
  } catch {
    Write-Host ("Serial port {0} is not currently openable: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Yellow
    Write-Host "Close Arduino IDE Serial Monitor or any other serial terminal, then retry." -ForegroundColor Yellow
    return $false
  }
}

if (-not (Test-Path -LiteralPath $SketchPath)) {
  throw "Firmware sketch not found: $SketchPath"
}

if (-not (Test-Path -LiteralPath $SecretsPath)) {
  throw "Missing firmware secrets file: $SecretsPath. Copy secrets.h.example to secrets.h and fill local Wi-Fi/API host values."
}

$ArduinoCli = Resolve-ArduinoCli -RequestedPath $CliPath

if (-not $BuildPath) {
  $BuildPath = Join-Path $env:TEMP "homecue-edge-esp32-build"
}
$BuildPath = [System.IO.Path]::GetFullPath($BuildPath)
New-Item -ItemType Directory -Force -Path $BuildPath | Out-Null

$Fqbn = "esp32:esp32:esp32s3:UploadSpeed=$UploadSpeed,USBMode=hwcdc,CDCOnBoot=cdc,MSCOnBoot=default,DFUOnBoot=default,UploadMode=default,CPUFreq=240,FlashMode=qio,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,DebugLevel=none,PSRAM=opi,LoopCore=1,EventsCore=1,EraseFlash=none,JTAGAdapter=default,ZigbeeMode=default"

Write-Host "HomeCue Edge ESP32 firmware flash helper"
Write-Host ("Sketch : {0}" -f $SketchDir)
Write-Host ("CLI    : {0}" -f $ArduinoCli)
Write-Host ("FQBN   : {0}" -f $Fqbn)
Write-Host ("Build  : {0}" -f $BuildPath)
Write-Host ("Port   : {0}" -f $Port)
Write-Host ""

$CompileArgs = @(
  "compile",
  "--fqbn", $Fqbn,
  "--build-path", $BuildPath,
  "--output-dir", $BuildPath,
  "--warnings", "default"
)
if ($Clean) {
  $CompileArgs += "--clean"
}
$CompileArgs += $SketchDir

Invoke-Checked -FilePath $ArduinoCli -Arguments $CompileArgs

if ($Upload) {
  if (-not (Test-SerialPortAvailable -Name $Port)) {
    throw "Serial port $Port is busy or unavailable."
  }

  $UploadArgs = @(
    "upload",
    "--fqbn", $Fqbn,
    "--port", $Port,
    "--input-dir", $BuildPath
  )
  if ($VerifyUpload) {
    $UploadArgs += "--verify"
  }
  $UploadArgs += $SketchDir
  Invoke-Checked -FilePath $ArduinoCli -Arguments $UploadArgs
}

Write-Host "ESP32 firmware flow complete."
