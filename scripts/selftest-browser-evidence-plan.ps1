$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$OutputDir = Join-Path $Root "assets\tmp\browser-evidence-plan-selftest"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Write-Summary {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [bool]$Desktop,
    [bool]$Phone,
    [bool]$Chrome,
    [switch]$WithManifest,
    [switch]$JsonOnlyManifest
  )

  $Path = Join-Path $OutputDir "$Name.json"
  $EvidenceFiles = @()
  if ($WithManifest -or $JsonOnlyManifest) {
    if ($Desktop) {
      $EvidenceFiles += [pscustomobject]@{ label = "Desktop JSON"; file = "assets/tmp/browser-evidence-plan-selftest/$Name/desktop-loop.json"; present = $true }
      if ($WithManifest) {
        $EvidenceFiles += [pscustomobject]@{ label = "Screenshot"; file = "assets/tmp/browser-evidence-plan-selftest/$Name/playwright-chromium-screens/01-control-console.png"; present = $true }
      }
    }
    if ($Phone) {
      $EvidenceFiles += [pscustomobject]@{ label = "Phone JSON"; file = "assets/tmp/browser-evidence-plan-selftest/$Name/phone-loop.json"; present = $true }
    }
    if ($Chrome) {
      $EvidenceFiles += [pscustomobject]@{ label = "Windows Chrome JSON"; file = "assets/tmp/browser-evidence-plan-selftest/$Name/chrome-loop.json"; present = $true }
      if ($WithManifest) {
        $EvidenceFiles += [pscustomobject]@{ label = "Screenshot"; file = "assets/tmp/browser-evidence-plan-selftest/$Name/windows-chrome-screens/01-control-console.png"; present = $true }
      }
    }
  }

  $Summary = [pscustomobject]@{
    success = $true
    generatedAt = "2026-06-19T00:00:00.000Z"
    loops = [pscustomobject]@{
      desktop = [pscustomobject]@{
        run = $Desktop
      }
      phone = [pscustomobject]@{ run = $Phone }
      windowsChrome = [pscustomobject]@{
        run = $Chrome
      }
    }
    evidence = [pscustomobject]@{
      files = $EvidenceFiles
    }
  }
  $Summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8

  if ($JsonOnlyManifest) {
    $EvidenceDir = Join-Path $OutputDir $Name
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    if ($Desktop) {
      Write-RawBrowserEvidence `
        -Path (Join-Path $EvidenceDir "desktop-loop.json") `
        -ScreenshotPath "assets/tmp/browser-evidence-plan-selftest/$Name/raw-desktop-screens/01-control-console.png"
    }
    if ($Chrome) {
      Write-RawBrowserEvidence `
        -Path (Join-Path $EvidenceDir "chrome-loop.json") `
        -ScreenshotPath "assets/tmp/browser-evidence-plan-selftest/$Name/raw-chrome-screens/01-control-console.png"
    }
    if ($Phone) {
      [pscustomobject]@{ success = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDir "phone-loop.json") -Encoding UTF8
    }
  }

  return $Path
}

function Write-RawBrowserEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ScreenshotPath
  )

  $Evidence = [pscustomobject]@{
    success = $true
    screenshots = @($ScreenshotPath)
    checks = [pscustomobject]@{
      screenshotEvidence = [pscustomobject]@{
        files = @([pscustomobject]@{ path = $ScreenshotPath })
      }
    }
  }
  $Evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Plan {
  param([string[]]$Arguments)

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-browser-evidence.ps1" -DryRun @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "check-browser-evidence.ps1 -DryRun failed: $($Arguments -join ' ')"
  }

  return $Output | ConvertFrom-Json
}

function Read-PlanWithResultJson {
  param(
    [string[]]$Arguments,
    [string]$ResultJsonPath
  )

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-browser-evidence.ps1" -DryRun -ResultJsonPath $ResultJsonPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "check-browser-evidence.ps1 -DryRun -ResultJsonPath failed: $($Arguments -join ' ')"
  }

  $Plan = $Output | ConvertFrom-Json
  Push-Location (Join-Path $Root "apps\web")
  try {
    npm run browser:evidence-result:check -- $ResultJsonPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "browser:evidence-result:check failed for dry-run result: $ResultJsonPath"
    }
  }
  finally {
    Pop-Location
  }
  $Result = Get-Content -Raw -LiteralPath $ResultJsonPath | ConvertFrom-Json
  return [pscustomobject]@{
    plan = $Plan
    result = $Result
  }
}

function Read-FailingPlan {
  param(
    [string[]]$Arguments,
    [string]$ExpectedError
  )

  $Process = New-Object System.Diagnostics.Process
  $ProcessArguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "$PSScriptRoot\check-browser-evidence.ps1",
    "-DryRun"
  ) + $Arguments
  $Process.StartInfo.FileName = "powershell"
  $Process.StartInfo.Arguments = Join-ProcessArguments $ProcessArguments
  $Process.StartInfo.UseShellExecute = $false
  $Process.StartInfo.RedirectStandardOutput = $true
  $Process.StartInfo.RedirectStandardError = $true
  [void]$Process.Start()
  $Output = $Process.StandardOutput.ReadToEnd() + $Process.StandardError.ReadToEnd()
  $Process.WaitForExit()

  if ($Process.ExitCode -eq 0) {
    throw "Expected check-browser-evidence.ps1 -DryRun to fail: $($Arguments -join ' ')"
  }

  if (-not $Output.Contains($ExpectedError)) {
    throw "Expected failure to contain '$ExpectedError', got: $Output"
  }
}

function Read-FailingCheck {
  param(
    [string[]]$Arguments,
    [string[]]$ExpectedSubstrings
  )

  $Process = New-Object System.Diagnostics.Process
  $ProcessArguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "$PSScriptRoot\check-browser-evidence.ps1"
  ) + $Arguments
  $Process.StartInfo.FileName = "powershell"
  $Process.StartInfo.Arguments = Join-ProcessArguments $ProcessArguments
  $Process.StartInfo.UseShellExecute = $false
  $Process.StartInfo.RedirectStandardOutput = $true
  $Process.StartInfo.RedirectStandardError = $true
  [void]$Process.Start()
  $Output = $Process.StandardOutput.ReadToEnd() + $Process.StandardError.ReadToEnd()
  $Process.WaitForExit()

  if ($Process.ExitCode -eq 0) {
    throw "Expected check-browser-evidence.ps1 to fail: $($Arguments -join ' ')"
  }

  foreach ($ExpectedSubstring in $ExpectedSubstrings) {
    if (-not $Output.Contains($ExpectedSubstring)) {
      throw "Expected failure to contain '$ExpectedSubstring', got: $Output"
    }
  }
}

function Join-ProcessArguments {
  param([string[]]$Arguments)

  return (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " ")
}

function ConvertTo-ProcessArgument {
  param([string]$Value)

  if ($null -eq $Value -or $Value -eq "") {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }

  return '"' + ($Value -replace '"', '\"') + '"'
}

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]$Actual,
    [Parameter(Mandatory = $true)]$Expected,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($Actual -ne $Expected) {
    throw "$Label mismatch: expected $Expected, got $Actual"
  }
}

function Assert-Null {
  param(
    $Actual,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($null -ne $Actual) {
    throw "$Label mismatch: expected null, got $Actual"
  }
}

function Assert-PathEndsWith {
  param(
    [Parameter(Mandatory = $true)][string]$Actual,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $NormalizedActual = $Actual.Replace("\", "/")
  $NormalizedExpected = $Expected.Replace("\", "/")
  if (-not $NormalizedActual.EndsWith($NormalizedExpected)) {
    throw "${Label}: expected '$Actual' to end with '$Expected'"
  }
}

function Assert-PortableEvidencePath {
  param(
    [Parameter(Mandatory = $true)][string]$Actual,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ([System.IO.Path]::IsPathRooted($Actual)) {
    throw "${Label} should be repo-relative: $Actual"
  }
  if ($Actual.Replace("\", "/").Contains($Root.ToString().Replace("\", "/"))) {
    throw "${Label} should not contain the repo root: $Actual"
  }
}

function Assert-ObjectKeys {
  param(
    [Parameter(Mandatory = $true)][object]$Value,
    [Parameter(Mandatory = $true)][string[]]$ExpectedKeys,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $ActualKeys = @($Value.PSObject.Properties.Name | Sort-Object)
  $ExpectedSorted = @($ExpectedKeys | Sort-Object)
  Assert-Equal ($ActualKeys -join ",") ($ExpectedSorted -join ",") $Label
}

function Assert-BrowserEvidencePlanManifest {
  param(
    [Parameter(Mandatory = $true)][object]$Plan,
    [Parameter(Mandatory = $true)][string]$Label
  )

  Assert-ObjectKeys $Plan @("summaryPath", "resultJsonPath", "inferredFromSummary", "requiredEvidence", "options", "selfTest", "paths") "$Label fields"
  Assert-ObjectKeys $Plan.inferredFromSummary @("desktop", "phone", "windowsChrome") "$Label inferredFromSummary fields"
  Assert-ObjectKeys $Plan.requiredEvidence @("desktop", "phone", "windowsChrome") "$Label requiredEvidence fields"
  Assert-ObjectKeys $Plan.options @("maxAgeMinutes") "$Label options fields"
  Assert-ObjectKeys $Plan.selfTest @("requested", "phoneEvidence", "desktopEvidence", "summary", "report") "$Label selfTest fields"
  Assert-ObjectKeys $Plan.paths @("desktopEvidence", "desktopScreenshotDir", "phoneEvidence", "windowsChromeEvidence", "windowsChromeScreenshotDir") "$Label paths fields"
}

function Assert-BrowserEvidenceChecksManifest {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][object]$Plan,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $Expected = @()
  if ($Plan.requiredEvidence.desktop) {
    $Expected += [pscustomobject]@{
      name = "desktop raw evidence"
      command = "npm run desktop:evidence:check"
      keys = @("name", "command", "required", "path", "screenshotDir")
    }
  }
  if ($Plan.requiredEvidence.windowsChrome) {
    $Expected += [pscustomobject]@{
      name = "Windows Chrome raw evidence"
      command = "npm run desktop:evidence:check -- --require-installed-chrome"
      keys = @("name", "command", "required", "path", "screenshotDir")
    }
  }
  if ($Plan.requiredEvidence.phone) {
    $Expected += [pscustomobject]@{
      name = "Android Chrome phone evidence"
      command = "npm run phone:evidence:check"
      keys = @("name", "command", "required", "path")
    }
  }
  $Expected += [pscustomobject]@{
    name = "full-loop summary evidence"
    command = "npm run summary:check"
    keys = @("name", "command", "required", "path")
  }
  if ($Plan.selfTest.phoneEvidence) {
    $Expected += [pscustomobject]@{
      name = "phone evidence validator self-test"
      command = "npm run phone:evidence:selftest"
      keys = @("name", "command", "required")
    }
  }
  if ($Plan.selfTest.desktopEvidence) {
    $Expected += [pscustomobject]@{
      name = "desktop evidence validator self-test"
      command = "npm run desktop:evidence:selftest"
      keys = @("name", "command", "required")
    }
  }
  if ($Plan.selfTest.summary) {
    $Expected += [pscustomobject]@{
      name = "summary validator self-test"
      command = "npm run summary:selftest -- $($Plan.summaryPath)"
      keys = @("name", "command", "required")
    }
  }
  if ($Plan.selfTest.report) {
    $Expected += [pscustomobject]@{
      name = "full-loop reporter self-test"
      command = "npm run report:selftest"
      keys = @("name", "command", "required")
    }
  }

  $Checks = @($Result.checks)
  Assert-Equal $Checks.Count $Expected.Count "$Label checks count"
  for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
    Assert-Equal $Checks[$Index].name $Expected[$Index].name "$Label check[$Index] name"
    Assert-Equal $Checks[$Index].command $Expected[$Index].command "$Label check[$Index] command"
    Assert-Equal $Checks[$Index].required $true "$Label check[$Index] required"
    Assert-ObjectKeys $Checks[$Index] $Expected[$Index].keys "$Label check[$Index] fields"
  }
}

$CompleteSummary = Write-Summary -Name "complete" -Desktop $true -Phone $true -Chrome $true -WithManifest
$DesktopOnlySummary = Write-Summary -Name "desktop-only" -Desktop $true -Phone $false -Chrome $false
$ChromeOnlySummary = Write-Summary -Name "chrome-only" -Desktop $false -Phone $false -Chrome $true
$JsonOnlySummary = Write-Summary -Name "json-only" -Desktop $true -Phone $false -Chrome $true -JsonOnlyManifest

$DefaultPlan = Read-Plan @()
Assert-BrowserEvidencePlanManifest $DefaultPlan "default plan"
Assert-PathEndsWith $DefaultPlan.summaryPath "assets/tmp/browser-evidence-default-summary/full-loop-report.json" "default summary path should use an isolated temp snapshot"
Assert-PortableEvidencePath $DefaultPlan.summaryPath "default summary path"
Assert-Null $DefaultPlan.options.maxAgeMinutes "default plan should not require fresh saved-result validation"
$DefaultSummary = Get-Content -Raw -LiteralPath (Join-Path $Root $DefaultPlan.summaryPath) | ConvertFrom-Json
$DefaultDevEnvEntry = @($DefaultSummary.evidence.files | Where-Object { $_.present -eq $true -and $_.label -eq "Dev Environment JSON" } | Select-Object -First 1)
if ($DefaultDevEnvEntry.Count -ne 0 -and -not ([string]$DefaultDevEnvEntry[0].file).EndsWith("assets/tmp/browser-evidence-default-summary/dev-env-check.json")) {
  throw "default summary should point Dev Environment JSON at the isolated temp snapshot: $($DefaultDevEnvEntry[0].file)"
}

$CompletePlan = Read-Plan @("-SummaryPath", $CompleteSummary, "-SelfTest")
Assert-BrowserEvidencePlanManifest $CompletePlan "complete plan"
Assert-Equal $CompletePlan.requiredEvidence.desktop $true "complete desktop required"
Assert-Equal $CompletePlan.requiredEvidence.phone $true "complete phone required"
Assert-Equal $CompletePlan.requiredEvidence.windowsChrome $true "complete Chrome required"
Assert-Equal $CompletePlan.selfTest.phoneEvidence $true "complete phone self-test"
Assert-Equal $CompletePlan.selfTest.desktopEvidence $true "complete desktop self-test"
Assert-Equal $CompletePlan.selfTest.summary $true "complete summary self-test"
Assert-Equal $CompletePlan.selfTest.report $true "complete report self-test"
Assert-PathEndsWith $CompletePlan.paths.desktopEvidence "assets/tmp/browser-evidence-plan-selftest/complete/desktop-loop.json" "complete desktop path was not inferred from manifest"
Assert-PathEndsWith $CompletePlan.paths.desktopScreenshotDir "assets/tmp/browser-evidence-plan-selftest/complete/playwright-chromium-screens" "complete desktop screenshot dir was not inferred from manifest"
Assert-PathEndsWith $CompletePlan.paths.phoneEvidence "assets/tmp/browser-evidence-plan-selftest/complete/phone-loop.json" "complete phone path was not inferred from manifest"
Assert-PathEndsWith $CompletePlan.paths.windowsChromeEvidence "assets/tmp/browser-evidence-plan-selftest/complete/chrome-loop.json" "complete Chrome path was not inferred from manifest"
Assert-PathEndsWith $CompletePlan.paths.windowsChromeScreenshotDir "assets/tmp/browser-evidence-plan-selftest/complete/windows-chrome-screens" "complete Chrome screenshot dir was not inferred from manifest"
foreach ($EvidencePath in @(
    $CompletePlan.summaryPath,
    $CompletePlan.paths.desktopEvidence,
    $CompletePlan.paths.desktopScreenshotDir,
    $CompletePlan.paths.phoneEvidence,
    $CompletePlan.paths.windowsChromeEvidence,
    $CompletePlan.paths.windowsChromeScreenshotDir
  )) {
  Assert-PortableEvidencePath $EvidencePath "complete plan evidence path"
}

$ResultJsonPath = Join-Path $OutputDir "complete-result.json"
$CompleteWithResult = Read-PlanWithResultJson -Arguments @("-SummaryPath", $CompleteSummary, "-SelfTest", "-MaxAgeMinutes", "30") -ResultJsonPath $ResultJsonPath
Assert-BrowserEvidencePlanManifest $CompleteWithResult.plan "complete result-json dry-run plan"
Assert-BrowserEvidencePlanManifest $CompleteWithResult.result.plan "complete result-json embedded plan"
Assert-Equal $CompleteWithResult.plan.requiredEvidence.desktop $true "result-json dry-run desktop required"
Assert-Equal $CompleteWithResult.plan.options.maxAgeMinutes 30 "result-json dry-run max age"
Assert-Equal $CompleteWithResult.result.mode "dry-run" "result-json mode"
Assert-Equal $CompleteWithResult.result.success $true "result-json success"
Assert-Equal $CompleteWithResult.result.plan.requiredEvidence.phone $true "result-json phone required"
Assert-Equal $CompleteWithResult.result.plan.options.maxAgeMinutes 30 "result-json embedded max age"
Assert-Equal $CompleteWithResult.result.plan.selfTest.report $true "result-json report self-test"
Assert-PortableEvidencePath $CompleteWithResult.result.plan.summaryPath "result-json plan summary path"
Assert-PortableEvidencePath $CompleteWithResult.result.plan.resultJsonPath "result-json plan result path"
Assert-BrowserEvidenceChecksManifest $CompleteWithResult.result $CompleteWithResult.plan "complete result-json"

$StaleResultJsonPath = Join-Path $OutputDir "stale-result.json"
Read-FailingCheck `
  @("-RequireDesktop", "-RequireChrome", "-ResultJsonPath", $StaleResultJsonPath, "-MaxAgeMinutes", "0.001") `
  @("browser:evidence-result:check", "--max-age-minutes 0.001", "generatedAt is older than --max-age-minutes")

$DesktopOnlyPlan = Read-Plan @("-SummaryPath", $DesktopOnlySummary)
Assert-BrowserEvidencePlanManifest $DesktopOnlyPlan "desktop-only plan"
Assert-Equal $DesktopOnlyPlan.requiredEvidence.desktop $true "desktop-only desktop required"
Assert-Equal $DesktopOnlyPlan.requiredEvidence.phone $false "desktop-only phone required"
Assert-Equal $DesktopOnlyPlan.requiredEvidence.windowsChrome $false "desktop-only Chrome required"
Assert-Equal $DesktopOnlyPlan.paths.phoneEvidence "__phone_not_run__.json" "desktop-only phone path should use sentinel"
Assert-Equal $DesktopOnlyPlan.paths.windowsChromeEvidence "__chrome_not_run__.json" "desktop-only Chrome path should use sentinel"
Assert-Equal $DesktopOnlyPlan.paths.windowsChromeScreenshotDir "__chrome_screens_not_run__" "desktop-only Chrome screenshot dir should use sentinel"

$ChromeOnlyPlan = Read-Plan @("-SummaryPath", $ChromeOnlySummary, "-SelfTest")
Assert-BrowserEvidencePlanManifest $ChromeOnlyPlan "chrome-only plan"
Assert-Equal $ChromeOnlyPlan.requiredEvidence.desktop $false "chrome-only desktop required"
Assert-Equal $ChromeOnlyPlan.requiredEvidence.phone $false "chrome-only phone required"
Assert-Equal $ChromeOnlyPlan.requiredEvidence.windowsChrome $true "chrome-only Chrome required"
Assert-Equal $ChromeOnlyPlan.selfTest.desktopEvidence $false "chrome-only desktop self-test"
Assert-Equal $ChromeOnlyPlan.selfTest.summary $false "chrome-only summary self-test"
Assert-Equal $ChromeOnlyPlan.selfTest.report $false "chrome-only report self-test"
Assert-Equal $ChromeOnlyPlan.paths.desktopEvidence "__desktop_not_run__.json" "chrome-only desktop path should use sentinel"
Assert-Equal $ChromeOnlyPlan.paths.desktopScreenshotDir "__desktop_screens_not_run__" "chrome-only desktop screenshot dir should use sentinel"
Assert-Equal $ChromeOnlyPlan.paths.phoneEvidence "__phone_not_run__.json" "chrome-only phone path should use sentinel"

$JsonOnlyPlan = Read-Plan @("-SummaryPath", $JsonOnlySummary)
Assert-BrowserEvidencePlanManifest $JsonOnlyPlan "json-only plan"
Assert-Equal $JsonOnlyPlan.requiredEvidence.desktop $true "json-only desktop required"
Assert-Equal $JsonOnlyPlan.requiredEvidence.windowsChrome $true "json-only Chrome required"
Assert-Equal $JsonOnlyPlan.paths.phoneEvidence "__phone_not_run__.json" "json-only phone path should use sentinel"
Assert-PathEndsWith $JsonOnlyPlan.paths.desktopScreenshotDir "assets/tmp/browser-evidence-plan-selftest/json-only/raw-desktop-screens" "json-only desktop screenshot dir was not inferred from raw JSON"
Assert-PathEndsWith $JsonOnlyPlan.paths.windowsChromeScreenshotDir "assets/tmp/browser-evidence-plan-selftest/json-only/raw-chrome-screens" "json-only Chrome screenshot dir was not inferred from raw JSON"

Read-FailingPlan @("-SummaryPath", $DesktopOnlySummary, "-RequirePhone") "Phone evidence was required"
Read-FailingPlan @("-SummaryPath", $DesktopOnlySummary, "-RequireChrome") "Windows Chrome evidence was required"
Read-FailingPlan @("-SummaryPath", $ChromeOnlySummary, "-RequireDesktop") "Desktop evidence was required"
Read-FailingPlan @("-SummaryPath", $CompleteSummary, "-MaxAgeMinutes", "0") "-MaxAgeMinutes must be a positive number"

Write-Host "Browser evidence plan self-test passed."
