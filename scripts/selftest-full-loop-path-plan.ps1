param()

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."

function Invoke-Plan {
  param([string[]]$Arguments)

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-full-loop.ps1" -DryRun @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "check-full-loop.ps1 -DryRun failed: $($Arguments -join ' ')"
  }

  return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw ("{0} Expected '{1}', got '{2}'." -f $Message, $Expected, $Actual)
  }
}

function Assert-StartsWith {
  param(
    [string]$Actual,
    [string]$ExpectedPrefix,
    [string]$Message
  )

  if (-not $Actual.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("{0} Expected '{1}' to start with '{2}'." -f $Message, $Actual, $ExpectedPrefix)
  }
}

function Assert-EndsWith {
  param(
    [string]$Actual,
    [string]$ExpectedSuffix,
    [string]$Message
  )

  if (-not $Actual.EndsWith($ExpectedSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("{0} Expected '{1}' to end with '{2}'." -f $Message, $Actual, $ExpectedSuffix)
  }
}

function Assert-PartialPath {
  param(
    [string]$Actual,
    [string]$RunId,
    [string]$Message
  )

  Assert-StartsWith $Actual ("assets/tmp/full-loop-partial/{0}/" -f $RunId) $Message
}

$DefaultPartial = Invoke-Plan @()
Assert-True $DefaultPartial.partialEvidenceRun "Default run should be treated as partial evidence."
Assert-True $DefaultPartial.requestedLoops.desktop "Default run should include desktop."
Assert-True (-not $DefaultPartial.requestedLoops.phone) "Default run should not include phone."
Assert-True (-not $DefaultPartial.requestedLoops.windowsChrome) "Default run should not include Windows Chrome."
Assert-Equal $DefaultPartial.gates.browserWrapperSharedStateLock.name "Global\HCEdgeBrowserLoopGate" "Default browser wrapper shared-state lock name."
Assert-Equal $DefaultPartial.gates.browserWrapperSharedStateLock.timeoutSeconds 1200 "Default browser wrapper shared-state lock timeout."
Assert-True $DefaultPartial.gates.webReadiness.httpProbeBeforePortReuse "Default run should HTTP-probe web readiness before port-only reuse."
Assert-True $DefaultPartial.gates.webReadiness.stalePortBlocksDuplicateStart "Default run should avoid duplicate web starts when the web port is stale."
Assert-PartialPath $DefaultPartial.outputs.reportPath $DefaultPartial.runId "Default report path should be per-run partial output."
Assert-PartialPath $DefaultPartial.outputs.summaryPath $DefaultPartial.runId "Default summary path should be per-run partial output."
Assert-PartialPath $DefaultPartial.outputs.preflightJsonPath $DefaultPartial.runId "Default preflight JSON should be per-run partial output."
Assert-PartialPath $DefaultPartial.evidence.desktopJson $DefaultPartial.runId "Default desktop evidence should be per-run partial output."
Assert-PartialPath $DefaultPartial.evidence.desktopScreenshotDir $DefaultPartial.runId "Default desktop screenshots should be per-run partial output."
Assert-Equal $DefaultPartial.evidence.phoneJson "__phone_not_run__.json" "Default phone evidence should use sentinel."
Assert-Equal $DefaultPartial.evidence.windowsChromeJson "__chrome_not_run__.json" "Default Chrome evidence should use sentinel."

$Full = Invoke-Plan @("-IncludePhone", "-IncludeChrome")
Assert-True (-not $Full.partialEvidenceRun) "Complete desktop+phone+Chrome run should not be partial."
Assert-Equal $Full.outputs.reportPath "assets/demo/full-loop-report.md" "Complete run should write the demo report."
Assert-Equal $Full.outputs.summaryPath "assets/demo/full-loop-report.json" "Complete run should write the demo summary."
Assert-Equal $Full.outputs.preflightJsonPath "assets/tmp/dev-env-check.json" "Complete run should use the shared preflight JSON path."
Assert-Equal $Full.evidence.desktopJson "assets/demo/desktop-loop.json" "Complete run should use demo desktop evidence."
Assert-Equal $Full.evidence.phoneJson "assets/demo/phone-loop.json" "Complete run should use demo phone evidence."
Assert-Equal $Full.evidence.windowsChromeJson "assets/demo/chrome-loop.json" "Complete run should use demo Chrome evidence."
Assert-Equal $Full.evidence.desktopScreenshotDir "assets/demo/playwright-chromium-screens" "Complete run should use demo desktop screenshots."
Assert-Equal $Full.evidence.windowsChromeScreenshotDir "assets/demo/windows-chrome-screens" "Complete run should use demo Chrome screenshots."
Assert-True $Full.gates.reportSelftest "Complete run should enable report selftest."
Assert-True $Full.gates.phoneSelftest "Complete run should enable phone selftest."
Assert-True $Full.gates.desktopAndSummarySelftests "Complete run should enable desktop and summary selftests."

$ChromeOnly = Invoke-Plan @("-SkipPreflight", "-SkipDesktop", "-IncludeChrome")
Assert-True $ChromeOnly.partialEvidenceRun "Chrome-only run should be partial."
Assert-True (-not $ChromeOnly.gates.preflightRun) "Chrome-only skip-preflight run should not run preflight."
Assert-True $ChromeOnly.gates.summaryAllowSkipDesktop "Chrome-only run should allow skipped desktop in summary check."
Assert-Equal $ChromeOnly.outputs.preflightEvidencePath "__dev_env_not_run__.json" "Chrome-only skip-preflight run should use dev-env sentinel."
Assert-Equal $ChromeOnly.evidence.desktopJson "__desktop_not_run__.json" "Chrome-only run should use desktop sentinel."
Assert-Equal $ChromeOnly.evidence.phoneJson "__phone_not_run__.json" "Chrome-only run should use phone sentinel."
Assert-PartialPath $ChromeOnly.evidence.windowsChromeJson $ChromeOnly.runId "Chrome-only evidence should be per-run partial output."
Assert-PartialPath $ChromeOnly.evidence.windowsChromeScreenshotDir $ChromeOnly.runId "Chrome-only screenshots should be per-run partial output."
Assert-True (-not $ChromeOnly.gates.desktopAndSummarySelftests) "Chrome-only run should skip desktop/summary selftests when desktop is skipped."

$PhoneOnly = Invoke-Plan @("-SkipDesktop", "-IncludePhone")
Assert-True $PhoneOnly.partialEvidenceRun "Phone-only run should be partial."
Assert-True (-not $PhoneOnly.requestedLoops.desktop) "Phone-only run should skip desktop."
Assert-True $PhoneOnly.requestedLoops.phone "Phone-only run should include phone."
Assert-True (-not $PhoneOnly.requestedLoops.windowsChrome) "Phone-only run should not include Windows Chrome."
Assert-True $PhoneOnly.gates.preflightRun "Phone-only run should run preflight."
Assert-True $PhoneOnly.gates.summaryAllowSkipDesktop "Phone-only run should allow skipped desktop in summary check."
Assert-True $PhoneOnly.gates.summaryRequirePhone "Phone-only run should require phone in summary check."
Assert-True (-not $PhoneOnly.gates.summaryRequireChrome) "Phone-only run should not require Chrome in summary check."
Assert-True (-not $PhoneOnly.gates.phoneSelftest) "Phone-only run should skip phone selftest because desktop evidence was skipped."
Assert-Equal $PhoneOnly.evidence.desktopJson "__desktop_not_run__.json" "Phone-only run should use desktop sentinel."
Assert-Equal $PhoneOnly.evidence.windowsChromeJson "__chrome_not_run__.json" "Phone-only run should use Chrome sentinel."
Assert-PartialPath $PhoneOnly.outputs.reportPath $PhoneOnly.runId "Phone-only report should be per-run partial output."
Assert-PartialPath $PhoneOnly.evidence.phoneJson $PhoneOnly.runId "Phone-only evidence should be per-run partial output."

$PhoneChromeOnly = Invoke-Plan @("-SkipDesktop", "-IncludePhone", "-IncludeChrome")
Assert-True $PhoneChromeOnly.partialEvidenceRun "Phone+Chrome without desktop should be partial."
Assert-True (-not $PhoneChromeOnly.requestedLoops.desktop) "Phone+Chrome without desktop should skip desktop."
Assert-True $PhoneChromeOnly.requestedLoops.phone "Phone+Chrome without desktop should include phone."
Assert-True $PhoneChromeOnly.requestedLoops.windowsChrome "Phone+Chrome without desktop should include Windows Chrome."
Assert-True $PhoneChromeOnly.gates.preflightRun "Phone+Chrome without desktop should run preflight."
Assert-True $PhoneChromeOnly.gates.summaryAllowSkipDesktop "Phone+Chrome without desktop should allow skipped desktop in summary check."
Assert-True $PhoneChromeOnly.gates.summaryRequirePhone "Phone+Chrome without desktop should require phone in summary check."
Assert-True $PhoneChromeOnly.gates.summaryRequireChrome "Phone+Chrome without desktop should require Chrome in summary check."
Assert-True (-not $PhoneChromeOnly.gates.reportSelftest) "Phone+Chrome without desktop should skip report selftest."
Assert-True (-not $PhoneChromeOnly.gates.phoneSelftest) "Phone+Chrome without desktop should skip phone selftest because desktop evidence was skipped."
Assert-True (-not $PhoneChromeOnly.gates.desktopAndSummarySelftests) "Phone+Chrome without desktop should skip desktop/summary selftests."
Assert-Equal $PhoneChromeOnly.evidence.desktopJson "__desktop_not_run__.json" "Phone+Chrome without desktop should use desktop sentinel."
Assert-PartialPath $PhoneChromeOnly.outputs.reportPath $PhoneChromeOnly.runId "Phone+Chrome without desktop report should be per-run partial output."
Assert-PartialPath $PhoneChromeOnly.evidence.phoneJson $PhoneChromeOnly.runId "Phone+Chrome without desktop phone evidence should be per-run partial output."
Assert-PartialPath $PhoneChromeOnly.evidence.windowsChromeJson $PhoneChromeOnly.runId "Phone+Chrome without desktop Chrome evidence should be per-run partial output."

$DesktopChrome = Invoke-Plan @("-IncludeChrome")
Assert-True $DesktopChrome.partialEvidenceRun "Desktop+Chrome without phone should be partial."
Assert-True $DesktopChrome.requestedLoops.desktop "Desktop+Chrome run should include desktop."
Assert-True $DesktopChrome.requestedLoops.windowsChrome "Desktop+Chrome run should include Windows Chrome."
Assert-True (-not $DesktopChrome.requestedLoops.phone) "Desktop+Chrome run should not include phone."
Assert-True $DesktopChrome.gates.preflightRun "Desktop+Chrome run should still run preflight."
Assert-True $DesktopChrome.gates.summaryRequireChrome "Desktop+Chrome run should require Chrome in summary check."
Assert-True (-not $DesktopChrome.gates.summaryRequirePhone) "Desktop+Chrome run should not require phone in summary check."
Assert-True $DesktopChrome.gates.desktopAndSummarySelftests "Desktop+Chrome run should enable desktop and summary selftests."
Assert-True (-not $DesktopChrome.gates.phoneSelftest) "Desktop+Chrome run should not enable phone selftest."
Assert-Equal $DesktopChrome.evidence.phoneJson "__phone_not_run__.json" "Desktop+Chrome run should use phone sentinel."
Assert-PartialPath $DesktopChrome.outputs.reportPath $DesktopChrome.runId "Desktop+Chrome report should be per-run partial output."
Assert-PartialPath $DesktopChrome.evidence.desktopJson $DesktopChrome.runId "Desktop+Chrome desktop evidence should be per-run partial output."
Assert-PartialPath $DesktopChrome.evidence.windowsChromeJson $DesktopChrome.runId "Desktop+Chrome Chrome evidence should be per-run partial output."

$DesktopPhone = Invoke-Plan @("-IncludePhone")
Assert-True $DesktopPhone.partialEvidenceRun "Desktop+phone without Windows Chrome should be partial."
Assert-True $DesktopPhone.requestedLoops.desktop "Desktop+phone run should include desktop."
Assert-True $DesktopPhone.requestedLoops.phone "Desktop+phone run should include phone."
Assert-True (-not $DesktopPhone.requestedLoops.windowsChrome) "Desktop+phone run should not include Windows Chrome."
Assert-True $DesktopPhone.gates.preflightRun "Desktop+phone run should run preflight."
Assert-True $DesktopPhone.gates.summaryRequirePhone "Desktop+phone run should require phone in summary check."
Assert-True (-not $DesktopPhone.gates.summaryRequireChrome) "Desktop+phone run should not require Chrome in summary check."
Assert-True $DesktopPhone.gates.phoneSelftest "Desktop+phone run should enable phone selftest."
Assert-True (-not $DesktopPhone.gates.desktopAndSummarySelftests) "Desktop+phone run should not enable desktop/summary selftests."
Assert-Equal $DesktopPhone.evidence.windowsChromeJson "__chrome_not_run__.json" "Desktop+phone run should use Chrome sentinel."
Assert-PartialPath $DesktopPhone.outputs.reportPath $DesktopPhone.runId "Desktop+phone report should be per-run partial output."
Assert-PartialPath $DesktopPhone.evidence.desktopJson $DesktopPhone.runId "Desktop+phone desktop evidence should be per-run partial output."
Assert-PartialPath $DesktopPhone.evidence.phoneJson $DesktopPhone.runId "Desktop+phone phone evidence should be per-run partial output."

$CustomReport = Invoke-Plan @("-ReportPath", "assets/tmp/custom-loop/custom-report.md")
Assert-True $CustomReport.partialEvidenceRun "Custom report default run should still be partial."
Assert-Equal $CustomReport.outputs.reportPath "assets/tmp/custom-loop/custom-report.md" "Custom report path should be honored."
Assert-Equal $CustomReport.outputs.summaryPath "assets/tmp/custom-loop/custom-report.json" "Summary path should follow custom report path when not provided."
Assert-PartialPath $CustomReport.evidence.desktopJson $CustomReport.runId "Custom report should not move default partial evidence out of the run directory."

$CustomSummary = Invoke-Plan @("-ReportPath", "assets/tmp/custom-loop/report.md", "-SummaryPath", "assets/tmp/custom-loop/summary.json")
Assert-Equal $CustomSummary.outputs.reportPath "assets/tmp/custom-loop/report.md" "Explicit custom report path should be honored."
Assert-Equal $CustomSummary.outputs.summaryPath "assets/tmp/custom-loop/summary.json" "Explicit custom summary path should be honored."

$CustomPartialDir = Invoke-Plan @("-IncludeChrome", "-PartialEvidenceDir", "assets/tmp/custom-loop/evidence")
Assert-True $CustomPartialDir.partialEvidenceRun "Custom partial evidence dir run should still be partial."
Assert-Equal $CustomPartialDir.outputs.partialEvidenceDir "assets/tmp/custom-loop/evidence" "Custom partial evidence dir should be honored."
Assert-Equal $CustomPartialDir.outputs.preflightJsonPath "assets/tmp/custom-loop/evidence/dev-env-check.json" "Custom partial evidence dir should hold preflight JSON."
Assert-Equal $CustomPartialDir.evidence.desktopJson "assets/tmp/custom-loop/evidence/desktop-loop.json" "Custom partial evidence dir should hold desktop JSON."
Assert-Equal $CustomPartialDir.evidence.windowsChromeJson "assets/tmp/custom-loop/evidence/chrome-loop.json" "Custom partial evidence dir should hold Chrome JSON."
Assert-Equal $CustomPartialDir.evidence.desktopScreenshotDir "assets/tmp/custom-loop/evidence/playwright-chromium-screens" "Custom partial evidence dir should hold desktop screenshots."
Assert-Equal $CustomPartialDir.evidence.windowsChromeScreenshotDir "assets/tmp/custom-loop/evidence/windows-chrome-screens" "Custom partial evidence dir should hold Chrome screenshots."

$CustomLockTimeout = Invoke-Plan @("-BrowserWrapperSharedStateLockTimeoutSeconds", "42")
Assert-Equal $CustomLockTimeout.gates.browserWrapperSharedStateLock.name "Global\HCEdgeBrowserLoopGate" "Custom browser wrapper shared-state lock name."
Assert-Equal $CustomLockTimeout.gates.browserWrapperSharedStateLock.timeoutSeconds 42 "Custom browser wrapper shared-state lock timeout."

Write-Host "Full-loop path plan self-test passed."
