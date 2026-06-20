param(
  [string]$DesktopEvidencePath = "",
  [string]$DesktopScreenshotDir = "",
  [string]$ChromeEvidencePath = "",
  [string]$ChromeScreenshotDir = "",
  [string]$PhoneEvidencePath = "",
  [string]$SummaryPath = "",
  [string]$ResultJsonPath = "",
  [switch]$RequireDesktop,
  [switch]$RequirePhone,
  [switch]$RequireChrome,
  [switch]$AllowSkipDesktop,
  [switch]$SelfTest,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$WebDir = Join-Path $Root "apps\web"
$SummaryPathProvided = -not [string]::IsNullOrWhiteSpace($SummaryPath)
if (-not $SummaryPathProvided) {
  $SummaryPath = Join-Path $Root "assets\demo\full-loop-report.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($SummaryPath)) {
  $SummaryPath = Join-Path $Root $SummaryPath
}
if ($ResultJsonPath -and -not [System.IO.Path]::IsPathRooted($ResultJsonPath)) {
  $ResultJsonPath = Join-Path $Root $ResultJsonPath
}

function Convert-ToRepoRelativeDir {
  param([string]$Path)

  $FullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
  $RootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $RootPrefix = $RootPath + [System.IO.Path]::DirectorySeparatorChar

  if (-not $FullPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Screenshot directory must be inside the repository root: $Path"
  }

  return ($FullPath.Substring($RootPrefix.Length).Replace("\", "/").TrimEnd("/") + "/")
}

function Assert-File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label not found: $Path"
  }
}

function Assert-Directory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Label not found: $Path"
  }
}

function Invoke-NpmChecked {
  param([string[]]$Arguments)

  npm @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "npm command failed: npm $($Arguments -join ' ')"
  }
}

function Resolve-RepoPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return Join-Path $Root $Path
}

function Read-JsonFile {
  param([string]$Path)

  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )

  $ResultDir = Split-Path -Parent $Path
  if ($ResultDir) {
    New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null
  }

  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $Utf8NoBom)
}

function Convert-ToRepoRelativePath {
  param([string]$Path)

  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $RootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $RootPrefix = $RootPath + [System.IO.Path]::DirectorySeparatorChar

  if (-not $FullPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path must be inside the repository root: $Path"
  }

  return $FullPath.Substring($RootPrefix.Length).Replace("\", "/")
}

function Convert-ToEvidencePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }
  if ($Path.StartsWith("__")) {
    return $Path
  }

  return Convert-ToRepoRelativePath $Path
}

function Get-FileSha256Prefix {
  param([string]$Path)

  $Bytes = [System.IO.File]::ReadAllBytes($Path)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()).Substring(0, 12)
  }
  finally {
    $Hasher.Dispose()
  }
}

function New-SummaryClone {
  param($Value)

  return (($Value | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
}

function Protect-DefaultSummaryFromMutableDevEnv {
  param($OriginalSummary)

  if ($SummaryPathProvided) {
    return $null
  }
  if ($OriginalSummary.environment.preflight.run -ne $true) {
    return $null
  }

  $DevEnvEntry = @($OriginalSummary.evidence.files | Where-Object {
      $_.present -eq $true -and $_.label -eq "Dev Environment JSON"
    } | Select-Object -First 1)
  if ($DevEnvEntry.Count -eq 0) {
    return $null
  }

  $SnapshotDir = Join-Path $Root "assets\tmp\browser-evidence-default-summary"
  $SnapshotDevEnvPath = Join-Path $SnapshotDir "dev-env-check.json"
  $SnapshotSummaryPath = Join-Path $SnapshotDir "full-loop-report.json"
  New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null

  $Preflight = $OriginalSummary.environment.preflight
  $SnapshotDevEnv = [pscustomobject]@{
    generatedAt = $Preflight.generatedAt
    success = $Preflight.success
    required = $Preflight.required
    requirePhone = $Preflight.requirePhone
    checks = $Preflight.checks
  }
  Write-JsonFile -Path $SnapshotDevEnvPath -Value $SnapshotDevEnv

  $SnapshotSummary = New-SummaryClone $OriginalSummary
  $SnapshotEntry = @($SnapshotSummary.evidence.files | Where-Object {
      $_.present -eq $true -and $_.label -eq "Dev Environment JSON"
    } | Select-Object -First 1)
  if ($SnapshotEntry.Count -ne 0) {
    $SnapshotEntry[0].file = Convert-ToRepoRelativePath $SnapshotDevEnvPath
    $SnapshotEntry[0].bytes = (Get-Item -LiteralPath $SnapshotDevEnvPath).Length
    $SnapshotEntry[0].sha256 = Get-FileSha256Prefix $SnapshotDevEnvPath
  }
  Write-JsonFile -Path $SnapshotSummaryPath -Value $SnapshotSummary

  return [pscustomobject]@{
    summaryPath = $SnapshotSummaryPath
    summary = $SnapshotSummary
  }
}

function Get-ManifestFile {
  param([string]$Label)

  $Entry = @($Summary.evidence.files | Where-Object { $_.present -eq $true -and $_.label -eq $Label } | Select-Object -First 1)
  if ($Entry.Count -eq 0) {
    return ""
  }

  return Resolve-RepoPath ([string]$Entry[0].file)
}

function Get-ScreenshotDirFromLoop {
  param(
    $Loop,
    [string]$DirectoryName,
    [string]$EvidencePath
  )

  $Entry = @($Summary.evidence.files | Where-Object {
      $_.present -eq $true -and
      $_.label -eq "Screenshot" -and
      $Loop.screenshotEvidence.files.path -contains $_.file
    } | Select-Object -First 1)

  if ($Entry.Count -eq 0 -and $DirectoryName) {
    $Entry = @($Summary.evidence.files | Where-Object {
        $_.present -eq $true -and
        $_.label -eq "Screenshot" -and
        ([string]$_.file).Replace("\", "/").Contains("/$DirectoryName/")
      } | Select-Object -First 1)
  }

  if ($Entry.Count -eq 0) {
    return Get-ScreenshotDirFromRawEvidence -EvidencePath $EvidencePath
  }

  return Split-Path -Parent (Resolve-RepoPath ([string]$Entry[0].file))
}

function Get-ScreenshotDirFromRawEvidence {
  param([string]$EvidencePath)

  if (-not $EvidencePath -or -not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    return ""
  }

  try {
    $RawEvidence = Read-JsonFile $EvidencePath
  }
  catch {
    return ""
  }

  $Screenshot = @($RawEvidence.screenshots | Select-Object -First 1)
  if ($Screenshot.Count -eq 0) {
    $Screenshot = @($RawEvidence.checks.screenshotEvidence.files.path | Select-Object -First 1)
  }
  if ($Screenshot.Count -eq 0 -or -not [string]$Screenshot[0]) {
    return ""
  }

  return Split-Path -Parent (Resolve-RepoPath ([string]$Screenshot[0]))
}

Assert-File -Path $SummaryPath -Label "Full-loop summary evidence"
$Summary = Read-JsonFile $SummaryPath
$DefaultSummarySnapshot = Protect-DefaultSummaryFromMutableDevEnv $Summary
if ($DefaultSummarySnapshot) {
  $SummaryPath = $DefaultSummarySnapshot.summaryPath
  $Summary = $DefaultSummarySnapshot.summary
}

if ($Summary.loops.phone.run -eq $true) {
  $RequirePhone = $true
}
if ($Summary.loops.windowsChrome.run -eq $true) {
  $RequireChrome = $true
}
if ($Summary.loops.desktop.run -ne $true) {
  $AllowSkipDesktop = $true
}
if ($RequireDesktop) {
  $AllowSkipDesktop = $false
}

if ($RequirePhone -and $Summary.loops.phone.run -ne $true) {
  throw "Phone evidence was required, but loops.phone.run is not true in the summary: $SummaryPath"
}
if ($RequireChrome -and $Summary.loops.windowsChrome.run -ne $true) {
  throw "Windows Chrome evidence was required, but loops.windowsChrome.run is not true in the summary: $SummaryPath"
}
if ((-not $AllowSkipDesktop) -and $Summary.loops.desktop.run -ne $true) {
  throw "Desktop evidence was required, but loops.desktop.run is not true in the summary: $SummaryPath"
}

if ($AllowSkipDesktop) {
  $DesktopEvidencePath = "__desktop_not_run__.json"
  $DesktopScreenshotDir = "__desktop_screens_not_run__"
}
elseif (-not $DesktopEvidencePath) {
  $DesktopEvidencePath = Get-ManifestFile "Desktop JSON"
}
if ((-not $AllowSkipDesktop) -and -not $DesktopEvidencePath) {
  $DesktopEvidencePath = Join-Path $Root "assets\demo\desktop-loop.json"
}
if ((-not $AllowSkipDesktop) -and -not $DesktopScreenshotDir) {
  $DesktopScreenshotDir = Get-ScreenshotDirFromLoop $Summary.loops.desktop "playwright-chromium-screens" $DesktopEvidencePath
}
if ((-not $AllowSkipDesktop) -and -not $DesktopScreenshotDir) {
  $DesktopScreenshotDir = Join-Path $Root "assets\demo\playwright-chromium-screens"
}
if (-not $RequireChrome) {
  $ChromeEvidencePath = "__chrome_not_run__.json"
  $ChromeScreenshotDir = "__chrome_screens_not_run__"
}
elseif (-not $ChromeEvidencePath) {
  $ChromeEvidencePath = Get-ManifestFile "Windows Chrome JSON"
}
if ($RequireChrome -and -not $ChromeEvidencePath) {
  $ChromeEvidencePath = Join-Path $Root "assets\demo\chrome-loop.json"
}
if ($RequireChrome -and -not $ChromeScreenshotDir) {
  $ChromeScreenshotDir = Get-ScreenshotDirFromLoop $Summary.loops.windowsChrome "windows-chrome-screens" $ChromeEvidencePath
}
if ($RequireChrome -and -not $ChromeScreenshotDir) {
  $ChromeScreenshotDir = Join-Path $Root "assets\demo\windows-chrome-screens"
}
if (-not $RequirePhone) {
  $PhoneEvidencePath = "__phone_not_run__.json"
}
elseif (-not $PhoneEvidencePath) {
  $PhoneEvidencePath = Get-ManifestFile "Phone JSON"
}
if ($RequirePhone -and -not $PhoneEvidencePath) {
  $PhoneEvidencePath = Join-Path $Root "assets\demo\phone-loop.json"
}

function New-EvidenceCheckPlan {
  return [pscustomobject]@{
    summaryPath = Convert-ToEvidencePath $SummaryPath
    resultJsonPath = Convert-ToEvidencePath $ResultJsonPath
    inferredFromSummary = [pscustomobject]@{
      desktop = [bool]($Summary.loops.desktop.run -eq $true)
      phone = [bool]($Summary.loops.phone.run -eq $true)
      windowsChrome = [bool]($Summary.loops.windowsChrome.run -eq $true)
    }
    requiredEvidence = [pscustomobject]@{
      desktop = -not [bool]$AllowSkipDesktop
      phone = [bool]$RequirePhone
      windowsChrome = [bool]$RequireChrome
    }
    selfTest = [pscustomobject]@{
      requested = [bool]$SelfTest
      phoneEvidence = [bool]($SelfTest -and $RequirePhone)
      desktopEvidence = [bool]($SelfTest -and $RequireChrome -and (-not $AllowSkipDesktop))
      summary = [bool]($SelfTest -and $RequireChrome -and (-not $AllowSkipDesktop))
      report = [bool]($SelfTest -and $RequirePhone -and $RequireChrome -and (-not $AllowSkipDesktop))
    }
    paths = [pscustomobject]@{
      desktopEvidence = Convert-ToEvidencePath $DesktopEvidencePath
      desktopScreenshotDir = Convert-ToEvidencePath $DesktopScreenshotDir
      phoneEvidence = Convert-ToEvidencePath $PhoneEvidencePath
      windowsChromeEvidence = Convert-ToEvidencePath $ChromeEvidencePath
      windowsChromeScreenshotDir = Convert-ToEvidencePath $ChromeScreenshotDir
    }
  }
}

function New-EvidenceCheckResult {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][bool]$Success,
    $Summary = $null
  )

  $Checks = @()
  if ($Plan.requiredEvidence.desktop) {
    $Checks += [pscustomobject]@{
      name = "desktop raw evidence"
      command = "npm run desktop:evidence:check"
      required = $true
      path = $Plan.paths.desktopEvidence
      screenshotDir = $Plan.paths.desktopScreenshotDir
    }
  }
  if ($Plan.requiredEvidence.windowsChrome) {
    $Checks += [pscustomobject]@{
      name = "Windows Chrome raw evidence"
      command = "npm run desktop:evidence:check -- --require-installed-chrome"
      required = $true
      path = $Plan.paths.windowsChromeEvidence
      screenshotDir = $Plan.paths.windowsChromeScreenshotDir
    }
  }
  if ($Plan.requiredEvidence.phone) {
    $Checks += [pscustomobject]@{
      name = "Android Chrome phone evidence"
      command = "npm run phone:evidence:check"
      required = $true
      path = $Plan.paths.phoneEvidence
    }
  }
  $Checks += [pscustomobject]@{
    name = "full-loop summary evidence"
    command = "npm run summary:check"
    required = $true
    path = $Plan.summaryPath
  }
  if ($Plan.selfTest.phoneEvidence) {
    $Checks += [pscustomobject]@{
      name = "phone evidence validator self-test"
      command = "npm run phone:evidence:selftest"
      required = $true
    }
  }
  if ($Plan.selfTest.desktopEvidence) {
    $Checks += [pscustomobject]@{
      name = "desktop evidence validator self-test"
      command = "npm run desktop:evidence:selftest"
      required = $true
    }
  }
  if ($Plan.selfTest.summary) {
    $Checks += [pscustomobject]@{
      name = "summary validator self-test"
      command = "npm run summary:selftest -- $($Plan.summaryPath)"
      required = $true
    }
  }
  if ($Plan.selfTest.report) {
    $Checks += [pscustomobject]@{
      name = "full-loop reporter self-test"
      command = "npm run report:selftest"
      required = $true
    }
  }

  return [pscustomobject]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    success = $Success
    mode = $Mode
    plan = $Plan
    checks = $Checks
    proofSummary = if ($Mode -eq "validate" -and $Summary) {
      New-EvidenceProofSummary -Plan $Plan -Summary $Summary
    } else {
      $null
    }
  }
}

function New-EvidenceProofSummary {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Summary
  )

  return [pscustomobject]@{
    summaryRunId = $Summary.runId
    appUrl = $Summary.appUrl
    apiBase = $Summary.apiBase
    requiredEvidence = $Plan.requiredEvidence
    browserParity = [pscustomobject]@{
      checked = [bool]($Summary.browserParity.checked -eq $true)
      success = [bool]($Summary.browserParity.success -eq $true)
      errorCount = @($Summary.browserParity.errors).Count
    }
    webReadiness = New-WebReadinessProofSummary -WebReadiness $Summary.environment.webReadiness
    loops = [pscustomobject]@{
      desktop = New-LoopProofSummary -Loop $Summary.loops.desktop
      windowsChrome = New-LoopProofSummary -Loop $Summary.loops.windowsChrome
      phone = [pscustomobject]@{
        run = [bool]($Summary.loops.phone.run -eq $true)
        success = $Summary.loops.phone.success
      }
    }
    evidence = [pscustomobject]@{
      summaryPath = $Plan.summaryPath
      desktopEvidencePath = $Plan.paths.desktopEvidence
      windowsChromeEvidencePath = $Plan.paths.windowsChromeEvidence
      phoneEvidencePath = $Plan.paths.phoneEvidence
      devEnvEvidencePath = Convert-ToEvidencePath (Get-ManifestFile "Dev Environment JSON")
      webReadinessEvidencePath = Convert-ToEvidencePath (Get-ManifestFile "Web Readiness JSON")
      desktopScreenshotDir = $Plan.paths.desktopScreenshotDir
      windowsChromeScreenshotDir = $Plan.paths.windowsChromeScreenshotDir
    }
  }
}

function New-WebReadinessProofSummary {
  param($WebReadiness)

  return [pscustomobject]@{
    run = [bool]($WebReadiness.run -eq $true)
    success = [bool]($WebReadiness.success -eq $true)
    strategy = $WebReadiness.strategy
    httpReadyAfter = [bool]($WebReadiness.httpReadyAfter -eq $true)
    duplicateStartAvoided = $WebReadiness.duplicateStartAvoided
  }
}

function New-LoopProofSummary {
  param($Loop)

  return [pscustomobject]@{
    run = [bool]($Loop.run -eq $true)
    success = $Loop.success
    title = $Loop.title
    runButton = $Loop.localizedUi.runButton
    textRequiredPhrases = $Loop.textIntegrity.requiredPhraseCount
    textMissingPhrases = $Loop.textIntegrity.missingPhraseCount
    textMojibake = $Loop.textIntegrity.mojibakeCount
    firstViewportMinVisibleRatio = $Loop.firstViewportVisibility.minVisibleRatio
    runtimeIssueCount = $Loop.runtimeHealth.issueCount
    screenshotCount = $Loop.screenshotEvidence.count
    uniqueScreenshotDigestCount = $Loop.screenshotEvidence.uniqueDigestCount
    externalExecutionSource = $Loop.externalExecutionSync.latestSource
    acceptedActionCount = $Loop.externalExecutionSync.acceptedActionCount
  }
}

$Plan = New-EvidenceCheckPlan

if ($DryRun) {
  if ($ResultJsonPath) {
    Write-JsonFile -Path $ResultJsonPath -Value (New-EvidenceCheckResult -Plan $Plan -Mode "dry-run" -Success $true)
  }
  $Plan | ConvertTo-Json -Depth 8
  exit 0
}

if (-not $AllowSkipDesktop) {
  Assert-File -Path $DesktopEvidencePath -Label "Desktop browser evidence"
  Assert-Directory -Path $DesktopScreenshotDir -Label "Desktop screenshot directory"
}

if ($RequireChrome) {
  Assert-File -Path $ChromeEvidencePath -Label "Windows Chrome evidence"
  Assert-Directory -Path $ChromeScreenshotDir -Label "Windows Chrome screenshot directory"
}

if ($RequirePhone) {
  Assert-File -Path $PhoneEvidencePath -Label "Phone evidence"
}

Push-Location $WebDir
try {
  if (-not $AllowSkipDesktop) {
    Invoke-NpmChecked @(
      "run",
      "desktop:evidence:check",
      "--",
      $DesktopEvidencePath,
      "--browser-name",
      "playwright-chromium",
      "--executable-path",
      "bundled",
      "--screenshot-dir",
      (Convert-ToRepoRelativeDir -Path $DesktopScreenshotDir)
    )
  }

  if ($RequireChrome) {
    Invoke-NpmChecked @(
      "run",
      "desktop:evidence:check",
      "--",
      $ChromeEvidencePath,
      "--browser-name",
      "windows-chrome",
      "--executable-path",
      "custom",
      "--screenshot-dir",
      (Convert-ToRepoRelativeDir -Path $ChromeScreenshotDir),
      "--require-installed-chrome"
    )
  }

  if ($RequirePhone) {
    Invoke-NpmChecked @(
      "run",
      "phone:evidence:check",
      "--",
      $PhoneEvidencePath
    )
  }

  $SummaryArgs = @(
    "run",
    "summary:check",
    "--",
    $SummaryPath
  )
  if ($AllowSkipDesktop) {
    $SummaryArgs += "--allow-skip-desktop"
  }
  if ($RequirePhone) {
    $SummaryArgs += "--require-phone"
  }
  if ($RequireChrome) {
    $SummaryArgs += "--require-chrome"
  }
  Invoke-NpmChecked $SummaryArgs

  if ($SelfTest) {
    if ($RequirePhone) {
      Invoke-NpmChecked @("run", "phone:evidence:selftest")
    }

    if ($RequireChrome -and (-not $AllowSkipDesktop)) {
      Invoke-NpmChecked @("run", "desktop:evidence:selftest")
      Invoke-NpmChecked @("run", "summary:selftest", "--", $SummaryPath)
    }

    if ($RequirePhone -and $RequireChrome -and (-not $AllowSkipDesktop)) {
      Invoke-NpmChecked @("run", "report:selftest")
    }
  }
}
finally {
  Pop-Location
}

if ($ResultJsonPath) {
  Write-JsonFile -Path $ResultJsonPath -Value (New-EvidenceCheckResult -Plan $Plan -Mode "validate" -Success $true -Summary $Summary)
  Push-Location $WebDir
  try {
    Invoke-NpmChecked @("run", "browser:evidence-result:check", "--", $ResultJsonPath)
  }
  finally {
    Pop-Location
  }
  Write-Host ("Browser evidence check JSON: {0}" -f $ResultJsonPath)
}

Write-Host "Browser evidence check passed."
