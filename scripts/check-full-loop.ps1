param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [switch]$IncludePhone,
  [switch]$IncludeChrome,
  [switch]$SkipDesktop,
  [int]$StartupTimeoutSeconds = 60,
  [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"
$WebDir = Join-Path $Root "apps\web"
$ApiPort = [System.Uri]$ApiBase | Select-Object -ExpandProperty Port
$WebPort = [System.Uri]$AppUrl | Select-Object -ExpandProperty Port

if (-not $ReportPath) {
  $ReportPath = Join-Path $Root "assets\demo\full-loop-report.md"
}
elseif (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
  $ReportPath = Join-Path $Root $ReportPath
}

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

function Wait-PortClosed {
  param([int]$Port)

  $Deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $Deadline) {
    if (-not (Test-PortListening $Port)) {
      return
    }
    Start-Sleep -Milliseconds 300
  }

  throw "Port $Port did not close after stopping the stale API process."
}

function Test-PortListening {
  param([int]$Port)

  $Connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  return $null -ne $Connection
}

function Test-ApiVisionContract {
  $Body = '{"room":"living room","camera":"phone","text_hint":"\u665a\u4e0a\u6709\u70b9\u7d2f\uff0c\u5750\u5728\u5ba2\u5385\u6c99\u53d1\u4e0a\uff0c\u5ba4\u5185\u5149\u7ebf\u504f\u6697"}'

  try {
    $Result = Invoke-RestMethod "$ApiBase/vision/scene" -Method Post -ContentType "application/json; charset=utf-8" -Body $Body -TimeoutSec 5
    return $Result.scene -eq "low-energy evening arrival" -and $Result.suggested_prompt -match "settling in after a tiring day"
  }
  catch {
    return $false
  }
}

function Stop-StaleApiIfManaged {
  $Connections = @(Get-NetTCPConnection -LocalPort $ApiPort -State Listen -ErrorAction SilentlyContinue)
  if ($Connections.Count -eq 0) {
    return
  }

  $ProcessId = $Connections[0].OwningProcess
  $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
  $CommandLine = $ProcessInfo.CommandLine

  if ($CommandLine -match "uvicorn" -and $CommandLine -match "app\.main:app") {
    Write-Warning "API on port $ApiPort failed the vision contract; restarting stale uvicorn process $ProcessId."
    Stop-Process -Id $ProcessId -Force
    Wait-PortClosed $ApiPort
    return
  }

  throw "API on port $ApiPort failed the vision contract and is not a managed uvicorn app: $CommandLine"
}

function Start-Api {
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

function Invoke-CheckedScript {
  param(
    [string]$Name,
    [string[]]$Arguments
  )

  & powershell @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed with exit code $LASTEXITCODE."
  }
}

function Ensure-Api {
  if (Test-HttpOk "$ApiBase/health") {
    Write-Host "API already running: $ApiBase"
    if (Test-ApiVisionContract) {
      Write-Host "API vision contract ready."
      return
    }

    Stop-StaleApiIfManaged
  }

  Start-Api
  if (-not (Test-ApiVisionContract)) {
    throw "API started, but /vision/scene did not pass the Chinese scene contract."
  }
  Write-Host "API vision contract ready."
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
  Invoke-CheckedScript "desktop loop" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\check-desktop-loop.ps1", "-AppUrl", $AppUrl, "-ApiBase", $ApiBase)
}

if ($IncludePhone) {
  Invoke-CheckedScript "phone loop" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\check-phone-loop.ps1", "-AppUrl", $AppUrl, "-ApiBase", $ApiBase)
}

if ($IncludeChrome) {
  Invoke-CheckedScript "chrome loop" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\check-chrome-loop.ps1", "-AppUrl", $AppUrl, "-ApiBase", $ApiBase)
}

Push-Location $WebDir
try {
  if ($SkipDesktop) {
    $DesktopEvidencePath = "__desktop_not_run__.json"
  }
  else {
    $DesktopEvidencePath = Join-Path $Root "assets\demo\desktop-loop.json"
  }

  $ReportArgs = @($ReportPath, $DesktopEvidencePath)
  if ($IncludePhone) {
    $ReportArgs += (Join-Path $Root "assets\demo\phone-loop.json")
  }
  else {
    $ReportArgs += "__phone_not_run__.json"
  }
  $ReportArgs += (Join-Path $Root "assets\demo\desktop-screens")
  if ($IncludeChrome) {
    $ReportArgs += (Join-Path $Root "assets\demo\chrome-loop.json")
  }
  else {
    $ReportArgs += "__chrome_not_run__.json"
  }

  npm run report:loop -- @ReportArgs
  if ($LASTEXITCODE -ne 0) {
    throw "report:loop failed."
  }
}
finally {
  Pop-Location
}

Write-Host "Full loop check complete."
