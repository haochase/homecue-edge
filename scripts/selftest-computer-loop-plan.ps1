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

  Push-Location (Join-Path $Root "apps\web")
  try {
    npm run computer:result:check -- $Path | Out-Host
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
    [hashtable]$Environment = @{}
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
      -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\check-computer-loop.ps1") + $Arguments) `
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
    throw "check-computer-loop.ps1 should have failed: $($Arguments -join ' ')"
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

try {
  $Implicit = Invoke-Plan @()
  Assert-Equal $Implicit.outputs.resultJsonPath "assets/tmp/computer-loop-check.json" "Implicit result path should use the stable default."
  Assert-True ($Implicit.outputs.outputDir.StartsWith("assets/tmp/computer-loop/")) "Implicit output dir should stay under computer-loop temp output."
  Assert-Equal (Get-FileHashOrMissing $ImplicitResultPath) $ImplicitResultBeforeHash "Default dry-run should not overwrite the stable result JSON."

  $DefaultResultPath = Join-Path $OutputDir "default-result.json"
  $Default = Invoke-Plan @("-ResultJsonPath", $DefaultResultPath)
  Assert-ComputerResultValid $DefaultResultPath
  $DefaultResult = Read-Result $DefaultResultPath

  Assert-True $Default.requestedLoops.desktop "Default computer loop should include desktop."
  Assert-True $Default.requestedLoops.windowsChrome "Default computer loop should include Windows Chrome."
  Assert-True (-not $Default.requestedLoops.phone) "Default computer loop should not include phone."
  Assert-True $Default.gates.fullLoopIncludeChrome "Full-loop command should include Chrome."
  Assert-True (-not $Default.gates.fullLoopIncludePhone) "Full-loop command should not include phone."
  Assert-True $Default.gates.browserEvidenceRequireDesktop "Browser evidence check should require desktop evidence."
  Assert-True $Default.gates.browserEvidenceRequireChrome "Browser evidence check should require Chrome evidence."
  Assert-True (-not $Default.gates.browserEvidenceRequirePhone) "Browser evidence check should not require phone evidence."
  Assert-Contains $Default.commands.fullLoop.display "check-full-loop.ps1" "Full-loop display command"
  Assert-Contains $Default.commands.fullLoop.display "-IncludeChrome" "Full-loop display command"
  Assert-Contains $Default.commands.browserEvidence.display "check-browser-evidence.ps1" "Browser evidence display command"
  Assert-Contains $Default.commands.browserEvidence.display "-RequireDesktop" "Browser evidence display command"
  Assert-Contains $Default.commands.browserEvidence.display "-RequireChrome" "Browser evidence display command"
  Assert-Equal $DefaultResult.mode "dry-run" "Dry-run result mode"
  Assert-Equal $DefaultResult.success $true "Dry-run result success"
  Assert-Equal $DefaultResult.plan.outputs.resultJsonPath $Default.outputs.resultJsonPath "Dry-run result should embed the same plan."
  Assert-True (@($DefaultResult.checks).Count -eq 2) "Dry-run result should describe the two computer-loop checks."

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
  Assert-ComputerResultValid $CustomResultPath

  Assert-Equal $Custom.outputs.outputDir "assets/tmp/computer-loop-plan-selftest/custom-out" "Custom output dir should be honored."
  Assert-Equal $Custom.outputs.reportPath "assets/tmp/computer-loop-plan-selftest/custom-out/custom-report.md" "Custom report path should be honored."
  Assert-Equal $Custom.outputs.summaryPath "assets/tmp/computer-loop-plan-selftest/custom-out/custom-summary.json" "Custom summary path should be honored."
  Assert-Equal $Custom.outputs.browserEvidenceResultJsonPath "assets/tmp/computer-loop-plan-selftest/custom-out/custom-browser-evidence.json" "Custom browser evidence result path should be honored."
  Assert-True $Custom.options.skipPreflight "Custom plan should preserve SkipPreflight."
  Assert-True $Custom.options.selfTest "Custom plan should preserve SelfTest."
  Assert-Equal $Custom.options.stepTimeoutSeconds 42 "Custom plan should preserve StepTimeoutSeconds."
  Assert-Contains $Custom.commands.fullLoop.display "-SkipPreflight" "Custom full-loop display command"
  Assert-Contains $Custom.commands.browserEvidence.display "-SelfTest" "Custom browser evidence display command"

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
  Assert-Equal $FailureResult.mode "failed" "Failed result mode"
  Assert-Equal $FailureResult.success $false "Failed result success"
  Assert-Equal $FailureResult.failure.stage "computer full loop" "Failed result stage"
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
  Assert-Equal $PostProcessFailureResult.mode "failed" "Post-process failed result mode"
  Assert-Equal $PostProcessFailureResult.success $false "Post-process failed result success"
  Assert-Equal $PostProcessFailureResult.failure.stage "result validation" "Post-process failed result stage"
  Assert-Equal $PostProcessFailureResult.failure.command "post-process computer loop evidence" "Post-process failed result command"
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
