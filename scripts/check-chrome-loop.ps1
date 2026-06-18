param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputPath = "",
  [string]$ChromePath = "",
  [switch]$Headed
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$WebDir = Join-Path $Root "apps\web"

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

if (-not $OutputPath) {
  $OutputPath = Join-Path $Root "assets\demo\chrome-loop.json"
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

  npm run desktop:loop -- $OutputPath $AppUrl $ApiBase
  if ($LASTEXITCODE -ne 0) {
    throw "chrome desktop:loop failed."
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
  Pop-Location
}

Write-Host "Chrome loop evidence: $OutputPath"
