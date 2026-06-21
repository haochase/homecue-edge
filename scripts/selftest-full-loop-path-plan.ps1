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

function Invoke-FullLoopExpectFailure {
  param([string[]]$Arguments)

  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-full-loop.ps1" @Arguments 2>&1
    $ExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }

  if ($ExitCode -eq 0) {
    throw "check-full-loop.ps1 should have failed: $($Arguments -join ' ')"
  }

  return (($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
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

function Assert-Contains {
  param(
    [string]$Actual,
    [string]$Expected,
    [string]$Message
  )

  if (-not $Actual.Contains($Expected)) {
    throw ("{0} Expected '{1}' to contain '{2}'." -f $Message, $Actual, $Expected)
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

function Assert-PlanManifest {
  param(
    [object]$Plan,
    [string]$Message
  )

  Assert-True ($null -ne $Plan.hardware) "$Message should expose hardware planning."
  Assert-True ($null -ne $Plan.hardware.esp32Serial) "$Message should expose ESP32 serial hardware planning."
  Assert-True ($null -ne $Plan.gates.esp32Serial) "$Message should expose ESP32 serial gates."
  Assert-True ($null -ne $Plan.outputs.esp32SerialLogPath) "$Message should expose ESP32 serial log output."
  Assert-True ($null -ne $Plan.outputs.esp32SerialResultJsonPath) "$Message should expose ESP32 serial result output."
  Assert-True ($null -ne $Plan.outputs.esp32SerialRecheckResultJsonPath) "$Message should expose ESP32 serial recheck result output."
}

$PhoneOptionConflict = Invoke-FullLoopExpectFailure @("-DryRun", "-IncludePhone", "-SkipPhone")
Assert-Contains $PhoneOptionConflict "-IncludePhone and -SkipPhone cannot be used together." "Phone include/skip conflict should fail early."

$DefaultPartial = Invoke-Plan @()
Assert-PlanManifest $DefaultPartial "Default run"
Assert-True $DefaultPartial.partialEvidenceRun "Default run should be treated as partial evidence."
Assert-True $DefaultPartial.isolatedEvidenceRun "Default run should write isolated run evidence."
Assert-True (-not $DefaultPartial.options.isolateEvidence) "Default run should not require explicit isolated evidence."
Assert-True (-not $DefaultPartial.options.skipPhone) "Default run should not skip phone."
Assert-True $DefaultPartial.requestedLoops.desktop "Default run should include desktop."
Assert-True $DefaultPartial.requestedLoops.phone "Default run should include phone."
Assert-True (-not $DefaultPartial.requestedLoops.windowsChrome) "Default run should not include Windows Chrome."
Assert-Equal $DefaultPartial.gates.browserWrapperSharedStateLock.name "Global\HCEdgeBrowserLoopGate" "Default browser wrapper shared-state lock name."
Assert-Equal $DefaultPartial.gates.browserWrapperSharedStateLock.timeoutSeconds 1200 "Default browser wrapper shared-state lock timeout."
Assert-True $DefaultPartial.gates.webReadiness.httpProbeBeforePortReuse "Default run should HTTP-probe web readiness before port-only reuse."
Assert-True $DefaultPartial.gates.webReadiness.stalePortBlocksDuplicateStart "Default run should avoid duplicate web starts when the web port is stale."
Assert-PartialPath $DefaultPartial.outputs.reportPath $DefaultPartial.runId "Default report path should be per-run partial output."
Assert-PartialPath $DefaultPartial.outputs.summaryPath $DefaultPartial.runId "Default summary path should be per-run partial output."
Assert-PartialPath $DefaultPartial.outputs.preflightJsonPath $DefaultPartial.runId "Default preflight JSON should be per-run partial output."
Assert-PartialPath $DefaultPartial.outputs.webReadinessEvidencePath $DefaultPartial.runId "Default web readiness evidence should be per-run partial output."
Assert-Equal $DefaultPartial.outputs.esp32SerialLogPath "__esp32_serial_not_run__.log" "Default ESP32 serial log should use sentinel."
Assert-Equal $DefaultPartial.outputs.esp32SerialResultJsonPath "__esp32_serial_not_run__.json" "Default ESP32 serial result should use sentinel."
Assert-Equal $DefaultPartial.outputs.esp32SerialRecheckResultJsonPath "__esp32_serial_recheck_not_run__.json" "Default ESP32 serial recheck result should use sentinel."
Assert-PartialPath $DefaultPartial.evidence.desktopJson $DefaultPartial.runId "Default desktop evidence should be per-run partial output."
Assert-PartialPath $DefaultPartial.evidence.desktopScreenshotDir $DefaultPartial.runId "Default desktop screenshots should be per-run partial output."
Assert-PartialPath $DefaultPartial.evidence.phoneJson $DefaultPartial.runId "Default phone evidence should be per-run partial output."
Assert-Equal $DefaultPartial.evidence.windowsChromeJson "__chrome_not_run__.json" "Default Chrome evidence should use sentinel."
Assert-True $DefaultPartial.gates.summaryRequirePhone "Default run should require phone in summary check."
Assert-True $DefaultPartial.gates.phoneSelftest "Default run should enable phone selftest."
Assert-True (-not $DefaultPartial.gates.esp32Serial.run) "Default run should not run ESP32 serial gate."
Assert-True (-not $DefaultPartial.hardware.esp32Serial.run) "Default hardware plan should not run ESP32 serial gate."

$DesktopOnlySkipPhone = Invoke-Plan @("-SkipPhone")
Assert-PlanManifest $DesktopOnlySkipPhone "Desktop-only skip-phone run"
Assert-True $DesktopOnlySkipPhone.partialEvidenceRun "Desktop-only skip-phone run should be partial."
Assert-True $DesktopOnlySkipPhone.isolatedEvidenceRun "Desktop-only skip-phone run should write isolated run evidence."
Assert-True $DesktopOnlySkipPhone.options.skipPhone "Desktop-only skip-phone run should preserve explicit phone skip."
Assert-True $DesktopOnlySkipPhone.requestedLoops.desktop "Desktop-only skip-phone run should include desktop."
Assert-True (-not $DesktopOnlySkipPhone.requestedLoops.phone) "Desktop-only skip-phone run should not include phone."
Assert-True (-not $DesktopOnlySkipPhone.requestedLoops.windowsChrome) "Desktop-only skip-phone run should not include Windows Chrome."
Assert-True $DesktopOnlySkipPhone.gates.preflightRun "Desktop-only skip-phone run should still run preflight."
Assert-True (-not $DesktopOnlySkipPhone.gates.summaryRequirePhone) "Desktop-only skip-phone run should not require phone in summary check."
Assert-True (-not $DesktopOnlySkipPhone.gates.phoneSelftest) "Desktop-only skip-phone run should not enable phone selftest."
Assert-Equal $DesktopOnlySkipPhone.evidence.phoneJson "__phone_not_run__.json" "Desktop-only skip-phone run should use phone sentinel."
Assert-Equal $DesktopOnlySkipPhone.evidence.windowsChromeJson "__chrome_not_run__.json" "Desktop-only skip-phone run should use Chrome sentinel."
Assert-PartialPath $DesktopOnlySkipPhone.outputs.reportPath $DesktopOnlySkipPhone.runId "Desktop-only skip-phone report should be per-run partial output."
Assert-PartialPath $DesktopOnlySkipPhone.outputs.summaryPath $DesktopOnlySkipPhone.runId "Desktop-only skip-phone summary should be per-run partial output."
Assert-PartialPath $DesktopOnlySkipPhone.evidence.desktopJson $DesktopOnlySkipPhone.runId "Desktop-only skip-phone desktop evidence should be per-run partial output."

$Full = Invoke-Plan @("-IncludeChrome")
Assert-PlanManifest $Full "Complete run"
Assert-True (-not $Full.partialEvidenceRun) "Complete desktop+phone+Chrome run should not be partial."
Assert-True (-not $Full.isolatedEvidenceRun) "Complete desktop+phone+Chrome run should keep demo evidence by default."
Assert-True (-not $Full.options.isolateEvidence) "Complete run should not isolate evidence unless requested."
Assert-Equal $Full.outputs.reportPath "assets/demo/full-loop-report.md" "Complete run should write the demo report."
Assert-Equal $Full.outputs.summaryPath "assets/demo/full-loop-report.json" "Complete run should write the demo summary."
Assert-Equal $Full.outputs.preflightJsonPath "assets/tmp/dev-env-check.json" "Complete run should use the shared preflight JSON path."
Assert-PartialPath $Full.outputs.webReadinessEvidencePath $Full.runId "Complete run should keep web readiness evidence in the run temp directory."
Assert-Equal $Full.evidence.desktopJson "assets/demo/desktop-loop.json" "Complete run should use demo desktop evidence."
Assert-Equal $Full.evidence.phoneJson "assets/demo/phone-loop.json" "Complete run should use demo phone evidence."
Assert-Equal $Full.evidence.windowsChromeJson "assets/demo/chrome-loop.json" "Complete run should use demo Chrome evidence."
Assert-Equal $Full.evidence.desktopScreenshotDir "assets/demo/playwright-chromium-screens" "Complete run should use demo desktop screenshots."
Assert-Equal $Full.evidence.windowsChromeScreenshotDir "assets/demo/windows-chrome-screens" "Complete run should use demo Chrome screenshots."
Assert-True $Full.gates.reportSelftest "Complete run should enable report selftest."
Assert-True $Full.gates.phoneSelftest "Complete run should enable phone selftest."
Assert-True $Full.gates.desktopAndSummarySelftests "Complete run should enable desktop and summary selftests."
Assert-Equal $Full.outputs.esp32SerialLogPath "__esp32_serial_not_run__.log" "Complete run without ESP32 should use ESP32 log sentinel."
Assert-Equal $Full.outputs.esp32SerialResultJsonPath "__esp32_serial_not_run__.json" "Complete run without ESP32 should use ESP32 result sentinel."
Assert-Equal $Full.outputs.esp32SerialRecheckResultJsonPath "__esp32_serial_recheck_not_run__.json" "Complete run without ESP32 should use ESP32 recheck result sentinel."

$FullWithEsp32 = Invoke-Plan @("-IncludePhone", "-IncludeChrome", "-IncludeEsp32Serial", "-Esp32Port", "COM9", "-Esp32SerialSeconds", "12", "-Esp32SerialCommandIndex", "2", "-Esp32SkipReset")
Assert-PlanManifest $FullWithEsp32 "Complete ESP32 run"
Assert-True (-not $FullWithEsp32.partialEvidenceRun) "Complete ESP32 run should keep the browser evidence shape complete."
Assert-True (-not $FullWithEsp32.isolatedEvidenceRun) "Complete ESP32 run should keep demo browser evidence by default."
Assert-True $FullWithEsp32.gates.esp32Serial.run "Complete ESP32 run should enable ESP32 serial gate."
Assert-True $FullWithEsp32.gates.esp32Serial.firmwareFlowRequired "Complete ESP32 run should require firmware flow."
Assert-True $FullWithEsp32.gates.esp32Serial.requireInteraction "Complete ESP32 run should require interaction markers."
Assert-True $FullWithEsp32.gates.esp32Serial.autoSerialLevel4 "Complete ESP32 run should use the automatic Level 4 serial route."
Assert-True $FullWithEsp32.gates.esp32Serial.savedLogRecheck "Complete ESP32 run should recheck the saved serial log."
Assert-True $FullWithEsp32.hardware.esp32Serial.run "Complete ESP32 hardware plan should mark the serial gate as running."
Assert-Equal $FullWithEsp32.hardware.esp32Serial.port "COM9" "Complete ESP32 run should preserve custom serial port."
Assert-Equal $FullWithEsp32.hardware.esp32Serial.baud 115200 "Complete ESP32 run should preserve default baud."
Assert-Equal $FullWithEsp32.hardware.esp32Serial.seconds 12 "Complete ESP32 run should preserve custom serial duration."
Assert-Equal $FullWithEsp32.hardware.esp32Serial.serialCommandIndex 2 "Complete ESP32 run should preserve command index."
Assert-True $FullWithEsp32.hardware.esp32Serial.skipReset "Complete ESP32 run should preserve skip-reset."
Assert-PartialPath $FullWithEsp32.outputs.esp32SerialLogPath $FullWithEsp32.runId "Complete ESP32 serial log should be in the run temp directory."
Assert-PartialPath $FullWithEsp32.outputs.esp32SerialResultJsonPath $FullWithEsp32.runId "Complete ESP32 serial result should be in the run temp directory."
Assert-PartialPath $FullWithEsp32.outputs.esp32SerialRecheckResultJsonPath $FullWithEsp32.runId "Complete ESP32 serial recheck result should be in the run temp directory."

$FullWithIsolatedEvidence = Invoke-Plan @("-IncludePhone", "-IncludeChrome", "-IncludeEsp32Serial", "-IsolateEvidence", "-PartialEvidenceDir", "assets/tmp/custom-loop/device-evidence")
Assert-PlanManifest $FullWithIsolatedEvidence "Complete isolated ESP32 run"
Assert-True (-not $FullWithIsolatedEvidence.partialEvidenceRun) "Complete isolated ESP32 run should keep the browser evidence shape complete."
Assert-True $FullWithIsolatedEvidence.isolatedEvidenceRun "Complete isolated ESP32 run should write isolated run evidence."
Assert-True $FullWithIsolatedEvidence.options.isolateEvidence "Complete isolated ESP32 run should preserve the isolate option."
Assert-Equal $FullWithIsolatedEvidence.outputs.partialEvidenceDir "assets/tmp/custom-loop/device-evidence" "Complete isolated ESP32 run should honor custom evidence dir."
Assert-Equal $FullWithIsolatedEvidence.outputs.reportPath "assets/tmp/custom-loop/device-evidence/full-loop-report.md" "Complete isolated ESP32 report should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.outputs.summaryPath "assets/tmp/custom-loop/device-evidence/full-loop-report.json" "Complete isolated ESP32 summary should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.outputs.preflightJsonPath "assets/tmp/custom-loop/device-evidence/dev-env-check.json" "Complete isolated ESP32 preflight JSON should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.evidence.desktopJson "assets/tmp/custom-loop/device-evidence/desktop-loop.json" "Complete isolated ESP32 desktop evidence should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.evidence.phoneJson "assets/tmp/custom-loop/device-evidence/phone-loop.json" "Complete isolated ESP32 phone evidence should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.evidence.windowsChromeJson "assets/tmp/custom-loop/device-evidence/chrome-loop.json" "Complete isolated ESP32 Chrome evidence should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.outputs.esp32SerialLogPath "assets/tmp/custom-loop/device-evidence/esp32-serial-level4.log" "Complete isolated ESP32 serial log should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.outputs.esp32SerialResultJsonPath "assets/tmp/custom-loop/device-evidence/esp32-serial-level4.json" "Complete isolated ESP32 serial result should be in the evidence dir."
Assert-Equal $FullWithIsolatedEvidence.outputs.esp32SerialRecheckResultJsonPath "assets/tmp/custom-loop/device-evidence/esp32-serial-saved-log-check.json" "Complete isolated ESP32 serial recheck result should be in the evidence dir."

$ChromeOnly = Invoke-Plan @("-SkipPreflight", "-SkipDesktop", "-SkipPhone", "-IncludeChrome")
Assert-PlanManifest $ChromeOnly "Chrome-only run"
Assert-True $ChromeOnly.partialEvidenceRun "Chrome-only run should be partial."
Assert-True (-not $ChromeOnly.gates.preflightRun) "Chrome-only skip-preflight run should not run preflight."
Assert-True $ChromeOnly.gates.summaryAllowSkipDesktop "Chrome-only run should allow skipped desktop in summary check."
Assert-Equal $ChromeOnly.outputs.preflightEvidencePath "__dev_env_not_run__.json" "Chrome-only skip-preflight run should use dev-env sentinel."
Assert-PartialPath $ChromeOnly.outputs.webReadinessEvidencePath $ChromeOnly.runId "Chrome-only run should still write web readiness evidence."
Assert-Equal $ChromeOnly.evidence.desktopJson "__desktop_not_run__.json" "Chrome-only run should use desktop sentinel."
Assert-Equal $ChromeOnly.evidence.phoneJson "__phone_not_run__.json" "Chrome-only run should use phone sentinel."
Assert-PartialPath $ChromeOnly.evidence.windowsChromeJson $ChromeOnly.runId "Chrome-only evidence should be per-run partial output."
Assert-PartialPath $ChromeOnly.evidence.windowsChromeScreenshotDir $ChromeOnly.runId "Chrome-only screenshots should be per-run partial output."
Assert-True (-not $ChromeOnly.gates.desktopAndSummarySelftests) "Chrome-only run should skip desktop/summary selftests when desktop is skipped."

$PhoneOnly = Invoke-Plan @("-SkipDesktop", "-IncludePhone")
Assert-PlanManifest $PhoneOnly "Phone-only run"
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
Assert-PlanManifest $PhoneChromeOnly "Phone+Chrome-only run"
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

$DesktopChrome = Invoke-Plan @("-SkipPhone", "-IncludeChrome")
Assert-PlanManifest $DesktopChrome "Desktop+Chrome run"
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
Assert-PlanManifest $DesktopPhone "Desktop+phone run"
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
Assert-PlanManifest $CustomReport "Custom report run"
Assert-True $CustomReport.partialEvidenceRun "Custom report default run should still be partial."
Assert-Equal $CustomReport.outputs.reportPath "assets/tmp/custom-loop/custom-report.md" "Custom report path should be honored."
Assert-Equal $CustomReport.outputs.summaryPath "assets/tmp/custom-loop/custom-report.json" "Summary path should follow custom report path when not provided."
Assert-PartialPath $CustomReport.evidence.desktopJson $CustomReport.runId "Custom report should not move default partial evidence out of the run directory."

$CustomSummary = Invoke-Plan @("-ReportPath", "assets/tmp/custom-loop/report.md", "-SummaryPath", "assets/tmp/custom-loop/summary.json")
Assert-PlanManifest $CustomSummary "Custom summary run"
Assert-Equal $CustomSummary.outputs.reportPath "assets/tmp/custom-loop/report.md" "Explicit custom report path should be honored."
Assert-Equal $CustomSummary.outputs.summaryPath "assets/tmp/custom-loop/summary.json" "Explicit custom summary path should be honored."

$CustomPartialDir = Invoke-Plan @("-SkipPhone", "-IncludeChrome", "-PartialEvidenceDir", "assets/tmp/custom-loop/evidence")
Assert-PlanManifest $CustomPartialDir "Custom partial evidence dir run"
Assert-True $CustomPartialDir.partialEvidenceRun "Custom partial evidence dir run should still be partial."
Assert-Equal $CustomPartialDir.outputs.partialEvidenceDir "assets/tmp/custom-loop/evidence" "Custom partial evidence dir should be honored."
Assert-Equal $CustomPartialDir.outputs.preflightJsonPath "assets/tmp/custom-loop/evidence/dev-env-check.json" "Custom partial evidence dir should hold preflight JSON."
Assert-Equal $CustomPartialDir.outputs.webReadinessEvidencePath "assets/tmp/custom-loop/evidence/web-readiness.json" "Custom partial evidence dir should hold web readiness JSON."
Assert-Equal $CustomPartialDir.outputs.esp32SerialLogPath "__esp32_serial_not_run__.log" "Custom partial evidence dir without ESP32 should use ESP32 log sentinel."
Assert-Equal $CustomPartialDir.outputs.esp32SerialResultJsonPath "__esp32_serial_not_run__.json" "Custom partial evidence dir without ESP32 should use ESP32 result sentinel."
Assert-Equal $CustomPartialDir.outputs.esp32SerialRecheckResultJsonPath "__esp32_serial_recheck_not_run__.json" "Custom partial evidence dir without ESP32 should use ESP32 recheck result sentinel."
Assert-Equal $CustomPartialDir.evidence.desktopJson "assets/tmp/custom-loop/evidence/desktop-loop.json" "Custom partial evidence dir should hold desktop JSON."
Assert-Equal $CustomPartialDir.evidence.windowsChromeJson "assets/tmp/custom-loop/evidence/chrome-loop.json" "Custom partial evidence dir should hold Chrome JSON."
Assert-Equal $CustomPartialDir.evidence.desktopScreenshotDir "assets/tmp/custom-loop/evidence/playwright-chromium-screens" "Custom partial evidence dir should hold desktop screenshots."
Assert-Equal $CustomPartialDir.evidence.windowsChromeScreenshotDir "assets/tmp/custom-loop/evidence/windows-chrome-screens" "Custom partial evidence dir should hold Chrome screenshots."

$CustomLockTimeout = Invoke-Plan @("-BrowserWrapperSharedStateLockTimeoutSeconds", "42")
Assert-PlanManifest $CustomLockTimeout "Custom lock timeout run"
Assert-Equal $CustomLockTimeout.gates.browserWrapperSharedStateLock.name "Global\HCEdgeBrowserLoopGate" "Custom browser wrapper shared-state lock name."
Assert-Equal $CustomLockTimeout.gates.browserWrapperSharedStateLock.timeoutSeconds 42 "Custom browser wrapper shared-state lock timeout."

Write-Host "Full-loop path plan self-test passed."
