param(
  [string]$Port = "COM7",
  [string]$CliPath = "",
  [string]$BuildPath = "",
  [ValidateSet("921600", "115200", "256000", "230400", "512000")]
  [string]$UploadSpeed = "921600",
  [ValidateSet("default", "cdc")]
  [string]$UploadMode = "default",
  [switch]$Upload,
  [switch]$Clean,
  [switch]$VerifyUpload,
  [switch]$EnableEspSr,
  [string]$EspSrModelsBin = "",
  [string]$EspSrWakeKeyword = "hiesp",
  [switch]$BootSpeakerTest,
  [ValidateRange(1, 3)]
  [int]$BootSpeakerTestSeconds = 1,
  [ValidateSet("all", "both", "left", "right", "sweep")]
  [string]$BootSpeakerTestMode = "all",
  [switch]$EnableSpeakerOutput,
  [switch]$DiagHttpServer,
  [string]$ApiHostOverride = "",
  [string]$ApiPortOverride = "",
  [string]$VoiceChatAccessTokenOverride = "",
  [string[]]$BlockedEspSrModelName = @("wn9s_nihaoxiaozhi"),
  [switch]$AllowBlockedEspSrModel
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$SketchDir = Join-Path $Root "firmware\esp32-audio"
$SketchPath = Join-Path $SketchDir "esp32-audio.ino"
$SecretsPath = Join-Path $SketchDir "secrets.h"
$DefaultToolPath = Join-Path $env:USERPROFILE ".codex\tools\arduino-cli\arduino-cli.exe"
$ArduinoEsp32Root = Join-Path $env:LOCALAPPDATA "Arduino15\packages\esp32\hardware\esp32\3.0.7"

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

function Show-DownloadModeHelp {
  param([string]$Name)

  Write-Host ""
  Write-Host ("{0} enumerates but is not accepting writes." -f $Name) -ForegroundColor Yellow
  Write-Host "The board is most likely stuck in a crashed/hung firmware state, so its" -ForegroundColor Yellow
  Write-Host "USB-Serial endpoint never drains and esptool reports 'Write timeout'." -ForegroundColor Yellow
  Write-Host "esptool cannot reset a hung board into the ROM loader by itself - put it" -ForegroundColor Yellow
  Write-Host "into download mode manually, then re-run this command:" -ForegroundColor Yellow
  Write-Host "  1. Hold BOOT." -ForegroundColor Yellow
  Write-Host "  2. While holding BOOT, tap RESET (or unplug/replug the USB cable)." -ForegroundColor Yellow
  Write-Host "  3. Release BOOT. The board is now in ROM download mode." -ForegroundColor Yellow
  Write-Host ("  4. Re-run: flash-esp32.ps1 -Port {0} -EnableEspSr -Upload" -f $Name) -ForegroundColor Yellow
  Write-Host ""
}

function Copy-DirectoryContents {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    throw "Source directory not found: $Source"
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Initialize-CustomEspSrLibrary {
  param(
    [string]$SketchWorkParent,
    [string]$WakeKeyword
  )

  $SourceLibrary = Join-Path $ArduinoEsp32Root "libraries\ESP_SR"
  $LocalLibraries = Join-Path $SketchWorkParent "libraries"
  $LocalEspSr = Join-Path $LocalLibraries "ESP_SR"
  Copy-DirectoryContents -Source $SourceLibrary -Destination $LocalEspSr

  $HalPath = Join-Path $LocalEspSr "src\esp32-hal-sr.c"
  $HalText = Get-Content -LiteralPath $HalPath -Raw -Encoding UTF8
  $Pattern = 'esp_srmodel_filter\(models,\s*ESP_WN_PREFIX,\s*"[^"]+"\)'
  $Replacement = 'esp_srmodel_filter(models, ESP_WN_PREFIX, "' + $WakeKeyword + '")'
  $Updated = [regex]::Replace($HalText, $Pattern, $Replacement, 1)
  if ($Updated -eq $HalText) {
    throw "Failed to patch ESP_SR WakeNet keyword in $HalPath"
  }
  Set-Content -LiteralPath $HalPath -Value $Updated -Encoding UTF8
  return $LocalEspSr
}

function Set-FirmwareSecretDefine {
  param(
    [string]$Path,
    [string]$Name,
    [string]$Value
  )

  if (-not $Value) {
    return
  }

  if ($Value -notmatch "^[A-Za-z0-9_.:~+\/=-]+$") {
    throw "-$Name override contains unsupported characters. Use a URL-safe token, LAN host/IP, or port."
  }

  $Text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $Pattern = "(?m)^#define\s+$([regex]::Escape($Name))\s+`"[^`"]*`""
  $Replacement = "#define $Name  `"$Value`""
  if (-not [regex]::IsMatch($Text, $Pattern)) {
    $Updated = $Text.TrimEnd() + "`n$Replacement`n"
    Set-Content -LiteralPath $Path -Value $Updated -Encoding UTF8
    return
  }
  $Updated = [regex]::Replace($Text, $Pattern, $Replacement, 1)
  Set-Content -LiteralPath $Path -Value $Updated -Encoding UTF8
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

function Get-BinaryPresentKeywords {
  param(
    [string]$Path,
    [string[]]$Keywords
  )

  if (-not $Keywords -or $Keywords.Count -eq 0) {
    return @()
  }

  $Bytes = [IO.File]::ReadAllBytes($Path)
  $Text = [Text.Encoding]::ASCII.GetString($Bytes)
  $Present = @()
  foreach ($Keyword in $Keywords) {
    if ($Keyword -and $Text.IndexOf($Keyword, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      $Present += $Keyword
    }
  }
  return $Present
}

function Assert-EspSrModelAllowed {
  param([string]$Path)

  if (-not $Path -or $AllowBlockedEspSrModel) {
    return
  }

  $Present = @(Get-BinaryPresentKeywords -Path $Path -Keywords $BlockedEspSrModelName)
  if ($Present.Count -gt 0) {
    $Message = ("ESP-SR model image contains blocked model(s): {0}. " +
      "These model(s) are blocked because they caused ESP-SR init crashes in hardware testing. " +
      "Use -AllowBlockedEspSrModel only for a deliberate recovery-aware experiment.") -f ($Present -join ", ")
    throw $Message
  }
}

# Returns the port state so we can fail fast (and with actionable guidance)
# instead of running a long compile that ends in a cryptic upload 'Write timeout'.
# A board running hung firmware still ENUMERATES and OPENS, but its USB-Serial
# OUT endpoint never drains, so a tiny write times out - that is the signal that
# manual ROM download mode is required (see Show-DownloadModeHelp).
function Test-SerialPortWritable {
  param([string]$Name)

  $SerialPort = New-Object System.IO.Ports.SerialPort $Name, 115200
  $SerialPort.WriteTimeout = 1500
  try {
    $SerialPort.Open()
  } catch {
    Write-Host ("Serial port {0} is not currently openable: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Yellow
    Write-Host "Close Arduino IDE Serial Monitor or any other serial terminal, then retry." -ForegroundColor Yellow
    return "busy"
  }

  try {
    # A lone newline is harmless: the firmware serial parser ignores empty lines
    # and the ROM loader resyncs on its own. A timeout here means the board is hung.
    $SerialPort.Write([byte[]](0x0A), 0, 1)
    return "writable"
  } catch [System.TimeoutException] {
    return "hung"
  } catch {
    Write-Host ("Serial port {0} write probe failed: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Yellow
    return "hung"
  } finally {
    if ($SerialPort.IsOpen) { $SerialPort.Close() }
  }
}

if (-not (Test-Path -LiteralPath $SketchPath)) {
  throw "Firmware sketch not found: $SketchPath"
}

if (-not (Test-Path -LiteralPath $SecretsPath)) {
  throw "Missing firmware secrets file: $SecretsPath. Copy secrets.h.example to secrets.h and fill local Wi-Fi/API host values."
}

if ($EspSrModelsBin -and -not $EnableEspSr) {
  throw "-EspSrModelsBin requires -EnableEspSr."
}

if ($EspSrWakeKeyword -ne "hiesp" -and -not $EnableEspSr) {
  throw "-EspSrWakeKeyword requires -EnableEspSr."
}

if ($BootSpeakerTest -and -not $EnableEspSr) {
  throw "-BootSpeakerTest requires -EnableEspSr."
}

if ($BootSpeakerTest -and -not $EnableSpeakerOutput) {
  throw "-BootSpeakerTest requires -EnableSpeakerOutput."
}

if ($DiagHttpServer -and -not $EnableEspSr) {
  throw "-DiagHttpServer requires -EnableEspSr."
}

if ($EspSrModelsBin -and -not (Test-Path -LiteralPath $EspSrModelsBin)) {
  throw "ESP-SR model image not found: $EspSrModelsBin"
}

if ($EspSrModelsBin) {
  Assert-EspSrModelAllowed -Path $EspSrModelsBin
}

if ($EspSrWakeKeyword -notmatch "^[A-Za-z0-9_+-]+$") {
  throw "-EspSrWakeKeyword must be ASCII letters, digits, underscore, plus, or hyphen."
}

if ($ApiPortOverride -and $ApiPortOverride -notmatch "^\d{1,5}$") {
  throw "-ApiPortOverride must be a TCP port number."
}

$ArduinoCli = Resolve-ArduinoCli -RequestedPath $CliPath

if (-not $BuildPath) {
  $BuildName = if ($EnableEspSr) { "homecue-edge-esp32-sr-build" } else { "homecue-edge-esp32-build" }
  $BuildPath = Join-Path $env:TEMP $BuildName
}
$BuildPath = [System.IO.Path]::GetFullPath($BuildPath)
New-Item -ItemType Directory -Force -Path $BuildPath | Out-Null

$BuildSketchDir = $SketchDir
$UseBuildSketchCopy = $EnableEspSr -or $ApiHostOverride -or $ApiPortOverride -or $VoiceChatAccessTokenOverride -or $BootSpeakerTest -or $DiagHttpServer
if ($UseBuildSketchCopy) {
  $SketchWorkParent = Join-Path $env:TEMP "homecue-edge-esp32-sr-sketch"
  $BuildSketchDir = Join-Path $SketchWorkParent "esp32-audio"
  if (Test-Path -LiteralPath $SketchWorkParent) {
    Remove-Item -LiteralPath $SketchWorkParent -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $SketchWorkParent | Out-Null
  Copy-Item -LiteralPath $SketchDir -Destination $SketchWorkParent -Recurse
}

if ($EnableEspSr) {
  $BuildOptions = @(
    "-DENABLE_ESP_SR=1",
    "-DHOMECUE_SR_WAKE_KEYWORD=\`"$EspSrWakeKeyword\`"",
    "-DHOMECUE_SPEAKER_OUTPUT_ENABLED=$(if ($EnableSpeakerOutput) { 1 } else { 0 })"
  )
  if ($BootSpeakerTest) {
    $BootModeValue = switch ($BootSpeakerTestMode) {
      "both" { 0 }
      "left" { 1 }
      "right" { 2 }
      "sweep" { 3 }
      default { 4 }
    }
    $BuildOptions += @(
      "-DHOMECUE_BOOT_SPEAKER_TEST=1",
      "-DHOMECUE_BOOT_SPEAKER_TEST_SECONDS=$BootSpeakerTestSeconds",
      "-DHOMECUE_BOOT_SPEAKER_TEST_MODE=$BootModeValue"
    )
  }
  if ($DiagHttpServer) {
    $BuildOptions += "-DHOMECUE_DIAG_HTTP_SERVER=1"
  }
  Set-Content -LiteralPath (Join-Path $BuildSketchDir "build_opt.h") -Value $BuildOptions -Encoding ASCII
  if ($EspSrWakeKeyword -ne "hiesp") {
    $LocalEspSr = Initialize-CustomEspSrLibrary -SketchWorkParent $SketchWorkParent -WakeKeyword $EspSrWakeKeyword
    $LocalLibraries = Join-Path $SketchWorkParent "libraries"
  }
}

if ($ApiHostOverride -or $ApiPortOverride -or $VoiceChatAccessTokenOverride) {
  $BuildSecretsPath = Join-Path $BuildSketchDir "secrets.h"
  Set-FirmwareSecretDefine -Path $BuildSecretsPath -Name "PC_HOST" -Value $ApiHostOverride
  Set-FirmwareSecretDefine -Path $BuildSecretsPath -Name "PC_PORT" -Value $ApiPortOverride
  Set-FirmwareSecretDefine -Path $BuildSecretsPath -Name "VOICE_CHAT_ACCESS_TOKEN" -Value $VoiceChatAccessTokenOverride
}

$PartitionScheme = if ($EnableEspSr) { "esp_sr_16" } else { "app3M_fat9M_16MB" }
$Fqbn = "esp32:esp32:esp32s3:UploadSpeed=$UploadSpeed,USBMode=hwcdc,CDCOnBoot=cdc,MSCOnBoot=default,DFUOnBoot=default,UploadMode=$UploadMode,CPUFreq=240,FlashMode=qio,FlashSize=16M,PartitionScheme=$PartitionScheme,DebugLevel=none,PSRAM=opi,LoopCore=1,EventsCore=1,EraseFlash=none,JTAGAdapter=default,ZigbeeMode=default"

Write-Host "HomeCue Edge ESP32 firmware flash helper"
Write-Host ("Sketch : {0}" -f $BuildSketchDir)
Write-Host ("CLI    : {0}" -f $ArduinoCli)
Write-Host ("FQBN   : {0}" -f $Fqbn)
Write-Host ("Build  : {0}" -f $BuildPath)
Write-Host ("Port   : {0}" -f $Port)
Write-Host ("ESP-SR : {0}" -f $(if ($EnableEspSr) { "enabled (-DENABLE_ESP_SR=1)" } else { "disabled" }))
if ($EnableEspSr) {
  Write-Host ("Wake   : {0}" -f $EspSrWakeKeyword)
  Write-Host ("Speaker output: {0}" -f $(if ($EnableSpeakerOutput) { "enabled" } else { "disabled" }))
  Write-Host ("Boot speaker test: {0}" -f $(if ($BootSpeakerTest) { "$BootSpeakerTestSeconds s / $BootSpeakerTestMode" } else { "disabled" }))
  Write-Host ("Diag HTTP server : {0}" -f $(if ($DiagHttpServer) { "enabled on port 80" } else { "disabled" }))
  if ($LocalEspSr) {
    Write-Host ("SR lib : {0}" -f $LocalEspSr)
  }
  if ($EspSrModelsBin) {
    Write-Host ("SR bin : {0}" -f (Resolve-Path -LiteralPath $EspSrModelsBin).Path)
  }
}
if ($ApiHostOverride) {
  Write-Host ("API host override: {0}" -f $ApiHostOverride)
}
if ($ApiPortOverride) {
  Write-Host ("API port override: {0}" -f $ApiPortOverride)
}
Write-Host ("Voice token: {0}" -f $(if ($VoiceChatAccessTokenOverride) { "configured" } else { "disabled" }))
Write-Host ""

$CompileArgs = @(
  "compile",
  "--fqbn", $Fqbn,
  "--build-path", $BuildPath,
  "--output-dir", $BuildPath,
  "--warnings", "default"
)
if ($LocalLibraries) {
  $CompileArgs += @("--libraries", $LocalLibraries)
}
if ($Clean) {
  $CompileArgs += "--clean"
}
$CompileArgs += $BuildSketchDir

Invoke-Checked -FilePath $ArduinoCli -Arguments $CompileArgs

if ($EnableEspSr -and -not (Test-Path -LiteralPath (Join-Path $BuildPath "srmodels.bin"))) {
  throw "ESP-SR build did not produce srmodels.bin. Check ESP_SR library/model installation."
}

if ($EnableEspSr -and $EspSrModelsBin) {
  Copy-Item -LiteralPath $EspSrModelsBin -Destination (Join-Path $BuildPath "srmodels.bin") -Force
  Write-Host ("ESP-SR model override copied to build output: {0}" -f (Join-Path $BuildPath "srmodels.bin"))
}

if ($EnableEspSr) {
  $BuiltModelsBin = Join-Path $BuildPath "srmodels.bin"
  if (-not (Test-BinaryContainsKeyword -Path $BuiltModelsBin -Keyword $EspSrWakeKeyword)) {
    throw "ESP-SR model image does not contain requested WakeNet keyword '$EspSrWakeKeyword': $BuiltModelsBin"
  }
  Assert-EspSrModelAllowed -Path $BuiltModelsBin
}

if ($Upload) {
  switch (Test-SerialPortWritable -Name $Port) {
    "busy" { throw "Serial port $Port is busy or unavailable." }
    "hung" {
      Show-DownloadModeHelp -Name $Port
      throw "Serial port $Port enumerates but is not writable (hung firmware). Enter ROM download mode and retry."
    }
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
  $UploadArgs += $BuildSketchDir

  Write-Host ("> {0} {1}" -f $ArduinoCli, ($UploadArgs -join " "))
  & $ArduinoCli @UploadArgs
  if ($LASTEXITCODE -ne 0) {
    # esptool surfaces a hung board mid-handshake as 'Write timeout' / connect
    # failure; translate that into the same actionable download-mode guidance.
    Show-DownloadModeHelp -Name $Port
    throw "Upload failed with exit code ${LASTEXITCODE}. See the ROM download-mode recovery steps above."
  }
}

Write-Host "ESP32 firmware flow complete."
