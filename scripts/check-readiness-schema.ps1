param(
  [Parameter(Mandatory = $true)]
  [string]$ReadinessJsonPath,
  [string]$ResultJsonPath = "",
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

function Test-HasProperty {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $false
  }

  return $Object.PSObject.Properties.Name -contains $Name
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )

  if (Test-HasProperty -Object $Object -Name $Name) {
    return $Object.$Name
  }

  return $Default
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

function Get-ExpectedExitCode {
  param(
    [string]$Status,
    [string]$Reason
  )

  if ($Status -eq "fail" -and $Reason -eq "required-check-failure") {
    return 1
  }
  if ($Status -eq "fail" -and $Reason -eq "blocking-release-gaps") {
    return 2
  }
  return 0
}

function ConvertTo-SortedString {
  param([object[]]$Values)

  return ((@($Values) | ForEach-Object { [string]$_ } | Sort-Object) -join ",")
}

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$InputPath = Resolve-Path -LiteralPath $ReadinessJsonPath
$Readiness = Read-JsonFile -Path $InputPath.Path

Write-Host "HomeCue Edge readiness schema check"
Write-Host ("Input  : {0}" -f $InputPath.Path)
Write-Host ""

Add-Check "readiness json parsed" ($null -ne $Readiness) ""
if (-not $Readiness) {
  if ($Required) {
    exit 1
  }
  exit 0
}

$TopGate = Get-PropertyValue -Object $Readiness -Name "gateOutcome"
$Evidence = Get-PropertyValue -Object $Readiness -Name "evidence"
$EvidenceGate = Get-PropertyValue -Object $Evidence -Name "gateOutcome"
$GapSummary = Get-PropertyValue -Object $Evidence -Name "releaseGapSummary"
$ReleaseGaps = @((Get-PropertyValue -Object $Evidence -Name "releaseGaps" -Default @()))
$NextActions = @((Get-PropertyValue -Object $Evidence -Name "nextActions" -Default @()))

Add-Check "top-level gateOutcome exists" ($null -ne $TopGate) ""
Add-Check "evidence gateOutcome exists" ($null -ne $EvidenceGate) ""
Add-Check "releaseGapSummary exists" ($null -ne $GapSummary) ""

if ($TopGate) {
  $Status = [string](Get-PropertyValue -Object $TopGate -Name "status" -Default "")
  $Reason = [string](Get-PropertyValue -Object $TopGate -Name "reason" -Default "")
  $ExpectedExitCode = [int](Get-PropertyValue -Object $TopGate -Name "expectedExitCode" -Default -1)
  $ExpectedFromReason = Get-ExpectedExitCode -Status $Status -Reason $Reason
  $StatusAllowed = @("pass", "warn", "fail") -contains $Status
  Add-Check "gateOutcome status allowed" $StatusAllowed ("status={0}" -f $Status)
  Add-Check "gateOutcome expected exit code matches reason" ($ExpectedExitCode -eq $ExpectedFromReason) ("status={0}, reason={1}, expected={2}, actual={3}" -f $Status, $Reason, $ExpectedFromReason, $ExpectedExitCode)
}

if ($TopGate -and $EvidenceGate) {
  $TopStatus = [string](Get-PropertyValue -Object $TopGate -Name "status" -Default "")
  $EvidenceStatus = [string](Get-PropertyValue -Object $EvidenceGate -Name "status" -Default "")
  $TopReason = [string](Get-PropertyValue -Object $TopGate -Name "reason" -Default "")
  $EvidenceReason = [string](Get-PropertyValue -Object $EvidenceGate -Name "reason" -Default "")
  $TopExit = [int](Get-PropertyValue -Object $TopGate -Name "expectedExitCode" -Default -1)
  $EvidenceExit = [int](Get-PropertyValue -Object $EvidenceGate -Name "expectedExitCode" -Default -2)
  Add-Check "top-level and evidence gateOutcome match" ($TopStatus -eq $EvidenceStatus -and $TopReason -eq $EvidenceReason -and $TopExit -eq $EvidenceExit) ("top={0}/{1}/{2}, evidence={3}/{4}/{5}" -f $TopStatus, $TopReason, $TopExit, $EvidenceStatus, $EvidenceReason, $EvidenceExit)
}

if ($Readiness -and $Evidence -and $TopGate) {
  $TopReady = [bool](Get-PropertyValue -Object $Readiness -Name "readyForRelease" -Default $false)
  $EvidenceReady = [bool](Get-PropertyValue -Object $Evidence -Name "readyForRelease" -Default $false)
  $GateReady = [bool](Get-PropertyValue -Object $TopGate -Name "readyForRelease" -Default $false)
  Add-Check "readyForRelease fields match" ($TopReady -eq $EvidenceReady -and $TopReady -eq $GateReady) ("top={0}, evidence={1}, gate={2}" -f $TopReady, $EvidenceReady, $GateReady)
}

if ($GapSummary) {
  $TotalCount = [int](Get-PropertyValue -Object $GapSummary -Name "totalCount" -Default -1)
  $BlockingCount = [int](Get-PropertyValue -Object $GapSummary -Name "blockingCount" -Default -1)
  $FollowUpCount = [int](Get-PropertyValue -Object $GapSummary -Name "followUpCount" -Default -1)
  $BlockingIds = @((Get-PropertyValue -Object $GapSummary -Name "blockingIds" -Default @()))
  $FollowUpIds = @((Get-PropertyValue -Object $GapSummary -Name "followUpIds" -Default @()))
  $ReleaseBlocked = [bool](Get-PropertyValue -Object $GapSummary -Name "releaseBlocked" -Default $false)
  $ActualBlocking = @($ReleaseGaps | Where-Object { $_.blocksRelease -eq $true })
  $ActualFollowUp = @($ReleaseGaps | Where-Object { $_.blocksRelease -ne $true })
  $ActualBlockingIds = @($ActualBlocking | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "id" -Default "") })
  $ActualFollowUpIds = @($ActualFollowUp | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "id" -Default "") })
  $ActualActions = @($ReleaseGaps | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "action" -Default "") })
  $ReleaseGapFieldsOk = $true
  foreach ($Gap in $ReleaseGaps) {
    $HasRequiredFields = (
      (Test-HasProperty -Object $Gap -Name "id") -and
      (Test-HasProperty -Object $Gap -Name "area") -and
      (Test-HasProperty -Object $Gap -Name "status") -and
      (Test-HasProperty -Object $Gap -Name "action") -and
      (Test-HasProperty -Object $Gap -Name "blocksRelease") -and
      [string](Get-PropertyValue -Object $Gap -Name "id" -Default "") -and
      [string](Get-PropertyValue -Object $Gap -Name "area" -Default "") -and
      [string](Get-PropertyValue -Object $Gap -Name "status" -Default "") -and
      [string](Get-PropertyValue -Object $Gap -Name "action" -Default "")
    )
    if (-not $HasRequiredFields) {
      $ReleaseGapFieldsOk = $false
      break
    }
  }

  Add-Check "release gap count totals match" ($TotalCount -eq $ReleaseGaps.Count -and $TotalCount -eq ($BlockingCount + $FollowUpCount)) ("total={0}, gaps={1}, blocking={2}, follow_up={3}" -f $TotalCount, $ReleaseGaps.Count, $BlockingCount, $FollowUpCount)
  Add-Check "release gap items include required fields" $ReleaseGapFieldsOk ("gaps={0}" -f $ReleaseGaps.Count)
  Add-Check "blocking gap ids match count" ($BlockingIds.Count -eq $BlockingCount -and $ActualBlocking.Count -eq $BlockingCount) ("ids={0}, actual={1}, count={2}" -f $BlockingIds.Count, $ActualBlocking.Count, $BlockingCount)
  Add-Check "follow-up gap ids match count" ($FollowUpIds.Count -eq $FollowUpCount -and $ActualFollowUp.Count -eq $FollowUpCount) ("ids={0}, actual={1}, count={2}" -f $FollowUpIds.Count, $ActualFollowUp.Count, $FollowUpCount)
  Add-Check "blocking gap ids match details" ((ConvertTo-SortedString $BlockingIds) -eq (ConvertTo-SortedString $ActualBlockingIds)) ("summary={0}, details={1}" -f (ConvertTo-SortedString $BlockingIds), (ConvertTo-SortedString $ActualBlockingIds))
  Add-Check "follow-up gap ids match details" ((ConvertTo-SortedString $FollowUpIds) -eq (ConvertTo-SortedString $ActualFollowUpIds)) ("summary={0}, details={1}" -f (ConvertTo-SortedString $FollowUpIds), (ConvertTo-SortedString $ActualFollowUpIds))
  Add-Check "releaseBlocked matches blocking count" ($ReleaseBlocked -eq ($BlockingCount -gt 0)) ("releaseBlocked={0}, blocking={1}" -f $ReleaseBlocked, $BlockingCount)
  Add-Check "nextActions match release gap actions" ((ConvertTo-SortedString $NextActions) -eq (ConvertTo-SortedString $ActualActions)) ("nextActions={0}, actions={1}" -f $NextActions.Count, $ActualActions.Count)

  if ($TopGate) {
    $GateBlockingCount = [int](Get-PropertyValue -Object $TopGate -Name "blockingGapCount" -Default -1)
    $GateBlockingIds = @((Get-PropertyValue -Object $TopGate -Name "blockingGapIds" -Default @()))
    Add-Check "gateOutcome blocking gaps match summary" ($GateBlockingCount -eq $BlockingCount -and (ConvertTo-SortedString $GateBlockingIds) -eq (ConvertTo-SortedString $BlockingIds)) ("gate={0} [{1}], summary={2} [{3}]" -f $GateBlockingCount, (ConvertTo-SortedString $GateBlockingIds), $BlockingCount, (ConvertTo-SortedString $BlockingIds))
  }
}

$SchemaOk = $Failures.Count -eq 0
Write-Host ""
Write-Host ("Summary: {0}" -f $(if ($SchemaOk) { "schema ok" } else { "schema warning" }))

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result = @{
    checkedAt = (Get-Date).ToString("o")
    inputPath = $InputPath.Path
    ok = [bool]$SchemaOk
    requiredMode = [bool]$Required
    failureCount = $Failures.Count
    failures = [string[]]$Failures.ToArray()
    checks = [object[]]$Checks.ToArray()
  }
  $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($Required -and -not $SchemaOk) {
  Write-Host "Readiness schema check failed." -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Readiness schema check complete."
exit 0
