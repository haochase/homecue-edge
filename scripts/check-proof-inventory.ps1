param(
  [string]$ProofRoot = ".\assets\demo",
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

function Get-JsonArrayCount {
  param(
    [object]$Json,
    [string]$PropertyName
  )

  if (-not $Json) {
    return 0
  }
  if (-not ($Json.PSObject.Properties.Name -contains $PropertyName)) {
    return 0
  }
  return @($Json.$PropertyName).Count
}

function Test-JsonCheckOk {
  param(
    [object]$Json,
    [string]$Name
  )

  if (-not $Json -or -not ($Json.PSObject.Properties.Name -contains "checks")) {
    return $false
  }

  $Match = @($Json.checks | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
  return ($Match.Count -gt 0 -and $Match[0].ok -eq $true)
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

function Get-FileEvidence {
  param(
    [string]$Path,
    [int]$MinimumBytes = 1
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{
      path = $Path
      exists = $false
      length = 0
      ok = $false
    }
  }

  $Item = Get-Item -LiteralPath $Path
  return [pscustomobject]@{
    path = $Path
    exists = $true
    length = [int64]$Item.Length
    ok = $Item.Length -ge $MinimumBytes
  }
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

function Get-AlibabaManualReview {
  param(
    [string]$ReviewPath,
    [object[]]$ValidImages
  )

  $RequiredBooleanFields = @(
    "qwenOrDashscopeVisible",
    "nonZeroUsageVisible",
    "dateOrRangeVisible",
    "regionCueVisible",
    "privacyMasked"
  )
  $ValidImageNames = [string[]]@($ValidImages | ForEach-Object { $_.name })

  if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
    return [pscustomobject]@{
      ok = $false
      path = $ReviewPath
      exists = $false
      parsed = $false
      imageName = ""
      imageInValidSet = $false
      reviewedAt = ""
      reviewedAtOk = $false
      requiredFields = [string[]]$RequiredBooleanFields
      missingOrFalseFields = [string[]]$RequiredBooleanFields
      reason = "missing-review"
    }
  }

  $Review = Read-JsonFile -Path $ReviewPath
  if (-not $Review) {
    return [pscustomobject]@{
      ok = $false
      path = $ReviewPath
      exists = $true
      parsed = $false
      imageName = ""
      imageInValidSet = $false
      reviewedAt = ""
      reviewedAtOk = $false
      requiredFields = [string[]]$RequiredBooleanFields
      missingOrFalseFields = [string[]]$RequiredBooleanFields
      reason = "invalid-json"
    }
  }

  $ImageName = [string](Get-PropertyValue -Object $Review -Name "imageName" -Default "")
  $ReviewedAt = [string](Get-PropertyValue -Object $Review -Name "reviewedAt" -Default "")
  $ParsedReviewedAt = [System.DateTimeOffset]::MinValue
  $ReviewedAtOk = [System.DateTimeOffset]::TryParse(
    $ReviewedAt,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::None,
    [ref]$ParsedReviewedAt
  )
  $ImageInValidSet = [bool]($ImageName -and ($ValidImageNames -contains $ImageName))
  $MissingOrFalseFields = New-Object System.Collections.Generic.List[string]

  foreach ($Field in $RequiredBooleanFields) {
    if (-not (Test-HasProperty -Object $Review -Name $Field) -or [bool]$Review.$Field -ne $true) {
      $MissingOrFalseFields.Add($Field)
    }
  }

  $Reasons = New-Object System.Collections.Generic.List[string]
  if (-not $ImageInValidSet) {
    $Reasons.Add("image-not-valid")
  }
  if (-not $ReviewedAtOk) {
    $Reasons.Add("invalid-reviewedAt")
  }
  if ($MissingOrFalseFields.Count -gt 0) {
    $Reasons.Add("missing-or-false-fields")
  }

  [pscustomobject]@{
    ok = [bool]($ImageInValidSet -and $ReviewedAtOk -and $MissingOrFalseFields.Count -eq 0)
    path = $ReviewPath
    exists = $true
    parsed = $true
    imageName = $ImageName
    imageInValidSet = $ImageInValidSet
    reviewedAt = $ReviewedAt
    reviewedAtOk = $ReviewedAtOk
    requiredFields = [string[]]$RequiredBooleanFields
    missingOrFalseFields = [string[]]$MissingOrFalseFields.ToArray()
    reason = if ($Reasons.Count -gt 0) { $Reasons -join "," } else { "" }
  }
}

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $false,
    [hashtable]$Evidence = @{}
  )

  $Status = if ($Ok) { "OK" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)

  $script:Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      required = [bool]$RequiredCheck
      detail = $Detail
      evidence = $Evidence
    })

  if ($Required -and $RequiredCheck -and -not $Ok) {
    $script:Failures.Add($Name)
  }
}

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$RepoRoot = Resolve-Path "$PSScriptRoot\.."
$ProofRootPath = Join-Path $RepoRoot $ProofRoot

Write-Host "HomeCue Edge proof inventory check"
Write-Host ("Repo   : {0}" -f $RepoRoot.Path)
Write-Host ("Proofs : {0}" -f $ProofRootPath)
Write-Host ""

$QwenPath = Join-Path $ProofRootPath "qwen-verification\latest.json"
$Qwen = Read-JsonFile -Path $QwenPath
$QwenOk = $Qwen -and $Qwen.status -eq "passed" -and $Qwen.planner_provider -eq "qwen"
$QwenDetail = if ($Qwen) {
  "status={0}, provider={1}, model={2}" -f $Qwen.status, $Qwen.planner_provider, $Qwen.model
} else {
  "missing"
}
Add-Check "qwen verification proof" $QwenOk $QwenDetail $true @{
  path = $QwenPath
  exists = [bool]$Qwen
  status = if ($Qwen) { $Qwen.status } else { "" }
  provider = if ($Qwen) { $Qwen.planner_provider } else { "" }
  model = if ($Qwen) { $Qwen.model } else { "" }
}

$AlibabaDir = Join-Path $ProofRootPath "alibaba-proof"
$MinimumAlibabaImageBytes = 1024
$AlibabaImageCandidates = @()
if (Test-Path -LiteralPath $AlibabaDir) {
  $AlibabaImageCandidates = @(Get-ChildItem -LiteralPath $AlibabaDir -File -ErrorAction SilentlyContinue | Where-Object {
      $_.Extension -match "^\.(png|jpe?g|webp)$"
    })
}
$AlibabaImageEvidence = @($AlibabaImageCandidates | ForEach-Object {
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
$AlibabaImages = @($AlibabaImageEvidence | Where-Object { $_.length -ge $MinimumAlibabaImageBytes -and $_.signatureOk })
$AlibabaInvalidImages = @($AlibabaImageEvidence | Where-Object { $_.length -lt $MinimumAlibabaImageBytes -or -not $_.signatureOk })
$AlibabaOk = $AlibabaImages.Count -gt 0
Add-Check "alibaba usage image proof" $AlibabaOk ("image_count={0}, candidate_count={1}, invalid_count={2}, minimum_bytes={3}, signature_required=true" -f $AlibabaImages.Count, $AlibabaImageCandidates.Count, $AlibabaInvalidImages.Count, $MinimumAlibabaImageBytes) $true @{
  path = $AlibabaDir
  minimumBytes = $MinimumAlibabaImageBytes
  signatureRequired = $true
  candidateCount = $AlibabaImageCandidates.Count
  imageCount = $AlibabaImages.Count
  images = [string[]]@($AlibabaImages | ForEach-Object { $_.name })
  validImages = [object[]]@($AlibabaImages | ForEach-Object {
      [pscustomobject]@{
        name = $_.name
        length = [int64]$_.length
      }
    })
  invalidImages = [object[]]@($AlibabaInvalidImages | ForEach-Object {
      [pscustomobject]@{
        name = $_.name
        length = [int64]$_.length
        reason = $_.invalidReason
      }
    })
}

$AlibabaReviewPath = Join-Path $AlibabaDir "alibaba-proof-review.json"
$AlibabaManualReview = Get-AlibabaManualReview -ReviewPath $AlibabaReviewPath -ValidImages $AlibabaImages
$AlibabaReviewDetail = if ($AlibabaManualReview.ok) {
  "image={0}, reviewed_at={1}" -f $AlibabaManualReview.imageName, $AlibabaManualReview.reviewedAt
} else {
  "reason={0}, image={1}, missing_or_false={2}" -f $AlibabaManualReview.reason, $AlibabaManualReview.imageName, (@($AlibabaManualReview.missingOrFalseFields) -join ",")
}
Add-Check "alibaba manual content review" $AlibabaManualReview.ok $AlibabaReviewDetail $true @{
  path = $AlibabaManualReview.path
  exists = [bool]$AlibabaManualReview.exists
  parsed = [bool]$AlibabaManualReview.parsed
  imageName = $AlibabaManualReview.imageName
  imageInValidSet = [bool]$AlibabaManualReview.imageInValidSet
  reviewedAt = $AlibabaManualReview.reviewedAt
  reviewedAtOk = [bool]$AlibabaManualReview.reviewedAtOk
  requiredFields = [string[]]@($AlibabaManualReview.requiredFields)
  missingOrFalseFields = [string[]]@($AlibabaManualReview.missingOrFalseFields)
  reason = $AlibabaManualReview.reason
}

$Level4Candidates = @(
  (Join-Path $ProofRootPath "esp32-level4-full-check.json"),
  (Join-Path $ProofRootPath "esp32-level4-check.json")
)
$Level4Evidence = $null
foreach ($Candidate in $Level4Candidates) {
  $Json = Read-JsonFile -Path $Candidate
  if ($Json -and (Get-JsonArrayCount -Json $Json -PropertyName "failures") -eq 0) {
    $Level4Evidence = [pscustomobject]@{
      path = $Candidate
      exists = $true
      passed = $true
    }
    break
  }
}
$Level4Ok = [bool]$Level4Evidence
Add-Check "esp32 guarded execute level4 proof" $Level4Ok $(if ($Level4Evidence) { $Level4Evidence.path } else { "no passing check json found" }) $false @{
  path = if ($Level4Evidence) { $Level4Evidence.path } else { "" }
}

$VoiceWsPath = Join-Path $ProofRootPath "voice-chat-ws-test.json"
$VoiceWs = Read-JsonFile -Path $VoiceWsPath
$VoiceWsOk = $VoiceWs -and $VoiceWs.status -eq "passed" -and (Test-JsonCheckOk -Json $VoiceWs -Name "feature_opus_gap_declared")
$VoiceWsDetail = if ($VoiceWs) {
  "status={0}, provider={1}, turn={2}, opus_gap_declared={3}" -f $VoiceWs.status, $VoiceWs.provider, $VoiceWs.turnIndex, (Test-JsonCheckOk -Json $VoiceWs -Name "feature_opus_gap_declared")
} else {
  "missing"
}
Add-Check "websocket voice-chat protocol proof" $VoiceWsOk $VoiceWsDetail $false @{
  path = $VoiceWsPath
  exists = [bool]$VoiceWs
  status = if ($VoiceWs) { $VoiceWs.status } else { "" }
  provider = if ($VoiceWs) { $VoiceWs.provider } else { "" }
  turnIndex = if ($VoiceWs) { [int]$VoiceWs.turnIndex } else { 0 }
  opusGapDeclared = if ($VoiceWs) { [bool](Test-JsonCheckOk -Json $VoiceWs -Name "feature_opus_gap_declared") } else { $false }
}

$VoiceBoardCandidates = New-Object System.Collections.Generic.List[object]
$BoardCandidatePaths = @()
$SpeakerPath = Join-Path $ProofRootPath "esp32-speaker-output-check.json"
if (Test-Path -LiteralPath $SpeakerPath) {
  $BoardCandidatePaths += $SpeakerPath
}
if (Test-Path -LiteralPath $ProofRootPath) {
  $BoardCandidatePaths += @(Get-ChildItem -LiteralPath $ProofRootPath -File -Filter "*voice-chat*check.json" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

foreach ($Path in ($BoardCandidatePaths | Select-Object -Unique)) {
  $Json = Read-JsonFile -Path $Path
  if (-not $Json) {
    continue
  }

  $Failed = (Get-JsonArrayCount -Json $Json -PropertyName "failures") -gt 0
  $AudioPlaybackCount = if ($Json.PSObject.Properties.Name -contains "audioPlaybackCount") { [int]$Json.audioPlaybackCount } else { 0 }
  $SessionTurnCount = Get-JsonArrayCount -Json $Json -PropertyName "sessionTurns"
  $Source = if ($Json.PSObject.Properties.Name -contains "source") { $Json.source } else { "" }
  $IsWebSocketProof = $Source -eq "serial-websocket-audio" -or $Path -match "voice-chat-ws"
  $VoiceBoardCandidates.Add([pscustomobject]@{
      path = $Path
      source = $Source
      websocket = [bool]$IsWebSocketProof
      passed = -not $Failed
      ready = (-not $Failed -and $AudioPlaybackCount -gt 0)
      failureCount = Get-JsonArrayCount -Json $Json -PropertyName "failures"
      expectedTurns = if ($Json.PSObject.Properties.Name -contains "expectedTurns") { [int]$Json.expectedTurns } else { 0 }
      sessionTurnCount = $SessionTurnCount
      wsHandshakeCount = if ($Json.PSObject.Properties.Name -contains "wsHandshakeCount") { [int]$Json.wsHandshakeCount } else { 0 }
      wsUploadCount = if ($Json.PSObject.Properties.Name -contains "wsUploadCount") { [int]$Json.wsUploadCount } else { 0 }
      wsReadyCount = if ($Json.PSObject.Properties.Name -contains "wsReadyCount") { [int]$Json.wsReadyCount } else { 0 }
      wakePhrase = if ($Json.PSObject.Properties.Name -contains "wakePhrase") { $Json.wakePhrase } else { "" }
      triggerCount = if ($Json.PSObject.Properties.Name -contains "triggerCount") { [int]$Json.triggerCount } else { 0 }
      audioPlaybackCount = $AudioPlaybackCount
    })
}

$PassingBoardProof = @($VoiceBoardCandidates | Where-Object { $_.ready } | Select-Object -First 1)
$BoardVoiceOk = $PassingBoardProof.Count -gt 0
$BoardDetail = if ($BoardVoiceOk) {
  "passing={0}, candidates={1}, wake='{2}', turns={3}" -f $PassingBoardProof[0].path, $VoiceBoardCandidates.Count, $PassingBoardProof[0].wakePhrase, $PassingBoardProof[0].sessionTurnCount
} else {
  "passing=0, candidates={0}" -f $VoiceBoardCandidates.Count
}
Add-Check "esp32 board voice-chat speaker proof" $BoardVoiceOk $BoardDetail $false @{
  candidateCount = $VoiceBoardCandidates.Count
  passingPath = if ($BoardVoiceOk) { $PassingBoardProof[0].path } else { "" }
  candidates = [object[]]$VoiceBoardCandidates.ToArray()
}

$PassingBoardWsProof = @(
  $VoiceBoardCandidates |
    Where-Object { $_.ready -and $_.websocket -and $_.wsHandshakeCount -gt 0 -and $_.wsReadyCount -gt 0 } |
    Sort-Object @{ Expression = "wsReadyCount"; Descending = $true }, @{ Expression = "audioPlaybackCount"; Descending = $true }, path |
    Select-Object -First 1
)
$BoardWsOk = $PassingBoardWsProof.Count -gt 0
$BoardWsDetail = if ($BoardWsOk) {
  "passing={0}, uploads={1}, ready={2}, playback={3}" -f $PassingBoardWsProof[0].path, $PassingBoardWsProof[0].wsUploadCount, $PassingBoardWsProof[0].wsReadyCount, $PassingBoardWsProof[0].audioPlaybackCount
} else {
  "passing=0, ws_candidates={0}" -f @($VoiceBoardCandidates | Where-Object { $_.websocket }).Count
}
Add-Check "esp32 board websocket voice-chat proof" $BoardWsOk $BoardWsDetail $false @{
  passingPath = if ($BoardWsOk) { $PassingBoardWsProof[0].path } else { "" }
  websocketCandidates = [object[]]@($VoiceBoardCandidates | Where-Object { $_.websocket })
}

$TargetWakeKeyword = "xiaoqian"
$WakeModelCandidates = New-Object System.Collections.Generic.List[object]
$WakeModelCandidatePaths = @(
  (Join-Path $ProofRootPath "esp32-sr-models-xiaoqian-check.json"),
  (Join-Path $ProofRootPath "esp32-sr-models-xiaoqian-build-check.json")
)
foreach ($Path in ($WakeModelCandidatePaths | Select-Object -Unique)) {
  $Json = Read-JsonFile -Path $Path
  if (-not $Json) {
    continue
  }

  $ProbeMatch = @()
  if ($Json.PSObject.Properties.Name -contains "probeWakeKeywords") {
    $ProbeMatch = @($Json.probeWakeKeywords | Where-Object { $_.keyword -eq $TargetWakeKeyword } | Select-Object -First 1)
  }
  $TargetWakePresent = if ($Json.PSObject.Properties.Name -contains "requiredWakeKeyword" -and $Json.requiredWakeKeyword -eq $TargetWakeKeyword) {
    [bool]$Json.requiredWakePresent
  } elseif ($ProbeMatch.Count -gt 0) {
    [bool]$ProbeMatch[0].present
  } else {
    $false
  }
  $BlockedModelsPresent = if ($Json.PSObject.Properties.Name -contains "blockedModelsPresent") {
    [string[]]@($Json.blockedModelsPresent)
  } else {
    [string[]]@()
  }

  $WakeModelCandidates.Add([pscustomobject]@{
      path = $Path
      status = if ($Json.PSObject.Properties.Name -contains "status") { $Json.status } else { "" }
      requiredWakeKeyword = if ($Json.PSObject.Properties.Name -contains "requiredWakeKeyword") { $Json.requiredWakeKeyword } else { "" }
      targetWakePresent = [bool]$TargetWakePresent
      requiredWakePresent = if ($Json.PSObject.Properties.Name -contains "requiredWakePresent") { [bool]$Json.requiredWakePresent } else { $false }
      requiredMultinetKeyword = if ($Json.PSObject.Properties.Name -contains "requiredMultinetKeyword") { $Json.requiredMultinetKeyword } else { "" }
      requiredMultinetPresent = if ($Json.PSObject.Properties.Name -contains "requiredMultinetPresent") { [bool]$Json.requiredMultinetPresent } else { $false }
      blockedModelsPresent = $BlockedModelsPresent
    })
}

$PassingWakeModel = @(
  $WakeModelCandidates |
    Where-Object {
      $_.requiredWakeKeyword -eq $TargetWakeKeyword -and
      $_.targetWakePresent -and
      $_.requiredMultinetPresent -and
      $_.blockedModelsPresent.Count -eq 0 -and
      $_.status -eq "passed"
    } |
    Select-Object -First 1
)
$WakeModelOk = $PassingWakeModel.Count -gt 0
$BestWakeModel = @($WakeModelCandidates | Select-Object -First 1)
$WakeModelDetail = if ($WakeModelOk) {
  "target={0}, passing={1}" -f $TargetWakeKeyword, $PassingWakeModel[0].path
} elseif ($BestWakeModel.Count -gt 0) {
  "target={0}, present={1}, status={2}, candidates={3}" -f $TargetWakeKeyword, $BestWakeModel[0].targetWakePresent, $BestWakeModel[0].status, $WakeModelCandidates.Count
} else {
  "target={0}, candidates=0" -f $TargetWakeKeyword
}
Add-Check "xiaoqian wake model proof" $WakeModelOk $WakeModelDetail $false @{
  targetWakeKeyword = $TargetWakeKeyword
  targetWakePresent = if ($BestWakeModel.Count -gt 0) { [bool]$BestWakeModel[0].targetWakePresent } else { $false }
  passingPath = if ($WakeModelOk) { $PassingWakeModel[0].path } else { "" }
  candidateCount = $WakeModelCandidates.Count
  candidates = [object[]]$WakeModelCandidates.ToArray()
}

$GalleryDirName = ("dev" + "post-upload")
$GalleryDir = Join-Path $ProofRootPath $GalleryDirName
$ExpectedGalleryAssets = @(
  "00-cover-homecue-edge.png",
  "01-control-console.png",
  "02-online-plan.png",
  "03-execution-guard.png",
  "04-device-after.png",
  "05-offline-fallback.png",
  "06-architecture.png"
)
$GalleryAssets = New-Object System.Collections.Generic.List[object]
foreach ($AssetName in $ExpectedGalleryAssets) {
  $GalleryAssets.Add((Get-FileEvidence -Path (Join-Path $GalleryDir $AssetName) -MinimumBytes 1024))
}
$MissingGalleryAssets = @($GalleryAssets | Where-Object { -not $_.ok })
$GalleryOk = $MissingGalleryAssets.Count -eq 0
$GalleryDetail = "present={0}/{1}, missing={2}" -f ($ExpectedGalleryAssets.Count - $MissingGalleryAssets.Count), $ExpectedGalleryAssets.Count, $MissingGalleryAssets.Count
Add-Check "submission gallery upload assets" $GalleryOk $GalleryDetail $false @{
  path = $GalleryDir
  expectedCount = $ExpectedGalleryAssets.Count
  presentCount = $ExpectedGalleryAssets.Count - $MissingGalleryAssets.Count
  assets = [object[]]$GalleryAssets.ToArray()
}

$VideoUploadDir = Join-Path $ProofRootPath "video-upload"
$VideoUploadFiles = @()
if (Test-Path -LiteralPath $VideoUploadDir) {
  $VideoUploadFiles = @(Get-ChildItem -LiteralPath $VideoUploadDir -File -ErrorAction SilentlyContinue | Where-Object {
      $_.Extension -match "^\.(webm|mp4|mov)$" -and $_.Length -gt 0
    })
}
$VideoUploadOk = $VideoUploadFiles.Count -gt 0
$VideoDetail = "video_count={0}, names={1}" -f $VideoUploadFiles.Count, (@($VideoUploadFiles | ForEach-Object { $_.Name }) -join ",")
Add-Check "submission video upload asset" $VideoUploadOk $VideoDetail $false @{
  path = $VideoUploadDir
  videoCount = $VideoUploadFiles.Count
  videos = [object[]]@($VideoUploadFiles | ForEach-Object {
      [pscustomobject]@{
        name = $_.Name
        path = $_.FullName
        length = [int64]$_.Length
      }
    })
}

$ReadyForExternalRelease = $QwenOk -and $AlibabaOk -and $AlibabaManualReview.ok
Write-Host ""
Write-Host ("Summary: {0}" -f $(if ($ReadyForExternalRelease) { "external cloud proof ready" } else { "external cloud proof not ready" }))
Write-Host "Note   : local voice/media proof does not replace cloud usage image proof."

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result = @{
    checkedAt = (Get-Date).ToString("o")
    proofRoot = $ProofRootPath
    readyForExternalRelease = [bool]$ReadyForExternalRelease
    requiredMode = [bool]$Required
    failures = [string[]]$Failures.ToArray()
    checks = [object[]]$Checks.ToArray()
  }
  $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Proof inventory check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Proof inventory check complete."
exit 0
