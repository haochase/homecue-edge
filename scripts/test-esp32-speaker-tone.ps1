param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$Seconds = 18,
  [int]$StartAfterSeconds = 5,
  [ValidateRange(1, 3)]
  [int]$ToneSeconds = 1,
  [ValidateSet("all", "both", "left", "right", "sweep")]
  [string]$ToneMode = "all",
  [ValidateRange(0, 32)]
  [int]$Volume = 18,
  [ValidateRange(0, 5000)]
  [int]$Amplitude = 1800,
  [ValidateSet("buffer", "sample", "sample32", "sample32bclk")]
  [string]$WriteMode = "buffer",
  [switch]$DumpRegisters,
  [switch]$MicProbe,
  [string]$SaveLogPath = ".\assets\demo\esp32-speaker-tone-test.log",
  [string]$ResultJsonPath = ".\assets\demo\esp32-speaker-tone-test-check.json",
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

function Write-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $false
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

New-ParentDirectory -Path $SaveLogPath
New-ParentDirectory -Path $ResultJsonPath

$SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$SerialPort.ReadTimeout = 200
$SerialPort.DtrEnable = $false
$SerialPort.RtsEnable = $true
$Chunks = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$Command = "homecue:speaker-test $ToneSeconds $ToneMode $Volume $Amplitude $WriteMode"
if ($DumpRegisters) {
  $Command = "$Command regs"
}
if ($MicProbe) {
  $Command = "$Command mic"
}
$CommandSent = $false

try {
  $SerialPort.Open()
  Write-Host "HomeCue Edge ESP32 speaker tone test"
  Write-Host ("Port   : {0} @ {1}" -f $Port, $Baud)
  Write-Host ("Command: {0}" -f $Command)
  Write-Host ""

  if (-not $SkipReset) {
    $SerialPort.RtsEnable = $false
    Start-Sleep -Milliseconds 100
    $SerialPort.RtsEnable = $true
  }

  $Deadline = (Get-Date).AddSeconds($Seconds)
  $SendAt = (Get-Date).AddSeconds($StartAfterSeconds)
  while ((Get-Date) -lt $Deadline) {
    try {
      $Text = $SerialPort.ReadExisting()
      if ($Text) {
        $Chunks.Add($Text)
        Write-Host $Text -NoNewline
      }
    } catch [TimeoutException] {
    }

    if (-not $CommandSent -and (Get-Date) -ge $SendAt) {
      $Marker = "`n> serial $Command`n"
      $Chunks.Add($Marker)
      Write-Host $Marker -NoNewline
      $SerialPort.WriteLine($Command)
      $CommandSent = $true
    }

    Start-Sleep -Milliseconds 100
  }
  Write-Host ""
} finally {
  if ($SerialPort.IsOpen) {
    $SerialPort.DtrEnable = $false
    $SerialPort.RtsEnable = $true
    $SerialPort.Close()
  }
}

$LogText = $Chunks -join ""
Set-Content -LiteralPath $SaveLogPath -Value $LogText -NoNewline
Write-Host ("Saved  : {0}" -f (Resolve-Path -LiteralPath $SaveLogPath).Path)
Write-Host ""
Write-Host "Checking speaker markers..."

$BootRequired = -not [bool]$SkipReset
$CommandMarker = "> serial $Command"
$PostCommandLog = $LogText
$CommandMarkerIndex = $LogText.IndexOf($CommandMarker)
if ($CommandMarkerIndex -ge 0) {
  $PostCommandLog = $LogText.Substring($CommandMarkerIndex)
}
$CrashPattern = "Guru Meditation Error|LoadProhibited|StoreProhibited|IllegalInstruction|Backtrace:"
$PostCommandResetPattern = "rst:0x|ESP-ROM:"
$ExpectedSegments = if ($ToneMode -eq "all") { 4 } else { 1 }
$SpeakerStartMatches = [regex]::Matches($LogText, "\[speaker-test\] start rate=\d+ channels=2 freq=\d+Hz volume=\d+(?: amplitude=\d+)? duration=\d+s pa=on(?: mode=(all|both|left|right|sweep))?(?: write=(buffer|sample|sample32|sample32bclk))?")
$SpeakerDoneMatches = [regex]::Matches($LogText, "\[speaker-test\] done wrote=\d+ expected=\d+")
$PaReadbackHighMatches = [regex]::Matches($LogText, "\[speaker-test\] PA readback pin=8 state=high")
$SpeakerDisabledMatches = [regex]::Matches($LogText, "\[speaker-test\] disabled - speaker output disabled")
$RegisterDumpBeginMatches = [regex]::Matches($LogText, "ES8311 register dump begin")
$MicBaselineMatches = [regex]::Matches($LogText, "\[speaker-test\] mic baseline mic bytes=\d+")
$MicActiveMatches = [regex]::Matches($LogText, "\[speaker-test\] mic active mic bytes=\d+")
$SpeakerStartOk = $SpeakerStartMatches.Count -ge $ExpectedSegments
$SpeakerDoneOk = $SpeakerDoneMatches.Count -ge $ExpectedSegments
$AudioReadyOk = ($LogText -match "\[esp-sr\] ready" -and $LogText -match "\[speaker\] ES8311 codec ready") -or $SpeakerStartOk
$ShortWriteOk = -not ($LogText -match "\[speaker-test\] short write")
$UnavailableOk = -not ($LogText -match "\[speaker-test\] unavailable")
$TxOk = -not ($LogText -match "\[speaker-test\] configureTX FAILED")
$FailedOk = -not ($LogText -match "\[serial\] SPEAKER TEST failed")
$NoCrashOk = -not ($LogText -match $CrashPattern) -and -not ($PostCommandLog -match $PostCommandResetPattern)
$ModeOk = $ToneMode -eq "all" -or $LogText -match ("mode={0}\b" -f [regex]::Escape($ToneMode))

Write-Check "boot banner" ($LogText -match "\[HomeCue Edge\].*firmware booting") "firmware restarted cleanly" $BootRequired
Write-Check "audio route ready" $AudioReadyOk "startup markers or successful tone start prove the route is initialized" $true
Write-Check "speaker PA enabled" ($LogText -match "\[speaker\] PA enabled pin=8" -or $SpeakerStartOk) "power amplifier enable is high" $true
Write-Check "speaker PA readback" ($PaReadbackHighMatches.Count -ge 1) ("saw {0} high readback marker(s)" -f $PaReadbackHighMatches.Count) $true
Write-Check "serial command sent" ($LogText -match [regex]::Escape("> serial $Command")) "test command injected over USB serial" $true
Write-Check "speaker test started" $SpeakerStartOk ("saw {0}/{1} segment start marker(s)" -f $SpeakerStartMatches.Count, $ExpectedSegments) $true
Write-Check "speaker test mode" $ModeOk ("expected mode={0}" -f $ToneMode) $true
Write-Check "speaker test wrote samples" $SpeakerDoneOk ("saw {0}/{1} segment done marker(s)" -f $SpeakerDoneMatches.Count, $ExpectedSegments) $true
Write-Check "ES8311 register dumps" (-not $DumpRegisters -or $RegisterDumpBeginMatches.Count -ge 4) ("saw {0} dump marker(s)" -f $RegisterDumpBeginMatches.Count) ([bool]$DumpRegisters)
Write-Check "mic acoustic probe" (-not $MicProbe -or ($MicBaselineMatches.Count -ge 1 -and $MicActiveMatches.Count -ge 1)) ("baseline={0} active={1}" -f $MicBaselineMatches.Count, $MicActiveMatches.Count) ([bool]$MicProbe)
Write-Check "no short write" $ShortWriteOk "I2S writes were complete" $true
Write-Check "TX configured" $TxOk "I2S TX accepted tone format" $true
Write-Check "speaker test available" $UnavailableOk "firmware was built with ENABLE_ESP_SR=1" $true
Write-Check "speaker test did not fail" $FailedOk "serial command did not report failure" $true
Write-Check "speaker output enabled" ($SpeakerDisabledMatches.Count -eq 0) ("disabled markers={0}" -f $SpeakerDisabledMatches.Count) $true
Write-Check "no crash markers" $NoCrashOk "no panic/reset marker in capture" $true
Write-Check "audible output" $false "cannot be proven by serial; user must confirm by listening" $false

$Result = @{
  port = $Port
  baud = $Baud
  seconds = $Seconds
  toneSeconds = $ToneSeconds
  toneMode = $ToneMode
  volume = $Volume
  amplitude = $Amplitude
  writeMode = $WriteMode
  dumpRegisters = [bool]$DumpRegisters
  micProbe = [bool]$MicProbe
  expectedSegments = $ExpectedSegments
  command = $Command
  requiredMode = [bool]$Required
  humanAudibleConfirmationRequired = $true
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}

$Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "ESP32 speaker tone test failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}
