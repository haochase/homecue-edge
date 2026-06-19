param(
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [switch]$IncludePhone,
  [switch]$IncludeChrome,
  [switch]$SkipDesktop,
  [switch]$SkipPreflight,
  [switch]$DryRun,
  [int]$StartupTimeoutSeconds = 60,
  [int]$StepTimeoutSeconds = 180,
  [string]$ReportPath = "",
  [string]$SummaryPath = "",
  [string]$AdbPath = "",
  [string]$PartialEvidenceDir = "",
  [int]$BrowserWrapperSharedStateLockTimeoutSeconds = 1200
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"
$WebDir = Join-Path $Root "apps\web"
$ApiPort = [System.Uri]$ApiBase | Select-Object -ExpandProperty Port
$WebPort = [System.Uri]$AppUrl | Select-Object -ExpandProperty Port
$FullLoopRunId = "full-loop-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), ([guid]::NewGuid().ToString("N").Substring(0, 8))
$IsPartialEvidenceRun = $SkipDesktop -or (-not $IncludePhone) -or (-not $IncludeChrome)
if (-not $PartialEvidenceDir) {
  $PartialEvidenceDir = Join-Path $Root ("assets\tmp\full-loop-partial\{0}" -f $FullLoopRunId)
}
elseif (-not [System.IO.Path]::IsPathRooted($PartialEvidenceDir)) {
  $PartialEvidenceDir = Join-Path $Root $PartialEvidenceDir
}
$PreflightJsonPath = if ($IsPartialEvidenceRun) {
  Join-Path $PartialEvidenceDir "dev-env-check.json"
} else {
  Join-Path $Root "assets\tmp\dev-env-check.json"
}
$PreflightEvidencePath = $PreflightJsonPath
$WebReadinessEvidencePath = Join-Path $PartialEvidenceDir "web-readiness.json"
$ReportPathProvided = -not [string]::IsNullOrWhiteSpace($ReportPath)
$SummaryPathProvided = -not [string]::IsNullOrWhiteSpace($SummaryPath)

function Get-DefaultAdbCandidates {
  $Candidates = New-Object System.Collections.Generic.List[string]
  $LocalAppDataValues = @(
    $env:LOCALAPPDATA,
    [Environment]::GetFolderPath("LocalApplicationData")
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($LocalAppData in $LocalAppDataValues) {
    $Candidates.Add([System.IO.Path]::Combine($LocalAppData, "Android", "Sdk", "platform-tools", "adb.exe"))
  }

  $PathAdb = Get-Command "adb.exe" -ErrorAction SilentlyContinue
  if ($PathAdb -and $PathAdb.Source) {
    $Candidates.Add($PathAdb.Source)
  }

  return @($Candidates.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Resolve-AdbExecutable {
  param([string]$ExplicitPath)

  $Candidates = if ([string]::IsNullOrWhiteSpace($ExplicitPath)) {
    @(Get-DefaultAdbCandidates)
  } else {
    @($ExplicitPath)
  }

  foreach ($Candidate in $Candidates) {
    if (Test-Path -LiteralPath $Candidate) {
      return (Get-Item -LiteralPath $Candidate).FullName
    }
  }

  if ($Candidates.Count -gt 0) {
    return $Candidates[0]
  }

  return ""
}

if ($IncludePhone) {
  $AdbPath = Resolve-AdbExecutable -ExplicitPath $AdbPath
}

if ($IsPartialEvidenceRun) {
  $DesktopEvidenceFile = Join-Path $PartialEvidenceDir "desktop-loop.json"
  $PhoneEvidenceFile = Join-Path $PartialEvidenceDir "phone-loop.json"
  $ChromeEvidenceFile = Join-Path $PartialEvidenceDir "chrome-loop.json"
  $DesktopScreenshotDir = Join-Path $PartialEvidenceDir "playwright-chromium-screens"
  $ChromeScreenshotDir = Join-Path $PartialEvidenceDir "windows-chrome-screens"
}
else {
  $DesktopEvidenceFile = Join-Path $Root "assets\demo\desktop-loop.json"
  $PhoneEvidenceFile = Join-Path $Root "assets\demo\phone-loop.json"
  $ChromeEvidenceFile = Join-Path $Root "assets\demo\chrome-loop.json"
  $DesktopScreenshotDir = Join-Path $Root "assets\demo\playwright-chromium-screens"
  $ChromeScreenshotDir = Join-Path $Root "assets\demo\windows-chrome-screens"
}

if (-not $ReportPathProvided) {
  $ReportPath = if ($IsPartialEvidenceRun) {
    Join-Path $PartialEvidenceDir "full-loop-report.md"
  } else {
    Join-Path $Root "assets\demo\full-loop-report.md"
  }
}
elseif (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
  $ReportPath = Join-Path $Root $ReportPath
}

if (-not $SummaryPathProvided) {
  $SummaryPath = if ($ReportPathProvided) {
    [System.IO.Path]::ChangeExtension($ReportPath, ".json")
  } elseif ($IsPartialEvidenceRun) {
    Join-Path $PartialEvidenceDir "full-loop-report.json"
  } else {
    Join-Path $Root "assets\demo\full-loop-report.json"
  }
}
elseif (-not [System.IO.Path]::IsPathRooted($SummaryPath)) {
  $SummaryPath = Join-Path $Root $SummaryPath
}

function Convert-ToPlanPath {
  param([string]$Path)

  if (-not $Path -or $Path.StartsWith("__")) {
    return $Path
  }

  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $RootPath = [System.IO.Path]::GetFullPath([string]$Root).TrimEnd("\", "/")
  $RootPrefix = $RootPath + [System.IO.Path]::DirectorySeparatorChar

  if ($FullPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $FullPath.Substring($RootPrefix.Length).Replace("\", "/")
  }

  return $FullPath
}

function New-FullLoopPlan {
  $DesktopEvidencePath = if ($SkipDesktop) { "__desktop_not_run__.json" } else { $DesktopEvidenceFile }
  $PhoneEvidencePath = if ($IncludePhone) { $PhoneEvidenceFile } else { "__phone_not_run__.json" }
  $ChromeEvidencePath = if ($IncludeChrome) { $ChromeEvidenceFile } else { "__chrome_not_run__.json" }
  $ResolvedPreflightEvidencePath = if ($SkipPreflight) { "__dev_env_not_run__.json" } else { $PreflightEvidencePath }
  $RunGlobalEvidenceSelfTests = (-not $SkipDesktop) -and $IncludePhone -and $IncludeChrome

  return [pscustomobject]@{
    runId = $FullLoopRunId
    partialEvidenceRun = [bool]$IsPartialEvidenceRun
    requestedLoops = [pscustomobject]@{
      desktop = -not [bool]$SkipDesktop
      phone = [bool]$IncludePhone
      windowsChrome = [bool]$IncludeChrome
    }
    options = [pscustomobject]@{
      skipPreflight = [bool]$SkipPreflight
      reportPathProvided = [bool]$ReportPathProvided
      summaryPathProvided = [bool]$SummaryPathProvided
    }
    outputs = [pscustomobject]@{
      partialEvidenceDir = Convert-ToPlanPath $PartialEvidenceDir
      reportPath = Convert-ToPlanPath $ReportPath
      summaryPath = Convert-ToPlanPath $SummaryPath
      preflightJsonPath = Convert-ToPlanPath $PreflightJsonPath
      preflightEvidencePath = Convert-ToPlanPath $ResolvedPreflightEvidencePath
      webReadinessEvidencePath = Convert-ToPlanPath $WebReadinessEvidencePath
    }
    evidence = [pscustomobject]@{
      desktopJson = Convert-ToPlanPath $DesktopEvidencePath
      phoneJson = Convert-ToPlanPath $PhoneEvidencePath
      windowsChromeJson = Convert-ToPlanPath $ChromeEvidencePath
      desktopScreenshotDir = Convert-ToPlanPath $DesktopScreenshotDir
      windowsChromeScreenshotDir = Convert-ToPlanPath $ChromeScreenshotDir
    }
    gates = [pscustomobject]@{
      preflightRun = -not [bool]$SkipPreflight
      summaryAllowSkipDesktop = [bool]$SkipDesktop
      summaryRequirePhone = [bool]$IncludePhone
      summaryRequireChrome = [bool]$IncludeChrome
      reportSelftest = [bool]$RunGlobalEvidenceSelfTests
      phoneSelftest = [bool]($IncludePhone -and (-not $SkipDesktop))
      desktopAndSummarySelftests = [bool]($IncludeChrome -and (-not $SkipDesktop))
      browserWrapperSharedStateLock = [pscustomobject]@{
        name = "Global\HCEdgeBrowserLoopGate"
        timeoutSeconds = $BrowserWrapperSharedStateLockTimeoutSeconds
      }
      webReadiness = [pscustomobject]@{
        httpProbeBeforePortReuse = $true
        stalePortBlocksDuplicateStart = $true
      }
    }
  }
}

if ($DryRun) {
  New-FullLoopPlan | ConvertTo-Json -Depth 8
  exit 0
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

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )

  $ResultDir = Split-Path -Parent $Path
  if ($ResultDir) {
    New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null
  }

  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $Utf8NoBom)
}

function Write-WebReadinessEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$Strategy,
    [Parameter(Mandatory = $true)][bool]$PortListeningBefore,
    [Parameter(Mandatory = $true)][bool]$HttpReadyBefore
  )

  Write-JsonFile -Path $WebReadinessEvidencePath -Value ([pscustomobject]@{
      generatedAt = (Get-Date).ToUniversalTime().ToString("o")
      runId = $FullLoopRunId
      appUrl = $AppUrl
      webPort = $WebPort
      strategy = $Strategy
      portListeningBefore = $PortListeningBefore
      httpReadyBefore = $HttpReadyBefore
      httpReadyAfter = [bool](Test-HttpOk $AppUrl)
      duplicateStartAvoided = [bool]($Strategy -in @("already-ready", "waited-on-stale-port"))
      gates = [pscustomobject]@{
        httpProbeBeforePortReuse = $true
        stalePortBlocksDuplicateStart = $true
      }
    })
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
  $PortListeningBefore = Test-PortListening $WebPort
  $HttpReadyBefore = Test-HttpOk $AppUrl

  if ($HttpReadyBefore) {
    Write-Host "Web already ready: $AppUrl"
    Write-WebReadinessEvidence -Strategy "already-ready" -PortListeningBefore $PortListeningBefore -HttpReadyBefore $HttpReadyBefore
    return
  }

  if ($PortListeningBefore) {
    Write-Warning "Web port $WebPort is listening, but $AppUrl is not HTTP-ready; waiting instead of starting a duplicate server."
    Wait-HttpOk $AppUrl "Web"
    Write-WebReadinessEvidence -Strategy "waited-on-stale-port" -PortListeningBefore $PortListeningBefore -HttpReadyBefore $HttpReadyBefore
    return
  }

  Write-Host "Starting web dev server on port $WebPort..."
  Start-Process `
    -FilePath "npm.cmd" `
    -ArgumentList @("run", "dev", "--", "--host", "127.0.0.1", "--port", "$WebPort") `
    -WorkingDirectory $WebDir `
    -WindowStyle Hidden

  Wait-HttpOk $AppUrl "Web"
  Write-WebReadinessEvidence -Strategy "started-new-server" -PortListeningBefore $PortListeningBefore -HttpReadyBefore $HttpReadyBefore
}

if (-not $SkipPreflight) {
  $PreflightArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "$PSScriptRoot\check-dev-env.ps1",
    "-Required",
    "-ResultJsonPath",
    $PreflightJsonPath
  )

  if ($IncludePhone) {
    $PreflightArgs += "-RequirePhone"
    if ($AdbPath) {
      $PreflightArgs += "-AdbPath"
      $PreflightArgs += $AdbPath
    }
  }

  Invoke-CheckedScript "development environment preflight" $PreflightArgs
}
else {
  $PreflightEvidencePath = "__dev_env_not_run__.json"
}

Ensure-Api
Ensure-Web

$env:FULL_LOOP_RUN_ID = $FullLoopRunId
Write-Host "Full loop run id: $FullLoopRunId"

if (-not $SkipDesktop) {
  Invoke-CheckedScript "desktop loop" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\check-desktop-loop.ps1", "-AppUrl", $AppUrl, "-ApiBase", $ApiBase, "-OutputPath", $DesktopEvidenceFile, "-ScreenshotDir", $DesktopScreenshotDir, "-SharedStateLockTimeoutSeconds", "$BrowserWrapperSharedStateLockTimeoutSeconds")
}

if ($IncludePhone) {
  $PhoneLoopArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\check-phone-loop.ps1", "-AppUrl", $AppUrl, "-ApiBase", $ApiBase, "-OutputPath", $PhoneEvidenceFile)
  if ($AdbPath) {
    $PhoneLoopArgs += "-AdbPath"
    $PhoneLoopArgs += $AdbPath
  }

  Invoke-CheckedScript "phone loop" $PhoneLoopArgs
}

if ($IncludeChrome) {
  Invoke-CheckedScript "chrome loop" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\check-chrome-loop.ps1", "-AppUrl", $AppUrl, "-ApiBase", $ApiBase, "-OutputPath", $ChromeEvidenceFile, "-ScreenshotDir", $ChromeScreenshotDir, "-SharedStateLockTimeoutSeconds", "$BrowserWrapperSharedStateLockTimeoutSeconds")
}

Push-Location $WebDir
try {
  if ($SkipDesktop) {
    $DesktopEvidencePath = "__desktop_not_run__.json"
  }
  else {
    $DesktopEvidencePath = $DesktopEvidenceFile
  }

  $ReportArgs = @($ReportPath, $DesktopEvidencePath)
  if ($IncludePhone) {
    $ReportArgs += $PhoneEvidenceFile
  }
  else {
    $ReportArgs += "__phone_not_run__.json"
  }
  $ReportArgs += $DesktopScreenshotDir
  if ($IncludeChrome) {
    $ReportArgs += $ChromeEvidenceFile
  }
  else {
    $ReportArgs += "__chrome_not_run__.json"
  }
  $ReportArgs += $SummaryPath
  $ReportArgs += $PreflightEvidencePath
  $ReportArgs += $WebReadinessEvidencePath

  npm run report:loop -- @ReportArgs
  if ($LASTEXITCODE -ne 0) {
    throw "report:loop failed."
  }

  $SummaryCheckArgs = @($SummaryPath)
  if ($SkipDesktop) {
    $SummaryCheckArgs += "--allow-skip-desktop"
  }
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

  $CanRunGlobalEvidenceSelfTests = (-not $SkipDesktop) -and $IncludePhone -and $IncludeChrome

  if ($CanRunGlobalEvidenceSelfTests) {
    npm run report:selftest
    if ($LASTEXITCODE -ne 0) {
      throw "report:selftest failed."
    }
  }
  else {
    Write-Host "Skipping report:selftest because this is not a complete desktop+phone+Chrome evidence run."
  }

  if ($IncludePhone -and (-not $SkipDesktop)) {
    npm run phone:evidence:selftest
    if ($LASTEXITCODE -ne 0) {
      throw "phone:evidence:selftest failed."
    }
  }
  elseif ($IncludePhone) {
    Write-Host "Skipping phone:evidence:selftest because desktop evidence was skipped."
  }

  if ($IncludeChrome -and (-not $SkipDesktop)) {
    npm run desktop:evidence:selftest
    if ($LASTEXITCODE -ne 0) {
      throw "desktop:evidence:selftest failed."
    }

    npm run summary:selftest -- $SummaryPath
    if ($LASTEXITCODE -ne 0) {
      throw "summary:selftest failed."
    }
  }
  elseif ($IncludeChrome) {
    Write-Host "Skipping desktop/summary self-tests because desktop evidence was skipped."
  }
}
finally {
  Remove-Item Env:\FULL_LOOP_RUN_ID -ErrorAction SilentlyContinue
  Pop-Location
}

Write-Host "Full loop check complete."
