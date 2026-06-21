$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$OutputDir = Join-Path $Root "assets\tmp\device-loop-plan-selftest"
$ImplicitResultPath = Join-Path $Root "assets\tmp\device-loop-check.json"
$LatestResultPath = Join-Path $Root "assets\tmp\device-loop-check-latest.json"

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
$HadLatestResult = Test-Path -LiteralPath $LatestResultPath -PathType Leaf
$LatestResultBackup = if ($HadLatestResult) {
  [System.IO.File]::ReadAllBytes($LatestResultPath)
} else {
  $null
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Invoke-Plan {
  param([string[]]$Arguments)

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-device-loop.ps1" -DryRun @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "check-device-loop.ps1 -DryRun failed: $($Arguments -join ' ')"
  }

  return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Read-Result {
  param([string]$Path)

  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
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

function Invoke-DeviceLoopExpectFailure {
  param(
    [string[]]$Arguments,
    [hashtable]$Environment = @{},
    [string]$ScriptName = "check-device-loop.ps1"
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

function Assert-DeviceLoopPlanManifest {
  param(
    [object]$Plan,
    [string]$Message
  )

  Assert-ObjectKeys $Plan @("runId", "requestedLoops", "options", "outputs", "expectedEvidence", "gates", "hardware", "commands") "$Message plan fields"
  Assert-ObjectKeys $Plan.requestedLoops @("desktop", "phone", "windowsChrome", "esp32Serial") "$Message requestedLoops fields"
  Assert-ObjectKeys $Plan.options @("skipPreflight", "selfTest", "adbPathProvided", "startupTimeoutSeconds", "stepTimeoutSeconds", "browserWrapperSharedStateLockTimeoutSeconds", "maxAgeMinutes") "$Message options fields"
  Assert-ObjectKeys $Plan.outputs @("outputDir", "reportPath", "summaryPath", "resultJsonPath", "browserEvidenceResultJsonPath", "esp32SerialLogPath", "esp32SerialResultJsonPath", "esp32SerialRecheckResultJsonPath") "$Message outputs fields"
  Assert-ObjectKeys $Plan.expectedEvidence @("desktopEvidence", "phoneEvidence", "windowsChromeEvidence", "esp32SerialLog", "esp32SerialResult") "$Message expectedEvidence fields"
  Assert-ObjectKeys $Plan.gates @("fullLoopIncludePhone", "fullLoopIncludeChrome", "fullLoopIncludeEsp32Serial", "fullLoopIsolateEvidence", "browserEvidenceRequireDesktop", "browserEvidenceRequirePhone", "browserEvidenceRequireChrome", "browserEvidenceSelfTest", "browserWrapperSharedStateLock", "fullLoopWebReadiness", "esp32Serial") "$Message gates fields"
  Assert-ObjectKeys $Plan.gates.browserWrapperSharedStateLock @("name", "timeoutSeconds") "$Message browser wrapper lock fields"
  Assert-ObjectKeys $Plan.gates.fullLoopWebReadiness @("httpProbeBeforePortReuse", "stalePortBlocksDuplicateStart", "lanReachabilityForEsp32") "$Message web readiness fields"
  Assert-ObjectKeys $Plan.gates.esp32Serial @("run", "firmwareFlowRequired", "autoSerialLevel4", "requireInteraction", "savedLogRecheck") "$Message ESP32 gate fields"
  Assert-ObjectKeys $Plan.hardware @("esp32Serial") "$Message hardware fields"
  Assert-ObjectKeys $Plan.hardware.esp32Serial @("run", "port", "baud", "seconds", "serialCommandIndex", "skipReset") "$Message ESP32 hardware fields"
  Assert-ObjectKeys $Plan.commands @("fullLoop", "browserEvidence", "esp32SerialRecheck") "$Message commands fields"
}

function Assert-DeviceResultChecksManifest {
  param(
    [object]$Result,
    [object]$Plan,
    [string]$Message
  )

  $Checks = @($Result.checks)
  Assert-Equal $Checks.Count 3 "$Message should describe the three device-loop checks."
  Assert-Equal $Checks[0].name "full device loop" "$Message first check name"
  Assert-Equal $Checks[1].name "saved browser evidence recheck" "$Message second check name"
  Assert-Equal $Checks[2].name "saved ESP32 serial log recheck" "$Message third check name"
  Assert-Equal $Checks[0].command $Plan.commands.fullLoop.display "$Message full-loop command"
  Assert-Equal $Checks[1].command $Plan.commands.browserEvidence.display "$Message browser-evidence command"
  Assert-Equal $Checks[2].command $Plan.commands.esp32SerialRecheck.display "$Message ESP32 recheck command"
  Assert-Equal $Checks[0].esp32SerialLogPath $Plan.outputs.esp32SerialLogPath "$Message full-loop ESP32 log path"
  Assert-Equal $Checks[0].esp32SerialResultJsonPath $Plan.outputs.esp32SerialResultJsonPath "$Message full-loop ESP32 result path"
  Assert-Equal $Checks[1].resultJsonPath $Plan.outputs.browserEvidenceResultJsonPath "$Message browser result path"
  Assert-Equal $Checks[2].logPath $Plan.outputs.esp32SerialLogPath "$Message ESP32 recheck log path"
  Assert-Equal $Checks[2].resultJsonPath $Plan.outputs.esp32SerialRecheckResultJsonPath "$Message ESP32 recheck result path"
}

function Assert-DeviceLoopRequiredGates {
  param(
    [object]$Plan,
    [string]$Message
  )

  Assert-True $Plan.requestedLoops.desktop "$Message should request desktop."
  Assert-True $Plan.requestedLoops.phone "$Message should request phone."
  Assert-True $Plan.requestedLoops.windowsChrome "$Message should request Windows Chrome."
  Assert-True $Plan.requestedLoops.esp32Serial "$Message should request ESP32 serial."
  Assert-True $Plan.gates.fullLoopIncludePhone "$Message full-loop should include phone."
  Assert-True $Plan.gates.fullLoopIncludeChrome "$Message full-loop should include Chrome."
  Assert-True $Plan.gates.fullLoopIncludeEsp32Serial "$Message full-loop should include ESP32 serial."
  Assert-True $Plan.gates.fullLoopIsolateEvidence "$Message full-loop should isolate complete device evidence."
  Assert-True $Plan.gates.browserEvidenceRequireDesktop "$Message browser evidence should require desktop."
  Assert-True $Plan.gates.browserEvidenceRequirePhone "$Message browser evidence should require phone."
  Assert-True $Plan.gates.browserEvidenceRequireChrome "$Message browser evidence should require Chrome."
  Assert-True $Plan.gates.esp32Serial.firmwareFlowRequired "$Message should require firmware-flow gate."
  Assert-True $Plan.gates.esp32Serial.autoSerialLevel4 "$Message should use auto serial Level 4."
  Assert-True $Plan.gates.esp32Serial.savedLogRecheck "$Message should recheck the saved ESP32 log."
}

try {
  $DeviceLoopScriptSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "check-device-loop.ps1")
  Assert-Contains $DeviceLoopScriptSource "Device loop proof summary" "Device loop wrapper should print a compact proof summary."
  Assert-Contains $DeviceLoopScriptSource "frontCamera={" "Device loop summary should include phone front-camera proof."
  Assert-Contains $DeviceLoopScriptSource "esp32Log={" "Device loop summary should include saved ESP32 serial log path."
  Assert-Contains $DeviceLoopScriptSource "HOMECUE_DEVICE_LOOP_SELFTEST_SKIP_CHILDREN" "Device loop should support child-skip failure selftests."

  $LatestWrapperSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "check-device-loop-latest.ps1")
  Assert-Contains $LatestWrapperSource "assets\tmp\device-loop-check-latest.json" "Latest wrapper should target the stable latest result JSON path."
  Assert-Contains $LatestWrapperSource "check-device-loop.ps1" "Latest wrapper should delegate to the device loop wrapper."
  Assert-Contains $LatestWrapperSource "-ResultJsonPath" "Latest wrapper should pass ResultJsonPath explicitly."
  Assert-Contains $LatestWrapperSource "-DryRun" "Latest wrapper should guard against dry-run overwriting latest evidence."
  Assert-Contains $LatestWrapperSource '$Arguments.SelfTest = $true' "Latest wrapper should forward SelfTest as a switch parameter."
  Assert-Contains $LatestWrapperSource '$Arguments.Esp32SkipReset = $true' "Latest wrapper should forward Esp32SkipReset as a switch parameter."

  $LatestDryRunFailure = Invoke-DeviceLoopExpectFailure -ScriptName "check-device-loop-latest.ps1" -Arguments @("-DryRun")
  Assert-Contains $LatestDryRunFailure "without overwriting latest result evidence" "Latest wrapper dry-run guard output"
  $LatestResultPathFailure = Invoke-DeviceLoopExpectFailure -ScriptName "check-device-loop-latest.ps1" -Arguments @(
    "-ResultJsonPath",
    "assets/tmp/device-loop-plan-selftest/should-not-write.json"
  )
  Assert-Contains $LatestResultPathFailure "always writes assets/tmp/device-loop-check-latest.json" "Latest wrapper result-path guard output"

  $LatestForwardFailure = Invoke-DeviceLoopExpectFailure `
    -ScriptName "check-device-loop-latest.ps1" `
    -Environment @{ HOMECUE_DEVICE_LOOP_SELFTEST_SKIP_CHILDREN = "1" } `
    -Arguments @(
      "-OutputDir",
      "assets/tmp/device-loop-plan-selftest/latest-out",
      "-BrowserEvidenceResultJsonPath",
      "assets/tmp/device-loop-plan-selftest/latest-out/missing-browser-evidence.json",
      "-SelfTest",
      "-MaxAgeMinutes",
      "30",
      "-Esp32Port",
      "COM9",
      "-Esp32SerialSeconds",
      "12",
      "-Esp32SerialCommandIndex",
      "2",
      "-Esp32SkipReset"
    )
  Assert-Contains $LatestForwardFailure "post-process device loop evidence" "Latest wrapper forwarded-run failure output"
  Assert-True (Test-Path -LiteralPath $LatestResultPath -PathType Leaf) "Latest wrapper should write the stable latest result JSON."
  $LatestForwardResult = Read-Result $LatestResultPath
  Assert-DeviceLoopPlanManifest $LatestForwardResult.plan "Latest forwarded failed result"
  Assert-DeviceLoopRequiredGates $LatestForwardResult.plan "Latest forwarded failed result"
  Assert-Equal $LatestForwardResult.plan.outputs.resultJsonPath "assets/tmp/device-loop-check-latest.json" "Latest wrapper should force the stable latest result path."
  Assert-Equal $LatestForwardResult.plan.outputs.outputDir "assets/tmp/device-loop-plan-selftest/latest-out" "Latest wrapper should forward OutputDir."
  Assert-Equal $LatestForwardResult.plan.outputs.browserEvidenceResultJsonPath "assets/tmp/device-loop-plan-selftest/latest-out/missing-browser-evidence.json" "Latest wrapper should forward BrowserEvidenceResultJsonPath."
  Assert-True $LatestForwardResult.plan.options.selfTest "Latest wrapper should forward SelfTest into the delegated plan."
  Assert-Equal $LatestForwardResult.plan.options.maxAgeMinutes 30 "Latest wrapper should forward MaxAgeMinutes into the delegated plan."
  Assert-Equal $LatestForwardResult.plan.hardware.esp32Serial.port "COM9" "Latest wrapper should forward custom ESP32 port."
  Assert-Equal $LatestForwardResult.plan.hardware.esp32Serial.seconds 12 "Latest wrapper should forward custom ESP32 duration."
  Assert-Equal $LatestForwardResult.plan.hardware.esp32Serial.serialCommandIndex 2 "Latest wrapper should forward custom serial command index."
  Assert-True $LatestForwardResult.plan.hardware.esp32Serial.skipReset "Latest wrapper should forward ESP32 skip reset."

  $Implicit = Invoke-Plan @()
  Assert-DeviceLoopPlanManifest $Implicit "Implicit"
  Assert-DeviceLoopRequiredGates $Implicit "Implicit"
  Assert-Equal $Implicit.outputs.resultJsonPath "assets/tmp/device-loop-check.json" "Implicit result path should use the stable default."
  Assert-True ($Implicit.outputs.outputDir.StartsWith("assets/tmp/device-loop/")) "Implicit output dir should stay under device-loop temp output."
  Assert-Equal (Get-FileHashOrMissing $ImplicitResultPath) $ImplicitResultBeforeHash "Default dry-run should not overwrite the stable result JSON."
  Assert-Equal $Implicit.expectedEvidence.esp32SerialLog $Implicit.outputs.esp32SerialLogPath "Implicit ESP32 log expected evidence should match output."
  Assert-Equal $Implicit.expectedEvidence.esp32SerialResult $Implicit.outputs.esp32SerialResultJsonPath "Implicit ESP32 result expected evidence should match output."

  $DefaultResultPath = Join-Path $OutputDir "default-result.json"
  $Default = Invoke-Plan @("-ResultJsonPath", $DefaultResultPath)
  Assert-DeviceLoopPlanManifest $Default "Default"
  Assert-DeviceLoopRequiredGates $Default "Default"
  $DefaultResult = Read-Result $DefaultResultPath
  Assert-DeviceLoopPlanManifest $DefaultResult.plan "Default dry-run result"
  Assert-Equal $DefaultResult.mode "dry-run" "Dry-run result mode"
  Assert-Equal $DefaultResult.success $true "Dry-run result success"
  Assert-Equal $DefaultResult.plan.outputs.resultJsonPath $Default.outputs.resultJsonPath "Dry-run result should embed the same plan."
  Assert-Equal $DefaultResult.proofSummary $null "Dry-run result should not include proof summary evidence."
  Assert-Equal $DefaultResult.browserEvidence $null "Dry-run result should not include nested browser evidence."
  Assert-Equal $DefaultResult.esp32Serial.liveCapture $null "Dry-run result should not include ESP32 live capture evidence."
  Assert-Equal $DefaultResult.esp32Serial.savedLogRecheck $null "Dry-run result should not include ESP32 saved-log evidence."
  Assert-DeviceResultChecksManifest $DefaultResult $Default "Dry-run result"

  Assert-Contains $Default.commands.fullLoop.display "check-full-loop.ps1" "Full-loop display command"
  Assert-Contains $Default.commands.fullLoop.display "-IncludePhone" "Full-loop display command"
  Assert-Contains $Default.commands.fullLoop.display "-IncludeChrome" "Full-loop display command"
  Assert-Contains $Default.commands.fullLoop.display "-IncludeEsp32Serial" "Full-loop display command"
  Assert-Contains $Default.commands.fullLoop.display "-IsolateEvidence" "Full-loop display command"
  Assert-Contains $Default.commands.browserEvidence.display "check-browser-evidence.ps1" "Browser evidence display command"
  Assert-Contains $Default.commands.browserEvidence.display "-RequireDesktop" "Browser evidence display command"
  Assert-Contains $Default.commands.browserEvidence.display "-RequirePhone" "Browser evidence display command"
  Assert-Contains $Default.commands.browserEvidence.display "-RequireChrome" "Browser evidence display command"
  Assert-Contains $Default.commands.esp32SerialRecheck.display "check-esp32-serial-log.ps1" "ESP32 recheck display command"
  Assert-Contains $Default.commands.esp32SerialRecheck.display "-LogPath" "ESP32 recheck display command"
  Assert-Contains $Default.commands.esp32SerialRecheck.display "-RequireInteraction" "ESP32 recheck display command"
  Assert-Contains $Default.commands.esp32SerialRecheck.display "-Required" "ESP32 recheck display command"
  Assert-Equal (Get-ArgumentValue $Default.commands.fullLoop.args "-PartialEvidenceDir") $Default.outputs.outputDir "Full-loop output command path"
  Assert-Equal (Get-ArgumentValue $Default.commands.fullLoop.args "-ReportPath") $Default.outputs.reportPath "Full-loop report command path"
  Assert-Equal (Get-ArgumentValue $Default.commands.fullLoop.args "-SummaryPath") $Default.outputs.summaryPath "Full-loop summary command path"
  Assert-Equal (Get-ArgumentValue $Default.commands.fullLoop.args "-Esp32Port") "COM7" "Default ESP32 port command arg"
  Assert-Equal (Get-ArgumentValue $Default.commands.fullLoop.args "-Esp32SerialSeconds") "45" "Default ESP32 duration command arg"
  Assert-Equal (Get-ArgumentValue $Default.commands.browserEvidence.args "-SummaryPath") $Default.outputs.summaryPath "Browser evidence summary command path"
  Assert-Equal (Get-ArgumentValue $Default.commands.browserEvidence.args "-ResultJsonPath") $Default.outputs.browserEvidenceResultJsonPath "Browser evidence result command path"
  Assert-Equal (Get-ArgumentValue $Default.commands.esp32SerialRecheck.args "-LogPath") $Default.outputs.esp32SerialLogPath "ESP32 saved-log recheck path"
  Assert-Equal (Get-ArgumentValue $Default.commands.esp32SerialRecheck.args "-ResultJsonPath") $Default.outputs.esp32SerialRecheckResultJsonPath "ESP32 recheck result path"
  Assert-NotContains (Get-ArgumentValue $Default.commands.fullLoop.args "-File") ([string]$Root) "Full-loop script command path should be portable"
  Assert-NotContains (Get-ArgumentValue $Default.commands.browserEvidence.args "-File") ([string]$Root) "Browser evidence script command path should be portable"
  Assert-NotContains (Get-ArgumentValue $Default.commands.esp32SerialRecheck.args "-File") ([string]$Root) "ESP32 recheck script command path should be portable"

  $CustomResultPath = Join-Path $OutputDir "custom-result.json"
  $Custom = Invoke-Plan @(
    "-OutputDir",
    "assets/tmp/device-loop-plan-selftest/custom-out",
    "-ReportPath",
    "assets/tmp/device-loop-plan-selftest/custom-out/custom-report.md",
    "-SummaryPath",
    "assets/tmp/device-loop-plan-selftest/custom-out/custom-summary.json",
    "-BrowserEvidenceResultJsonPath",
    "assets/tmp/device-loop-plan-selftest/custom-out/custom-browser-evidence.json",
    "-Esp32SerialRecheckResultJsonPath",
    "assets/tmp/device-loop-plan-selftest/custom-out/custom-esp32-recheck.json",
    "-ResultJsonPath",
    $CustomResultPath,
    "-SkipPreflight",
    "-SelfTest",
    "-MaxAgeMinutes",
    "30",
    "-StepTimeoutSeconds",
    "42",
    "-Esp32Port",
    "COM9",
    "-Esp32Baud",
    "921600",
    "-Esp32SerialSeconds",
    "12",
    "-Esp32SerialCommandIndex",
    "2",
    "-Esp32SkipReset"
  )
  Assert-DeviceLoopPlanManifest $Custom "Custom"
  Assert-DeviceLoopRequiredGates $Custom "Custom"
  $CustomResult = Read-Result $CustomResultPath
  Assert-DeviceLoopPlanManifest $CustomResult.plan "Custom dry-run result"
  Assert-Equal $Custom.outputs.outputDir "assets/tmp/device-loop-plan-selftest/custom-out" "Custom output dir should be honored."
  Assert-Equal $Custom.outputs.reportPath "assets/tmp/device-loop-plan-selftest/custom-out/custom-report.md" "Custom report path should be honored."
  Assert-Equal $Custom.outputs.summaryPath "assets/tmp/device-loop-plan-selftest/custom-out/custom-summary.json" "Custom summary path should be honored."
  Assert-Equal $Custom.outputs.browserEvidenceResultJsonPath "assets/tmp/device-loop-plan-selftest/custom-out/custom-browser-evidence.json" "Custom browser evidence result path should be honored."
  Assert-Equal $Custom.outputs.esp32SerialLogPath "assets/tmp/device-loop-plan-selftest/custom-out/esp32-serial-level4.log" "Custom output dir should own ESP32 serial log."
  Assert-Equal $Custom.outputs.esp32SerialResultJsonPath "assets/tmp/device-loop-plan-selftest/custom-out/esp32-serial-level4.json" "Custom output dir should own ESP32 live result."
  Assert-Equal $Custom.outputs.esp32SerialRecheckResultJsonPath "assets/tmp/device-loop-plan-selftest/custom-out/custom-esp32-recheck.json" "Custom ESP32 recheck path should be honored."
  Assert-True $Custom.options.skipPreflight "Custom plan should preserve SkipPreflight."
  Assert-True $Custom.options.selfTest "Custom plan should preserve SelfTest."
  Assert-Equal $Custom.options.maxAgeMinutes 30 "Custom plan should preserve MaxAgeMinutes."
  Assert-Equal $Custom.options.stepTimeoutSeconds 42 "Custom plan should preserve StepTimeoutSeconds."
  Assert-Equal $Custom.hardware.esp32Serial.port "COM9" "Custom plan should preserve ESP32 port."
  Assert-Equal $Custom.hardware.esp32Serial.baud 921600 "Custom plan should preserve ESP32 baud."
  Assert-Equal $Custom.hardware.esp32Serial.seconds 12 "Custom plan should preserve ESP32 duration."
  Assert-Equal $Custom.hardware.esp32Serial.serialCommandIndex 2 "Custom plan should preserve serial command index."
  Assert-True $Custom.hardware.esp32Serial.skipReset "Custom plan should preserve ESP32 skip-reset."
  Assert-Contains $Custom.commands.fullLoop.display "-SkipPreflight" "Custom full-loop display command"
  Assert-Contains $Custom.commands.fullLoop.display "-Esp32SkipReset" "Custom full-loop display command"
  Assert-Contains $Custom.commands.browserEvidence.display "-SelfTest" "Custom browser evidence display command"
  Assert-Contains $Custom.commands.browserEvidence.display "-MaxAgeMinutes" "Custom browser evidence display command"
  Assert-Equal (Get-ArgumentValue $Custom.commands.browserEvidence.args "-MaxAgeMinutes") "30" "Custom browser evidence MaxAgeMinutes command arg"
  Assert-DeviceResultChecksManifest $CustomResult $Custom "Custom dry-run result"

  $PostProcessFailureResultPath = Join-Path $OutputDir "failed-postprocess-result.json"
  $PostProcessFailureOutput = Invoke-DeviceLoopExpectFailure `
    -Environment @{ HOMECUE_DEVICE_LOOP_SELFTEST_SKIP_CHILDREN = "1" } `
    -Arguments @(
      "-ResultJsonPath",
      $PostProcessFailureResultPath,
      "-OutputDir",
      "assets/tmp/device-loop-plan-selftest/failed-postprocess-out"
    )
  Assert-True (Test-Path -LiteralPath $PostProcessFailureResultPath -PathType Leaf) "Post-process failure should still write result JSON."
  $PostProcessFailureResult = Read-Result $PostProcessFailureResultPath
  Assert-DeviceLoopPlanManifest $PostProcessFailureResult.plan "Post-process failed result"
  Assert-Equal $PostProcessFailureResult.mode "failed" "Post-process failed result mode"
  Assert-Equal $PostProcessFailureResult.success $false "Post-process failed result success"
  Assert-Equal $PostProcessFailureResult.failure.stage "result validation" "Post-process failed result stage"
  Assert-Equal $PostProcessFailureResult.failure.checkName "result validation" "Post-process failed result check name"
  Assert-Equal $PostProcessFailureResult.failure.command "post-process device loop evidence" "Post-process failed result command"
  Assert-Contains $PostProcessFailureOutput "post-process device loop evidence" "Post-process failed command output"
}
finally {
  if ($HadImplicitResult) {
    [System.IO.File]::WriteAllBytes($ImplicitResultPath, $ImplicitResultBackup)
  }
  else {
    Remove-Item -LiteralPath $ImplicitResultPath -Force -ErrorAction SilentlyContinue
  }
  if ($HadLatestResult) {
    [System.IO.File]::WriteAllBytes($LatestResultPath, $LatestResultBackup)
  }
  else {
    Remove-Item -LiteralPath $LatestResultPath -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Device loop plan self-test passed."
