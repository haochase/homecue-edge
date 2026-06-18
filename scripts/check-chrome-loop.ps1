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

Invoke-RestMethod "$ApiBase/health" | Out-Null

Push-Location $WebDir
try {
  $env:DESKTOP_LOOP_BROWSER_NAME = "windows-chrome"
  $env:DESKTOP_LOOP_EXECUTABLE_PATH = $ChromePath
  $env:DESKTOP_LOOP_HEADED = if ($Headed) { "true" } else { "false" }

  npm run desktop:loop -- $OutputPath $AppUrl $ApiBase
  if ($LASTEXITCODE -ne 0) {
    throw "chrome desktop:loop failed."
  }
}
finally {
  Remove-Item Env:\DESKTOP_LOOP_BROWSER_NAME -ErrorAction SilentlyContinue
  Remove-Item Env:\DESKTOP_LOOP_EXECUTABLE_PATH -ErrorAction SilentlyContinue
  Remove-Item Env:\DESKTOP_LOOP_HEADED -ErrorAction SilentlyContinue
  Pop-Location
}

Write-Host "Chrome loop evidence: $OutputPath"
