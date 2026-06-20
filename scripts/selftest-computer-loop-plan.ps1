$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$OutputDir = Join-Path $Root "assets\tmp\computer-loop-plan-selftest"
$ImplicitResultPath = Join-Path $Root "assets\tmp\computer-loop-check.json"

function Get-FileHashOrMissing {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return "__missing__"
  }

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$HadImplicitResult = Test-Path -LiteralPath $ImplicitResultPath -PathType Leaf
$ImplicitResultBackup = if ($HadImplicitResult) {
  [System.IO.File]::ReadAllBytes($ImplicitResultPath)
} else {
  $null
}
$ImplicitResultBeforeHash = Get-FileHashOrMissing $ImplicitResultPath
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Invoke-Plan {
  param([string[]]$Arguments)

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-computer-loop.ps1" -DryRun @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "check-computer-loop.ps1 -DryRun failed: $($Arguments -join ' ')"
  }

  return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Read-Result {
  param([string]$Path)

  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Assert-ComputerResultValid {
  param([string]$Path)

  $WebRoot = Join-Path $Root "apps\web"
  $RootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd("\")
  $ResultPath = (Resolve-Path -LiteralPath $Path).Path
  if (-not $ResultPath.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Result path must stay inside repository root: $Path"
  }
  $RepoRelativePath = $ResultPath.Substring($RootPath.Length).TrimStart("\")
  $ValidatorPath = Join-Path "..\.." $RepoRelativePath

  Push-Location $WebRoot
  try {
    npm run computer:result:check -- $ValidatorPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "computer:result:check failed for dry-run result: $Path"
    }
  }
  finally {
    Pop-Location
  }
}

function Normalize-ProcessPathEnvironment {
  $PathEntries = @(
    [Environment]::GetEnvironmentVariables("Process").GetEnumerator() |
      Where-Object { [string]::Equals([string]$_.Key, "Path", [System.StringComparison]::OrdinalIgnoreCase) }
  )

  if ($PathEntries.Count -le 1) {
    return
  }

  $PathValue = @($PathEntries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } | Select-Object -First 1).Value
  foreach ($Entry in $PathEntries) {
    [Environment]::SetEnvironmentVariable([string]$Entry.Key, $null, "Process")
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$PathValue)) {
    [Environment]::SetEnvironmentVariable("Path", [string]$PathValue, "Process")
  }
}

function Invoke-ComputerLoopExpectFailure {
  param(
    [string[]]$Arguments,
    [hashtable]$Environment = @{},
    [string]$ScriptName = "check-computer-loop.ps1"
  )

  $StdoutPath = Join-Path $OutputDir "failed-command.out.txt"
  $StderrPath = Join-Path $OutputDir "failed-command.err.txt"
  Remove-Item -LiteralPath $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue

  Normalize-ProcessPathEnvironment
  $PreviousEnvironment = @{}
  foreach ($Key in $Environment.Keys) {
    $PreviousEnvironment[$Key] = [Environment]::GetEnvironmentVariable($Key, "Process")
    [Environment]::SetEnvironmentVariable($Key, [string]$Environment[$Key], "Process")
  }
  try {
    $Process = Start-Process `
      -FilePath "powershell" `
      -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\$ScriptName") + $Arguments) `
      -WorkingDirectory $Root `
      -RedirectStandardOutput $StdoutPath `
      -RedirectStandardError $StderrPath `
      -PassThru `
      -WindowStyle Hidden
    Wait-Process -Id $Process.Id
    $Process.Refresh()
  }
  finally {
    foreach ($Key in $Environment.Keys) {
      [Environment]::SetEnvironmentVariable($Key, $PreviousEnvironment[$Key], "Process")
    }
  }

  $Output = @(
    if (Test-Path -LiteralPath $StdoutPath) { Get-Content -Raw -LiteralPath $StdoutPath }
    if (Test-Path -LiteralPath $StderrPath) { Get-Content -Raw -LiteralPath $StderrPath }
  ) -join [Environment]::NewLine

  if ($Process.ExitCode -eq 0) {
    throw "$ScriptName should have failed: $($Arguments -join ' ')"
  }

  return $Output
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw ("{0} Expected '{1}', got '{2}'." -f $Message, $Expected, $Actual)
  }
}

function Assert-Contains {
  param(
    [string]$Actual,
    [string]$Expected,
    [string]$Message
  )

  if (-not $Actual.Contains($Expected)) {
    throw ("{0} Expected '{1}' to contain '{2}'." -f $Message, $Actual, $Expected)
  }
}

function Assert-NotContains {
  param(
    [string]$Actual,
    [string]$Unexpected,
    [string]$Message
  )

  if ($Actual.Contains($Unexpected)) {
    throw ("{0} Expected '{1}' not to contain '{2}'." -f $Message, $Actual, $Unexpected)
  }
}

function Assert-ObjectKeys {
  param(
    [object]$Value,
    [string[]]$ExpectedKeys,
    [string]$Message
  )

  $ActualKeys = @($Value.PSObject.Properties.Name | Sort-Object)
  $ExpectedSorted = @($ExpectedKeys | Sort-Object)
  Assert-Equal ($ActualKeys -join ",") ($ExpectedSorted -join ",") $Message
}

function Assert-ComputerLoopPlanManifest {
  param(
    [object]$Plan,
    [string]$Message
  )

  Assert-ObjectKeys $Plan @("runId", "requestedLoops", "options", "outputs", "expectedEvidence", "gates", "commands") "$Message plan fields"
  Assert-ObjectKeys $Plan.requestedLoops @("desktop", "phone", "windowsChrome") "$Message requestedLoops fields"
  Assert-ObjectKeys $Plan.options @("skipPreflight", "selfTest", "startupTimeoutSeconds", "stepTimeoutSeconds", "browserWrapperSharedStateLockTimeoutSeconds") "$Message options fields"
  Assert-ObjectKeys $Plan.outputs @("outputDir", "reportPath", "summaryPath", "resultJsonPath", "browserEvidenceResultJsonPath") "$Message outputs fields"
  Assert-ObjectKeys $Plan.expectedEvidence @("phoneEvidence") "$Message expectedEvidence fields"
  Assert-ObjectKeys $Plan.gates @("fullLoopIncludeChrome", "fullLoopIncludePhone", "browserEvidenceRequireDesktop", "browserEvidenceRequireChrome", "browserEvidenceRequirePhone", "browserEvidenceSelfTest", "browserWrapperSharedStateLock", "fullLoopWebReadiness") "$Message gates fields"
  Assert-ObjectKeys $Plan.gates.browserWrapperSharedStateLock @("name", "timeoutSeconds") "$Message browser wrapper lock fields"
  Assert-ObjectKeys $Plan.gates.fullLoopWebReadiness @("httpProbeBeforePortReuse", "stalePortBlocksDuplicateStart") "$Message web readiness gate fields"
  Assert-ObjectKeys $Plan.commands @("fullLoop", "browserEvidence") "$Message commands fields"
  Assert-ObjectKeys $Plan.commands.fullLoop @("executable", "args", "display") "$Message full-loop command fields"
  Assert-ObjectKeys $Plan.commands.browserEvidence @("executable", "args", "display") "$Message browser-evidence command fields"
}

function Assert-ComputerResultChecksManifest {
  param(
    [object]$Result,
    [object]$Plan,
    [string]$Message
  )

  $Checks = @($Result.checks)
  Assert-True ($Checks.Count -eq 2) "$Message should describe the two computer-loop checks."
  Assert-Equal $Checks[0].name "computer full loop" "$Message first check name"
  Assert-Equal $Checks[1].name "saved browser evidence recheck" "$Message second check name"
  Assert-Equal $Checks[0].command $Plan.commands.fullLoop.display "$Message full-loop check command"
  Assert-Equal $Checks[1].command $Plan.commands.browserEvidence.display "$Message browser-evidence check command"
  Assert-Equal $Checks[0].required $true "$Message full-loop check required flag"
  Assert-Equal $Checks[1].required $true "$Message browser-evidence check required flag"
  Assert-Equal $Checks[0].summaryPath $Plan.outputs.summaryPath "$Message full-loop summary path"
  Assert-Equal $Checks[0].reportPath $Plan.outputs.reportPath "$Message full-loop report path"
  Assert-Equal $Checks[1].resultJsonPath $Plan.outputs.browserEvidenceResultJsonPath "$Message browser-evidence result path"
  Assert-ObjectKeys $Checks[0] @("name", "command", "required", "summaryPath", "reportPath") "$Message full-loop check fields"
  Assert-ObjectKeys $Checks[1] @("name", "command", "required", "resultJsonPath") "$Message browser-evidence check fields"
}

function Assert-FailureManifest {
  param(
    [object]$Failure,
    [string]$Message
  )

  Assert-ObjectKeys $Failure @("stage", "checkName", "command", "exitCode", "message") "$Message failure fields"
}

function Get-ArgumentValue {
  param(
    [object[]]$Arguments,
    [string]$Name
  )

  for ($Index = 0; $Index -lt ($Arguments.Count - 1); $Index++) {
    if ($Arguments[$Index] -eq $Name) {
      return [string]$Arguments[$Index + 1]
    }
  }

  throw "Argument not found: $Name"
}

function Assert-ComputerLoopSourceStateFormatting {
  param([string]$ScriptSource)

  $Tokens = $null
  $ParseErrors = $null
  $Ast = [System.Management.Automation.Language.Parser]::ParseInput($ScriptSource, [ref]$Tokens, [ref]$ParseErrors)
  if ($ParseErrors.Count -gt 0) {
    throw ("check-computer-loop.ps1 should parse cleanly before extracting Format-SourceState: {0}" -f $ParseErrors[0].Message)
  }

  $FunctionAst = $Ast.Find(
    {
      param($Node)
      $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq "Format-SourceState"
    },
    $true
  )
  if (-not $FunctionAst) {
    throw "check-computer-loop.ps1 should define Format-SourceState."
  }

  $FunctionScript = [scriptblock]::Create($FunctionAst.Extent.Text)
  . $FunctionScript

  Assert-Equal (Format-SourceState $null) "unknown" "Source-state formatter should handle missing source state."
  Assert-Equal (Format-SourceState ([pscustomobject]@{
        branch = "edge-branch"
        commit = "abcdef1234567890"
        dirty = $false
        statusCount = 0
        statusSha256 = "e3b0c44298fc"
      })) "edge-branch@abcdef1/clean#0:e3b0c44298fc" "Source-state formatter should include clean status count and hash."
  Assert-Equal (Format-SourceState ([pscustomobject]@{
        branch = "edge-branch"
        commit = "1234567890abcdef"
        dirty = $true
        statusCount = 4
        statusSha256 = "5fe0d2de92f3"
      })) "edge-branch@1234567/dirty#4:5fe0d2de92f3" "Source-state formatter should include dirty status count and hash."
  Assert-Equal (Format-SourceState ([pscustomobject]@{
        branch = "edge-branch"
        commit = "123"
        dirty = $null
      })) "edge-branch@123/unknown#unknown:unknown" "Source-state formatter should show unknown when status metadata is missing."
}

try {
  $ComputerLoopScriptSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "check-computer-loop.ps1")
  Assert-Contains $ComputerLoopScriptSource "devEnvEvidence={" "Wrapper proof summary should print the dev environment evidence path label."
  Assert-Contains $ComputerLoopScriptSource "webReadinessEvidence={" "Wrapper proof summary should print the web readiness evidence path label."
  Assert-ComputerLoopSourceStateFormatting $ComputerLoopScriptSource
  Assert-Contains $ComputerLoopScriptSource '$ProofSummary.evidence.devEnvEvidencePath' "Wrapper proof summary should use proofSummary dev environment evidence."
  Assert-Contains $ComputerLoopScriptSource '$ProofSummary.evidence.webReadinessEvidencePath' "Wrapper proof summary should use proofSummary web readiness evidence."
  $LatestWrapperSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "check-computer-loop-latest.ps1")
  Assert-Contains $LatestWrapperSource "assets\tmp\computer-loop-check-latest.json" "Latest wrapper should target the stable latest result JSON path."
  Assert-Contains $LatestWrapperSource "check-computer-loop.ps1" "Latest wrapper should delegate to the full computer loop wrapper."
  Assert-Contains $LatestWrapperSource "-ResultJsonPath" "Latest wrapper should pass ResultJsonPath explicitly."
  Assert-Contains $LatestWrapperSource "-DryRun" "Latest wrapper should guard against dry-run overwriting latest evidence."
  Assert-Contains $LatestWrapperSource "@Arguments" "Latest wrapper should delegate with named splatting so switch parameters are preserved."
  Assert-Contains $LatestWrapperSource '$Arguments.SelfTest = $true' "Latest wrapper should forward SelfTest as a switch parameter."
  Assert-Contains $LatestWrapperSource "ResultJsonPath = `$LatestResultJsonPath" "Latest wrapper should force the stable latest result path by name."

  $LatestDryRunFailure = Invoke-ComputerLoopExpectFailure -ScriptName "check-computer-loop-latest.ps1" -Arguments @("-DryRun")
  Assert-Contains $LatestDryRunFailure "without overwriting latest result evidence" "Latest wrapper dry-run guard output"
  $LatestResultPathFailure = Invoke-ComputerLoopExpectFailure -ScriptName "check-computer-loop-latest.ps1" -Arguments @(
    "-ResultJsonPath",
    "assets/tmp/computer-loop-plan-selftest/should-not-write.json"
  )
  Assert-Contains $LatestResultPathFailure "always writes assets/tmp/computer-loop-check-latest.json" "Latest wrapper result-path guard output"

  $Implicit = Invoke-Plan @()
  Assert-ComputerLoopPlanManifest $Implicit "Implicit"
  Assert-Equal $Implicit.outputs.resultJsonPath "assets/tmp/computer-loop-check.json" "Implicit result path should use the stable default."
  Assert-True ($Implicit.outputs.outputDir.StartsWith("assets/tmp/computer-loop/")) "Implicit output dir should stay under computer-loop temp output."
  Assert-Equal (Get-FileHashOrMissing $ImplicitResultPath) $ImplicitResultBeforeHash "Default dry-run should not overwrite the stable result JSON."

  $DefaultResultPath = Join-Path $OutputDir "default-result.json"
  $Default = Invoke-Plan @("-ResultJsonPath", $DefaultResultPath)
  Assert-ComputerLoopPlanManifest $Default "Default"
  Assert-ComputerResultValid $DefaultResultPath
  $DefaultResult = Read-Result $DefaultResultPath
  Assert-ComputerLoopPlanManifest $DefaultResult.plan "Default dry-run result"

  Assert-True $Default.requestedLoops.desktop "Default computer loop should include desktop."
  Assert-True $Default.requestedLoops.windowsChrome "Default computer loop should include Windows Chrome."
  Assert-True (-not $Default.requestedLoops.phone) "Default computer loop should not include phone."
  Assert-True $Default.gates.fullLoopIncludeChrome "Full-loop command should include Chrome."
  Assert-True (-not $Default.gates.fullLoopIncludePhone) "Full-loop command should not include phone."
  Assert-True $Default.gates.browserEvidenceRequireDesktop "Browser evidence check should require desktop evidence."
  Assert-True $Default.gates.browserEvidenceRequireChrome "Browser evidence check should require Chrome evidence."
  Assert-True (-not $Default.gates.browserEvidenceRequirePhone) "Browser evidence check should not require phone evidence."
  Assert-Equal $Default.expectedEvidence.phoneEvidence "__phone_not_run__.json" "Computer-only dry-run should expose the skipped phone evidence sentinel."
  Assert-True $Default.gates.fullLoopWebReadiness.httpProbeBeforePortReuse "Computer loop should require full-loop HTTP web readiness probing."
  Assert-True $Default.gates.fullLoopWebReadiness.stalePortBlocksDuplicateStart "Computer loop should require stale web ports to block duplicate starts."
  Assert-Contains $Default.commands.fullLoop.display "check-full-loop.ps1" "Full-loop display command"
  Assert-Contains $Default.commands.fullLoop.display "-IncludeChrome" "Full-loop display command"
  $DefaultFullLoopScriptArg = Get-ArgumentValue $Default.commands.fullLoop.args "-File"
  $DefaultFullLoopOutputArg = Get-ArgumentValue $Default.commands.fullLoop.args "-PartialEvidenceDir"
  $DefaultFullLoopReportArg = Get-ArgumentValue $Default.commands.fullLoop.args "-ReportPath"
  $DefaultFullLoopSummaryArg = Get-ArgumentValue $Default.commands.fullLoop.args "-SummaryPath"
  Assert-Equal $DefaultFullLoopScriptArg "scripts/check-full-loop.ps1" "Full-loop script command path"
  Assert-Equal $DefaultFullLoopOutputArg $Default.outputs.outputDir "Full-loop output command path"
  Assert-Equal $DefaultFullLoopReportArg $Default.outputs.reportPath "Full-loop report command path"
  Assert-Equal $DefaultFullLoopSummaryArg $Default.outputs.summaryPath "Full-loop summary command path"
  Assert-NotContains $DefaultFullLoopScriptArg ([string]$Root) "Full-loop script command path should be portable"
  Assert-NotContains $DefaultFullLoopOutputArg ([string]$Root) "Full-loop output command path should be portable"
  Assert-NotContains $DefaultFullLoopReportArg ([string]$Root) "Full-loop report command path should be portable"
  Assert-NotContains $DefaultFullLoopSummaryArg ([string]$Root) "Full-loop summary command path should be portable"
  Assert-Contains $Default.commands.browserEvidence.display "check-browser-evidence.ps1" "Browser evidence display command"
  Assert-Contains $Default.commands.browserEvidence.display "-RequireDesktop" "Browser evidence display command"
  Assert-Contains $Default.commands.browserEvidence.display "-RequireChrome" "Browser evidence display command"
  $DefaultBrowserEvidenceScriptArg = Get-ArgumentValue $Default.commands.browserEvidence.args "-File"
  $DefaultBrowserEvidenceSummaryArg = Get-ArgumentValue $Default.commands.browserEvidence.args "-SummaryPath"
  $DefaultBrowserEvidenceResultArg = Get-ArgumentValue $Default.commands.browserEvidence.args "-ResultJsonPath"
  Assert-Equal $DefaultBrowserEvidenceScriptArg "scripts/check-browser-evidence.ps1" "Browser evidence script command path"
  Assert-Equal $DefaultBrowserEvidenceSummaryArg $Default.outputs.summaryPath "Browser evidence summary command path"
  Assert-Equal $DefaultBrowserEvidenceResultArg $Default.outputs.browserEvidenceResultJsonPath "Browser evidence result command path"
  Assert-NotContains $DefaultBrowserEvidenceScriptArg ([string]$Root) "Browser evidence script command path should be portable"
  Assert-NotContains $DefaultBrowserEvidenceSummaryArg ([string]$Root) "Browser evidence summary command path should be portable"
  Assert-NotContains $DefaultBrowserEvidenceResultArg ([string]$Root) "Browser evidence result command path should be portable"
  Assert-Equal $DefaultResult.mode "dry-run" "Dry-run result mode"
  Assert-Equal $DefaultResult.success $true "Dry-run result success"
  Assert-Equal $DefaultResult.plan.outputs.resultJsonPath $Default.outputs.resultJsonPath "Dry-run result should embed the same plan."
  Assert-True (-not $DefaultResult.plan.gates.browserEvidenceRequirePhone) "Dry-run result should preserve the skipped phone evidence gate."
  Assert-Equal $DefaultResult.plan.expectedEvidence.phoneEvidence "__phone_not_run__.json" "Dry-run result should preserve the skipped phone evidence sentinel."
  Assert-Equal $DefaultResult.proofSummary $null "Dry-run result should not include proof summary evidence."
  Assert-Equal $DefaultResult.browserEvidence $null "Dry-run result should not include nested browser evidence."
  Assert-ComputerResultChecksManifest $DefaultResult $Default "Dry-run result"

  $CustomResultPath = Join-Path $OutputDir "custom-result.json"
  $Custom = Invoke-Plan @(
    "-OutputDir",
    "assets/tmp/computer-loop-plan-selftest/custom-out",
    "-ReportPath",
    "assets/tmp/computer-loop-plan-selftest/custom-out/custom-report.md",
    "-SummaryPath",
    "assets/tmp/computer-loop-plan-selftest/custom-out/custom-summary.json",
    "-BrowserEvidenceResultJsonPath",
    "assets/tmp/computer-loop-plan-selftest/custom-out/custom-browser-evidence.json",
    "-ResultJsonPath",
    $CustomResultPath,
    "-SkipPreflight",
    "-SelfTest",
    "-StepTimeoutSeconds",
    "42"
  )
  Assert-ComputerLoopPlanManifest $Custom "Custom"
  Assert-ComputerResultValid $CustomResultPath
  $CustomResult = Read-Result $CustomResultPath
  Assert-ComputerLoopPlanManifest $CustomResult.plan "Custom dry-run result"

  Assert-Equal $Custom.outputs.outputDir "assets/tmp/computer-loop-plan-selftest/custom-out" "Custom output dir should be honored."
  Assert-Equal $Custom.outputs.reportPath "assets/tmp/computer-loop-plan-selftest/custom-out/custom-report.md" "Custom report path should be honored."
  Assert-Equal $Custom.outputs.summaryPath "assets/tmp/computer-loop-plan-selftest/custom-out/custom-summary.json" "Custom summary path should be honored."
  Assert-Equal $Custom.outputs.browserEvidenceResultJsonPath "assets/tmp/computer-loop-plan-selftest/custom-out/custom-browser-evidence.json" "Custom browser evidence result path should be honored."
  Assert-True $Custom.options.skipPreflight "Custom plan should preserve SkipPreflight."
  Assert-True $Custom.options.selfTest "Custom plan should preserve SelfTest."
  Assert-Equal $Custom.options.stepTimeoutSeconds 42 "Custom plan should preserve StepTimeoutSeconds."
  Assert-Contains $Custom.commands.fullLoop.display "-SkipPreflight" "Custom full-loop display command"
  Assert-Contains $Custom.commands.browserEvidence.display "-SelfTest" "Custom browser evidence display command"
  Assert-True (-not $CustomResult.plan.gates.browserEvidenceRequirePhone) "Custom dry-run result should preserve the skipped phone evidence gate."
  Assert-Equal $CustomResult.plan.expectedEvidence.phoneEvidence "__phone_not_run__.json" "Custom dry-run result should preserve the skipped phone evidence sentinel."
  Assert-Equal $CustomResult.proofSummary $null "Custom dry-run result should not include proof summary evidence."
  Assert-Equal $CustomResult.browserEvidence $null "Custom dry-run result should not include nested browser evidence."
  Assert-ComputerResultChecksManifest $CustomResult $Custom "Custom dry-run result"

  $FailureResultPath = Join-Path $OutputDir "failed-result.json"
  $FailureOutput = Invoke-ComputerLoopExpectFailure @(
    "-AppUrl",
    "not-a-url",
    "-ResultJsonPath",
    $FailureResultPath,
    "-OutputDir",
    "assets/tmp/computer-loop-plan-selftest/failed-out"
  )
  Assert-True (Test-Path -LiteralPath $FailureResultPath -PathType Leaf) "Failed computer loop should still write result JSON."
  Assert-ComputerResultValid $FailureResultPath
  $FailureResult = Read-Result $FailureResultPath
  Assert-ComputerLoopPlanManifest $FailureResult.plan "Failed result"
  Assert-Equal $FailureResult.mode "failed" "Failed result mode"
  Assert-Equal $FailureResult.success $false "Failed result success"
  Assert-Equal $FailureResult.failure.stage "computer full loop" "Failed result stage"
  Assert-Equal $FailureResult.failure.checkName "computer full loop" "Failed result check name"
  Assert-FailureManifest $FailureResult.failure "Failed result"
  Assert-Contains $FailureResult.failure.command "check-full-loop.ps1" "Failed result command"
  Assert-Contains $FailureOutput "computer full loop failed" "Failed command output"

  $PostProcessFailureResultPath = Join-Path $OutputDir "failed-postprocess-result.json"
  $PostProcessOutputDir = "assets/tmp/computer-loop-plan-selftest/failed-postprocess-out"
  $PostProcessFailureOutput = Invoke-ComputerLoopExpectFailure `
    -Environment @{ HOMECUE_COMPUTER_LOOP_SELFTEST_SKIP_CHILDREN = "1" } `
    -Arguments @(
      "-ResultJsonPath",
      $PostProcessFailureResultPath,
      "-OutputDir",
      $PostProcessOutputDir
    )
  Assert-True (Test-Path -LiteralPath $PostProcessFailureResultPath -PathType Leaf) "Post-process failure should still write result JSON."
  Assert-ComputerResultValid $PostProcessFailureResultPath
  $PostProcessFailureResult = Read-Result $PostProcessFailureResultPath
  Assert-ComputerLoopPlanManifest $PostProcessFailureResult.plan "Post-process failed result"
  Assert-Equal $PostProcessFailureResult.mode "failed" "Post-process failed result mode"
  Assert-Equal $PostProcessFailureResult.success $false "Post-process failed result success"
  Assert-Equal $PostProcessFailureResult.failure.stage "result validation" "Post-process failed result stage"
  Assert-Equal $PostProcessFailureResult.failure.checkName "result validation" "Post-process failed result check name"
  Assert-Equal $PostProcessFailureResult.failure.command "post-process computer loop evidence" "Post-process failed result command"
  Assert-FailureManifest $PostProcessFailureResult.failure "Post-process failed result"
  Assert-Contains $PostProcessFailureOutput "post-process computer loop evidence" "Post-process failed command output"
}
finally {
  if ($HadImplicitResult) {
    [System.IO.File]::WriteAllBytes($ImplicitResultPath, $ImplicitResultBackup)
  }
  else {
    Remove-Item -LiteralPath $ImplicitResultPath -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Computer loop plan self-test passed."
