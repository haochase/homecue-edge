param(
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

function Get-CommitBucket {
  param([string]$Path)

  if ($Path -match "^firmware/esp32-audio/") {
    return "esp32-sr-recovery"
  }
  if ($Path -match "^scripts/test-voice-chat(-ws)?(-stale-result)?\.ps1$" -or $Path -match "^apps/api/app/voice_chat(_ws)?\.py$") {
    return "voice-chat-runtime"
  }
  if ($Path -match "^scripts/test-esp32-voice-chat(-session|-ws)?-audio\.ps1$") {
    return "voice-chat-runtime"
  }
  if ($Path -match "^scripts/(check-proof-readiness|check-readiness-schema|check-readiness-regression|check-working-tree-intent|check-proof-inventory|prepare-alibaba-proof-intake|check-release-gate-snapshot|check-release-gate-snapshot-schema|check-release-gate-snapshot-freshness|check-voice-system-readiness)\.ps1$") {
    return "proof-readiness"
  }
  if ($Path -match "^scripts/(check-esp32|test-esp32|flash-esp32|read-esp32|check-firmware|sample-esp32|README\.md)") {
    return "esp32-sr-recovery"
  }
  if ($Path -match "^scripts/new-esp32-sr-model-pack\.ps1$") {
    return "esp32-sr-recovery"
  }
  if ($Path -match "^scripts/resume-esp32-speaker-audible-test\.ps1$") {
    return "esp32-sr-recovery"
  }
  if ($Path -match "^scripts/(check-companion-available-hardware|collect-speaker-physical-evidence|prepare-waveshare-factory-ab|record-speaker-physical-check|test-waveshare-speaker-ab)\.ps1$") {
    return "esp32-sr-recovery"
  }
  if ($Path -match "^scripts/deploy-api-ubuntu\.ps1$") {
    return "deployment-tooling"
  }
  if ($Path -match "^scripts/(start-software-demo|test-software-demo-profile)\.ps1$") {
    return "app-code"
  }
  if ($Path -match "^scripts/check-local\.ps1$") {
    return "repository-safety"
  }
  if ($Path -match "^(AGENTS\.md|CONTRIBUTING\.md|\.gitignore|scripts/scan-secrets\.ps1|scripts/hooks/)") {
    return "repository-safety"
  }
  if ($Path -match "^apps/") {
    return "app-code"
  }
  if ($Path -match "^(README\.md|LICENSE|\.github/|docs/)") {
    return "public-release-docs"
  }
  if ($Path -match "^assets/") {
    return "local-proof-evidence"
  }

  return "uncategorized"
}

function Get-IntentNote {
  param(
    [string]$Path,
    [string]$Bucket
  )

  if ($Bucket -eq "esp32-sr-recovery") {
    if ($Path -match "\.example$") {
      return "Public example config for ESP32 setup; keep placeholder values only and rely on scan-secrets."
    }
    return "ESP32 voice, recovery, or serial proof tooling; keep separate from API/web business changes."
  }
  if ($Bucket -eq "proof-readiness") {
    return "Release proof status aggregation; verify it stays read-only and does not replace real proof."
  }
  if ($Bucket -eq "voice-chat-runtime") {
    return "Voice chat API/runtime proof tooling; verify ASR/model/TTS remain optional and tested."
  }
  if ($Bucket -eq "repository-safety") {
    return "Public-repo safety framework; run scan-secrets before staging."
  }
  if ($Bucket -eq "deployment-tooling") {
    return "Public deployment helper; verify defaults stay generic and secrets stay in local env files."
  }
  if ($Bucket -eq "app-code") {
    return "Application behavior change; run check-local and review user-facing behavior."
  }
  if ($Bucket -eq "public-release-docs") {
    return "Public release documentation; check that no private workspace context leaked."
  }
  if ($Bucket -eq "local-proof-evidence") {
    return "Proof assets are usually gitignored local evidence; do not stage binaries unless explicitly intended."
  }

  return "Needs manual classification before commit."
}

function Test-RiskyPathName {
  param([string]$Path)

  if ($Path -match "^scripts/resume-esp32-") {
    return $false
  }
  if ($Path -match "^firmware/esp32-audio/secrets\.h\.example$") {
    return $false
  }
  if ($Path -match "\.example$") {
    return $false
  }

  $RiskyNonTechnicalTerms = @(
    ('inter' + 'view'),
    ('res' + 'ume'),
    ('pri' + 'vate'),
    ('per' + 'sonal')
  )
  $RiskyNonTechnicalRegex = "(?i)({0})" -f (($RiskyNonTechnicalTerms | ForEach-Object { [regex]::Escape($_) }) -join "|")

  if ($Path -match $RiskyNonTechnicalRegex) {
    return $true
  }
  if ($Path -match "(?i)(secret|token|key)" -and $Path -notmatch "^scripts/scan-secrets\.ps1$") {
    return $true
  }

  return $false
}

$RepoRoot = Resolve-Path "$PSScriptRoot\.."
Push-Location $RepoRoot
try {
  $BranchLine = (& git status --short --branch 2>$null)
  $StatusLines = @(& git status --porcelain=v1 --untracked-files=all 2>$null)
} finally {
  Pop-Location
}

$Items = New-Object System.Collections.Generic.List[object]
$Warnings = New-Object System.Collections.Generic.List[string]
$BranchText = if ($BranchLine) { [string]$BranchLine[0] } else { "" }
$Ahead = 0
$Behind = 0
if ($BranchText -match "ahead\s+(\d+)") {
  $Ahead = [int]$Matches[1]
}
if ($BranchText -match "behind\s+(\d+)") {
  $Behind = [int]$Matches[1]
}

foreach ($Line in $StatusLines) {
  if (-not $Line -or $Line.Length -lt 4) {
    continue
  }

  $Status = $Line.Substring(0, 2)
  $Path = $Line.Substring(3).Trim()
  if ($Path.StartsWith('"') -and $Path.EndsWith('"')) {
    $Path = $Path.Substring(1, $Path.Length - 2)
  }

  $Bucket = Get-CommitBucket -Path $Path
  $RiskyPath = Test-RiskyPathName -Path $Path
  $NeedsManualReview = $RiskyPath -or $Bucket -eq "uncategorized" -or $Bucket -eq "local-proof-evidence"
  if ($NeedsManualReview) {
    $Warnings.Add(("{0} ({1})" -f $Path, $Bucket))
  }

  $Items.Add([pscustomobject]@{
      status = $Status
      path = $Path
      bucket = $Bucket
      riskyPathName = [bool]$RiskyPath
      needsManualReview = [bool]$NeedsManualReview
      note = Get-IntentNote -Path $Path -Bucket $Bucket
    })
}

$Buckets = $Items | Group-Object bucket | Sort-Object Name
$BucketCounts = [ordered]@{}
$BucketReviewCounts = [ordered]@{}
foreach ($Bucket in $Buckets) {
  $BucketCounts[$Bucket.Name] = [int]$Bucket.Count
  $BucketReviewCounts[$Bucket.Name] = [int](($Bucket.Group | Where-Object { $_.needsManualReview }).Count)
}

Write-Host "HomeCue Edge working tree intent check"
Write-Host ("Repo   : {0}" -f $RepoRoot.Path)
Write-Host ("Branch : {0}" -f $BranchText)
Write-Host ("Ahead  : {0}" -f $Ahead)
Write-Host ("Behind : {0}" -f $Behind)
Write-Host ("Dirty  : {0}" -f $Items.Count)
Write-Host ""

if ($Items.Count -eq 0) {
  Write-Host "Working tree is clean."
} else {
  Write-Host "Suggested commit buckets:"
  foreach ($Bucket in $Buckets) {
    Write-Host ("- {0}: {1}" -f $Bucket.Name, $Bucket.Count)
    foreach ($Item in ($Items | Where-Object { $_.bucket -eq $Bucket.Name } | Sort-Object path)) {
      $ReviewSuffix = if ($Item.needsManualReview) { " [review]" } else { "" }
      Write-Host ("  {0} {1}{2}" -f $Item.status, $Item.path, $ReviewSuffix)
    }
  }
}

if ($Warnings.Count -gt 0) {
  Write-Host ""
  Write-Host "Manual review required:" -ForegroundColor Yellow
  foreach ($Warning in $Warnings) {
    Write-Host ("- {0}" -f $Warning) -ForegroundColor Yellow
  }
}

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result = @{
    checkedAt = (Get-Date).ToString("o")
    branch = $BranchText
    ahead = $Ahead
    behind = $Behind
    dirtyCount = $Items.Count
    warningCount = $Warnings.Count
    bucketCounts = $BucketCounts
    bucketReviewCounts = $BucketReviewCounts
    requiredMode = [bool]$Required
    warnings = [string[]]$Warnings.ToArray()
    items = [object[]]$Items.ToArray()
  }
  $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ""
  Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($Required -and $Warnings.Count -gt 0) {
  Write-Host "Working tree intent check failed manual-review item(s)." -ForegroundColor Red
  exit 1
}

Write-Host "Working tree intent check complete."
exit 0
