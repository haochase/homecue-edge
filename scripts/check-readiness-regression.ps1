param(
  [string]$ResultRoot = "",
  [switch]$ProbePort,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

function New-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = ""
  )

  $Status = if ($Ok) { "OK" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)

  $script:Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      ok = [bool]$Ok
      detail = $Detail
    })

  if (-not $Ok) {
    $script:Failures.Add($Name)
  }
}

function Invoke-Tool {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments
  )

  & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments | Out-Host
  return $LASTEXITCODE
}

function Invoke-ReadinessRun {
  param(
    [string]$Name,
    [string]$JsonPath,
    [string]$MarkdownPath,
    [switch]$Strict
  )

  $Args = New-Object System.Collections.Generic.List[string]
  if (-not $ProbePort) {
    $Args.Add("-SkipPortProbe")
  }
  $Args.Add("-ResultJsonPath")
  $Args.Add($JsonPath)
  $Args.Add("-ResultMarkdownPath")
  $Args.Add($MarkdownPath)
  if ($Strict) {
    $Args.Add("-FailOnBlockingGaps")
  }

  Write-Host ""
  Write-Host ("Running {0} readiness..." -f $Name)
  $ExitCode = Invoke-Tool -ScriptPath (Join-Path $PSScriptRoot "check-proof-readiness.ps1") -Arguments $Args.ToArray()
  $Json = Read-JsonFile -Path $JsonPath
  $ExpectedExitCode = if ($Json -and $Json.gateOutcome) { [int]$Json.gateOutcome.expectedExitCode } else { -1 }
  $ReleaseGapSummary = if ($Json -and $Json.evidence -and $Json.evidence.releaseGapSummary) { $Json.evidence.releaseGapSummary } else { $null }
  Add-Check ("{0} readiness exit matches gateOutcome" -f $Name) ($ExitCode -eq $ExpectedExitCode) ("actual={0}, expected={1}" -f $ExitCode, $ExpectedExitCode)

  return [pscustomobject]@{
    name = $Name
    jsonPath = $JsonPath
    markdownPath = $MarkdownPath
    exitCode = [int]$ExitCode
    expectedExitCode = [int]$ExpectedExitCode
    gateStatus = if ($Json -and $Json.gateOutcome) { $Json.gateOutcome.status } else { "" }
    gateReason = if ($Json -and $Json.gateOutcome) { $Json.gateOutcome.reason } else { "" }
    readyForRelease = if ($Json) { [bool]$Json.readyForRelease } else { $false }
    releaseGapTotalCount = if ($ReleaseGapSummary) { [int]$ReleaseGapSummary.totalCount } else { -1 }
    blockingGapCount = if ($ReleaseGapSummary) { [int]$ReleaseGapSummary.blockingCount } else { -1 }
    followUpGapCount = if ($ReleaseGapSummary) { [int]$ReleaseGapSummary.followUpCount } else { -1 }
    blockingGapIds = if ($ReleaseGapSummary) { [string[]]@($ReleaseGapSummary.blockingIds) } else { [string[]]@() }
    followUpGapIds = if ($ReleaseGapSummary) { [string[]]@($ReleaseGapSummary.followUpIds) } else { [string[]]@() }
  }
}

function Invoke-SchemaRun {
  param(
    [string]$Name,
    [string]$ReadinessJsonPath,
    [string]$ResultJsonPath
  )

  Write-Host ""
  Write-Host ("Running {0} schema check..." -f $Name)
  $ExitCode = Invoke-Tool `
    -ScriptPath (Join-Path $PSScriptRoot "check-readiness-schema.ps1") `
    -Arguments @("-ReadinessJsonPath", $ReadinessJsonPath, "-ResultJsonPath", $ResultJsonPath, "-Required")
  $Json = Read-JsonFile -Path $ResultJsonPath
  $SchemaOk = $Json -and $Json.ok -eq $true
  Add-Check ("{0} schema check passed" -f $Name) ($ExitCode -eq 0 -and $SchemaOk) ("exit={0}, ok={1}" -f $ExitCode, $SchemaOk)

  return [pscustomobject]@{
    name = $Name
    resultJsonPath = $ResultJsonPath
    exitCode = [int]$ExitCode
    ok = [bool]$SchemaOk
  }
}

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$RepoRoot = Resolve-Path "$PSScriptRoot\.."
if (-not $ResultRoot) {
  $ResultRoot = Join-Path $env:TEMP ("homecue-readiness-regression-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
New-Directory -Path $ResultRoot

Write-Host "HomeCue Edge readiness regression check"
Write-Host ("Repo    : {0}" -f $RepoRoot.Path)
Write-Host ("Results : {0}" -f (Resolve-Path -LiteralPath $ResultRoot).Path)
Write-Host ("Port    : {0}" -f $(if ($ProbePort) { "probe enabled" } else { "skipped" }))

$DefaultReadiness = Invoke-ReadinessRun `
  -Name "default" `
  -JsonPath (Join-Path $ResultRoot "readiness-default.json") `
  -MarkdownPath (Join-Path $ResultRoot "readiness-default.md")
$DefaultSchema = Invoke-SchemaRun `
  -Name "default" `
  -ReadinessJsonPath $DefaultReadiness.jsonPath `
  -ResultJsonPath (Join-Path $ResultRoot "schema-default.json")

$StrictReadiness = Invoke-ReadinessRun `
  -Name "strict" `
  -JsonPath (Join-Path $ResultRoot "readiness-strict.json") `
  -MarkdownPath (Join-Path $ResultRoot "readiness-strict.md") `
  -Strict
$StrictSchema = Invoke-SchemaRun `
  -Name "strict" `
  -ReadinessJsonPath $StrictReadiness.jsonPath `
  -ResultJsonPath (Join-Path $ResultRoot "schema-strict.json")

$DefaultBlockingIds = [string[]]@($DefaultReadiness.blockingGapIds | Sort-Object)
$StrictBlockingIds = [string[]]@($StrictReadiness.blockingGapIds | Sort-Object)
$DefaultFollowUpIds = [string[]]@($DefaultReadiness.followUpGapIds | Sort-Object)
$StrictFollowUpIds = [string[]]@($StrictReadiness.followUpGapIds | Sort-Object)
$ReleaseGapSummariesMatch = (
  $DefaultReadiness.releaseGapTotalCount -eq $StrictReadiness.releaseGapTotalCount -and
  $DefaultReadiness.blockingGapCount -eq $StrictReadiness.blockingGapCount -and
  $DefaultReadiness.followUpGapCount -eq $StrictReadiness.followUpGapCount -and
  ($DefaultBlockingIds -join ",") -eq ($StrictBlockingIds -join ",") -and
  ($DefaultFollowUpIds -join ",") -eq ($StrictFollowUpIds -join ",")
)
Add-Check "default and strict release gaps match" $ReleaseGapSummariesMatch (
  "default={0}/{1}/{2} [{3}], strict={4}/{5}/{6} [{7}]" -f
  $DefaultReadiness.releaseGapTotalCount,
  $DefaultReadiness.blockingGapCount,
  $DefaultReadiness.followUpGapCount,
  ($DefaultBlockingIds -join ","),
  $StrictReadiness.releaseGapTotalCount,
  $StrictReadiness.blockingGapCount,
  $StrictReadiness.followUpGapCount,
  ($StrictBlockingIds -join ",")
)

$DefaultModeOk = if ($DefaultReadiness.blockingGapCount -gt 0) {
  $DefaultReadiness.gateStatus -eq "warn" -and
  $DefaultReadiness.gateReason -eq "not-ready-report-only" -and
  $DefaultReadiness.expectedExitCode -eq 0 -and
  $DefaultReadiness.exitCode -eq 0
} else {
  $DefaultReadiness.gateStatus -eq "pass" -and
  $DefaultReadiness.gateReason -eq "ready" -and
  $DefaultReadiness.expectedExitCode -eq 0 -and
  $DefaultReadiness.exitCode -eq 0
}
Add-Check "default readiness mode semantics" $DefaultModeOk (
  "status={0}, reason={1}, blocking={2}, exit={3}" -f
  $DefaultReadiness.gateStatus,
  $DefaultReadiness.gateReason,
  $DefaultReadiness.blockingGapCount,
  $DefaultReadiness.exitCode
)

$StrictModeOk = if ($StrictReadiness.blockingGapCount -gt 0) {
  $StrictReadiness.gateStatus -eq "fail" -and
  $StrictReadiness.gateReason -eq "blocking-release-gaps" -and
  $StrictReadiness.expectedExitCode -eq 2 -and
  $StrictReadiness.exitCode -eq 2
} else {
  $StrictReadiness.gateStatus -eq "pass" -and
  $StrictReadiness.gateReason -eq "ready" -and
  $StrictReadiness.expectedExitCode -eq 0 -and
  $StrictReadiness.exitCode -eq 0
}
Add-Check "strict readiness mode semantics" $StrictModeOk (
  "status={0}, reason={1}, blocking={2}, exit={3}" -f
  $StrictReadiness.gateStatus,
  $StrictReadiness.gateReason,
  $StrictReadiness.blockingGapCount,
  $StrictReadiness.exitCode
)

$RegressionOk = $Failures.Count -eq 0
$Result = @{
  checkedAt = (Get-Date).ToString("o")
  resultRoot = (Resolve-Path -LiteralPath $ResultRoot).Path
  ok = [bool]$RegressionOk
  requiredMode = [bool]$Required
  probePort = [bool]$ProbePort
  defaultReadiness = $DefaultReadiness
  defaultSchema = $DefaultSchema
  strictReadiness = $StrictReadiness
  strictSchema = $StrictSchema
  failureCount = $Failures.Count
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}
$RegressionJsonPath = Join-Path $ResultRoot "readiness-regression.json"
$Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $RegressionJsonPath -Encoding UTF8

Write-Host ""
Write-Host ("Summary: {0}" -f $(if ($RegressionOk) { "regression ok" } else { "regression warning" }))
Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $RegressionJsonPath).Path)

if ($Required -and -not $RegressionOk) {
  Write-Host "Readiness regression check failed." -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Readiness regression check complete."
exit 0
