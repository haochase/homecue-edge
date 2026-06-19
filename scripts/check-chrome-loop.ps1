param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputPath = "",
  [string]$ScreenshotDir = "",
  [string]$ChromePath = "",
  [int]$SharedStateLockTimeoutSeconds = 1200,
  [switch]$Headed,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$WebDir = Join-Path $Root "apps\web"
$SharedStateLockName = "Global\HCEdgeBrowserLoopGate"

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

function Get-ChromeSourceKind {
  param(
    [Parameter(Mandatory = $true)][string]$Path
  )

  $FullPath = [System.IO.Path]::GetFullPath($Path)

  if (Test-PathInside -ChildPath $FullPath -ParentPath ${env:ProgramFiles(x86)}) {
    return "program-files-x86"
  }
  if (Test-PathInside -ChildPath $FullPath -ParentPath $env:ProgramFiles) {
    return "program-files"
  }
  if (Test-PathInside -ChildPath $FullPath -ParentPath $env:LOCALAPPDATA) {
    return "local-app-data"
  }

  return "custom-path"
}

function Test-PathInside {
  param(
    [Parameter(Mandatory = $true)][string]$ChildPath,
    [string]$ParentPath
  )

  if (-not $ParentPath) {
    return $false
  }

  $ParentFullPath = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([char[]]@("\", "/"))
  $ParentPrefix = $ParentFullPath + [System.IO.Path]::DirectorySeparatorChar

  return $ChildPath.StartsWith($ParentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
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
  $OutputPath = Join-Path $Root "assets\demo\chrome-loop.json"
}
else {
  $OutputPath = Resolve-RootedPath $OutputPath
}
if (-not $ScreenshotDir) {
  $ScreenshotDir = Join-Path $Root "assets\demo\windows-chrome-screens"
}
else {
  $ScreenshotDir = Resolve-RootedPath $ScreenshotDir
}
$ExpectedScreenshotDir = Convert-ToRepoRelativeDir -Path $ScreenshotDir

if ($DryRun) {
  [pscustomobject]@{
    appUrl = $AppUrl
    apiBase = $ApiBase
    browserName = "windows-chrome"
    dryRun = $true
    options = [pscustomobject]@{
      headed = [bool]$Headed
      chromePathMode = if ([string]::IsNullOrWhiteSpace($ChromePath)) { "auto-detect" } else { "explicit" }
    }
    sharedStateLock = [pscustomobject]@{
      name = $SharedStateLockName
      timeoutSeconds = $SharedStateLockTimeoutSeconds
    }
    outputs = [pscustomobject]@{
      outputPath = Convert-ToPlanPath $OutputPath
      screenshotDir = Convert-ToPlanPath $ScreenshotDir
      expectedScreenshotDir = $ExpectedScreenshotDir
    }
  } | ConvertTo-Json -Depth 5
  exit 0
}

if (-not $ChromePath) {
  $Candidates = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
  )
  $ChromePath = $Candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

if (-not $ChromePath -or -not (Test-Path -LiteralPath $ChromePath)) {
  throw "Chrome executable not found. Pass -ChromePath with the path to chrome.exe."
}

$ChromeItem = Get-Item -LiteralPath $ChromePath
$ChromeVersion = $ChromeItem.VersionInfo

Invoke-WithSharedStateLock {
  Invoke-RestMethod "$ApiBase/health" | Out-Null

  Push-Location $WebDir
  try {
    $env:DESKTOP_LOOP_BROWSER_NAME = "windows-chrome"
    $env:DESKTOP_LOOP_EXECUTABLE_PATH = $ChromePath
    $env:DESKTOP_LOOP_EXECUTABLE_FILE_NAME = $ChromeItem.Name
    $env:DESKTOP_LOOP_EXECUTABLE_SOURCE = Get-ChromeSourceKind -Path $ChromeItem.FullName
    $env:DESKTOP_LOOP_EXECUTABLE_PRODUCT_NAME = $ChromeVersion.ProductName
    $env:DESKTOP_LOOP_EXECUTABLE_COMPANY_NAME = $ChromeVersion.CompanyName
    $env:DESKTOP_LOOP_EXECUTABLE_PRODUCT_VERSION = $ChromeVersion.ProductVersion
    $env:DESKTOP_LOOP_HEADED = if ($Headed) { "true" } else { "false" }
    $env:DESKTOP_LOOP_SCREENSHOT_DIR = $ScreenshotDir

    npm run desktop:loop -- $OutputPath $AppUrl $ApiBase
    if ($LASTEXITCODE -ne 0) {
      throw "chrome desktop:loop failed."
    }

    $EvidenceCheckArgs = @(
      $OutputPath,
      "--browser-name",
      "windows-chrome",
      "--executable-path",
      "custom",
      "--screenshot-dir",
      $ExpectedScreenshotDir,
      "--require-installed-chrome"
    )
    npm run desktop:evidence:check -- @EvidenceCheckArgs
    if ($LASTEXITCODE -ne 0) {
      throw "chrome desktop:evidence:check failed."
    }
  }
  finally {
    Remove-Item Env:\DESKTOP_LOOP_BROWSER_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_EXECUTABLE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_EXECUTABLE_FILE_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_EXECUTABLE_SOURCE -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_EXECUTABLE_PRODUCT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_EXECUTABLE_COMPANY_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_EXECUTABLE_PRODUCT_VERSION -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_HEADED -ErrorAction SilentlyContinue
    Remove-Item Env:\DESKTOP_LOOP_SCREENSHOT_DIR -ErrorAction SilentlyContinue
    Pop-Location
  }
}

Write-Host "Chrome loop evidence: $OutputPath"
