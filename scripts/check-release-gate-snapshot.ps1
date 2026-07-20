param(
  [Parameter(Mandatory = $true)]
  [string]$IntentJsonPath,
  [Parameter(Mandatory = $true)]
  [string]$ProofInventoryJsonPath,
  [Parameter(Mandatory = $true)]
  [string]$ReadinessJsonPath,
  [Parameter(Mandatory = $true)]
  [string]$PortStateJsonPath,
  [Parameter(Mandatory = $true)]
  [string]$PortSchemaJsonPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultJsonPath,
  [string]$ResultMarkdownPath = "",
  [switch]$Required
)

$ErrorActionPreference = "Stop"
$SnapshotSchemaName = "homecue-release-gate-snapshot"
$SnapshotSchemaVersion = 1
$SnapshotGenerator = "check-release-gate-snapshot.ps1"

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

function Resolve-InputFilePath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  try {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      return (Resolve-Path -LiteralPath $Path).Path
    }
  } catch {
    return $Path
  }

  return $Path
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

function Get-NestedPropertyValue {
  param(
    [object]$Object,
    [string[]]$Path,
    [object]$Default = $null
  )

  $Current = $Object
  foreach ($Part in $Path) {
    if (-not (Test-HasProperty -Object $Current -Name $Part)) {
      return $Default
    }
    $Current = $Current.$Part
  }

  return $Current
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

function Add-UniqueString {
  param(
    [System.Collections.Generic.List[string]]$List,
    [string]$Value
  )

  if ($Value -and -not $List.Contains($Value)) {
    $List.Add($Value)
  }
}

function Get-NumericPropertyEntries {
  param([object]$Object)

  $Entries = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Object) {
    return [object[]]@()
  }

  foreach ($Property in @($Object.PSObject.Properties | Sort-Object Name)) {
    $Value = 0
    if (-not [int]::TryParse([string]$Property.Value, [ref]$Value)) {
      $Value = 0
    }
    $Entries.Add([pscustomobject]@{
        name = [string]$Property.Name
        value = [int]$Value
      })
  }

  return [object[]]$Entries.ToArray()
}

function Get-NumericPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )

  foreach ($Entry in @(Get-NumericPropertyEntries -Object $Object)) {
    if ($Entry.name -eq $Name) {
      return [int]$Entry.value
    }
  }

  return 0
}

function Add-ActionItem {
  param(
    [System.Collections.Generic.List[object]]$Items,
    [System.Collections.Generic.List[string]]$TextList,
    [string]$Id,
    [string]$Category,
    [string]$Action
  )

  foreach ($Item in $Items) {
    if ([string]$Item.id -eq $Id -and [string]$Item.category -eq $Category) {
      return
    }
  }

  $Items.Add([pscustomobject]@{
      id = $Id
      category = $Category
      action = $Action
    })
  Add-UniqueString -List $TextList -Value $Action
}

function Get-CheckStatus {
  param(
    [object]$Json,
    [string]$Name
  )

  $Checks = @((Get-PropertyValue -Object $Json -Name "checks" -Default @()))
  $Match = @($Checks | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
  if ($Match.Count -eq 0) {
    return "unknown"
  }

  return [string](Get-PropertyValue -Object $Match[0] -Name "status" -Default "unknown")
}

function Get-ReleaseGapSummary {
  param([object]$Readiness)

  $Summary = Get-NestedPropertyValue -Object $Readiness -Path @("evidence", "releaseGapSummary")
  if ($null -eq $Summary) {
    $Summary = Get-PropertyValue -Object $Readiness -Name "releaseGapSummary"
  }
  if ($null -eq $Summary) {
    return [pscustomobject]@{
      totalCount = 0
      blockingCount = 0
      followUpCount = 0
      blockingIds = [string[]]@()
      followUpIds = [string[]]@()
    }
  }

  $Total = Get-PropertyValue -Object $Summary -Name "totalCount"
  if ($null -eq $Total) {
    $Total = Get-PropertyValue -Object $Summary -Name "total" -Default 0
  }
  $Blocking = Get-PropertyValue -Object $Summary -Name "blockingCount"
  if ($null -eq $Blocking) {
    $Blocking = Get-PropertyValue -Object $Summary -Name "blocking" -Default 0
  }
  $FollowUp = Get-PropertyValue -Object $Summary -Name "followUpCount"
  if ($null -eq $FollowUp) {
    $FollowUp = Get-PropertyValue -Object $Summary -Name "followUp" -Default 0
  }

  return [pscustomobject]@{
    totalCount = [int]$Total
    blockingCount = [int]$Blocking
    followUpCount = [int]$FollowUp
    blockingIds = [string[]]@((Get-PropertyValue -Object $Summary -Name "blockingIds" -Default @()))
    followUpIds = [string[]]@((Get-PropertyValue -Object $Summary -Name "followUpIds" -Default @()))
  }
}

function Get-AlibabaImageCount {
  param([object]$Proof)

  $SummaryCount = Get-NestedPropertyValue -Object $Proof -Path @("summary", "alibabaUsageImageCount")
  if ($null -ne $SummaryCount) {
    return [int]$SummaryCount
  }

  $Checks = @((Get-PropertyValue -Object $Proof -Name "checks" -Default @()))
  $Match = @($Checks | Where-Object { $_.name -eq "alibaba usage image proof" } | Select-Object -First 1)
  if ($Match.Count -eq 0) {
    return 0
  }

  $ImageCount = Get-NestedPropertyValue -Object $Match[0] -Path @("evidence", "imageCount")
  if ($null -eq $ImageCount) {
    return 0
  }

  return [int]$ImageCount
}

function Get-AlibabaProofEvidence {
  param([object]$Proof)

  $ImageCount = Get-AlibabaImageCount -Proof $Proof
  $CandidateCount = 0
  $InvalidImageCount = 0
  $ValidImageDetails = @()
  $InvalidImageDetails = @()
  $MinimumBytes = 0
  $SignatureRequired = $false
  $ManualReviewStatus = "unknown"
  $ManualReviewPath = ""
  $ManualReviewImageName = ""
  $ManualReviewReason = ""
  $ManualReviewMissingFields = @()

  $Checks = @((Get-PropertyValue -Object $Proof -Name "checks" -Default @()))
  $Match = @($Checks | Where-Object { $_.name -eq "alibaba usage image proof" } | Select-Object -First 1)
  if ($Match.Count -gt 0) {
    $Evidence = Get-PropertyValue -Object $Match[0] -Name "evidence"
    if ($Evidence) {
      $CandidateValue = Get-PropertyValue -Object $Evidence -Name "candidateCount"
      if ($null -ne $CandidateValue) {
        $CandidateCount = [int]$CandidateValue
      }

      $MinimumValue = Get-PropertyValue -Object $Evidence -Name "minimumBytes"
      if ($null -ne $MinimumValue) {
        $MinimumBytes = [int]$MinimumValue
      }

      if (Test-HasProperty -Object $Evidence -Name "signatureRequired") {
        $SignatureRequired = [bool]$Evidence.signatureRequired
      }

      $ValidImages = @((Get-PropertyValue -Object $Evidence -Name "validImages" -Default @()))
      $ValidImageDetails = @($ValidImages | ForEach-Object {
          [pscustomobject]@{
            name = [string](Get-PropertyValue -Object $_ -Name "name" -Default "")
            length = [int64](Get-PropertyValue -Object $_ -Name "length" -Default 0)
          }
        })

      $InvalidImages = @((Get-PropertyValue -Object $Evidence -Name "invalidImages" -Default @()))
      $InvalidImageCount = $InvalidImages.Count
      $InvalidImageDetails = @($InvalidImages | ForEach-Object {
          [pscustomobject]@{
            name = [string](Get-PropertyValue -Object $_ -Name "name" -Default "")
            length = [int64](Get-PropertyValue -Object $_ -Name "length" -Default 0)
            reason = [string](Get-PropertyValue -Object $_ -Name "reason" -Default "")
          }
        })
    }
  }

  $ReviewMatch = @($Checks | Where-Object { $_.name -eq "alibaba manual content review" } | Select-Object -First 1)
  if ($ReviewMatch.Count -gt 0) {
    $ManualReviewStatus = [string](Get-PropertyValue -Object $ReviewMatch[0] -Name "status" -Default "unknown")
    $ReviewEvidence = Get-PropertyValue -Object $ReviewMatch[0] -Name "evidence"
    if ($ReviewEvidence) {
      $ManualReviewPath = [string](Get-PropertyValue -Object $ReviewEvidence -Name "path" -Default "")
      $ManualReviewImageName = [string](Get-PropertyValue -Object $ReviewEvidence -Name "imageName" -Default "")
      $ManualReviewReason = [string](Get-PropertyValue -Object $ReviewEvidence -Name "reason" -Default "")
      $ManualReviewMissingFields = [string[]]@((Get-PropertyValue -Object $ReviewEvidence -Name "missingOrFalseFields" -Default @()))
    }
  }

  if ($CandidateCount -eq 0 -and $ImageCount -gt 0) {
    $CandidateCount = $ImageCount
  }

  return [pscustomobject]@{
    imageCount = [int]$ImageCount
    candidateCount = [int]$CandidateCount
    invalidImageCount = [int]$InvalidImageCount
    images = [object[]]$ValidImageDetails
    invalidImages = [object[]]$InvalidImageDetails
    minimumBytes = [int]$MinimumBytes
    signatureRequired = [bool]$SignatureRequired
    manualReviewStatus = $ManualReviewStatus
    manualReviewPath = $ManualReviewPath
    manualReviewImageName = $ManualReviewImageName
    manualReviewReason = $ManualReviewReason
    manualReviewMissingFields = [string[]]$ManualReviewMissingFields
  }
}

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]

Write-Host "HomeCue Edge release gate snapshot"
Write-Host ("Intent   : {0}" -f $IntentJsonPath)
Write-Host ("Proof    : {0}" -f $ProofInventoryJsonPath)
Write-Host ("Readiness: {0}" -f $ReadinessJsonPath)
Write-Host ("Port     : {0}" -f $PortStateJsonPath)
Write-Host ("Schema   : {0}" -f $PortSchemaJsonPath)
Write-Host ""

$Intent = Read-JsonFile -Path $IntentJsonPath
$Proof = Read-JsonFile -Path $ProofInventoryJsonPath
$Readiness = Read-JsonFile -Path $ReadinessJsonPath
$PortState = Read-JsonFile -Path $PortStateJsonPath
$PortSchema = Read-JsonFile -Path $PortSchemaJsonPath

$IntentJsonPathForReport = Resolve-InputFilePath -Path $IntentJsonPath
$ProofInventoryJsonPathForReport = Resolve-InputFilePath -Path $ProofInventoryJsonPath
$ReadinessJsonPathForReport = Resolve-InputFilePath -Path $ReadinessJsonPath
$PortStateJsonPathForReport = Resolve-InputFilePath -Path $PortStateJsonPath
$PortSchemaJsonPathForReport = Resolve-InputFilePath -Path $PortSchemaJsonPath

Add-Check "intent json parsed" ($null -ne $Intent) ""
Add-Check "proof inventory json parsed" ($null -ne $Proof) ""
Add-Check "readiness json parsed" ($null -ne $Readiness) ""
Add-Check "port state json parsed" ($null -ne $PortState) ""
Add-Check "port schema json parsed" ($null -ne $PortSchema) ""

$GapSummary = Get-ReleaseGapSummary -Readiness $Readiness
$AlibabaEvidence = Get-AlibabaProofEvidence -Proof $Proof
$AlibabaImageCount = [int]$AlibabaEvidence.imageCount
$PortStateValue = [string](Get-PropertyValue -Object $PortState -Name "state" -Default "unknown")
$PortSchemaOk = [bool](Get-PropertyValue -Object $PortSchema -Name "ok" -Default $false)
$ReadyForExternalRelease = [bool](Get-PropertyValue -Object $Proof -Name "readyForExternalRelease" -Default $false)
$ReadyForRelease = [bool](Get-PropertyValue -Object $Readiness -Name "readyForRelease" -Default $false)
$ReadyForSubmit = (
  $ReadyForExternalRelease -and
  $ReadyForRelease -and
  [int](Get-PropertyValue -Object $Intent -Name "warningCount" -Default 1) -eq 0 -and
  [int](Get-PropertyValue -Object $Intent -Name "dirtyCount" -Default 1) -eq 0 -and
  [int]$GapSummary.blockingCount -eq 0
)

$Blockers = New-Object System.Collections.Generic.List[string]
foreach ($Id in @($GapSummary.blockingIds)) {
  if ($Id -and -not $Blockers.Contains([string]$Id)) {
    $Blockers.Add([string]$Id)
  }
}
if ($AlibabaImageCount -eq 0 -and -not $Blockers.Contains("alibaba-usage-image")) {
  $Blockers.Add("alibaba-usage-image")
}
if ([int](Get-PropertyValue -Object $Intent -Name "dirtyCount" -Default 0) -gt 0 -and -not $Blockers.Contains("git-worktree")) {
  $Blockers.Add("git-worktree")
}

$OperationalBlockers = New-Object System.Collections.Generic.List[string]
if ($PortStateValue -ne "writable" -and $PortStateValue -ne "openable") {
  $OperationalBlockers.Add("esp32-port-state")
}

$NextActions = New-Object System.Collections.Generic.List[string]
$NextActionItems = New-Object System.Collections.Generic.List[object]
if ($Blockers.Contains("git-worktree")) {
  Add-ActionItem -Items $NextActionItems -TextList $NextActions -Id "git-worktree" -Category "release" -Action "Review and stage public repo changes by intent bucket; run staged secret scan and required tests before any authorized commit or push."
}
if ($Blockers.Contains("alibaba-usage-image")) {
  Add-ActionItem -Items $NextActionItems -TextList $NextActions -Id "alibaba-usage-image" -Category "release" -Action "Add a redacted Alibaba Cloud / DashScope usage screenshot under gitignored assets/demo/alibaba-proof, then rerun proof inventory and strict readiness."
}
if ($Blockers.Contains("alibaba-proof-review")) {
  Add-ActionItem -Items $NextActionItems -TextList $NextActions -Id "alibaba-proof-review" -Category "release" -Action "Complete alibaba-proof-review.json for the valid Alibaba proof image, then rerun proof inventory, strict readiness, and release snapshot checks."
}
if ($Blockers.Contains("proof-inventory-external-release")) {
  Add-ActionItem -Items $NextActionItems -TextList $NextActions -Id "proof-inventory-external-release" -Category "release" -Action "Refresh proof inventory and readiness after external cloud proof is complete."
}
if ($OperationalBlockers.Contains("esp32-port-state")) {
  Add-ActionItem -Items $NextActionItems -TextList $NextActions -Id "esp32-port-state" -Category "operational" -Action "Recover ESP32 serial enumeration or rerun the port check with the actual COM port before fresh hardware proof."
}
if ($NextActions.Count -eq 0) {
  Add-ActionItem -Items $NextActionItems -TextList $NextActions -Id "final-release-checks" -Category "release" -Action "Run final all-files secret scan, staged scan, check-local, and user-authorized submission or release flow."
}

Add-Check "submit-ready remains separated from local checks" (-not $ReadyForSubmit -or $Blockers.Count -eq 0) ("ready={0}, blockers={1}" -f $ReadyForSubmit, ($Blockers -join ","))
Add-Check "port schema passed" $PortSchemaOk ("ok={0}" -f $PortSchemaOk)
Add-Check "release blockers summarized" ($GapSummary.blockingCount -ge 0) ("blocking={0}" -f $GapSummary.blockingCount)
Add-Check "next actions summarized" ($NextActions.Count -gt 0) ("actions={0}" -f $NextActions.Count)
Add-Check "alibaba proof quality summarized" `
  ($AlibabaEvidence.minimumBytes -gt 0 -and $AlibabaEvidence.signatureRequired -and $AlibabaEvidence.candidateCount -eq ($AlibabaEvidence.imageCount + $AlibabaEvidence.invalidImageCount)) `
  ("images={0}, candidates={1}, invalid={2}, minimum_bytes={3}, signature_required={4}" -f $AlibabaEvidence.imageCount, $AlibabaEvidence.candidateCount, $AlibabaEvidence.invalidImageCount, $AlibabaEvidence.minimumBytes, $AlibabaEvidence.signatureRequired)
Add-Check "alibaba manual review summarized" `
  (@("OK", "WARN") -contains $AlibabaEvidence.manualReviewStatus) `
  ("status={0}, image={1}, reason={2}" -f $AlibabaEvidence.manualReviewStatus, $AlibabaEvidence.manualReviewImageName, $AlibabaEvidence.manualReviewReason)

New-ParentDirectory -Path $ResultJsonPath
$CheckedAt = (Get-Date).ToString("o")
$Result = @{
  schema = @{
    name = $SnapshotSchemaName
    version = $SnapshotSchemaVersion
    generator = $SnapshotGenerator
  }
  checkedAt = $CheckedAt
  readyForSubmit = [bool]$ReadyForSubmit
  blockers = [string[]]$Blockers.ToArray()
  operationalBlockers = [string[]]$OperationalBlockers.ToArray()
  nextActions = [string[]]$NextActions.ToArray()
  nextActionItems = [object[]]$NextActionItems.ToArray()
  blockerSummary = @{
    releaseBlockerCount = [int]$Blockers.Count
    operationalBlockerCount = [int]$OperationalBlockers.Count
    totalBlockerCount = [int]($Blockers.Count + $OperationalBlockers.Count)
    nextActionItemCount = [int]$NextActionItems.Count
    hasReleaseBlockers = [bool]($Blockers.Count -gt 0)
    hasOperationalBlockers = [bool]($OperationalBlockers.Count -gt 0)
    blocked = [bool](($Blockers.Count + $OperationalBlockers.Count) -gt 0)
    readyForSubmit = [bool]$ReadyForSubmit
  }
  repo = @{
    ahead = [int](Get-PropertyValue -Object $Intent -Name "ahead" -Default 0)
    behind = [int](Get-PropertyValue -Object $Intent -Name "behind" -Default 0)
    dirtyCount = [int](Get-PropertyValue -Object $Intent -Name "dirtyCount" -Default 0)
    warningCount = [int](Get-PropertyValue -Object $Intent -Name "warningCount" -Default 0)
    bucketCounts = Get-PropertyValue -Object $Intent -Name "bucketCounts" -Default @{}
    bucketReviewCounts = Get-PropertyValue -Object $Intent -Name "bucketReviewCounts" -Default @{}
  }
  proof = @{
    readyForExternalRelease = [bool]$ReadyForExternalRelease
    qwenVerification = Get-CheckStatus -Json $Proof -Name "qwen verification proof"
    alibabaUsageImageCount = [int]$AlibabaEvidence.imageCount
    alibabaUsageCandidateCount = [int]$AlibabaEvidence.candidateCount
    alibabaUsageInvalidImageCount = [int]$AlibabaEvidence.invalidImageCount
    alibabaUsageImages = [object[]]$AlibabaEvidence.images
    alibabaUsageInvalidImages = [object[]]$AlibabaEvidence.invalidImages
    alibabaUsageMinimumBytes = [int]$AlibabaEvidence.minimumBytes
    alibabaUsageSignatureRequired = [bool]$AlibabaEvidence.signatureRequired
    alibabaManualReview = $AlibabaEvidence.manualReviewStatus
    alibabaManualReviewPath = $AlibabaEvidence.manualReviewPath
    alibabaManualReviewImageName = $AlibabaEvidence.manualReviewImageName
    alibabaManualReviewReason = $AlibabaEvidence.manualReviewReason
    alibabaManualReviewMissingFields = [string[]]@($AlibabaEvidence.manualReviewMissingFields)
    xiaoqianWakeModel = Get-CheckStatus -Json $Proof -Name "xiaoqian wake model proof"
  }
  readiness = @{
    readyForRelease = [bool]$ReadyForRelease
    gateStatus = [string](Get-NestedPropertyValue -Object $Readiness -Path @("gateOutcome", "status") -Default "")
    gateReason = [string](Get-NestedPropertyValue -Object $Readiness -Path @("gateOutcome", "reason") -Default "")
    releaseGapTotalCount = [int]$GapSummary.totalCount
    blockingGapCount = [int]$GapSummary.blockingCount
    followUpGapCount = [int]$GapSummary.followUpCount
    blockingGapIds = [string[]]@($GapSummary.blockingIds)
    followUpGapIds = [string[]]@($GapSummary.followUpIds)
  }
  hardware = @{
    requestedPort = [string](Get-PropertyValue -Object $PortState -Name "requestedPort" -Default "")
    port = [string](Get-PropertyValue -Object $PortState -Name "port" -Default "")
    portState = $PortStateValue
    detectedPorts = [string[]]@((Get-PropertyValue -Object $PortState -Name "detectedPorts" -Default @()))
    nextAction = [string](Get-PropertyValue -Object $PortState -Name "nextAction" -Default "")
    recoverySteps = [string[]]@((Get-PropertyValue -Object $PortState -Name "recoverySteps" -Default @()))
    portSchemaOk = [bool]$PortSchemaOk
  }
  sourcePaths = @{
    intentJsonPath = $IntentJsonPathForReport
    proofInventoryJsonPath = $ProofInventoryJsonPathForReport
    readinessJsonPath = $ReadinessJsonPathForReport
    portStateJsonPath = $PortStateJsonPathForReport
    portSchemaJsonPath = $PortSchemaJsonPathForReport
  }
  requiredMode = [bool]$Required
  ok = [bool]($Failures.Count -eq 0)
  failureCount = $Failures.Count
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}

$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8

if ($ResultMarkdownPath) {
  New-ParentDirectory -Path $ResultMarkdownPath
  $Lines = New-Object System.Collections.Generic.List[string]
  $Lines.Add("# HomeCue Release Gate Snapshot")
  $Lines.Add("")
  $Lines.Add(('- Schema: `{0}/v{1}` generated by `{2}`' -f $SnapshotSchemaName, $SnapshotSchemaVersion, $SnapshotGenerator))
  $Lines.Add(('- Checked at: `{0}`' -f $CheckedAt))
  $Lines.Add(('- Required mode: `{0}`' -f [bool]$Required))
  $Lines.Add(("- Ready for submit: **{0}**" -f $ReadyForSubmit))
  $Lines.Add("")
  $Lines.Add("## Release Blockers")
  $Lines.Add("")
  if ($Blockers.Count -eq 0) {
    $Lines.Add("- (none)")
  } else {
    foreach ($Blocker in $Blockers) {
      $Lines.Add(('- `{0}`' -f $Blocker))
    }
  }
  $Lines.Add("")
  $Lines.Add("## Operational Blockers")
  $Lines.Add("")
  if ($OperationalBlockers.Count -eq 0) {
    $Lines.Add("- (none)")
  } else {
    foreach ($Blocker in $OperationalBlockers) {
      $Lines.Add(('- `{0}`' -f $Blocker))
    }
  }
  $Lines.Add("")
  $Lines.Add("## Next Actions")
  $Lines.Add("")
  for ($Index = 0; $Index -lt $NextActionItems.Count; $Index++) {
    $Item = $NextActionItems[$Index]
    $Lines.Add(('{0}. `[{1}/{2}]` {3}' -f ($Index + 1), $Item.category, $Item.id, $Item.action))
  }
  $Lines.Add("")
  $Lines.Add("## Blocker Summary")
  $Lines.Add("")
  $Lines.Add(('- Release blockers: `{0}`' -f $Result.blockerSummary.releaseBlockerCount))
  $Lines.Add(('- Operational blockers: `{0}`' -f $Result.blockerSummary.operationalBlockerCount))
  $Lines.Add(('- Total blockers: `{0}`' -f $Result.blockerSummary.totalBlockerCount))
  $Lines.Add(('- Next action items: `{0}`' -f $Result.blockerSummary.nextActionItemCount))
  $Lines.Add(('- Blocked: `{0}`' -f $Result.blockerSummary.blocked))
  $Lines.Add(('- Ready for submit: `{0}`' -f $Result.blockerSummary.readyForSubmit))
  $Lines.Add("")
  $Lines.Add("## Snapshot")
  $Lines.Add("")
  $Lines.Add(('- Repo: ahead `{0}`, dirty `{1}`, warnings `{2}`' -f $Result.repo.ahead, $Result.repo.dirtyCount, $Result.repo.warningCount))
  $Lines.Add(('- Proof: external release ready `{0}`, Alibaba usage images `{1}`, candidates `{2}`, invalid `{3}`, min bytes `{4}`, signature required `{5}`, manual review `{6}`' -f $Result.proof.readyForExternalRelease, $Result.proof.alibabaUsageImageCount, $Result.proof.alibabaUsageCandidateCount, $Result.proof.alibabaUsageInvalidImageCount, $Result.proof.alibabaUsageMinimumBytes, $Result.proof.alibabaUsageSignatureRequired, $Result.proof.alibabaManualReview))
  $Lines.Add(('- Readiness: gate `{0}`, blocking gaps `{1}`, follow-up gaps `{2}`' -f $Result.readiness.gateStatus, $Result.readiness.blockingGapCount, $Result.readiness.followUpGapCount))
  $Lines.Add(('- Hardware: `{0}` state `{1}`, port schema OK `{2}`' -f $Result.hardware.requestedPort, $Result.hardware.portState, $Result.hardware.portSchemaOk))
  $Lines.Add("")
  $Lines.Add("## Proof Signals")
  $Lines.Add("")
  $Lines.Add(('- Qwen verification: `{0}`' -f $Result.proof.qwenVerification))
  $Lines.Add(('- Alibaba image candidates: `{0}`' -f $Result.proof.alibabaUsageCandidateCount))
  $Lines.Add(('- Alibaba valid images: `{0}`' -f $Result.proof.alibabaUsageImageCount))
  $Lines.Add(('- Alibaba invalid images: `{0}`' -f $Result.proof.alibabaUsageInvalidImageCount))
  $Lines.Add(('- Alibaba image minimum bytes: `{0}`' -f $Result.proof.alibabaUsageMinimumBytes))
  $Lines.Add(('- Alibaba signature required: `{0}`' -f $Result.proof.alibabaUsageSignatureRequired))
  $Lines.Add(('- Alibaba manual review: `{0}`' -f $Result.proof.alibabaManualReview))
  $Lines.Add(('- Alibaba manual review image: `{0}`' -f $Result.proof.alibabaManualReviewImageName))
  $Lines.Add(('- Alibaba manual review missing fields: `{0}`' -f (@($Result.proof.alibabaManualReviewMissingFields) -join ",")))
  $Lines.Add(('- Xiaoqian wake model: `{0}`' -f $Result.proof.xiaoqianWakeModel))
  $Lines.Add("")
  $Lines.Add("## Alibaba Valid Images")
  $Lines.Add("")
  if ($Result.proof.alibabaUsageImages.Count -eq 0) {
    $Lines.Add("- (none)")
  } else {
    foreach ($ValidImage in @($Result.proof.alibabaUsageImages)) {
      $Lines.Add(('- `{0}` length `{1}`' -f $ValidImage.name, $ValidImage.length))
    }
  }
  $Lines.Add("")
  $Lines.Add("## Alibaba Invalid Images")
  $Lines.Add("")
  if ($Result.proof.alibabaUsageInvalidImages.Count -eq 0) {
    $Lines.Add("- (none)")
  } else {
    foreach ($InvalidImage in @($Result.proof.alibabaUsageInvalidImages)) {
      $Lines.Add(('- `{0}` length `{1}` reason `{2}`' -f $InvalidImage.name, $InvalidImage.length, $InvalidImage.reason))
    }
  }
  $Lines.Add("")
  $Lines.Add("## Checks")
  $Lines.Add("")
  foreach ($Check in @($Result.checks)) {
    $Detail = [string]$Check.detail
    $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
    $Lines.Add(('- [{0}] `{1}`{2}' -f $Check.status, $Check.name, $DetailSuffix))
  }
  $Lines.Add("")
  $Lines.Add("## Repo Buckets")
  $Lines.Add("")
  $BucketEntries = @(Get-NumericPropertyEntries -Object $Result.repo.bucketCounts)
  if ($BucketEntries.Count -eq 0) {
    $Lines.Add("- (none)")
  } else {
    foreach ($Entry in $BucketEntries) {
      $ReviewCount = Get-NumericPropertyValue -Object $Result.repo.bucketReviewCounts -Name $Entry.name
      $Lines.Add(('- `{0}`: dirty `{1}`, review `{2}`' -f $Entry.name, $Entry.value, $ReviewCount))
    }
  }
  $Lines.Add("")
  $Lines.Add("## Source Files")
  $Lines.Add("")
  $Lines.Add(('- Intent: `{0}`' -f $IntentJsonPathForReport))
  $Lines.Add(('- Proof inventory: `{0}`' -f $ProofInventoryJsonPathForReport))
  $Lines.Add(('- Readiness: `{0}`' -f $ReadinessJsonPathForReport))
  $Lines.Add(('- Port state: `{0}`' -f $PortStateJsonPathForReport))
  $Lines.Add(('- Port schema: `{0}`' -f $PortSchemaJsonPathForReport))
  $Lines | Set-Content -LiteralPath $ResultMarkdownPath -Encoding UTF8
}

Write-Host ""
Write-Host ("Ready for submit: {0}" -f $ReadyForSubmit)
Write-Host ("Blockers        : {0}" -f $(if ($Blockers.Count -gt 0) { $Blockers -join ", " } else { "(none)" }))
Write-Host ("Operational     : {0}" -f $(if ($OperationalBlockers.Count -gt 0) { $OperationalBlockers -join ", " } else { "(none)" }))
Write-Host ("Next actions    : {0}" -f $NextActions.Count)
Write-Host ("Result          : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
if ($ResultMarkdownPath) {
  Write-Host ("Report          : {0}" -f (Resolve-Path -LiteralPath $ResultMarkdownPath).Path)
}

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Release gate snapshot failed." -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Release gate snapshot complete."
exit 0
