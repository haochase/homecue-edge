$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$LockName = "Global\HCEdgeBrowserLoopGate"
$LockSelftestDir = Join-Path $Root "assets\tmp\browser-wrapper-path-selftest-lock"

function Invoke-Plan {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptName,
    [string[]]$Arguments = @()
  )

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\$ScriptName" -DryRun @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$ScriptName -DryRun failed: $($Arguments -join ' ')"
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

function Assert-Contains {
  param(
    [string]$Actual,
    [string]$Expected,
    [string]$Message
  )

  if (-not $Actual.Contains($Expected)) {
    throw ("{0} Expected output to contain '{1}'. Actual: {2}" -f $Message, $Expected, $Actual)
  }
}

function Assert-StartsWith {
  param(
    [string]$Actual,
    [string]$ExpectedPrefix,
    [string]$Message
  )

  if (-not $Actual.StartsWith($ExpectedPrefix, [System.StringComparison]::Ordinal)) {
    throw ("{0} Expected '{1}' to start with '{2}'." -f $Message, $Actual, $ExpectedPrefix)
  }
}

function Normalize-ProcessPathEnvironment {
  $PathEntries = @(
    [Environment]::GetEnvironmentVariables("Process").GetEnumerator() |
      Where-Object { [string]::Equals([string]$_.Key, "Path", [System.StringComparison]::OrdinalIgnoreCase) }
  )

  if ($PathEntries.Count -le 1) {
    return
  }

  $PathValue = @($PathEntries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } | Select-Object -First 1).Value
  foreach ($Entry in $PathEntries) {
    [Environment]::SetEnvironmentVariable([string]$Entry.Key, $null, "Process")
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$PathValue)) {
    [Environment]::SetEnvironmentVariable("Path", [string]$PathValue, "Process")
  }
}

function Assert-LockTimeout {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptName,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$ScreenshotDir,
    [string[]]$ExtraArguments = @()
  )

  Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
  $StdoutPath = Join-Path $LockSelftestDir ("{0}.out.txt" -f ([System.IO.Path]::GetFileNameWithoutExtension($OutputPath)))
  $StderrPath = Join-Path $LockSelftestDir ("{0}.err.txt" -f ([System.IO.Path]::GetFileNameWithoutExtension($OutputPath)))
  Remove-Item -LiteralPath $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue

  $Mutex = New-Object System.Threading.Mutex($false, $LockName)
  $HasLock = $false
  try {
    $HasLock = $Mutex.WaitOne(0)
    Assert-True $HasLock "Self-test could not acquire shared browser-loop lock."

    $Arguments = @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      "$PSScriptRoot\$ScriptName",
      "-OutputPath",
      $OutputPath,
      "-ScreenshotDir",
      $ScreenshotDir,
      "-SharedStateLockTimeoutSeconds",
      "1"
    ) + $ExtraArguments
    Normalize-ProcessPathEnvironment
    $Process = Start-Process `
      -FilePath "powershell" `
      -ArgumentList $Arguments `
      -WorkingDirectory $Root `
      -RedirectStandardOutput $StdoutPath `
      -RedirectStandardError $StderrPath `
      -PassThru `
      -WindowStyle Hidden
    Wait-Process -Id $Process.Id
    $Process.Refresh()

    $ExitCode = $Process.ExitCode
    $Text = @(
      if (Test-Path -LiteralPath $StdoutPath) { Get-Content -Raw -LiteralPath $StdoutPath }
      if (Test-Path -LiteralPath $StderrPath) { Get-Content -Raw -LiteralPath $StderrPath }
    ) -join [Environment]::NewLine

    Assert-True ($ExitCode -ne 0) "$ScriptName should fail while the shared browser-loop lock is held."
    Assert-Contains $Text "Timed out waiting for browser loop shared-state lock" "$ScriptName lock timeout."
    Assert-True (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) "$ScriptName should not write evidence after lock timeout."
  }
  finally {
    if ($HasLock) {
      $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
  }
}

$DesktopDefault = Invoke-Plan -ScriptName "check-desktop-loop.ps1"
Assert-StartsWith $DesktopDefault.runId "desktop-loop-" "Desktop default run id."
Assert-Equal $DesktopDefault.browserName "playwright-chromium" "Desktop wrapper browser name."
Assert-Equal $DesktopDefault.outputs.outputPath "assets/demo/desktop-loop.json" "Desktop default output path."
Assert-Equal $DesktopDefault.outputs.screenshotDir "assets/demo/playwright-chromium-screens" "Desktop default screenshot path."
Assert-Equal $DesktopDefault.outputs.expectedScreenshotDir "assets/demo/playwright-chromium-screens/" "Desktop default validator screenshot path."
Assert-Equal $DesktopDefault.sharedStateLock.name "Global\HCEdgeBrowserLoopGate" "Desktop shared-state lock name."
Assert-Equal $DesktopDefault.sharedStateLock.timeoutSeconds 1200 "Desktop default shared-state lock timeout."

$DesktopRelative = Invoke-Plan -ScriptName "check-desktop-loop.ps1" -Arguments @(
  "-OutputPath",
  ".\assets\tmp\desktop-wrapper-selftest.json",
  "-ScreenshotDir",
  ".\assets\tmp\desktop-wrapper-selftest-screens",
  "-SharedStateLockTimeoutSeconds",
  "42"
)
Assert-StartsWith $DesktopRelative.runId "desktop-loop-" "Desktop relative run id."
Assert-Equal $DesktopRelative.outputs.outputPath "assets/tmp/desktop-wrapper-selftest.json" "Desktop relative output path."
Assert-Equal $DesktopRelative.outputs.screenshotDir "assets/tmp/desktop-wrapper-selftest-screens" "Desktop relative screenshot path."
Assert-Equal $DesktopRelative.outputs.expectedScreenshotDir "assets/tmp/desktop-wrapper-selftest-screens/" "Desktop relative validator screenshot path."
Assert-Equal $DesktopRelative.sharedStateLock.timeoutSeconds 42 "Desktop custom shared-state lock timeout."

$ChromeDefault = Invoke-Plan -ScriptName "check-chrome-loop.ps1"
Assert-StartsWith $ChromeDefault.runId "chrome-loop-" "Chrome default run id."
Assert-Equal $ChromeDefault.browserName "windows-chrome" "Chrome wrapper browser name."
Assert-Equal $ChromeDefault.outputs.outputPath "assets/demo/chrome-loop.json" "Chrome default output path."
Assert-Equal $ChromeDefault.outputs.screenshotDir "assets/demo/windows-chrome-screens" "Chrome default screenshot path."
Assert-Equal $ChromeDefault.outputs.expectedScreenshotDir "assets/demo/windows-chrome-screens/" "Chrome default validator screenshot path."
Assert-Equal $ChromeDefault.options.chromePathMode "auto-detect" "Chrome default path mode."
Assert-Equal $ChromeDefault.sharedStateLock.name "Global\HCEdgeBrowserLoopGate" "Chrome shared-state lock name."
Assert-Equal $ChromeDefault.sharedStateLock.timeoutSeconds 1200 "Chrome default shared-state lock timeout."

$ChromeRelative = Invoke-Plan -ScriptName "check-chrome-loop.ps1" -Arguments @(
  "-OutputPath",
  ".\assets\tmp\chrome-wrapper-selftest.json",
  "-ScreenshotDir",
  ".\assets\tmp\chrome-wrapper-selftest-screens",
  "-SharedStateLockTimeoutSeconds",
  "42",
  "-ChromePath",
  "C:\Chrome\chrome.exe",
  "-Headed"
)
Assert-StartsWith $ChromeRelative.runId "chrome-loop-" "Chrome relative run id."
Assert-Equal $ChromeRelative.outputs.outputPath "assets/tmp/chrome-wrapper-selftest.json" "Chrome relative output path."
Assert-Equal $ChromeRelative.outputs.screenshotDir "assets/tmp/chrome-wrapper-selftest-screens" "Chrome relative screenshot path."
Assert-Equal $ChromeRelative.outputs.expectedScreenshotDir "assets/tmp/chrome-wrapper-selftest-screens/" "Chrome relative validator screenshot path."
Assert-Equal $ChromeRelative.options.chromePathMode "explicit" "Chrome explicit path mode."
Assert-Equal $ChromeRelative.options.headed $true "Chrome headed flag."
Assert-Equal $ChromeRelative.sharedStateLock.timeoutSeconds 42 "Chrome custom shared-state lock timeout."

New-Item -ItemType Directory -Force -Path $LockSelftestDir | Out-Null
$FakeChromePath = Join-Path $LockSelftestDir "fake-chrome.exe"
if (-not (Test-Path -LiteralPath $FakeChromePath -PathType Leaf)) {
  New-Item -ItemType File -Path $FakeChromePath | Out-Null
}

Assert-LockTimeout `
  -ScriptName "check-desktop-loop.ps1" `
  -OutputPath (Join-Path $LockSelftestDir "desktop-timeout.json") `
  -ScreenshotDir (Join-Path $LockSelftestDir "desktop-timeout-screens")

Assert-LockTimeout `
  -ScriptName "check-chrome-loop.ps1" `
  -OutputPath (Join-Path $LockSelftestDir "chrome-timeout.json") `
  -ScreenshotDir (Join-Path $LockSelftestDir "chrome-timeout-screens") `
  -ExtraArguments @("-ChromePath", $FakeChromePath)

Write-Host "Browser wrapper path self-test passed."
