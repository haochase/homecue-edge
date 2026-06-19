param(
  [string]$AdbPath = "",
  [string]$AppUrl = "http://127.0.0.1:5173",
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$ChromePackage = "com.android.chrome",
  [string]$ChromeActivity = "com.google.android.apps.chrome.Main",
  [int]$CdpPort = 9222,
  [string]$OutputPath = "",
  [switch]$SkipPermissionGrant,
  [switch]$SkipReverse
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$WebDir = Join-Path $Root "apps\web"

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

if (-not $OutputPath) {
  $OutputPath = Join-Path $Root "assets\demo\phone-loop.json"
}
else {
  $OutputPath = Resolve-RootedPath $OutputPath
}

if (-not (Test-Path -LiteralPath $AdbPath)) {
  throw "adb.exe not found: $AdbPath"
}

function Invoke-Adb {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  & $AdbPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "adb failed: $($Arguments -join ' ')"
  }
}

function Grant-ChromePermission {
  param([string]$Permission)

  try {
    Invoke-Adb -Arguments @("shell", "pm", "grant", $ChromePackage, $Permission) | Out-Null
    Write-Host "Granted Chrome permission: $Permission"
  }
  catch {
    Write-Warning "Could not grant Chrome permission $Permission. Continue if it was already allowed on the phone."
  }
}

function Close-StaleHomeCueTabs {
  param(
    [string]$Endpoint,
    [string]$TargetUrl
  )

  $TargetOrigin = ([System.Uri]$TargetUrl).GetLeftPart([System.UriPartial]::Authority)

  try {
    $Targets = Expand-JsonArray -Value (Invoke-RestMethod "$Endpoint/json/list")
  }
  catch {
    Write-Warning "Could not inspect Android Chrome targets before launch. Continuing with existing tabs."
    return
  }

  $ClosedCount = 0
  foreach ($Target in $Targets) {
    $Url = [string]$Target.url
    if (
      $Target.type -eq "page" -and
      ($Url.StartsWith($TargetOrigin) -or $Url.Contains("/phone-probe.html"))
    ) {
      try {
        Invoke-RestMethod -Method Put "$Endpoint/json/close/$($Target.id)" | Out-Null
        $ClosedCount += 1
      }
      catch {
        Write-Warning "Could not close stale Android Chrome tab: $Url"
      }
    }
  }

  if ($ClosedCount -gt 0) {
    Write-Host "Closed stale HomeCue Android Chrome tabs: $ClosedCount"
    Start-Sleep -Milliseconds 500
  }
}

function Expand-JsonArray {
  param($Value)

  if ($Value -is [System.Array]) {
    return $Value
  }

  return @($Value)
}

function Get-ConnectedAndroidDevices {
  param([string]$Executable)

  try {
    & $Executable start-server 2>$null | Out-Null
  }
  catch {
    # The retry loop below will still report no authorized device if startup failed.
  }

  $Deadline = (Get-Date).AddSeconds(15)
  do {
    $DeviceLines = & $Executable devices -l
    if ($LASTEXITCODE -eq 0) {
      $Devices = @($DeviceLines | Where-Object { [string]$_ -match "^\S+\s+device(?:\s|$)" })
      if ($Devices.Count -gt 0) {
        return $Devices
      }
    }

    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $Deadline)

  return @()
}

$ConnectedDevices = @(Get-ConnectedAndroidDevices -Executable $AdbPath)
if ($ConnectedDevices.Count -eq 0) {
  throw "No authorized Android device found. Unlock the phone and accept the USB debugging prompt."
}

Write-Host "Android device:"
$ConnectedDevices | ForEach-Object { Write-Host "  $_" }

if (-not $SkipPermissionGrant) {
  Grant-ChromePermission "android.permission.CAMERA"
  Grant-ChromePermission "android.permission.RECORD_AUDIO"
}

if (-not $SkipReverse) {
  Invoke-Adb -Arguments @("reverse", "tcp:5173", "tcp:5173") | Out-Null
  Invoke-Adb -Arguments @("reverse", "tcp:8723", "tcp:8723") | Out-Null
}

Invoke-Adb -Arguments @("forward", "tcp:$CdpPort", "localabstract:chrome_devtools_remote") | Out-Null

$TargetUrl = "$AppUrl/?apiBase=$([System.Uri]::EscapeDataString($ApiBase))"
$CdpEndpoint = "http://127.0.0.1:$CdpPort"
Close-StaleHomeCueTabs -Endpoint $CdpEndpoint -TargetUrl $TargetUrl

Invoke-Adb -Arguments @("shell", "input", "keyevent", "KEYCODE_WAKEUP") | Out-Null
Invoke-Adb -Arguments @("shell", "wm", "dismiss-keyguard") | Out-Null
Invoke-Adb -Arguments @(
  "shell",
  "am",
  "start",
  "-n",
  "$ChromePackage/$ChromeActivity",
  "-a",
  "android.intent.action.VIEW",
  "-d",
  $TargetUrl
) | Out-Null
Start-Sleep -Seconds 2

$WindowState = (& $AdbPath shell dumpsys window) -join "`n"
if ($WindowState -notmatch [regex]::Escape($ChromePackage)) {
  $FocusLine = ($WindowState -split "`n" | Where-Object { $_ -match "mCurrentFocus|mFocusedApp" } | Select-Object -First 2) -join " "
  throw "Chrome is not the foreground app after launch. Current focus: $FocusLine"
}

$Version = Invoke-RestMethod "$CdpEndpoint/json/version"
Write-Host ("Android Chrome: {0}" -f $Version.Browser)

Push-Location $WebDir
try {
  npm run phone:loop -- $AppUrl $ApiBase $CdpEndpoint $OutputPath
  if ($LASTEXITCODE -ne 0) {
    throw "phone:loop failed."
  }

  npm run phone:evidence:check -- $OutputPath $AppUrl $ApiBase $CdpEndpoint
  if ($LASTEXITCODE -ne 0) {
    throw "phone:evidence:check failed."
  }
}
finally {
  Pop-Location
}

Write-Host "Phone loop evidence: $OutputPath"
