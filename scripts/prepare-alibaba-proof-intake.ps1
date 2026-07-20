param(
  [string]$ProofRoot = ".\assets\demo",
  [string]$ResultJsonPath = "",
  [string]$ResultMarkdownPath = "",
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

function ConvertTo-MarkdownText {
  param([object]$Value)
  if ($null -eq $Value) {
    return ""
  }
  return ([string]$Value) -replace "(`r`n|`n|`r)", " "
}

$RepoRoot = Resolve-Path "$PSScriptRoot\.."
$ProofRootPath = Join-Path $RepoRoot $ProofRoot
$AlibabaDir = Join-Path $ProofRootPath "alibaba-proof"
$GuidePath = Join-Path $AlibabaDir "README-alibaba-proof-intake.local.md"
$ReviewTemplatePath = Join-Path $AlibabaDir "alibaba-proof-review.template.local.json"
$AcceptedExtensions = @(".png", ".jpg", ".jpeg", ".webp")
$MinimumBytes = 1024
$RequiredVisibleFields = @(
  "Qwen or DashScope model name",
  "non-zero calls, tokens, or usage curve",
  "date or time range matching the verification window",
  "Singapore or Alibaba Cloud International region cue"
)
$PrivacyFieldsToMask = @(
  "API keys or access tokens",
  "account ID, UID, real name, email, or phone",
  "billing, payment, invoice, or tax details"
)
$NextSteps = @(
  "Log in to Alibaba Cloud International or Model Studio and switch region to Singapore.",
  "Capture Usage Statistics, Model Usage, API Logs, or an equivalent non-zero Qwen/DashScope usage page.",
  "Mask private account, key, contact, and billing details before saving.",
  "Save the masked image into the generated alibaba-proof folder with a .png, .jpg, .jpeg, or .webp extension.",
  "Copy alibaba-proof-review.template.local.json to alibaba-proof-review.json and mark the required fields true only after manual content review.",
  "Rerun check-proof-inventory.ps1, strict proof readiness, and the release snapshot schema/freshness checks."
)

$ProofRootCreated = -not (Test-Path -LiteralPath $ProofRootPath)
if ($ProofRootCreated) {
  New-Item -ItemType Directory -Path $ProofRootPath -Force | Out-Null
}
$AlibabaDirCreated = -not (Test-Path -LiteralPath $AlibabaDir)
New-Item -ItemType Directory -Path $AlibabaDir -Force | Out-Null

$Candidates = @(Get-ChildItem -LiteralPath $AlibabaDir -File -ErrorAction SilentlyContinue | Where-Object {
    $AcceptedExtensions -contains $_.Extension.ToLowerInvariant()
  })
$IgnoredFiles = @(Get-ChildItem -LiteralPath $AlibabaDir -File -ErrorAction SilentlyContinue | Where-Object {
    $AcceptedExtensions -notcontains $_.Extension.ToLowerInvariant() -and $_.Name -ne (Split-Path -Leaf $GuidePath)
  })

$GuideLines = New-Object System.Collections.Generic.List[string]
$GuideLines.Add("# Alibaba Proof Intake")
$GuideLines.Add("")
$GuideLines.Add("This local file is generated under a gitignored proof directory. Do not commit screenshots, account data, or this intake note.")
$GuideLines.Add("")
$GuideLines.Add("## Drop Folder")
$DropPathLine = "- Path: {0}" -f $AlibabaDir
$AcceptedExtensionsLine = "- Accepted image extensions: {0}" -f ($AcceptedExtensions -join ", ")
$MinimumBytesLine = "- Minimum local image size: {0} bytes" -f $MinimumBytes
$GuideLines.Add($DropPathLine)
$GuideLines.Add($AcceptedExtensionsLine)
$GuideLines.Add($MinimumBytesLine)
$GuideLines.Add("")
$GuideLines.Add("## Screenshot Must Show")
foreach ($Field in $RequiredVisibleFields) {
  $FieldLine = "- {0}" -f $Field
  $GuideLines.Add($FieldLine)
}
$GuideLines.Add("")
$GuideLines.Add("## Mask Before Saving")
foreach ($Field in $PrivacyFieldsToMask) {
  $FieldLine = "- {0}" -f $Field
  $GuideLines.Add($FieldLine)
}
$GuideLines.Add("")
$GuideLines.Add("## Next Steps")
for ($Index = 0; $Index -lt $NextSteps.Count; $Index++) {
  $GuideLines.Add(("{0}. {1}" -f ($Index + 1), $NextSteps[$Index]))
}
$GuideLines.Add("")
$GuideLines.Add("## Manual Review Marker")
$GuideLines.Add("- Template: alibaba-proof-review.template.local.json")
$GuideLines.Add("- Required runtime file: alibaba-proof-review.json")
$GuideLines.Add("- The review file is not OCR. It is a local human assertion that the saved proof image actually shows the required fields and masks private details.")
$GuideLines.Add("")
$GuideLines.Add("Do not create placeholder images. If an image appears invalid, re-export the real masked screenshot and rerun the proof checks.")
$GuideLines | Set-Content -LiteralPath $GuidePath -Encoding UTF8

$ReviewTemplate = [ordered]@{
  reviewedAt = (Get-Date).ToString("o")
  imageName = "replace-with-saved-proof-image.png"
  qwenOrDashscopeVisible = $false
  nonZeroUsageVisible = $false
  dateOrRangeVisible = $false
  regionCueVisible = $false
  privacyMasked = $false
  notes = "Copy this file to alibaba-proof-review.json after saving the real masked screenshot, then set each field truthfully."
}
$ReviewTemplate | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ReviewTemplatePath -Encoding UTF8

$Result = [ordered]@{
  checkedAt = (Get-Date).ToString("o")
  proofRoot = $ProofRootPath
  alibabaProofDir = $AlibabaDir
  guidePath = $GuidePath
  reviewTemplatePath = $ReviewTemplatePath
  proofRootCreated = [bool]$ProofRootCreated
  alibabaProofDirCreated = [bool]$AlibabaDirCreated
  guideWritten = [bool](Test-Path -LiteralPath $GuidePath)
  reviewTemplateWritten = [bool](Test-Path -LiteralPath $ReviewTemplatePath)
  acceptedExtensions = [string[]]$AcceptedExtensions
  minimumBytes = [int]$MinimumBytes
  candidateCount = $Candidates.Count
  candidateImages = [object[]]@($Candidates | ForEach-Object {
      [pscustomobject]@{
        name = $_.Name
        length = [int64]$_.Length
      }
    })
  ignoredFileCount = $IgnoredFiles.Count
  ignoredFiles = [string[]]@($IgnoredFiles | ForEach-Object { $_.Name })
  requiredVisibleFields = [string[]]$RequiredVisibleFields
  privacyFieldsToMask = [string[]]$PrivacyFieldsToMask
  nextSteps = [string[]]$NextSteps
}

Write-Host "HomeCue Edge Alibaba proof intake"
Write-Host ("Proof dir : {0}" -f $AlibabaDir)
Write-Host ("Guide     : {0}" -f $GuidePath)
Write-Host ("Template  : {0}" -f $ReviewTemplatePath)
Write-Host ("Candidates: {0}" -f $Candidates.Count)
if ($IgnoredFiles.Count -gt 0) {
  Write-Host ("Ignored   : {0}" -f (@($IgnoredFiles | ForEach-Object { $_.Name }) -join ", "))
}
Write-Host "No placeholder images were created."

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result    : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($ResultMarkdownPath) {
  New-ParentDirectory -Path $ResultMarkdownPath
  $MarkdownLines = New-Object System.Collections.Generic.List[string]
  $MarkdownLines.Add("# Alibaba Proof Intake Result")
  $MarkdownLines.Add("")
  $CheckedAtLine = "- Checked at: {0}" -f $Result.checkedAt
  $ProofDirLine = "- Proof dir: {0}" -f $AlibabaDir
  $GuideLine = "- Guide: {0}" -f $GuidePath
  $TemplateLine = "- Review template: {0}" -f $ReviewTemplatePath
  $CandidateLine = "- Candidate images: {0}" -f $Candidates.Count
  $IgnoredLine = "- Ignored files: {0}" -f $IgnoredFiles.Count
  $MarkdownLines.Add($CheckedAtLine)
  $MarkdownLines.Add($ProofDirLine)
  $MarkdownLines.Add($GuideLine)
  $MarkdownLines.Add($TemplateLine)
  $MarkdownLines.Add($CandidateLine)
  $MarkdownLines.Add($IgnoredLine)
  $MarkdownLines.Add("")
  $MarkdownLines.Add("## Next Steps")
  for ($Index = 0; $Index -lt $NextSteps.Count; $Index++) {
    $MarkdownLines.Add(("{0}. {1}" -f ($Index + 1), (ConvertTo-MarkdownText $NextSteps[$Index])))
  }
  $MarkdownLines.Add("")
  $MarkdownLines.Add("No placeholder images were created.")
  $MarkdownLines | Set-Content -LiteralPath $ResultMarkdownPath -Encoding UTF8
  Write-Host ("Report    : {0}" -f (Resolve-Path -LiteralPath $ResultMarkdownPath).Path)
}

if ($Required -and -not (Test-Path -LiteralPath $GuidePath)) {
  Write-Host "Alibaba proof intake guide was not written." -ForegroundColor Red
  exit 1
}
if ($Required -and -not (Test-Path -LiteralPath $ReviewTemplatePath)) {
  Write-Host "Alibaba proof review template was not written." -ForegroundColor Red
  exit 1
}

Write-Host "Alibaba proof intake prepared."
exit 0
