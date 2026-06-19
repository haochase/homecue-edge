param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [switch]$IncludePhone,
  [switch]$IncludeChrome,
  [switch]$SkipDesktop,
  [int]$StartupTimeoutSeconds = 60,
  [int]$StepTimeoutSeconds = 180,
  [string]$ReportPath = "",
  [string]$SummaryPath = ""
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"
$WebDir = Join-Path $Root "apps\web"
$ApiPort = [System.Uri]$ApiBase | Select-Object -ExpandProperty Port
$WebPort = [System.Uri]$AppUrl | Select-Object -ExpandProperty Port
$FullLoopRunId = "full-loop-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), ([guid]::NewGuid().ToString("N").Substring(0, 8))

if (-not $ReportPath) {
  $ReportPath = Join-Path $Root "assets\demo\full-loop-report.md"
}
elseif (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
  $ReportPath = Join-Path $Root $ReportPath
}

if (-not $SummaryPath) {
  $SummaryPath = Join-Path $Root "assets\demo\full-loop-report.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($SummaryPath)) {
  $SummaryPath = Join-Path $Root $SummaryPath
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
  $Client = $null

  try {
    $Client = New-Object System.Net.WebClient
    $Client.Encoding = [System.Text.Encoding]::UTF8
    $Client.Headers["Content-Type"] = "application/json; charset=utf-8"
    $Text = $Client.UploadString("$ApiBase/vision/scene", "POST", $Body)
    $Result = $Text | ConvertFrom-Json
    $ExpectedPromptText = [string]::Concat([char]0x4f4e, [char]0x8d1f, [char]0x62c5)
    return $Result.scene -eq "low-energy evening arrival" -and $Result.suggested_prompt.Contains($ExpectedPromptText)
  }
  catch {
    return $false
  }
  finally {
    if ($Client) {
      $Client.Dispose()
    }
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
    [string[]]$Arguments,
    [int]$TimeoutSeconds = $StepTimeoutSeconds
  )

  $Process = New-Object System.Diagnostics.Process
  $Process.StartInfo.FileName = "powershell"
  $Process.StartInfo.Arguments = Join-ProcessArguments $Arguments
  $Process.StartInfo.WorkingDirectory = $Root
  $Process.StartInfo.UseShellExecute = $false
  $Process.StartInfo.RedirectStandardOutput = $true
  $Process.StartInfo.RedirectStandardError = $true
  $Process.StartInfo.CreateNoWindow = $true

  [void]$Process.Start()

  if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-ProcessTree -ProcessId $Process.Id
    Write-ScriptLogText -Text $Process.StandardOutput.ReadToEnd()
    Write-ScriptLogText -Text $Process.StandardError.ReadToEnd()
    throw "$Name timed out after $TimeoutSeconds seconds."
  }

  Write-ScriptLogText -Text $Process.StandardOutput.ReadToEnd()
  Write-ScriptLogText -Text $Process.StandardError.ReadToEnd()

  if ($Process.ExitCode -ne 0) {
    throw "$Name failed with exit code $($Process.ExitCode)."
  }
}

function Join-ProcessArguments {
  param([string[]]$Arguments)

  return (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " ")
}

function ConvertTo-ProcessArgument {
  param([string]$Value)

  if ($null -eq $Value -or $Value -eq "") {
    return '""'
  }

  if ($Value -notmatch '[\s"]') {
    return $Value
  }

  return '"' + ($Value -replace '"', '\"') + '"'
}

function Stop-ProcessTree {
  param([int]$ProcessId)

  $Children = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ProcessId })
  foreach ($Child in $Children) {
    Stop-ProcessTree -ProcessId $Child.ProcessId
  }

  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Write-ScriptLogText {
  param([string]$Text)

  if ($Text) {
    Write-Host $Text.TrimEnd()
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

$env:FULL_LOOP_RUN_ID = $FullLoopRunId
Write-Host "Full loop run id: $FullLoopRunId"

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
  $ReportArgs += $SummaryPath

  npm run report:loop -- @ReportArgs
  if ($LASTEXITCODE -ne 0) {
    throw "report:loop failed."
  }

  $SummaryCheckArgs = @($SummaryPath)
  if ($IncludePhone) {
    $SummaryCheckArgs += "--require-phone"
  }
  if ($IncludeChrome) {
    $SummaryCheckArgs += "--require-chrome"
  }

  npm run summary:check -- @SummaryCheckArgs
  if ($LASTEXITCODE -ne 0) {
    throw "summary:check failed."
  }

  if ($IncludeChrome) {
    npm run desktop:evidence:selftest
    if ($LASTEXITCODE -ne 0) {
      throw "desktop:evidence:selftest failed."
    }

    npm run summary:selftest
    if ($LASTEXITCODE -ne 0) {
      throw "summary:selftest failed."
    }
  }
}
finally {
  Remove-Item Env:\FULL_LOOP_RUN_ID -ErrorAction SilentlyContinue
  Pop-Location
}

Write-Host "Full loop check complete."
