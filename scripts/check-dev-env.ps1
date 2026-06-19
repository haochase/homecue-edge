[CmdletBinding()]
param(
  [string]$AdbPath = "",
  [string]$ChromePath = "",
  [string]$ResultJsonPath = "",
  [switch]$Required,
  [switch]$RequirePhone
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"
$WebDir = Join-Path $Root "apps\web"
$ApiEnvExample = Join-Path $ApiDir ".env.example"
$ApiRequirements = Join-Path $ApiDir "requirements.txt"
$WebPackageJson = Join-Path $WebDir "package.json"
$WebPackageLock = Join-Path $WebDir "package-lock.json"

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

$AdbPath = Resolve-AdbExecutable -ExplicitPath $AdbPath

if (-not $ResultJsonPath) {
  $ResultJsonPath = Join-Path $Root "assets\tmp\dev-env-check.json"
} elseif (-not [System.IO.Path]::IsPathRooted($ResultJsonPath)) {
  $ResultJsonPath = Join-Path $Root $ResultJsonPath
}

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $false,
    [string]$Category = "host"
  )

  $Status = if ($Ok) { "OK" } elseif ($Required -and $RequiredCheck) { "FAIL" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)

  $Checks.Add([pscustomobject]@{
    name = $Name
    category = $Category
    ok = $Ok
    required = [bool]$RequiredCheck
    status = $Status
    detail = $Detail
  })

  if ($Required -and $RequiredCheck -and -not $Ok) {
    $Failures.Add($Name)
  }
}

function Get-CommandText {
  param([string]$CommandName)

  $Command = Get-Command $CommandName -ErrorAction SilentlyContinue
  if (-not $Command) {
    return $null
  }

  return $Command.Source
}

function Get-CommandOutput {
  param([string]$CommandName, [string[]]$Arguments)

  try {
    $Output = & $CommandName @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $null
    }
    return ($Output -join " ").Trim()
  }
  catch {
    return $null
  }
}

function Get-ChromeCandidate {
  param([string]$ExplicitPath)

  if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath)) {
    return (Get-Item -LiteralPath $ExplicitPath)
  }

  $Candidates = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
  )

  foreach ($Candidate in $Candidates) {
    if (Test-Path -LiteralPath $Candidate) {
      return (Get-Item -LiteralPath $Candidate)
    }
  }

  return $null
}

function Test-PortListening {
  param([int]$Port)

  try {
    $Connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return $null -ne $Connection
  }
  catch {
    return $false
  }
}

function Get-AuthorizedAndroidDevices {
  param([string]$Executable)

  try {
    & $Executable start-server 2>$null | Out-Null
  }
  catch {
    # `devices` below will surface the actual unavailable state.
  }

  $Deadline = (Get-Date).AddSeconds(15)
  do {
    try {
      $DeviceLines = @(& $Executable devices -l 2>$null)
      if ($LASTEXITCODE -eq 0) {
        $Devices = @($DeviceLines | Where-Object { [string]$_ -match "^\S+\s+device(?:\s|$)" })
        if ($Devices.Count -gt 0) {
          return $Devices
        }
      }

      $DeviceState = ((& $Executable get-state 2>$null) -join " ").Trim()
      if ($LASTEXITCODE -eq 0 -and $DeviceState -eq "device") {
        return @("adb default device")
      }
    }
    catch {
      # Keep retrying until the short deadline expires. ADB can briefly report
      # no devices while a phone is waking or an existing forward is settling.
    }

    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $Deadline)

  return @()
}

function Get-AdbFailureDetail {
  param([string]$Executable)

  $DevicesText = "unavailable"
  $StateText = "unavailable"

  try {
    $DeviceLines = @(& $Executable devices -l 2>$null)
    $DevicesText = (($DeviceLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | ").Trim()
    if (-not $DevicesText) {
      $DevicesText = "empty devices list"
    }
  }
  catch {
    $DevicesText = $_.Exception.Message
  }

  try {
    $StateText = ((& $Executable get-state 2>$null) -join " ").Trim()
    if (-not $StateText) {
      $StateText = "empty get-state"
    }
  }
  catch {
    $StateText = $_.Exception.Message
  }

  return "none detected; adb path: $Executable; devices: $DevicesText; get-state: $StateText"
}

Write-Host "HomeCue AI companion dev environment check"
Write-Host ("Repo: {0}" -f $Root)
Write-Host ""

$NodePath = Get-CommandText "node"
$NodeVersionText = Get-CommandOutput "node" @("--version")
$NodeMajor = $null
if ($NodeVersionText -match "^v?(\d+)\.") {
  $NodeMajor = [int]$Matches[1]
}
Add-Check "node" ($NodePath -and $NodeMajor -ge 20) $(if ($NodePath) { "$NodeVersionText ($NodePath)" } else { "not found" }) $true "host"

$NpmPath = Get-CommandText "npm"
$NpmVersionText = Get-CommandOutput "npm" @("--version")
Add-Check "npm" ($NpmPath -and $NpmVersionText) $(if ($NpmPath) { "$NpmVersionText ($NpmPath)" } else { "not found" }) $true "host"

Add-Check "api directory" (Test-Path -LiteralPath $ApiDir) $ApiDir $true "repo"
Add-Check "api requirements" (Test-Path -LiteralPath $ApiRequirements) $ApiRequirements $true "repo"
Add-Check "api env template" (Test-Path -LiteralPath $ApiEnvExample) $ApiEnvExample $true "repo"
Add-Check "web package" (Test-Path -LiteralPath $WebPackageJson) $WebPackageJson $true "repo"
Add-Check "web package lock" (Test-Path -LiteralPath $WebPackageLock) $WebPackageLock $true "repo"

$ChromeItem = Get-ChromeCandidate -ExplicitPath $ChromePath
if ($ChromeItem) {
  $ChromeVersion = $ChromeItem.VersionInfo.ProductVersion
  Add-Check "Windows Chrome" $true ("{0} {1}" -f $ChromeItem.Name, $ChromeVersion) $true "browser"
} else {
  Add-Check "Windows Chrome" $false "chrome.exe not found in standard locations" $true "browser"
}

Add-Check "API port 8723" (Test-PortListening 8723) "listening means an API may already be running" $false "network"
Add-Check "web port 5173" (Test-PortListening 5173) "listening means Vite may already be running" $false "network"
Add-Check "Android CDP port 9222" (Test-PortListening 9222) "listening means adb forward may already be active" $false "network"

$AdbFound = Test-Path -LiteralPath $AdbPath
Add-Check "adb.exe" $AdbFound $(if ($AdbFound) { $AdbPath } else { "not found: $AdbPath" }) $RequirePhone "phone"

if ($RequirePhone) {
  $AuthorizedDevices = @()
  if ($AdbFound) {
    $AuthorizedDevices = @(Get-AuthorizedAndroidDevices -Executable $AdbPath)
  }
  $AuthorizedDeviceDetail = if ($AuthorizedDevices.Count) {
    ($AuthorizedDevices -join "; ")
  } elseif ($AdbFound) {
    Get-AdbFailureDetail -Executable $AdbPath
  } else {
    "none detected"
  }
  Add-Check "authorized Android device" ($AuthorizedDevices.Count -gt 0) $AuthorizedDeviceDetail $true "phone"
}
else {
  Add-Check "authorized Android device" $true "skipped; pass -RequirePhone to require USB debugging authorization" $false "phone"
}

$Result = [pscustomobject]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  success = $Failures.Count -eq 0
  required = [bool]$Required
  requirePhone = [bool]$RequirePhone
  checks = @($Checks.ToArray())
}

$ResultDir = Split-Path -Parent $ResultJsonPath
if ($ResultDir) {
  New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ResultJsonPath, (($Result | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $Utf8NoBom)
Write-Host ""
Write-Host ("Dev environment JSON: {0}" -f $ResultJsonPath)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Dev environment check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Dev environment check complete."
exit 0
