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

$CompleteSummary = Write-Summary -Name "complete" -Desktop $true -Phone $true -Chrome $true -WithManifest
$DesktopOnlySummary = Write-Summary -Name "desktop-only" -Desktop $true -Phone $false -Chrome $false
$ChromeOnlySummary = Write-Summary -Name "chrome-only" -Desktop $false -Phone $false -Chrome $true
$JsonOnlySummary = Write-Summary -Name "json-only" -Desktop $true -Phone $false -Chrome $true -JsonOnlyManifest

$DefaultPlan = Read-Plan @()
if (-not $DefaultPlan.summaryPath.EndsWith("assets\tmp\browser-evidence-default-summary\full-loop-report.json")) {
  throw "default summary path should use an isolated temp snapshot: $($DefaultPlan.summaryPath)"
}
$DefaultSummary = Get-Content -Raw -LiteralPath $DefaultPlan.summaryPath | ConvertFrom-Json
$DefaultDevEnvEntry = @($DefaultSummary.evidence.files | Where-Object { $_.present -eq $true -and $_.label -eq "Dev Environment JSON" } | Select-Object -First 1)
if ($DefaultDevEnvEntry.Count -ne 0 -and -not ([string]$DefaultDevEnvEntry[0].file).EndsWith("assets/tmp/browser-evidence-default-summary/dev-env-check.json")) {
  throw "default summary should point Dev Environment JSON at the isolated temp snapshot: $($DefaultDevEnvEntry[0].file)"
}

$CompletePlan = Read-Plan @("-SummaryPath", $CompleteSummary, "-SelfTest")
Assert-Equal $CompletePlan.requiredEvidence.desktop $true "complete desktop required"
Assert-Equal $CompletePlan.requiredEvidence.phone $true "complete phone required"
Assert-Equal $CompletePlan.requiredEvidence.windowsChrome $true "complete Chrome required"
Assert-Equal $CompletePlan.selfTest.phoneEvidence $true "complete phone self-test"
Assert-Equal $CompletePlan.selfTest.desktopEvidence $true "complete desktop self-test"
Assert-Equal $CompletePlan.selfTest.summary $true "complete summary self-test"
Assert-Equal $CompletePlan.selfTest.report $true "complete report self-test"
if (-not $CompletePlan.paths.desktopEvidence.EndsWith("assets\tmp\browser-evidence-plan-selftest\complete\desktop-loop.json")) {
  throw "complete desktop path was not inferred from manifest: $($CompletePlan.paths.desktopEvidence)"
}
if (-not $CompletePlan.paths.desktopScreenshotDir.EndsWith("assets\tmp\browser-evidence-plan-selftest\complete\playwright-chromium-screens")) {
  throw "complete desktop screenshot dir was not inferred from manifest: $($CompletePlan.paths.desktopScreenshotDir)"
}
if (-not $CompletePlan.paths.phoneEvidence.EndsWith("assets\tmp\browser-evidence-plan-selftest\complete\phone-loop.json")) {
  throw "complete phone path was not inferred from manifest: $($CompletePlan.paths.phoneEvidence)"
}
if (-not $CompletePlan.paths.windowsChromeEvidence.EndsWith("assets\tmp\browser-evidence-plan-selftest\complete\chrome-loop.json")) {
  throw "complete Chrome path was not inferred from manifest: $($CompletePlan.paths.windowsChromeEvidence)"
}
if (-not $CompletePlan.paths.windowsChromeScreenshotDir.EndsWith("assets\tmp\browser-evidence-plan-selftest\complete\windows-chrome-screens")) {
  throw "complete Chrome screenshot dir was not inferred from manifest: $($CompletePlan.paths.windowsChromeScreenshotDir)"
}

$ResultJsonPath = Join-Path $OutputDir "complete-result.json"
$CompleteWithResult = Read-PlanWithResultJson -Arguments @("-SummaryPath", $CompleteSummary, "-SelfTest") -ResultJsonPath $ResultJsonPath
Assert-Equal $CompleteWithResult.plan.requiredEvidence.desktop $true "result-json dry-run desktop required"
Assert-Equal $CompleteWithResult.result.mode "dry-run" "result-json mode"
Assert-Equal $CompleteWithResult.result.success $true "result-json success"
Assert-Equal $CompleteWithResult.result.plan.requiredEvidence.phone $true "result-json phone required"
Assert-Equal $CompleteWithResult.result.plan.selfTest.report $true "result-json report self-test"
if (-not (@($CompleteWithResult.result.checks | Where-Object { $_.command -eq "npm run phone:evidence:check" }).Count -eq 1)) {
  throw "result JSON did not include the phone evidence check command."
}
if (-not (@($CompleteWithResult.result.checks | Where-Object { $_.command -eq "npm run report:selftest" }).Count -eq 1)) {
  throw "result JSON did not include the report self-test command."
}

$DesktopOnlyPlan = Read-Plan @("-SummaryPath", $DesktopOnlySummary)
Assert-Equal $DesktopOnlyPlan.requiredEvidence.desktop $true "desktop-only desktop required"
Assert-Equal $DesktopOnlyPlan.requiredEvidence.phone $false "desktop-only phone required"
Assert-Equal $DesktopOnlyPlan.requiredEvidence.windowsChrome $false "desktop-only Chrome required"

$ChromeOnlyPlan = Read-Plan @("-SummaryPath", $ChromeOnlySummary, "-SelfTest")
Assert-Equal $ChromeOnlyPlan.requiredEvidence.desktop $false "chrome-only desktop required"
Assert-Equal $ChromeOnlyPlan.requiredEvidence.phone $false "chrome-only phone required"
Assert-Equal $ChromeOnlyPlan.requiredEvidence.windowsChrome $true "chrome-only Chrome required"
Assert-Equal $ChromeOnlyPlan.selfTest.desktopEvidence $false "chrome-only desktop self-test"
Assert-Equal $ChromeOnlyPlan.selfTest.summary $false "chrome-only summary self-test"
Assert-Equal $ChromeOnlyPlan.selfTest.report $false "chrome-only report self-test"

$JsonOnlyPlan = Read-Plan @("-SummaryPath", $JsonOnlySummary)
Assert-Equal $JsonOnlyPlan.requiredEvidence.desktop $true "json-only desktop required"
Assert-Equal $JsonOnlyPlan.requiredEvidence.windowsChrome $true "json-only Chrome required"
if (-not $JsonOnlyPlan.paths.desktopScreenshotDir.EndsWith("assets\tmp\browser-evidence-plan-selftest\json-only\raw-desktop-screens")) {
  throw "json-only desktop screenshot dir was not inferred from raw JSON: $($JsonOnlyPlan.paths.desktopScreenshotDir)"
}
if (-not $JsonOnlyPlan.paths.windowsChromeScreenshotDir.EndsWith("assets\tmp\browser-evidence-plan-selftest\json-only\raw-chrome-screens")) {
  throw "json-only Chrome screenshot dir was not inferred from raw JSON: $($JsonOnlyPlan.paths.windowsChromeScreenshotDir)"
}

Read-FailingPlan @("-SummaryPath", $DesktopOnlySummary, "-RequirePhone") "Phone evidence was required"
Read-FailingPlan @("-SummaryPath", $DesktopOnlySummary, "-RequireChrome") "Windows Chrome evidence was required"
Read-FailingPlan @("-SummaryPath", $ChromeOnlySummary, "-RequireDesktop") "Desktop evidence was required"

Write-Host "Browser evidence plan self-test passed."
