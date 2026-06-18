param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [switch]$IncludePhone,
  [switch]$SkipDesktop,
  [int]$StartupTimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"
$WebDir = Join-Path $Root "apps\web"
$ApiPort = [System.Uri]$ApiBase | Select-Object -ExpandProperty Port
$WebPort = [System.Uri]$AppUrl | Select-Object -ExpandProperty Port

function Test-HttpOk {
  param([string]$Url)

  try {
    Invoke-RestMethod $Url -TimeoutSec 3 | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

function Wait-HttpOk {
  param(
    [string]$Url,
    [string]$Name
  )

  $Deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
  while ((Get-Date) -lt $Deadline) {
    if (Test-HttpOk $Url) {
      Write-Host "$Name ready: $Url"
      return
    }
    Start-Sleep -Milliseconds 700
  }

  throw "$Name did not become ready within $StartupTimeoutSeconds seconds: $Url"
}

function Test-PortListening {
  param([int]$Port)

  $Connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  return $null -ne $Connection
}

function Ensure-Api {
  if (Test-HttpOk "$ApiBase/health") {
    Write-Host "API already running: $ApiBase"
    return
  }

  if (-not (Test-Path (Join-Path $ApiDir ".venv"))) {
    Push-Location $ApiDir
    try {
      python -m venv .venv
      .\.venv\Scripts\python.exe -m pip install -r requirements.txt
    }
    finally {
      Pop-Location
    }
  }

  Write-Host "Starting API on port $ApiPort..."
  Start-Process `
    -FilePath (Join-Path $ApiDir ".venv\Scripts\python.exe") `
    -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$ApiPort" `
    -WorkingDirectory $ApiDir `
    -WindowStyle Hidden

  Wait-HttpOk "$ApiBase/health" "API"
}

function Ensure-Web {
  if (Test-PortListening $WebPort) {
    Write-Host "Web server already listening: $AppUrl"
    return
  }

  Write-Host "Starting web dev server on port $WebPort..."
  Start-Process `
    -FilePath "npm.cmd" `
    -ArgumentList @("run", "dev", "--", "--host", "127.0.0.1", "--port", "$WebPort") `
    -WorkingDirectory $WebDir `
    -WindowStyle Hidden

  Wait-HttpOk $AppUrl "Web"
}

Ensure-Api
Ensure-Web

if (-not $SkipDesktop) {
  powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-desktop-loop.ps1" -AppUrl $AppUrl -ApiBase $ApiBase
}

if ($IncludePhone) {
  powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-phone-loop.ps1" -AppUrl $AppUrl -ApiBase $ApiBase
}

Write-Host "Full loop check complete."
