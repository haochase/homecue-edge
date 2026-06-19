param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$WebDir = Join-Path $Root "apps\web"

if (-not $OutputPath) {
  $OutputPath = Join-Path $Root "assets\demo\desktop-loop.json"
}

Invoke-RestMethod "$ApiBase/health" | Out-Null

Push-Location $WebDir
try {
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
    "assets/demo/playwright-chromium-screens/"
  )
  npm run desktop:evidence:check -- @EvidenceCheckArgs
  if ($LASTEXITCODE -ne 0) {
    throw "desktop:evidence:check failed."
  }
}
finally {
  Pop-Location
}

Write-Host "Desktop loop evidence: $OutputPath"
