param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputDir = "",
  [string]$ReportPath = "",
  [string]$SummaryPath = "",
  [string]$ResultJsonPath = "",
  [string]$BrowserEvidenceResultJsonPath = "",
  [string]$Esp32SerialRecheckResultJsonPath = "",
  [string]$AdbPath = "",
  [switch]$SkipPreflight,
  [switch]$SelfTest,
  [switch]$DryRun,
  [int]$StartupTimeoutSeconds = 60,
  [int]$StepTimeoutSeconds = 240,
  [int]$BrowserWrapperSharedStateLockTimeoutSeconds = 1200,
  [string]$Esp32Port = "COM7",
  [int]$Esp32Baud = 115200,
  [int]$Esp32SerialSeconds = 45,
  [int]$Esp32SerialCommandIndex = 0,
  [switch]$Esp32SkipReset,
  [double]$MaxAgeMinutes = 0
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$DeviceLoopRunId = "device-loop-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), ([guid]::NewGuid().ToString("N").Substring(0, 8))
$ResultJsonPathProvided = -not [string]::IsNullOrWhiteSpace($ResultJsonPath)
$MaxAgeMinutesProvided = $PSBoundParameters.ContainsKey("MaxAgeMinutes")

if ($MaxAgeMinutesProvided -and $MaxAgeMinutes -le 0) {
  throw "-MaxAgeMinutes must be a positive number when provided."
}

function Resolve-RootedPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return Join-Path $Root $Path
}

if (-not $OutputDir) {
  $OutputDir = Join-Path $Root ("assets\tmp\device-loop\{0}" -f $DeviceLoopRunId)
}
else {
  $OutputDir = Resolve-RootedPath $OutputDir
}

if (-not $ReportPath) {
  $ReportPath = Join-Path $OutputDir "device-loop-report.md"
}
else {
  $ReportPath = Resolve-RootedPath $ReportPath
}

if (-not $SummaryPath) {
  $SummaryPath = Join-Path $OutputDir "device-loop-report.json"
}
else {
  $SummaryPath = Resolve-RootedPath $SummaryPath
}

if (-not $ResultJsonPath) {
  $ResultJsonPath = Join-Path $Root "assets\tmp\device-loop-check.json"
}
else {
  $ResultJsonPath = Resolve-RootedPath $ResultJsonPath
}

if (-not $BrowserEvidenceResultJsonPath) {
  $BrowserEvidenceResultJsonPath = Join-Path $OutputDir "browser-evidence-check.json"
}
else {
  $BrowserEvidenceResultJsonPath = Resolve-RootedPath $BrowserEvidenceResultJsonPath
}

if (-not $Esp32SerialRecheckResultJsonPath) {
  $Esp32SerialRecheckResultJsonPath = Join-Path $OutputDir "esp32-serial-saved-log-check.json"
}
else {
  $Esp32SerialRecheckResultJsonPath = Resolve-RootedPath $Esp32SerialRecheckResultJsonPath
}

$Esp32SerialLogPath = Join-Path $OutputDir "esp32-serial-level4.log"
$Esp32SerialResultJsonPath = Join-Path $OutputDir "esp32-serial-level4.json"

function Convert-ToPlanPath {
  param([string]$Path)

  if (-not $Path -or $Path.StartsWith("__")) {
    return $Path
  }

  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $RootPath = [System.IO.Path]::GetFullPath([string]$Root).TrimEnd("\", "/")
  $RootPrefix = $RootPath + [System.IO.Path]::DirectorySeparatorChar

  if ($FullPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $FullPath.Substring($RootPrefix.Length).Replace("\", "/")
  }

  return $FullPath
}

function ConvertTo-DisplayArgument {
  param([string]$Value)

  if ($null -eq $Value -or $Value -eq "") {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }

  return '"' + ($Value -replace '"', '\"') + '"'
}

function Join-DisplayCommand {
  param([string[]]$Arguments)

  return (($Arguments | ForEach-Object { ConvertTo-DisplayArgument $_ }) -join " ")
}

function ConvertTo-AsciiSafeJsonText {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [int]$Depth = 12
  )

  $Json = $Value | ConvertTo-Json -Depth $Depth
  $JsonText = [string]::Join([Environment]::NewLine, @($Json))
  return [regex]::Replace($JsonText, '[^\x00-\x7F]', {
      param($Match)
      '\u{0:x4}' -f [int][char]$Match.Value[0]
    })
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )

  $ResultDir = Split-Path -Parent $Path
  if ($ResultDir) {
    New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null
  }

  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, ((ConvertTo-AsciiSafeJsonText -Value $Value -Depth 12) + [Environment]::NewLine), $Utf8NoBom)
}

function Get-StringSha256Prefix {
  param([string]$Value)

  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()).Substring(0, 12)
  }
  finally {
    $Hasher.Dispose()
  }
}

function Get-GitOutput {
  param([string[]]$Arguments)

  Push-Location $Root
  try {
    $Output = @(& git @Arguments)
    if ($LASTEXITCODE -ne 0) {
      throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return $Output
  }
  finally {
    Pop-Location
  }
}

function Get-SourceState {
  $Branch = (Get-GitOutput -Arguments @("rev-parse", "--abbrev-ref", "HEAD") | Select-Object -First 1)
  $Commit = (Get-GitOutput -Arguments @("rev-parse", "HEAD") | Select-Object -First 1)
  $StatusLines = @(Get-GitOutput -Arguments @("status", "--short"))
  $StatusText = $StatusLines -join "`n"

  return [pscustomobject]@{
    branch = [string]$Branch
    commit = [string]$Commit
    dirty = [bool]($StatusLines.Count -gt 0)
    statusCount = [int]$StatusLines.Count
    statusSha256 = Get-StringSha256Prefix $StatusText
  }
}

function Read-JsonFile {
  param([string]$Path)

  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function New-DeviceLoopPlan {
  $FullLoopArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Convert-ToPlanPath "$PSScriptRoot\check-full-loop.ps1"),
    "-AppUrl",
    $AppUrl,
    "-ApiBase",
    $ApiBase,
    "-IncludePhone",
    "-IncludeChrome",
    "-IncludeEsp32Serial",
    "-IsolateEvidence",
    "-StartupTimeoutSeconds",
    "$StartupTimeoutSeconds",
    "-StepTimeoutSeconds",
    "$StepTimeoutSeconds",
    "-BrowserWrapperSharedStateLockTimeoutSeconds",
    "$BrowserWrapperSharedStateLockTimeoutSeconds",
    "-PartialEvidenceDir",
    (Convert-ToPlanPath $OutputDir),
    "-ReportPath",
    (Convert-ToPlanPath $ReportPath),
    "-SummaryPath",
    (Convert-ToPlanPath $SummaryPath),
    "-Esp32Port",
    $Esp32Port,
    "-Esp32Baud",
    "$Esp32Baud",
    "-Esp32SerialSeconds",
    "$Esp32SerialSeconds",
    "-Esp32SerialCommandIndex",
    "$Esp32SerialCommandIndex"
  )
  if ($AdbPath) {
    $FullLoopArgs += @("-AdbPath", (Convert-ToPlanPath $AdbPath))
  }
  if ($SkipPreflight) {
    $FullLoopArgs += "-SkipPreflight"
  }
  if ($Esp32SkipReset) {
    $FullLoopArgs += "-Esp32SkipReset"
  }

  $BrowserEvidenceArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Convert-ToPlanPath "$PSScriptRoot\check-browser-evidence.ps1"),
    "-SummaryPath",
    (Convert-ToPlanPath $SummaryPath),
    "-RequireDesktop",
    "-RequirePhone",
    "-RequireChrome",
    "-ResultJsonPath",
    (Convert-ToPlanPath $BrowserEvidenceResultJsonPath)
  )
  if ($SelfTest) {
    $BrowserEvidenceArgs += "-SelfTest"
  }
  if ($MaxAgeMinutesProvided) {
    $BrowserEvidenceArgs += @("-MaxAgeMinutes", ([string]$MaxAgeMinutes))
  }

  $Esp32SerialRecheckArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Convert-ToPlanPath "$PSScriptRoot\check-esp32-serial-log.ps1"),
    "-LogPath",
    (Convert-ToPlanPath $Esp32SerialLogPath),
    "-RequireInteraction",
    "-Required",
    "-ResultJsonPath",
    (Convert-ToPlanPath $Esp32SerialRecheckResultJsonPath)
  )

  return [pscustomobject]@{
    runId = $DeviceLoopRunId
    requestedLoops = [pscustomobject]@{
      desktop = $true
      phone = $true
      windowsChrome = $true
      esp32Serial = $true
    }
    options = [pscustomobject]@{
      skipPreflight = [bool]$SkipPreflight
      selfTest = [bool]$SelfTest
      adbPathProvided = -not [string]::IsNullOrWhiteSpace($AdbPath)
      startupTimeoutSeconds = $StartupTimeoutSeconds
      stepTimeoutSeconds = $StepTimeoutSeconds
      browserWrapperSharedStateLockTimeoutSeconds = $BrowserWrapperSharedStateLockTimeoutSeconds
      maxAgeMinutes = if ($MaxAgeMinutesProvided) { [double]$MaxAgeMinutes } else { $null }
    }
    outputs = [pscustomobject]@{
      outputDir = Convert-ToPlanPath $OutputDir
      reportPath = Convert-ToPlanPath $ReportPath
      summaryPath = Convert-ToPlanPath $SummaryPath
      resultJsonPath = Convert-ToPlanPath $ResultJsonPath
      browserEvidenceResultJsonPath = Convert-ToPlanPath $BrowserEvidenceResultJsonPath
      esp32SerialLogPath = Convert-ToPlanPath $Esp32SerialLogPath
      esp32SerialResultJsonPath = Convert-ToPlanPath $Esp32SerialResultJsonPath
      esp32SerialRecheckResultJsonPath = Convert-ToPlanPath $Esp32SerialRecheckResultJsonPath
    }
    expectedEvidence = [pscustomobject]@{
      desktopEvidence = "required-from-summary"
      phoneEvidence = "required-from-summary"
      windowsChromeEvidence = "required-from-summary"
      esp32SerialLog = Convert-ToPlanPath $Esp32SerialLogPath
      esp32SerialResult = Convert-ToPlanPath $Esp32SerialResultJsonPath
    }
    gates = [pscustomobject]@{
      fullLoopIncludePhone = $true
      fullLoopIncludeChrome = $true
      fullLoopIncludeEsp32Serial = $true
      fullLoopIsolateEvidence = $true
      browserEvidenceRequireDesktop = $true
      browserEvidenceRequirePhone = $true
      browserEvidenceRequireChrome = $true
      browserEvidenceSelfTest = [bool]$SelfTest
      browserWrapperSharedStateLock = [pscustomobject]@{
        name = "Global\HCEdgeBrowserLoopGate"
        timeoutSeconds = $BrowserWrapperSharedStateLockTimeoutSeconds
      }
      fullLoopWebReadiness = [pscustomobject]@{
        httpProbeBeforePortReuse = $true
        stalePortBlocksDuplicateStart = $true
        lanReachabilityForEsp32 = $true
      }
      esp32Serial = [pscustomobject]@{
        run = $true
        firmwareFlowRequired = $true
        autoSerialLevel4 = $true
        requireInteraction = $true
        savedLogRecheck = $true
      }
    }
    hardware = [pscustomobject]@{
      esp32Serial = [pscustomobject]@{
        run = $true
        port = $Esp32Port
        baud = $Esp32Baud
        seconds = $Esp32SerialSeconds
        serialCommandIndex = $Esp32SerialCommandIndex
        skipReset = [bool]$Esp32SkipReset
      }
    }
    commands = [pscustomobject]@{
      fullLoop = [pscustomobject]@{
        executable = "powershell"
        args = $FullLoopArgs
        display = Join-DisplayCommand (@("powershell") + $FullLoopArgs)
      }
      browserEvidence = [pscustomobject]@{
        executable = "powershell"
        args = $BrowserEvidenceArgs
        display = Join-DisplayCommand (@("powershell") + $BrowserEvidenceArgs)
      }
      esp32SerialRecheck = [pscustomobject]@{
        executable = "powershell"
        args = $Esp32SerialRecheckArgs
        display = Join-DisplayCommand (@("powershell") + $Esp32SerialRecheckArgs)
      }
    }
  }
}

function New-DeviceLoopResult {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][bool]$Success,
    $BrowserEvidenceResult = $null,
    $Esp32SerialResult = $null,
    $Esp32SerialRecheckResult = $null,
    $ProofSummary = $null,
    $Failure = $null
  )

  return [pscustomobject]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    success = $Success
    mode = $Mode
    runId = $Plan.runId
    sourceState = Get-SourceState
    plan = $Plan
    checks = @(
      [pscustomobject]@{
        name = "full device loop"
        command = $Plan.commands.fullLoop.display
        required = $true
        summaryPath = $Plan.outputs.summaryPath
        reportPath = $Plan.outputs.reportPath
        esp32SerialLogPath = $Plan.outputs.esp32SerialLogPath
        esp32SerialResultJsonPath = $Plan.outputs.esp32SerialResultJsonPath
      },
      [pscustomobject]@{
        name = "saved browser evidence recheck"
        command = $Plan.commands.browserEvidence.display
        required = $true
        resultJsonPath = $Plan.outputs.browserEvidenceResultJsonPath
      },
      [pscustomobject]@{
        name = "saved ESP32 serial log recheck"
        command = $Plan.commands.esp32SerialRecheck.display
        required = $true
        logPath = $Plan.outputs.esp32SerialLogPath
        resultJsonPath = $Plan.outputs.esp32SerialRecheckResultJsonPath
      }
    )
    proofSummary = $ProofSummary
    browserEvidence = $BrowserEvidenceResult
    esp32Serial = [pscustomobject]@{
      liveCapture = $Esp32SerialResult
      savedLogRecheck = $Esp32SerialRecheckResult
    }
    failure = $Failure
  }
}

function New-DeviceLoopFailure {
  param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [Parameter(Mandatory = $true)]$Command,
    [Parameter(Mandatory = $true)]$ErrorRecord,
    $ExitCode = $null
  )

  $Message = if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
    $ErrorRecord.Exception.Message
  } else {
    [string]$ErrorRecord
  }

  return [pscustomobject]@{
    stage = $Stage
    checkName = $Stage
    command = $Command.display
    exitCode = if ($null -ne $ExitCode) { [int]$ExitCode } else { $null }
    message = $Message
  }
}

function New-LoopProofSummary {
  param($Loop)

  return [pscustomobject]@{
    run = [bool]($Loop.run -eq $true)
    success = [bool]($Loop.success -eq $true)
    title = $Loop.title
    runButton = $Loop.localizedUi.runButton
    textRequiredPhrases = $Loop.textIntegrity.requiredPhraseCount
    textMissingPhrases = $Loop.textIntegrity.missingPhraseCount
    textMojibake = $Loop.textIntegrity.mojibakeCount
    firstViewportMinVisibleRatio = $Loop.firstViewportVisibility.minVisibleRatio
    runtimeIssueCount = $Loop.runtimeHealth.issueCount
    screenshotCount = $Loop.screenshotEvidence.count
    uniqueScreenshotDigestCount = $Loop.screenshotEvidence.uniqueDigestCount
    externalExecutionSource = $Loop.externalExecutionSync.latestSource
    acceptedActionCount = $Loop.externalExecutionSync.acceptedActionCount
  }
}

function New-PhoneProofSummary {
  param($Loop)

  return [pscustomobject]@{
    run = [bool]($Loop.run -eq $true)
    success = [bool]($Loop.success -eq $true)
    title = $Loop.title
    textRequiredPhrases = $Loop.textIntegrity.requiredPhraseCount
    textMissingPhrases = $Loop.textIntegrity.missingPhraseCount
    textMojibake = $Loop.textIntegrity.mojibakeCount
    frontCameraReady = [bool]($Loop.frontCamera.ready -eq $true)
    frontCameraFacingMode = $Loop.frontCamera.facingMode
    speechInputAvailable = $Loop.speechInput.available
    speechInputSkipped = $Loop.speechInput.skipped
    rawImageNotRetained = $Loop.scene.rawImageNotRetained
    runtimeIssueCount = $Loop.runtimeHealth.issueCount
    externalExecutionSource = $Loop.externalExecution.latestSource
    acceptedActionCount = $Loop.externalExecution.acceptedActionCount
  }
}

function New-Esp32SerialProofSummary {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$SerialResult,
    [Parameter(Mandatory = $true)]$RecheckResult
  )

  $LiveFailures = @($SerialResult.failures)
  $RecheckFailures = @($RecheckResult.failures)

  return [pscustomobject]@{
    run = $true
    success = [bool]($LiveFailures.Count -eq 0 -and $RecheckFailures.Count -eq 0)
    port = $Plan.hardware.esp32Serial.port
    baud = $Plan.hardware.esp32Serial.baud
    seconds = $Plan.hardware.esp32Serial.seconds
    serialCommandIndex = $Plan.hardware.esp32Serial.serialCommandIndex
    skipReset = $Plan.hardware.esp32Serial.skipReset
    requireInteraction = [bool]($SerialResult.requireInteraction -eq $true)
    requiredMode = [bool]($SerialResult.requiredMode -eq $true)
    liveFailureCount = $LiveFailures.Count
    recheckFailureCount = $RecheckFailures.Count
    liveCheckCount = @($SerialResult.checks).Count
    recheckCheckCount = @($RecheckResult.checks).Count
    liveResultJsonPath = $Plan.outputs.esp32SerialResultJsonPath
    savedLogPath = $Plan.outputs.esp32SerialLogPath
    savedLogRecheckResultJsonPath = $Plan.outputs.esp32SerialRecheckResultJsonPath
  }
}

function New-DeviceLoopProofSummary {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Summary,
    [Parameter(Mandatory = $true)]$BrowserEvidenceResult,
    [Parameter(Mandatory = $true)]$Esp32SerialResult,
    [Parameter(Mandatory = $true)]$Esp32SerialRecheckResult
  )

  return [pscustomobject]@{
    summaryRunId = $Summary.runId
    appUrl = $Summary.appUrl
    apiBase = $Summary.apiBase
    requestedLoops = $Plan.requestedLoops
    browserParity = [pscustomobject]@{
      checked = [bool]($Summary.browserParity.checked -eq $true)
      success = [bool]($Summary.browserParity.success -eq $true)
      errorCount = @($Summary.browserParity.errors).Count
    }
    webReadiness = [pscustomobject]@{
      run = [bool]($Summary.environment.webReadiness.run -eq $true)
      success = [bool]($Summary.environment.webReadiness.success -eq $true)
      strategy = $Summary.environment.webReadiness.strategy
      httpReadyAfter = [bool]($Summary.environment.webReadiness.httpReadyAfter -eq $true)
      duplicateStartAvoided = $Summary.environment.webReadiness.duplicateStartAvoided
    }
    loops = [pscustomobject]@{
      desktop = New-LoopProofSummary -Loop $Summary.loops.desktop
      phone = New-PhoneProofSummary -Loop $Summary.loops.phone
      windowsChrome = New-LoopProofSummary -Loop $Summary.loops.windowsChrome
    }
    hardware = [pscustomobject]@{
      esp32Serial = New-Esp32SerialProofSummary -Plan $Plan -SerialResult $Esp32SerialResult -RecheckResult $Esp32SerialRecheckResult
    }
    evidence = [pscustomobject]@{
      reportPath = $Plan.outputs.reportPath
      summaryPath = $Plan.outputs.summaryPath
      browserEvidenceResultJsonPath = $Plan.outputs.browserEvidenceResultJsonPath
      browserEvidenceSuccess = [bool]($BrowserEvidenceResult.success -eq $true)
      desktopEvidencePath = $BrowserEvidenceResult.proofSummary.evidence.desktopEvidencePath
      windowsChromeEvidencePath = $BrowserEvidenceResult.proofSummary.evidence.windowsChromeEvidencePath
      phoneEvidencePath = $BrowserEvidenceResult.proofSummary.evidence.phoneEvidencePath
      devEnvEvidencePath = $BrowserEvidenceResult.proofSummary.evidence.devEnvEvidencePath
      webReadinessEvidencePath = $BrowserEvidenceResult.proofSummary.evidence.webReadinessEvidencePath
      desktopScreenshotDir = $BrowserEvidenceResult.proofSummary.evidence.desktopScreenshotDir
      windowsChromeScreenshotDir = $BrowserEvidenceResult.proofSummary.evidence.windowsChromeScreenshotDir
      esp32SerialLogPath = $Plan.outputs.esp32SerialLogPath
      esp32SerialResultJsonPath = $Plan.outputs.esp32SerialResultJsonPath
      esp32SerialRecheckResultJsonPath = $Plan.outputs.esp32SerialRecheckResultJsonPath
    }
  }
}

function Invoke-CheckedScript {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$Command
  )

  Push-Location $Root
  try {
    & $Command.executable @($Command.args)
    if ($LASTEXITCODE -ne 0) {
      throw "$Name failed with exit code $LASTEXITCODE."
    }
  }
  finally {
    Pop-Location
  }
}

function Invoke-CheckedScriptWithResult {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$Command,
    [Parameter(Mandatory = $true)]$Plan
  )

  if ($env:HOMECUE_DEVICE_LOOP_SELFTEST_SKIP_CHILDREN -eq "1") {
    Write-Host "Skipping $Name because HOMECUE_DEVICE_LOOP_SELFTEST_SKIP_CHILDREN=1."
    return
  }

  try {
    Invoke-CheckedScript -Name $Name -Command $Command
  }
  catch {
    $Failure = New-DeviceLoopFailure -Stage $Name -Command $Command -ErrorRecord $_ -ExitCode $LASTEXITCODE
    Write-JsonFile -Path $ResultJsonPath -Value (New-DeviceLoopResult -Plan $Plan -Mode "failed" -Success $false -Failure $Failure)
    throw
  }
}

function Invoke-PostProcessWithResult {
  param([Parameter(Mandatory = $true)]$Plan)

  try {
    $BrowserEvidenceResult = Read-JsonFile $BrowserEvidenceResultJsonPath
    if ($BrowserEvidenceResult.success -ne $true) {
      throw "Browser evidence recheck did not report success: $BrowserEvidenceResultJsonPath"
    }

    $Esp32SerialResult = Read-JsonFile $Esp32SerialResultJsonPath
    $Esp32SerialFailures = @($Esp32SerialResult.failures)
    if ($Esp32SerialFailures.Count -gt 0) {
      throw "ESP32 live serial gate reported failure(s): $($Esp32SerialFailures -join ', ')"
    }

    $Esp32SerialRecheckResult = Read-JsonFile $Esp32SerialRecheckResultJsonPath
    $Esp32SerialRecheckFailures = @($Esp32SerialRecheckResult.failures)
    if ($Esp32SerialRecheckFailures.Count -gt 0) {
      throw "Saved ESP32 serial log recheck reported failure(s): $($Esp32SerialRecheckFailures -join ', ')"
    }

    $Summary = Read-JsonFile $SummaryPath
    $ProofSummary = New-DeviceLoopProofSummary -Plan $Plan -Summary $Summary -BrowserEvidenceResult $BrowserEvidenceResult -Esp32SerialResult $Esp32SerialResult -Esp32SerialRecheckResult $Esp32SerialRecheckResult

    Write-JsonFile -Path $ResultJsonPath -Value (New-DeviceLoopResult -Plan $Plan -Mode "validate" -Success $true -BrowserEvidenceResult $BrowserEvidenceResult -Esp32SerialResult $Esp32SerialResult -Esp32SerialRecheckResult $Esp32SerialRecheckResult -ProofSummary $ProofSummary)
    return $ProofSummary
  }
  catch {
    $ErrorRecord = $_
    $Failure = New-DeviceLoopFailure -Stage "result validation" -Command ([pscustomobject]@{
        display = "post-process device loop evidence"
      }) -ErrorRecord $ErrorRecord -ExitCode $null
    Write-JsonFile -Path $ResultJsonPath -Value (New-DeviceLoopResult -Plan $Plan -Mode "failed" -Success $false -Failure $Failure)
    Write-Error "post-process device loop evidence failed: $($ErrorRecord.Exception.Message)" -ErrorAction Continue
    throw
  }
}

function Format-ProofStatus {
  param($Value)

  if ($Value -eq $true) {
    return "pass"
  }
  if ($Value -eq $false) {
    return "fail"
  }

  return "unknown"
}

function Format-SourceState {
  param($SourceState)

  if (-not $SourceState) {
    return "unknown"
  }

  $Commit = if ($SourceState.commit) { ([string]$SourceState.commit).Substring(0, [Math]::Min(7, ([string]$SourceState.commit).Length)) } else { "unknown" }
  $Dirty = if ($SourceState.dirty -eq $true) {
    "dirty"
  }
  elseif ($SourceState.dirty -eq $false) {
    "clean"
  }
  else {
    "unknown"
  }

  $StatusCount = if ($null -ne $SourceState.statusCount) { $SourceState.statusCount } else { "unknown" }
  $StatusSha = if ($SourceState.statusSha256) { $SourceState.statusSha256 } else { "unknown" }

  return ("{0}@{1}/{2}#{3}:{4}" -f $SourceState.branch, $Commit, $Dirty, $StatusCount, $StatusSha)
}

$Plan = New-DeviceLoopPlan

if ($DryRun) {
  if ($ResultJsonPathProvided) {
    Write-JsonFile -Path $ResultJsonPath -Value (New-DeviceLoopResult -Plan $Plan -Mode "dry-run" -Success $true)
  }
  $Plan | ConvertTo-Json -Depth 12
  exit 0
}

Invoke-CheckedScriptWithResult -Name "full device loop" -Command $Plan.commands.fullLoop -Plan $Plan
Invoke-CheckedScriptWithResult -Name "saved browser evidence recheck" -Command $Plan.commands.browserEvidence -Plan $Plan
Invoke-CheckedScriptWithResult -Name "saved ESP32 serial log recheck" -Command $Plan.commands.esp32SerialRecheck -Plan $Plan

$ProofSummary = Invoke-PostProcessWithResult -Plan $Plan
$SourceState = Get-SourceState
Write-Host ("Device loop check JSON: {0}" -f $ResultJsonPath)
Write-Host ("Device loop proof summary: desktop={0}, phone={1}, chrome={2}, parity={3}, esp32={4}, frontCamera={5}/{6}, speech={7}, text={8}/{9}/{10}+{11}/{12}/{13}+{14}/{15}/{16}, screenshots={17}+{18}, source={19}, esp32Log={20}, summary={21}" -f (Format-ProofStatus $ProofSummary.loops.desktop.success), (Format-ProofStatus $ProofSummary.loops.phone.success), (Format-ProofStatus $ProofSummary.loops.windowsChrome.success), (Format-ProofStatus $ProofSummary.browserParity.success), (Format-ProofStatus $ProofSummary.hardware.esp32Serial.success), (Format-ProofStatus $ProofSummary.loops.phone.frontCameraReady), $ProofSummary.loops.phone.frontCameraFacingMode, (Format-ProofStatus $ProofSummary.loops.phone.speechInputAvailable), $ProofSummary.loops.desktop.textRequiredPhrases, $ProofSummary.loops.desktop.textMissingPhrases, $ProofSummary.loops.desktop.textMojibake, $ProofSummary.loops.phone.textRequiredPhrases, $ProofSummary.loops.phone.textMissingPhrases, $ProofSummary.loops.phone.textMojibake, $ProofSummary.loops.windowsChrome.textRequiredPhrases, $ProofSummary.loops.windowsChrome.textMissingPhrases, $ProofSummary.loops.windowsChrome.textMojibake, $ProofSummary.loops.desktop.screenshotCount, $ProofSummary.loops.windowsChrome.screenshotCount, (Format-SourceState $SourceState), $ProofSummary.evidence.esp32SerialLogPath, $ProofSummary.evidence.summaryPath)
Write-Host "Device loop check passed."
