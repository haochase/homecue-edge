param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputDir = "",
  [string]$ReportPath = "",
  [string]$SummaryPath = "",
  [string]$ResultJsonPath = "",
  [string]$BrowserEvidenceResultJsonPath = "",
  [switch]$SkipPreflight,
  [switch]$SelfTest,
  [switch]$DryRun,
  [int]$StartupTimeoutSeconds = 60,
  [int]$StepTimeoutSeconds = 180,
  [int]$BrowserWrapperSharedStateLockTimeoutSeconds = 1200
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$WebDir = Join-Path $Root "apps\web"
$ComputerLoopRunId = "computer-loop-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), ([guid]::NewGuid().ToString("N").Substring(0, 8))
$ResultJsonPathProvided = -not [string]::IsNullOrWhiteSpace($ResultJsonPath)

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
  $OutputDir = Join-Path $Root ("assets\tmp\computer-loop\{0}" -f $ComputerLoopRunId)
}
else {
  $OutputDir = Resolve-RootedPath $OutputDir
}

if (-not $ReportPath) {
  $ReportPath = Join-Path $OutputDir "computer-loop-report.md"
}
else {
  $ReportPath = Resolve-RootedPath $ReportPath
}

if (-not $SummaryPath) {
  $SummaryPath = Join-Path $OutputDir "computer-loop-report.json"
}
else {
  $SummaryPath = Resolve-RootedPath $SummaryPath
}

if (-not $ResultJsonPath) {
  $ResultJsonPath = Join-Path $Root "assets\tmp\computer-loop-check.json"
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

function Join-DisplayCommand {
  param([string[]]$Arguments)

  return (($Arguments | ForEach-Object { ConvertTo-DisplayArgument $_ }) -join " ")
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
  [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $Utf8NoBom)
}

function Read-JsonFile {
  param([string]$Path)

  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function New-ComputerLoopPlan {
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
    "-IncludeChrome",
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
    (Convert-ToPlanPath $SummaryPath)
  )
  if ($SkipPreflight) {
    $FullLoopArgs += "-SkipPreflight"
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
    "-RequireChrome",
    "-ResultJsonPath",
    (Convert-ToPlanPath $BrowserEvidenceResultJsonPath)
  )
  if ($SelfTest) {
    $BrowserEvidenceArgs += "-SelfTest"
  }

  return [pscustomobject]@{
    runId = $ComputerLoopRunId
    requestedLoops = [pscustomobject]@{
      desktop = $true
      phone = $false
      windowsChrome = $true
    }
    options = [pscustomobject]@{
      skipPreflight = [bool]$SkipPreflight
      selfTest = [bool]$SelfTest
      startupTimeoutSeconds = $StartupTimeoutSeconds
      stepTimeoutSeconds = $StepTimeoutSeconds
      browserWrapperSharedStateLockTimeoutSeconds = $BrowserWrapperSharedStateLockTimeoutSeconds
    }
    outputs = [pscustomobject]@{
      outputDir = Convert-ToPlanPath $OutputDir
      reportPath = Convert-ToPlanPath $ReportPath
      summaryPath = Convert-ToPlanPath $SummaryPath
      resultJsonPath = Convert-ToPlanPath $ResultJsonPath
      browserEvidenceResultJsonPath = Convert-ToPlanPath $BrowserEvidenceResultJsonPath
    }
    expectedEvidence = [pscustomobject]@{
      phoneEvidence = "__phone_not_run__.json"
    }
    gates = [pscustomobject]@{
      fullLoopIncludeChrome = $true
      fullLoopIncludePhone = $false
      browserEvidenceRequireDesktop = $true
      browserEvidenceRequireChrome = $true
      browserEvidenceRequirePhone = $false
      browserEvidenceSelfTest = [bool]$SelfTest
      browserWrapperSharedStateLock = [pscustomobject]@{
        name = "Global\HCEdgeBrowserLoopGate"
        timeoutSeconds = $BrowserWrapperSharedStateLockTimeoutSeconds
      }
      fullLoopWebReadiness = [pscustomobject]@{
        httpProbeBeforePortReuse = $true
        stalePortBlocksDuplicateStart = $true
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
    }
  }
}

function New-ComputerLoopResult {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][bool]$Success,
    $BrowserEvidenceResult = $null,
    $ProofSummary = $null,
    $Failure = $null
  )

  return [pscustomobject]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    success = $Success
    mode = $Mode
    runId = $Plan.runId
    plan = $Plan
    checks = @(
      [pscustomobject]@{
        name = "computer full loop"
        command = $Plan.commands.fullLoop.display
        required = $true
        summaryPath = $Plan.outputs.summaryPath
        reportPath = $Plan.outputs.reportPath
      },
      [pscustomobject]@{
        name = "saved browser evidence recheck"
        command = $Plan.commands.browserEvidence.display
        required = $true
        resultJsonPath = $Plan.outputs.browserEvidenceResultJsonPath
      }
    )
    proofSummary = $ProofSummary
    browserEvidence = $BrowserEvidenceResult
    failure = $Failure
  }
}

function New-ComputerLoopFailure {
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

function New-ComputerLoopProofSummary {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Summary,
    [Parameter(Mandatory = $true)]$BrowserEvidenceResult
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
      windowsChrome = New-LoopProofSummary -Loop $Summary.loops.windowsChrome
      phone = [pscustomobject]@{
        run = [bool]($Summary.loops.phone.run -eq $true)
        success = $Summary.loops.phone.success
      }
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
    }
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

  if ($env:HOMECUE_COMPUTER_LOOP_SELFTEST_SKIP_CHILDREN -eq "1") {
    Write-Host "Skipping $Name because HOMECUE_COMPUTER_LOOP_SELFTEST_SKIP_CHILDREN=1."
    return
  }

  try {
    Invoke-CheckedScript -Name $Name -Command $Command
  }
  catch {
    $Failure = New-ComputerLoopFailure -Stage $Name -Command $Command -ErrorRecord $_ -ExitCode $LASTEXITCODE
    Write-JsonFile -Path $ResultJsonPath -Value (New-ComputerLoopResult -Plan $Plan -Mode "failed" -Success $false -Failure $Failure)
    throw
  }
}

function Invoke-PostProcessWithResult {
  param([Parameter(Mandatory = $true)]$Plan)

  $script:ComputerLoopResultValidationFailureWritten = $false

  try {
    $BrowserEvidenceResult = Read-JsonFile $BrowserEvidenceResultJsonPath
    if ($BrowserEvidenceResult.success -ne $true) {
      throw "Browser evidence recheck did not report success: $BrowserEvidenceResultJsonPath"
    }
    $Summary = Read-JsonFile $SummaryPath
    $ProofSummary = New-ComputerLoopProofSummary -Plan $Plan -Summary $Summary -BrowserEvidenceResult $BrowserEvidenceResult

    Write-JsonFile -Path $ResultJsonPath -Value (New-ComputerLoopResult -Plan $Plan -Mode "validate" -Success $true -BrowserEvidenceResult $BrowserEvidenceResult -ProofSummary $ProofSummary)
    try {
      Invoke-NpmChecked @("run", "computer:result:check", "--", $ResultJsonPath)
    }
    catch {
      $Failure = New-ComputerLoopFailure -Stage "result validation" -Command ([pscustomobject]@{
          display = "npm run computer:result:check -- $ResultJsonPath"
        }) -ErrorRecord $_ -ExitCode $LASTEXITCODE
      Write-JsonFile -Path $ResultJsonPath -Value (New-ComputerLoopResult -Plan $Plan -Mode "failed" -Success $false -Failure $Failure)
      $script:ComputerLoopResultValidationFailureWritten = $true
      throw
    }

    return $ProofSummary
  }
  catch {
    if ($script:ComputerLoopResultValidationFailureWritten -eq $true) {
      throw
    }

    $ErrorRecord = $_
    $Failure = New-ComputerLoopFailure -Stage "result validation" -Command ([pscustomobject]@{
        display = "post-process computer loop evidence"
      }) -ErrorRecord $ErrorRecord -ExitCode $null
    Write-JsonFile -Path $ResultJsonPath -Value (New-ComputerLoopResult -Plan $Plan -Mode "failed" -Success $false -Failure $Failure)
    Write-Error "post-process computer loop evidence failed: $($ErrorRecord.Exception.Message)" -ErrorAction Continue
    throw
  }
}

function Invoke-NpmChecked {
  param([string[]]$Arguments)

  Push-Location $WebDir
  try {
    npm @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "npm command failed: npm $($Arguments -join ' ')"
    }
  }
  finally {
    Pop-Location
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

function Format-LoopRunStatus {
  param($Loop)

  if ($Loop.run -ne $true) {
    return "not-run"
  }

  return Format-ProofStatus $Loop.success
}

$Plan = New-ComputerLoopPlan

if ($DryRun) {
  if ($ResultJsonPathProvided) {
    Write-JsonFile -Path $ResultJsonPath -Value (New-ComputerLoopResult -Plan $Plan -Mode "dry-run" -Success $true)
  }
  $Plan | ConvertTo-Json -Depth 10
  exit 0
}

Invoke-CheckedScriptWithResult -Name "computer full loop" -Command $Plan.commands.fullLoop -Plan $Plan
Invoke-CheckedScriptWithResult -Name "saved browser evidence recheck" -Command $Plan.commands.browserEvidence -Plan $Plan

$ProofSummary = Invoke-PostProcessWithResult -Plan $Plan
Write-Host ("Computer loop check JSON: {0}" -f $ResultJsonPath)
Write-Host ("Computer loop proof summary: desktop={0}, chrome={1}, phone={2}, parity={3}, web={4}, text={5}/{6}/{7}+{8}/{9}/{10}, screenshots={11}+{12}, phoneEvidence={13}, summary={14}" -f (Format-ProofStatus $ProofSummary.loops.desktop.success), (Format-ProofStatus $ProofSummary.loops.windowsChrome.success), (Format-LoopRunStatus $ProofSummary.loops.phone), (Format-ProofStatus $ProofSummary.browserParity.success), $ProofSummary.webReadiness.strategy, $ProofSummary.loops.desktop.textRequiredPhrases, $ProofSummary.loops.desktop.textMissingPhrases, $ProofSummary.loops.desktop.textMojibake, $ProofSummary.loops.windowsChrome.textRequiredPhrases, $ProofSummary.loops.windowsChrome.textMissingPhrases, $ProofSummary.loops.windowsChrome.textMojibake, $ProofSummary.loops.desktop.screenshotCount, $ProofSummary.loops.windowsChrome.screenshotCount, $ProofSummary.evidence.phoneEvidencePath, $ProofSummary.evidence.summaryPath)
Write-Host "Computer loop check passed."
