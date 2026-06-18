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
}
finally {
  Pop-Location
}

Write-Host "Desktop loop evidence: $OutputPath"
