param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputPath = "",
  [string]$ScreenshotDir = "",
  [int]$SharedStateLockTimeoutSeconds = 1200,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$WebDir = Join-Path $Root "apps\web"
$SharedStateLockName = "Global\HCEdgeBrowserLoopGate"
$DesktopLoopRunId = if ($env:FULL_LOOP_RUN_ID) {
  $env:FULL_LOOP_RUN_ID
}
else {
  "desktop-loop-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), ([guid]::NewGuid().ToString("N").Substring(0, 8))
}

function Resolve-RootedPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return Join-Path $Root $Path
}

function Convert-ToPlanPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $RootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $RootPrefix = $RootPath + [System.IO.Path]::DirectorySeparatorChar

  if ($FullPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $FullPath.Substring($RootPrefix.Length).Replace("\", "/")
  }

  return $FullPath
}

function Convert-ToRepoRelativeDir {
  param([string]$Path)

  $FullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
  $RootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $RootPrefix = $RootPath + [System.IO.Path]::DirectorySeparatorChar

  if (-not $FullPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ScreenshotDir must be inside the repository root: $Path"
  }

  return ($FullPath.Substring($RootPrefix.Length).Replace("\", "/").TrimEnd("/") + "/")
}

function Invoke-WithSharedStateLock {
  param([scriptblock]$Body)

  $Mutex = New-Object System.Threading.Mutex($false, $SharedStateLockName)
  $HasLock = $false

  try {
    Write-Host "Waiting for browser loop shared-state lock: $SharedStateLockName"
    $HasLock = $Mutex.WaitOne([TimeSpan]::FromSeconds($SharedStateLockTimeoutSeconds))
    if (-not $HasLock) {
      throw "Timed out waiting for browser loop shared-state lock after $SharedStateLockTimeoutSeconds seconds."
    }

    & $Body
  }
  finally {
    if ($HasLock) {
      $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
  }
}

if (-not $OutputPath) {
  $OutputPath = Join-Path $Root "assets\demo\desktop-loop.json"
}
else {
  $OutputPath = Resolve-RootedPath $OutputPath
}
if (-not $ScreenshotDir) {
  $ScreenshotDir = Join-Path $Root "assets\demo\playwright-chromium-screens"
}
else {
  $ScreenshotDir = Resolve-RootedPath $ScreenshotDir
}
$ExpectedScreenshotDir = Convert-ToRepoRelativeDir -Path $ScreenshotDir

if ($DryRun) {
  [pscustomobject]@{
    runId = $DesktopLoopRunId
    appUrl = $AppUrl
    apiBase = $ApiBase
    browserName = "playwright-chromium"
    dryRun = $true
    outputs = [pscustomobject]@{
      outputPath = Convert-ToPlanPath $OutputPath
      screenshotDir = Convert-ToPlanPath $ScreenshotDir
      expectedScreenshotDir = $ExpectedScreenshotDir
    }
    sharedStateLock = [pscustomobject]@{
      name = $SharedStateLockName
      timeoutSeconds = $SharedStateLockTimeoutSeconds
    }
  } | ConvertTo-Json -Depth 5
  exit 0
}

Invoke-WithSharedStateLock {
  Invoke-RestMethod "$ApiBase/health" | Out-Null

  Push-Location $WebDir
  $PreviousDesktopLoopRunId = $env:DESKTOP_LOOP_RUN_ID
  try {
    $env:DESKTOP_LOOP_RUN_ID = $DesktopLoopRunId
    $env:DESKTOP_LOOP_SCREENSHOT_DIR = $ScreenshotDir
    npm run desktop:loop -- $OutputPath $AppUrl $ApiBase
    if ($LASTEXITCODE -ne 0) {
      throw "desktop:loop failed."
    }

    $EvidenceCheckArgs = @(
      $OutputPath,
      "--browser-name",
      "playwright-chromium",
      "--executable-path",
      "bundled",
      "--screenshot-dir",
      $ExpectedScreenshotDir
    )
    npm run desktop:evidence:check -- @EvidenceCheckArgs
    if ($LASTEXITCODE -ne 0) {
      throw "desktop:evidence:check failed."
    }
  }
  finally {
    if ($null -ne $PreviousDesktopLoopRunId) {
      $env:DESKTOP_LOOP_RUN_ID = $PreviousDesktopLoopRunId
    }
    else {
      Remove-Item Env:\DESKTOP_LOOP_RUN_ID -ErrorAction SilentlyContinue
    }
    Remove-Item Env:\DESKTOP_LOOP_SCREENSHOT_DIR -ErrorAction SilentlyContinue
    Pop-Location
  }
}

Write-Host "Desktop loop evidence: $OutputPath"
