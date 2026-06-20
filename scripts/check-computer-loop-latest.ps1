param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputDir = "",
  [string]$ReportPath = "",
  [string]$SummaryPath = "",
  [string]$BrowserEvidenceResultJsonPath = "",
  [string]$ResultJsonPath = "",
  [switch]$SkipPreflight,
  [switch]$SelfTest,
  [switch]$DryRun,
  [int]$StartupTimeoutSeconds = 60,
  [int]$StepTimeoutSeconds = 180,
  [int]$BrowserWrapperSharedStateLockTimeoutSeconds = 1200
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$LatestResultJsonPath = Join-Path $Root "assets\tmp\computer-loop-check-latest.json"

if ($PSBoundParameters.ContainsKey("ResultJsonPath")) {
  throw "check-computer-loop-latest.ps1 always writes assets/tmp/computer-loop-check-latest.json; omit -ResultJsonPath."
}

if ($DryRun) {
  throw "Use check-computer-loop.ps1 -DryRun to inspect the plan without overwriting latest result evidence."
}

$Arguments = @{
  AppUrl = $AppUrl
  ApiBase = $ApiBase
  StartupTimeoutSeconds = $StartupTimeoutSeconds
  StepTimeoutSeconds = $StepTimeoutSeconds
  BrowserWrapperSharedStateLockTimeoutSeconds = $BrowserWrapperSharedStateLockTimeoutSeconds
  ResultJsonPath = $LatestResultJsonPath
}
if ($OutputDir) {
  $Arguments.OutputDir = $OutputDir
}
if ($ReportPath) {
  $Arguments.ReportPath = $ReportPath
}
if ($SummaryPath) {
  $Arguments.SummaryPath = $SummaryPath
}
if ($BrowserEvidenceResultJsonPath) {
  $Arguments.BrowserEvidenceResultJsonPath = $BrowserEvidenceResultJsonPath
}
if ($SkipPreflight) {
  $Arguments.SkipPreflight = $true
}
if ($SelfTest) {
  $Arguments.SelfTest = $true
}

& "$PSScriptRoot\check-computer-loop.ps1" @Arguments
exit $LASTEXITCODE
