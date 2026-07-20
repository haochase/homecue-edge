param(
  [string]$Port = "COM7",
  [string]$ProofRoot = ".\assets\demo",
  [string]$ResultJsonPath = "",
  [string]$ResultMarkdownPath = "",
  [switch]$SkipPortProbe,
  [switch]$SkipSecretScan,
  [switch]$SkipWorkingTreeIntent,
  [switch]$SkipProofInventory,
  [switch]$FailOnBlockingGaps,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

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

function Add-ReleaseGap {
  param(
    [string]$Id,
    [string]$Area,
    [string]$Status,
    [string]$Action,
    [bool]$BlocksRelease = $false
  )

  $script:ReleaseGaps.Add([pscustomobject]@{
      id = $Id
      area = $Area
      status = $Status
      action = $Action
      blocksRelease = [bool]$BlocksRelease
    })
}

function ConvertTo-MarkdownText {
  param([object]$Value)

  if ($null -eq $Value) {
    return ""
  }

  $Text = ([string]$Value) -replace "(`r`n|`n|`r)", " "
  if ($script:RepoRoot -and $script:RepoRoot.Path) {
    $Text = $Text -replace [regex]::Escape($script:RepoRoot.Path), "<repo>"
  }
  return $Text
}

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

function Test-PublicEnvExample {
  param([string]$Path)

  $RequiredKeys = @(
    "QWEN_API_KEY",
    "QWEN_API_BASE",
    "QWEN_MODEL",
    "PLANNER_PROVIDER",
    "VOICE_CHAT_TTS_PROVIDER",
    "VOICE_CHAT_TTS_API_KEY",
    "VOICE_CHAT_TTS_API_BASE",
    "VOICE_CHAT_TTS_MODEL",
    "VOICE_CHAT_TTS_VOICE",
    "VOICE_CHAT_TTS_LANGUAGE_TYPE"
  )
  $Parsed = @{}
  $Problems = New-Object System.Collections.Generic.List[string]

  if (-not (Test-Path -LiteralPath $Path)) {
    $Problems.Add("missing .env.example")
    return [pscustomobject]@{
      exists = $false
      ok = $false
      keyCount = 0
      requiredKeyCount = $RequiredKeys.Count
      missingKeys = [string[]]$RequiredKeys
      problems = [string[]]$Problems.ToArray()
    }
  }

  $Lines = Get-Content -LiteralPath $Path
  foreach ($Line in $Lines) {
    $Trimmed = $Line.Trim()
    if (-not $Trimmed -or $Trimmed.StartsWith("#")) {
      continue
    }

    $Parts = $Trimmed -split "=", 2
    if ($Parts.Count -ne 2) {
      $Problems.Add(("invalid env line: {0}" -f $Trimmed))
      continue
    }

    $Key = $Parts[0].Trim()
    $Value = $Parts[1].Trim()
    $Parsed[$Key] = $Value

    if ($Key -match "(API_KEY|TOKEN|SECRET)$" -and $Value) {
      $Problems.Add(("{0} must stay blank in the public example" -f $Key))
    }
    if ($Value -match "(sk-[A-Za-z0-9]|ghp_|AKIA|tp-[A-Za-z0-9])") {
      $Problems.Add(("{0} looks like a real token value" -f $Key))
    }
    if ($Value -match "^[A-Za-z]:\\" -or $Value -match "\\Users\\|/Users/|/home/") {
      $Problems.Add(("{0} contains a local filesystem path" -f $Key))
    }
  }

  $MissingKeys = @($RequiredKeys | Where-Object { -not $Parsed.ContainsKey($_) })
  foreach ($MissingKey in $MissingKeys) {
    $Problems.Add(("missing required example key: {0}" -f $MissingKey))
  }

  return [pscustomobject]@{
    exists = $true
    ok = $Problems.Count -eq 0
    keyCount = $Parsed.Count
    requiredKeyCount = $RequiredKeys.Count
    missingKeys = [string[]]$MissingKeys
    problems = [string[]]$Problems.ToArray()
  }
}

function Get-GitOutput {
  param([string[]]$GitArgs)
  try {
    return (& git @GitArgs 2>$null)
  } catch {
    return $null
  }
}

function Get-CheckByName {
  param(
    [object[]]$Checks,
    [string]$Name
  )

  return @($Checks | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Test-ImageFileSignature {
  param([System.IO.FileInfo]$File)

  $Extension = $File.Extension.ToLowerInvariant()
  $RequiredHeaderLength = switch -Regex ($Extension) {
    "^\.png$" { 8; break }
    "^\.jpe?g$" { 3; break }
    "^\.webp$" { 12; break }
    default {
      return [pscustomobject]@{
        ok = $false
        reason = "unsupported-extension"
      }
    }
  }

  if ($File.Length -lt $RequiredHeaderLength) {
    return [pscustomobject]@{
      ok = $false
      reason = "too-small-for-signature"
    }
  }

  $HeaderLength = [Math]::Min(12, [int]$File.Length)
  $Header = New-Object byte[] $HeaderLength
  $Stream = [System.IO.File]::OpenRead($File.FullName)
  try {
    [void]$Stream.Read($Header, 0, $HeaderLength)
  } finally {
    $Stream.Dispose()
  }

  $SignatureOk = $false
  if ($Extension -eq ".png") {
    $SignatureOk = $HeaderLength -ge 8 -and
      $Header[0] -eq 0x89 -and $Header[1] -eq 0x50 -and $Header[2] -eq 0x4E -and $Header[3] -eq 0x47 -and
      $Header[4] -eq 0x0D -and $Header[5] -eq 0x0A -and $Header[6] -eq 0x1A -and $Header[7] -eq 0x0A
  } elseif ($Extension -eq ".jpg" -or $Extension -eq ".jpeg") {
    $SignatureOk = $HeaderLength -ge 3 -and $Header[0] -eq 0xFF -and $Header[1] -eq 0xD8 -and $Header[2] -eq 0xFF
  } elseif ($Extension -eq ".webp") {
    $SignatureOk = $HeaderLength -ge 12 -and
      [System.Text.Encoding]::ASCII.GetString($Header, 0, 4) -eq "RIFF" -and
      [System.Text.Encoding]::ASCII.GetString($Header, 8, 4) -eq "WEBP"
  }

  [pscustomobject]@{
    ok = [bool]$SignatureOk
    reason = if ($SignatureOk) { "" } else { "invalid-signature" }
  }
}

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]
$ReleaseGaps = New-Object System.Collections.Generic.List[object]
$Evidence = [ordered]@{}
$RepoRoot = Resolve-Path "$PSScriptRoot\.."
$ProofRootPath = Join-Path $RepoRoot $ProofRoot

Write-Host "HomeCue Edge proof readiness check"
Write-Host ("Repo   : {0}" -f $RepoRoot.Path)
Write-Host ("Proofs : {0}" -f $ProofRootPath)
Write-Host ""

$BranchLine = Get-GitOutput -GitArgs @("status", "--short", "--branch")
$Porcelain = @(Get-GitOutput -GitArgs @("status", "--porcelain"))
$BranchText = if ($BranchLine) { [string]$BranchLine[0] } else { "" }
$Ahead = 0
$Behind = 0
if ($BranchText -match "ahead\s+(\d+)") {
  $Ahead = [int]$Matches[1]
}
if ($BranchText -match "behind\s+(\d+)") {
  $Behind = [int]$Matches[1]
}
$DirtyCount = @($Porcelain | Where-Object { $_ -and $_.Trim() }).Count
$GitCleanAndSynced = ($Ahead -eq 0 -and $Behind -eq 0 -and $DirtyCount -eq 0)
$Evidence.git = @{
  branch = $BranchText
  ahead = $Ahead
  behind = $Behind
  dirtyCount = $DirtyCount
}
Write-Check "git clean and synced" $GitCleanAndSynced ("branch='{0}', ahead={1}, behind={2}, dirty={3}" -f $BranchText, $Ahead, $Behind, $DirtyCount) $true

$SecretScan = $null
if (-not $SkipSecretScan) {
  $TempSecretScanJson = Join-Path $env:TEMP "homecue-proof-readiness-secret-scan.json"
  $SecretScanScript = Join-Path $PSScriptRoot "scan-secrets.ps1"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $SecretScanScript -All -IncludeUntracked -Quiet -ResultJsonPath $TempSecretScanJson | Out-Host
  $SecretScan = Read-JsonFile -Path $TempSecretScanJson
}
$SecretScanClean = $SecretScan -and $SecretScan.clean -eq $true
$SecretScanDetail = if ($SkipSecretScan) {
  "skipped by caller"
} elseif ($SecretScan) {
  "clean={0}, findings={1}, scanned={2}, skipped={3}" -f $SecretScan.clean, $SecretScan.findingCount, $SecretScan.scannedCount, $SecretScan.skippedCount
} else {
  "scan did not produce json"
}
$Evidence.secretScan = @{
  ran = -not [bool]$SkipSecretScan
  clean = [bool]$SecretScanClean
  findingCount = if ($SecretScan) { [int]$SecretScan.findingCount } else { -1 }
  scannedCount = if ($SecretScan) { [int]$SecretScan.scannedCount } else { 0 }
  skippedCount = if ($SecretScan) { [int]$SecretScan.skippedCount } else { 0 }
}
Write-Check "secret scan all+untracked clean" $SecretScanClean $SecretScanDetail $true

$EnvExamplePath = Join-Path $RepoRoot "apps\api\.env.example"
$EnvExample = Test-PublicEnvExample -Path $EnvExamplePath
$EnvExampleSafe = $EnvExample.ok -eq $true
$EnvExampleDetail = if ($EnvExample.exists) {
  "keys={0}, required={1}, missing={2}, problems={3}" -f $EnvExample.keyCount, $EnvExample.requiredKeyCount, @($EnvExample.missingKeys).Count, @($EnvExample.problems).Count
} else {
  "missing: $EnvExamplePath"
}
$Evidence.publicEnvExample = @{
  path = $EnvExamplePath
  exists = [bool]$EnvExample.exists
  safe = [bool]$EnvExampleSafe
  keyCount = [int]$EnvExample.keyCount
  requiredKeyCount = [int]$EnvExample.requiredKeyCount
  missingKeys = [string[]]@($EnvExample.missingKeys)
  problems = [string[]]@($EnvExample.problems)
}
Write-Check "public env example safe" $EnvExampleSafe $EnvExampleDetail $true

$WorkingTreeIntent = $null
if (-not $SkipWorkingTreeIntent) {
  $TempIntentJson = Join-Path $env:TEMP "homecue-proof-readiness-working-tree-intent.json"
  $IntentScript = Join-Path $PSScriptRoot "check-working-tree-intent.ps1"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $IntentScript -ResultJsonPath $TempIntentJson | Out-Host
  $WorkingTreeIntent = Read-JsonFile -Path $TempIntentJson
}
$IntentOk = $WorkingTreeIntent -and $WorkingTreeIntent.warningCount -eq 0
$IntentDetail = if ($SkipWorkingTreeIntent) {
  "skipped by caller"
} elseif ($WorkingTreeIntent) {
  "dirty={0}, warnings={1}, ahead={2}, behind={3}" -f $WorkingTreeIntent.dirtyCount, $WorkingTreeIntent.warningCount, $WorkingTreeIntent.ahead, $WorkingTreeIntent.behind
} else {
  "intent check did not produce json"
}
$IntentBuckets = @{}
if ($WorkingTreeIntent) {
  foreach ($Group in (@($WorkingTreeIntent.items) | Group-Object bucket | Sort-Object Name)) {
    $IntentBuckets[$Group.Name] = $Group.Count
  }
}
$Evidence.workingTreeIntent = @{
  ran = -not [bool]$SkipWorkingTreeIntent
  ok = [bool]$IntentOk
  dirtyCount = if ($WorkingTreeIntent) { [int]$WorkingTreeIntent.dirtyCount } else { -1 }
  warningCount = if ($WorkingTreeIntent) { [int]$WorkingTreeIntent.warningCount } else { -1 }
  buckets = $IntentBuckets
  warnings = if ($WorkingTreeIntent) { [string[]]@($WorkingTreeIntent.warnings) } else { [string[]]@() }
}
Write-Check "working tree intent classified" $IntentOk $IntentDetail $true

$ProofInventory = $null
if (-not $SkipProofInventory) {
  $TempInventoryJson = Join-Path $env:TEMP "homecue-proof-readiness-inventory.json"
  $InventoryScript = Join-Path $PSScriptRoot "check-proof-inventory.ps1"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $InventoryScript -ProofRoot $ProofRoot -ResultJsonPath $TempInventoryJson | Out-Host
  $ProofInventory = Read-JsonFile -Path $TempInventoryJson
}
$InventoryChecks = if ($ProofInventory) { [object[]]@($ProofInventory.checks) } else { [object[]]@() }
$InventoryOk = $ProofInventory -and $InventoryChecks.Count -gt 0
$InventoryDetail = if ($SkipProofInventory) {
  "skipped by caller"
} elseif ($ProofInventory) {
  "checks={0}, external_cloud_ready={1}" -f $InventoryChecks.Count, $ProofInventory.readyForExternalRelease
} else {
  "inventory check did not produce json"
}
$InventoryQwen = @(Get-CheckByName -Checks $InventoryChecks -Name "qwen verification proof")
$InventoryAlibaba = @(Get-CheckByName -Checks $InventoryChecks -Name "alibaba usage image proof")
$InventoryAlibabaReview = @(Get-CheckByName -Checks $InventoryChecks -Name "alibaba manual content review")
$InventoryBoardWs = @(Get-CheckByName -Checks $InventoryChecks -Name "esp32 board websocket voice-chat proof")
$InventoryXiaoqianWake = @(Get-CheckByName -Checks $InventoryChecks -Name "xiaoqian wake model proof")
$InventoryGallery = @(Get-CheckByName -Checks $InventoryChecks -Name "submission gallery upload assets")
$InventoryVideo = @(Get-CheckByName -Checks $InventoryChecks -Name "submission video upload asset")
$Evidence.proofInventory = @{
  ran = -not [bool]$SkipProofInventory
  ok = [bool]$InventoryOk
  readyForExternalRelease = if ($ProofInventory) { [bool]$ProofInventory.readyForExternalRelease } else { $false }
  checkedAt = if ($ProofInventory) { $ProofInventory.checkedAt } else { "" }
  checkCount = $InventoryChecks.Count
  qwen = if ($InventoryQwen.Count -gt 0) { $InventoryQwen[0].status } else { "" }
  alibaba = if ($InventoryAlibaba.Count -gt 0) { $InventoryAlibaba[0].status } else { "" }
  alibabaImageCount = if ($InventoryAlibaba.Count -gt 0 -and $InventoryAlibaba[0].evidence) { [int]$InventoryAlibaba[0].evidence.imageCount } else { 0 }
  alibabaManualReview = if ($InventoryAlibabaReview.Count -gt 0) { $InventoryAlibabaReview[0].status } else { "" }
  alibabaManualReviewReason = if ($InventoryAlibabaReview.Count -gt 0 -and $InventoryAlibabaReview[0].evidence) { [string]$InventoryAlibabaReview[0].evidence.reason } else { "" }
  boardWebSocketVoice = if ($InventoryBoardWs.Count -gt 0) { $InventoryBoardWs[0].status } else { "" }
  xiaoqianWakeModel = if ($InventoryXiaoqianWake.Count -gt 0) { $InventoryXiaoqianWake[0].status } else { "" }
  xiaoqianWakePresent = if ($InventoryXiaoqianWake.Count -gt 0 -and $InventoryXiaoqianWake[0].evidence) { [bool]$InventoryXiaoqianWake[0].evidence.targetWakePresent } else { $false }
  galleryUploadAssets = if ($InventoryGallery.Count -gt 0) { $InventoryGallery[0].status } else { "" }
  videoUploadAsset = if ($InventoryVideo.Count -gt 0) { $InventoryVideo[0].status } else { "" }
}
Write-Check "proof inventory summarized" $InventoryOk $InventoryDetail $false

$QwenPath = Join-Path $ProofRootPath "qwen-verification\latest.json"
$Qwen = Read-JsonFile -Path $QwenPath
$QwenPassed = $Qwen -and $Qwen.status -eq "passed" -and $Qwen.planner_provider -eq "qwen"
$QwenDetail = if ($Qwen) {
  "status={0}, provider={1}, model={2}, checked_at={3}" -f $Qwen.status, $Qwen.planner_provider, $Qwen.model, $Qwen.checked_at
} else {
  "missing: $QwenPath"
}
$Evidence.qwen = @{
  path = $QwenPath
  exists = [bool]$Qwen
  status = if ($Qwen) { $Qwen.status } else { "" }
  provider = if ($Qwen) { $Qwen.planner_provider } else { "" }
  model = if ($Qwen) { $Qwen.model } else { "" }
  checkedAt = if ($Qwen) { $Qwen.checked_at } else { "" }
}
Write-Check "qwen proof passed" $QwenPassed $QwenDetail $true

$AlibabaDir = Join-Path $ProofRootPath "alibaba-proof"
$MinimumAlibabaImageBytes = 1024
$AlibabaFileCandidates = @()
if (Test-Path -LiteralPath $AlibabaDir) {
  $AlibabaFileCandidates = @(Get-ChildItem -LiteralPath $AlibabaDir -File -ErrorAction SilentlyContinue | Where-Object {
      $_.Extension -match "^\.(png|jpe?g|webp)$"
    })
}
$AlibabaFileEvidence = @($AlibabaFileCandidates | ForEach-Object {
    $Signature = if ($_.Length -ge $MinimumAlibabaImageBytes) {
      Test-ImageFileSignature -File $_
    } else {
      [pscustomobject]@{
        ok = $false
        reason = "too-small"
      }
    }
    [pscustomobject]@{
      item = $_
      name = $_.Name
      length = [int64]$_.Length
      signatureOk = [bool]$Signature.ok
      invalidReason = if ($_.Length -lt $MinimumAlibabaImageBytes) { "too-small" } elseif (-not $Signature.ok) { $Signature.reason } else { "" }
    }
  })
$AlibabaFiles = @($AlibabaFileEvidence | Where-Object { $_.length -ge $MinimumAlibabaImageBytes -and $_.signatureOk })
$AlibabaInvalidFiles = @($AlibabaFileEvidence | Where-Object { $_.length -lt $MinimumAlibabaImageBytes -or -not $_.signatureOk })
$AlibabaReady = $AlibabaFiles.Count -gt 0
$Evidence.alibaba = @{
  path = $AlibabaDir
  minimumBytes = $MinimumAlibabaImageBytes
  signatureRequired = $true
  candidateCount = $AlibabaFileCandidates.Count
  imageCount = $AlibabaFiles.Count
  images = [string[]]@($AlibabaFiles | ForEach-Object { $_.name })
  invalidImages = [object[]]@($AlibabaInvalidFiles | ForEach-Object {
      [pscustomobject]@{
        name = $_.name
        length = [int64]$_.length
        reason = $_.invalidReason
      }
    })
}
Write-Check "alibaba usage proof images" $AlibabaReady ("image_count={0}, candidate_count={1}, invalid_count={2}, minimum_bytes={3}, signature_required=true" -f $AlibabaFiles.Count, $AlibabaFileCandidates.Count, $AlibabaInvalidFiles.Count, $MinimumAlibabaImageBytes) $true

$Level4Candidates = @(
  (Join-Path $ProofRootPath "esp32-level4-full-check.json"),
  (Join-Path $ProofRootPath "esp32-level4-check.json")
)
$BestLevel4 = $null
foreach ($Candidate in $Level4Candidates) {
  $Json = Read-JsonFile -Path $Candidate
  if ($Json -and @($Json.failures).Count -eq 0) {
    $BestLevel4 = [pscustomobject]@{
      path = $Candidate
      json = $Json
    }
    break
  }
}
$Level4Ready = [bool]$BestLevel4
$Evidence.level4 = @{
  passed = $Level4Ready
  path = if ($BestLevel4) { $BestLevel4.path } else { "" }
}
Write-Check "esp32 level4 proof" $Level4Ready $(if ($BestLevel4) { $BestLevel4.path } else { "no passing level4 check json found" }) $false

$StalePath = Join-Path $ProofRootPath (("dev" + "post") + "-readiness\latest.json")
$StaleSnapshot = Read-JsonFile -Path $StalePath
$SnapshotOk = $StaleSnapshot -and $StaleSnapshot.status -eq "passed"
$SnapshotDetail = if ($StaleSnapshot) {
  "status={0}, checked_at={1}" -f $StaleSnapshot.status, $StaleSnapshot.checked_at
} else {
  "missing: $StalePath"
}
$Evidence.legacySnapshot = @{
  path = $StalePath
  exists = [bool]$StaleSnapshot
  status = if ($StaleSnapshot) { $StaleSnapshot.status } else { "" }
  checkedAt = if ($StaleSnapshot) { $StaleSnapshot.checked_at } else { "" }
}
Write-Check "legacy readiness snapshot passed" $SnapshotOk $SnapshotDetail $false

$PortState = $null
if (-not $SkipPortProbe) {
  $TempPortJson = Join-Path $env:TEMP "homecue-proof-readiness-port.json"
  $PortScript = Join-Path $PSScriptRoot "check-esp32-port-state.ps1"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $PortScript -Port $Port -ResultJsonPath $TempPortJson | Out-Host
  $PortState = Read-JsonFile -Path $TempPortJson
}
$PortReady = $PortState -and $PortState.state -eq "writable"
$PortDetail = if ($SkipPortProbe) {
  "skipped by caller"
} elseif ($PortState) {
  "state={0}, ports={1}" -f $PortState.state, (@($PortState.detectedPorts) -join ",")
} else {
  "probe did not produce json"
}
$Evidence.port = @{
  probed = -not [bool]$SkipPortProbe
  port = $Port
  state = if ($PortState) { $PortState.state } else { "" }
  detectedPorts = if ($PortState) { [string[]]@($PortState.detectedPorts) } else { [string[]]@() }
}
Write-Check "esp32 port writable" $PortReady $PortDetail $false

if (-not $GitCleanAndSynced) {
  Add-ReleaseGap `
    -Id "git-worktree" `
    -Area "repository" `
    -Status ("ahead={0}, behind={1}, dirty={2}" -f $Ahead, $Behind, $DirtyCount) `
    -Action "Review the intent buckets, stage only intended public-repo changes, then commit or leave the repo out of release claims." `
    -BlocksRelease $true
}
if (-not $SecretScanClean) {
  Add-ReleaseGap `
    -Id "secret-scan" `
    -Area "repository-safety" `
    -Status $SecretScanDetail `
    -Action "Remove or mask secret-shaped values and rerun scan-secrets.ps1 -All -IncludeUntracked plus -Staged." `
    -BlocksRelease $true
}
if (-not $EnvExampleSafe) {
  Add-ReleaseGap `
    -Id "public-env-example" `
    -Area "repository-safety" `
    -Status $EnvExampleDetail `
    -Action "Keep public example keys present but blank, and remove token-shaped values or local filesystem paths." `
    -BlocksRelease $true
}
if (-not $IntentOk) {
  Add-ReleaseGap `
    -Id "working-tree-intent" `
    -Area "repository" `
    -Status $IntentDetail `
    -Action "Classify or remove unrecognized dirty files before staging any public-repo change." `
    -BlocksRelease $true
}
if (-not $QwenPassed) {
  Add-ReleaseGap `
    -Id "qwen-proof" `
    -Area "cloud-proof" `
    -Status $QwenDetail `
    -Action "Rerun verify-qwen.ps1 with ACTIVE_PROVIDER=qwen and keep the resulting local proof JSON." `
    -BlocksRelease $true
}
if (-not $AlibabaReady) {
  Add-ReleaseGap `
    -Id "alibaba-usage-image" `
    -Area "cloud-proof" `
    -Status ("image_count={0}, candidate_count={1}, invalid_count={2}, minimum_bytes={3}, signature_required=true" -f $AlibabaFiles.Count, $AlibabaFileCandidates.Count, $AlibabaInvalidFiles.Count, $MinimumAlibabaImageBytes) `
    -Action "Add at least one masked DashScope or Model Studio usage screenshot under assets/demo/alibaba-proof/." `
    -BlocksRelease $true
}
if ($AlibabaReady -and $InventoryAlibabaReview.Count -gt 0 -and $InventoryAlibabaReview[0].status -ne "OK") {
  Add-ReleaseGap `
    -Id "alibaba-proof-review" `
    -Area "cloud-proof" `
    -Status ("status={0}, reason={1}" -f $InventoryAlibabaReview[0].status, $Evidence.proofInventory.alibabaManualReviewReason) `
    -Action "Complete alibaba-proof-review.json for the valid Alibaba usage image, confirming Qwen/DashScope, non-zero usage, date/range, region cue, and privacy masking." `
    -BlocksRelease $true
}
if ($InventoryXiaoqianWake.Count -gt 0 -and $InventoryXiaoqianWake[0].status -ne "OK") {
  Add-ReleaseGap `
    -Id "xiaoqian-wake-model" `
    -Area "hardware-voice" `
    -Status ("status={0}, present={1}" -f $InventoryXiaoqianWake[0].status, $Evidence.proofInventory.xiaoqianWakePresent) `
    -Action "Generate or obtain a real xiaoqian WakeNet/custom wake model, rebuild srmodels.bin, then rerun check-esp32-sr-models.ps1 and a real wake proof." `
    -BlocksRelease $false
}
if (-not $SkipPortProbe -and -not $PortReady) {
  Add-ReleaseGap `
    -Id "esp32-port" `
    -Area "hardware" `
    -Status $PortDetail `
    -Action "Recover the ESP32 serial connection before attempting fresh flash, serial capture, or hardware voice proof." `
    -BlocksRelease $false
}
if ($InventoryOk -and $ProofInventory -and $ProofInventory.readyForExternalRelease -ne $true) {
  Add-ReleaseGap `
    -Id "proof-inventory-external-release" `
    -Area "submission" `
    -Status ("external_cloud_ready={0}" -f $ProofInventory.readyForExternalRelease) `
    -Action "Treat local voice/media proof as supporting evidence only; complete required cloud usage proof before external submission." `
    -BlocksRelease $true
}

$ReleaseGapItems = [object[]]$ReleaseGaps.ToArray()
$BlockingReleaseGaps = @($ReleaseGapItems | Where-Object { $_.blocksRelease })
$FollowUpReleaseGaps = @($ReleaseGapItems | Where-Object { -not $_.blocksRelease })
$Evidence.releaseGaps = $ReleaseGapItems
$Evidence.releaseGapSummary = @{
  totalCount = $ReleaseGapItems.Count
  blockingCount = $BlockingReleaseGaps.Count
  followUpCount = $FollowUpReleaseGaps.Count
  blockingIds = [string[]]@($BlockingReleaseGaps | ForEach-Object { $_.id })
  followUpIds = [string[]]@($FollowUpReleaseGaps | ForEach-Object { $_.id })
  releaseBlocked = [bool]($BlockingReleaseGaps.Count -gt 0)
}
$Evidence.nextActions = [string[]]@($ReleaseGapItems | ForEach-Object { $_.action })

$ReadyForRelease = $GitCleanAndSynced -and $SecretScanClean -and $EnvExampleSafe -and $QwenPassed -and $AlibabaReady -and ($BlockingReleaseGaps.Count -eq 0)
$Evidence.readyForRelease = $ReadyForRelease
$GateStatus = "pass"
$GateReason = "ready"
$ExpectedExitCode = 0
if ($Required -and $Failures.Count -gt 0) {
  $GateStatus = "fail"
  $GateReason = "required-check-failure"
  $ExpectedExitCode = 1
} elseif ($FailOnBlockingGaps -and $BlockingReleaseGaps.Count -gt 0) {
  $GateStatus = "fail"
  $GateReason = "blocking-release-gaps"
  $ExpectedExitCode = 2
} elseif (-not $ReadyForRelease) {
  $GateStatus = "warn"
  $GateReason = "not-ready-report-only"
}
$GateOutcome = @{
  status = $GateStatus
  reason = $GateReason
  expectedExitCode = [int]$ExpectedExitCode
  requiredMode = [bool]$Required
  failOnBlockingGaps = [bool]$FailOnBlockingGaps
  requiredFailureCount = $Failures.Count
  requiredFailures = [string[]]$Failures.ToArray()
  blockingGapCount = $BlockingReleaseGaps.Count
  blockingGapIds = [string[]]@($BlockingReleaseGaps | ForEach-Object { $_.id })
  readyForRelease = [bool]$ReadyForRelease
}
$Evidence.gateOutcome = $GateOutcome
$CheckedAt = (Get-Date).ToString("o")
Write-Host ""
Write-Host ("Summary: {0}" -f $(if ($ReadyForRelease) { "ready" } else { "not ready" }))
Write-Host ("Gate outcome: status={0}, expected_exit={1}, reason={2}" -f $GateStatus, $ExpectedExitCode, $GateReason)
if ($ReleaseGaps.Count -gt 0) {
  Write-Host "Next actions:"
  foreach ($Gap in $ReleaseGaps) {
    Write-Host ("- [{0}] {1}" -f $Gap.id, $Gap.action)
  }
}

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result = @{
    checkedAt = $CheckedAt
    readyForRelease = [bool]$ReadyForRelease
    requiredMode = [bool]$Required
    failOnBlockingGaps = [bool]$FailOnBlockingGaps
    gateOutcome = $GateOutcome
    failures = [string[]]$Failures.ToArray()
    evidence = $Evidence
    checks = [object[]]$Checks.ToArray()
  }
  $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($ResultMarkdownPath) {
  New-ParentDirectory -Path $ResultMarkdownPath
  $MarkdownLines = New-Object System.Collections.Generic.List[string]
  $MarkdownLines.Add("# HomeCue Edge Proof Readiness")
  $MarkdownLines.Add("")
  $MarkdownLines.Add(("- Checked at: {0}" -f $CheckedAt))
  $MarkdownLines.Add(("- Summary: {0}" -f $(if ($ReadyForRelease) { "ready" } else { "not ready" })))
  $MarkdownLines.Add(("- Required mode: {0}" -f [bool]$Required))
  $MarkdownLines.Add(("- Fail on blocking gaps: {0}" -f [bool]$FailOnBlockingGaps))
  $MarkdownLines.Add(("- Gate outcome: status={0}, expected_exit={1}, reason={2}" -f $GateStatus, $ExpectedExitCode, $GateReason))
  $MarkdownLines.Add("")
  $MarkdownLines.Add("## Evidence Snapshot")
  $MarkdownLines.Add(("- Git: branch='{0}', ahead={1}, behind={2}, dirty={3}" -f $BranchText, $Ahead, $Behind, $DirtyCount))
  $MarkdownLines.Add(("- Secret scan: ran={0}, clean={1}, findings={2}, scanned={3}, skipped={4}" -f (-not [bool]$SkipSecretScan), [bool]$SecretScanClean, $Evidence.secretScan.findingCount, $Evidence.secretScan.scannedCount, $Evidence.secretScan.skippedCount))
  $MarkdownLines.Add(("- Public env example: safe={0}, keys={1}/{2}" -f [bool]$EnvExampleSafe, $Evidence.publicEnvExample.keyCount, $Evidence.publicEnvExample.requiredKeyCount))
  $MarkdownLines.Add(("- Working-tree intent: ran={0}, ok={1}, dirty={2}, warnings={3}" -f (-not [bool]$SkipWorkingTreeIntent), [bool]$IntentOk, $Evidence.workingTreeIntent.dirtyCount, $Evidence.workingTreeIntent.warningCount))
  $MarkdownLines.Add(("- Proof inventory: ran={0}, ok={1}, checks={2}, external_cloud_ready={3}" -f (-not [bool]$SkipProofInventory), [bool]$InventoryOk, $Evidence.proofInventory.checkCount, $Evidence.proofInventory.readyForExternalRelease))
  $MarkdownLines.Add(("- Qwen proof: status={0}, provider={1}, model={2}" -f $Evidence.qwen.status, $Evidence.qwen.provider, $Evidence.qwen.model))
  $MarkdownLines.Add(("- Alibaba usage images: count={0}" -f $Evidence.alibaba.imageCount))
  $MarkdownLines.Add(("- Alibaba manual review: status={0}, reason={1}" -f $Evidence.proofInventory.alibabaManualReview, $Evidence.proofInventory.alibabaManualReviewReason))
  $MarkdownLines.Add(("- ESP32 port: probed={0}, port={1}, state={2}" -f (-not [bool]$SkipPortProbe), $Port, $Evidence.port.state))
  $MarkdownLines.Add(("- Release gaps: total={0}, blocking={1}, follow_up={2}" -f $Evidence.releaseGapSummary.totalCount, $Evidence.releaseGapSummary.blockingCount, $Evidence.releaseGapSummary.followUpCount))
  if ($Evidence.releaseGapSummary.blockingCount -gt 0) {
    $MarkdownLines.Add(("- Blocking gap IDs: {0}" -f ($Evidence.releaseGapSummary.blockingIds -join ", ")))
  }
  $MarkdownLines.Add("")
  $MarkdownLines.Add("## Release Gaps")
  if ($ReleaseGaps.Count -eq 0) {
    $MarkdownLines.Add("- None")
  } else {
    foreach ($Gap in $ReleaseGaps) {
      $Blocker = if ($Gap.blocksRelease) { "BLOCKING" } else { "FOLLOW-UP" }
      $MarkdownLines.Add(("- [{0}] {1} ({2}): {3}" -f $Blocker, $Gap.id, $Gap.area, (ConvertTo-MarkdownText $Gap.status)))
      $MarkdownLines.Add(("  Action: {0}" -f (ConvertTo-MarkdownText $Gap.action)))
    }
  }
  $MarkdownLines.Add("")
  $MarkdownLines.Add("## Checks")
  foreach ($Check in $Checks) {
    $Requirement = if ($Check.required) { "required" } else { "optional" }
    $Detail = ConvertTo-MarkdownText $Check.detail
    $Suffix = if ($Detail) { " - $Detail" } else { "" }
    $MarkdownLines.Add(("- [{0}] {1} ({2}){3}" -f $Check.status, $Check.name, $Requirement, $Suffix))
  }

  $MarkdownLines | Set-Content -LiteralPath $ResultMarkdownPath -Encoding UTF8
  Write-Host ("Report : {0}" -f (Resolve-Path -LiteralPath $ResultMarkdownPath).Path)
}

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Proof readiness check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

if ($FailOnBlockingGaps -and $BlockingReleaseGaps.Count -gt 0) {
  Write-Host "Proof readiness check found blocking release gap(s):" -ForegroundColor Red
  foreach ($Gap in $BlockingReleaseGaps) {
    Write-Host ("- {0}: {1}" -f $Gap.id, $Gap.status) -ForegroundColor Red
  }
  exit 2
}

Write-Host "Proof readiness check complete."
exit 0
