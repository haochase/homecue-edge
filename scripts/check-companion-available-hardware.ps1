param(
  [string]$ApiBase = "http://127.0.0.1:8723",
  [string]$WebBase = "http://127.0.0.1:5173",
  [string]$PhoneApiBase = "http://127.0.0.1:8723",
  [string]$PhoneWebBase = "http://127.0.0.1:5173",
  [string]$AdbPath = "",
  [string]$ChromePackage = "com.android.chrome",
  [int]$ChromeDevToolsPort = 9222,
  [string]$Esp32Port = "COM7",
  [int]$Esp32Seconds = 90,
  [string]$ResultJsonPath = ".\assets\demo\companion-available-hardware-current.json",
  [string]$Esp32LogPath = ".\assets\demo\companion-available-hardware-esp32.log",
  [string]$Esp32CheckJsonPath = ".\assets\demo\companion-available-hardware-esp32-check.json",
  [switch]$SkipPhone,
  [switch]$SkipAdbReverse,
  [switch]$GrantChromeMediaPermissions,
  [switch]$SkipEsp32,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $true
  )

  $Status = if ($Ok) { "OK" } else { "FAIL" }
  $Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      required = [bool]$RequiredCheck
      detail = $Detail
    })

  if ($RequiredCheck -and -not $Ok) {
    $Failures.Add($Name)
  }

  Write-Host ("[{0}] {1} - {2}" -f $Status, $Name, $Detail)
}

function Ensure-ParentDirectory {
  param([string]$Path)

  $Parent = Split-Path -Parent $Path
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
  }
}

function Resolve-AdbPath {
  if ($AdbPath) {
    if (-not (Test-Path -LiteralPath $AdbPath)) {
      throw "ADB not found at $AdbPath"
    }
    return $AdbPath
  }

  $SdkAdb = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
  if (Test-Path -LiteralPath $SdkAdb) {
    return $SdkAdb
  }

  $Command = Get-Command adb.exe -ErrorAction SilentlyContinue
  if ($Command) {
    return $Command.Source
  }

  throw "ADB not found. Set -AdbPath or install Android platform-tools."
}

function Get-UrlPort {
  param([string]$Url)

  $Uri = [Uri]$Url
  if ($Uri.Port -gt 0) {
    return $Uri.Port
  }
  if ($Uri.Scheme -eq "https") {
    return 443
  }
  return 80
}

function Invoke-HttpText {
  param(
    [string]$Name,
    [string]$Uri,
    [string]$ExpectedText = ""
  )

  try {
    $Response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 10
    $Content = [string]$Response.Content
    $Ok = $Response.StatusCode -ge 200 -and $Response.StatusCode -lt 300
    if ($ExpectedText) {
      $Ok = $Ok -and $Content.Contains($ExpectedText)
    }
    Add-Check $Name $Ok ("HTTP {0}" -f $Response.StatusCode)
    return [pscustomobject]@{
      ok = $Ok
      statusCode = $Response.StatusCode
      contentPrefix = $Content.Substring(0, [Math]::Min(240, $Content.Length))
    }
  } catch {
    Add-Check $Name $false $_.Exception.Message
    return [pscustomobject]@{
      ok = $false
      error = $_.Exception.Message
    }
  }
}

function Invoke-HttpJson {
  param(
    [string]$Name,
    [string]$Uri
  )

  try {
    $Value = Invoke-RestMethod -Uri $Uri -TimeoutSec 10
    Add-Check $Name $true $Uri
    return [pscustomobject]@{
      ok = $true
      value = $Value
    }
  } catch {
    Add-Check $Name $false $_.Exception.Message
    return [pscustomobject]@{
      ok = $false
      error = $_.Exception.Message
    }
  }
}

function Start-PhoneChromeUrl {
  param(
    [string]$Adb,
    [string]$Url
  )

  & $Adb shell am start -n "$ChromePackage/com.google.android.apps.chrome.Main" -a android.intent.action.VIEW -d $Url | Out-Null
}

function Invoke-AdbForwardDevTools {
  param([string]$Adb)

  & $Adb forward "tcp:$ChromeDevToolsPort" localabstract:chrome_devtools_remote | Out-Null
}

function Find-ChromePage {
  param([string]$ExpectedUrl)

  $Expected = [Uri]$ExpectedUrl
  $Pages = Invoke-RestMethod -Uri "http://127.0.0.1:$ChromeDevToolsPort/json" -TimeoutSec 10
  foreach ($Page in @($Pages)) {
    try {
      $PageUri = [Uri]$Page.url
      if (
        $PageUri.Scheme -eq $Expected.Scheme -and
        $PageUri.Host -eq $Expected.Host -and
        $PageUri.Port -eq $Expected.Port -and
        $PageUri.AbsolutePath -eq $Expected.AbsolutePath
      ) {
        return $Page
      }
    } catch {
      continue
    }
  }

  return $null
}

function Receive-CdpMessage {
  param(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [int]$WantedId
  )

  $Buffer = New-Object byte[] 262144
  $Builder = New-Object System.Text.StringBuilder
  $Cancellation = [Threading.CancellationToken]::None

  while ($true) {
    $Segment = [ArraySegment[byte]]::new($Buffer)
    $Receive = $Socket.ReceiveAsync($Segment, $Cancellation).GetAwaiter().GetResult()
    if ($Receive.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
      throw "Chrome DevTools socket closed"
    }

    [void]$Builder.Append([Text.Encoding]::UTF8.GetString($Buffer, 0, $Receive.Count))
    if (-not $Receive.EndOfMessage) {
      continue
    }

    $Text = $Builder.ToString()
    [void]$Builder.Clear()
    if ([string]::IsNullOrWhiteSpace($Text)) {
      continue
    }

    $Message = $Text | ConvertFrom-Json
    if ($Message.id -eq $WantedId) {
      return $Message
    }
  }
}

function Send-CdpCommand {
  param(
    [string]$WebSocketDebuggerUrl,
    [string]$Method,
    [hashtable]$Params = @{}
  )

  $Socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $Cancellation = [Threading.CancellationToken]::None
  try {
    $Socket.ConnectAsync([Uri]$WebSocketDebuggerUrl, $Cancellation).GetAwaiter().GetResult()
    $Id = Get-Random -Minimum 1000 -Maximum 999999
    $Payload = @{
      id = $Id
      method = $Method
      params = $Params
    } | ConvertTo-Json -Depth 30 -Compress
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
    $Socket.SendAsync(
      [ArraySegment[byte]]::new($Bytes),
      [System.Net.WebSockets.WebSocketMessageType]::Text,
      $true,
      $Cancellation
    ).GetAwaiter().GetResult()
    return Receive-CdpMessage -Socket $Socket -WantedId $Id
  } finally {
    $Socket.Dispose()
  }
}

function Invoke-CdpEvaluate {
  param(
    [string]$WebSocketDebuggerUrl,
    [string]$Expression
  )

  $Response = Send-CdpCommand -WebSocketDebuggerUrl $WebSocketDebuggerUrl -Method "Runtime.evaluate" -Params @{
    expression = $Expression
    returnByValue = $true
    awaitPromise = $true
  }

  if ($Response.result.exceptionDetails) {
    throw ($Response.result.exceptionDetails.text | Out-String)
  }

  return $Response.result.result.value
}

function Wait-CdpValue {
  param(
    [string]$WebSocketDebuggerUrl,
    [string]$Expression,
    [scriptblock]$Ready,
    [int]$Seconds = 12
  )

  $Last = $null
  for ($Attempt = 0; $Attempt -lt $Seconds; $Attempt += 1) {
    $Last = Invoke-CdpEvaluate -WebSocketDebuggerUrl $WebSocketDebuggerUrl -Expression $Expression
    if (& $Ready $Last) {
      return $Last
    }
    Start-Sleep -Seconds 1
  }

  return $Last
}

Write-Host "HomeCue companion available-hardware check"
Write-Host ""

$ApiHealth = Invoke-HttpJson -Name "API health" -Uri "$($ApiBase.TrimEnd('/'))/health"
$WebRoot = Invoke-HttpText -Name "Web root" -Uri $WebBase -ExpectedText "HomeCue Edge"
$ProbeStatic = Invoke-HttpText -Name "Phone probe static page" -Uri "$($WebBase.TrimEnd('/'))/phone-probe.html" -ExpectedText "HomeCue Phone Probe"

$PhoneResult = $null
if (-not $SkipPhone) {
  try {
    $Adb = Resolve-AdbPath
    $AdbDevices = (& $Adb devices -l) -join "`n"
    $DeviceOnline = $AdbDevices -match "\sdevice\s"
    Add-Check "ADB phone online" $DeviceOnline "android device listed"

    if ($GrantChromeMediaPermissions) {
      & $Adb shell pm grant $ChromePackage android.permission.RECORD_AUDIO | Out-Null
      & $Adb shell pm grant $ChromePackage android.permission.CAMERA | Out-Null
      Add-Check "Chrome Android media grants" $true "RECORD_AUDIO and CAMERA granted" $false
    }

    if (-not $SkipAdbReverse) {
      $PhoneWebPort = Get-UrlPort $PhoneWebBase
      $WebPort = Get-UrlPort $WebBase
      $PhoneApiPort = Get-UrlPort $PhoneApiBase
      $ApiPort = Get-UrlPort $ApiBase
      & $Adb reverse "tcp:$PhoneWebPort" "tcp:$WebPort" | Out-Null
      & $Adb reverse "tcp:$PhoneApiPort" "tcp:$ApiPort" | Out-Null
      Add-Check "ADB reverse" $true ("phone web {0}->{1}, api {2}->{3}" -f $PhoneWebPort, $WebPort, $PhoneApiPort, $ApiPort) $false
    }

    Invoke-AdbForwardDevTools -Adb $Adb
    $Stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $EncodedPhoneApi = [Uri]::EscapeDataString($PhoneApiBase)

    $MainUrl = "$($PhoneWebBase.TrimEnd('/'))/?apiBase=$EncodedPhoneApi&t=$Stamp"
    Start-PhoneChromeUrl -Adb $Adb -Url $MainUrl
    Start-Sleep -Seconds 5
    $MainPage = Find-ChromePage -ExpectedUrl $MainUrl
    if (-not $MainPage) {
      throw "Phone Chrome main app page not found in DevTools"
    }

    $MainExpression = @"
(() => ({
  title: document.title,
  href: location.href,
  bodyText: document.body.innerText,
  hasHomeCue: /HomeCue Edge|QWEN EDGEAGENT/i.test(document.body.innerText),
  hasLoadError: /Could not load|failed to fetch|NetworkError/i.test(document.body.innerText)
}))()
"@
    $MainDom = Invoke-CdpEvaluate -WebSocketDebuggerUrl $MainPage.webSocketDebuggerUrl -Expression $MainExpression
    Add-Check "Phone Chrome main UI" ([bool]$MainDom.hasHomeCue -and -not [bool]$MainDom.hasLoadError) $MainDom.title

    $ProbeUrl = "$($PhoneWebBase.TrimEnd('/'))/phone-probe.html?apiBase=$EncodedPhoneApi&t=$Stamp"
    Start-PhoneChromeUrl -Adb $Adb -Url $ProbeUrl
    Start-Sleep -Seconds 2
    $ProbePage = Find-ChromePage -ExpectedUrl $ProbeUrl
    if (-not $ProbePage) {
      throw "Phone Chrome probe page not found in DevTools"
    }

    $ProbeExpression = @"
(() => {
  let log = null;
  try {
    log = JSON.parse(document.querySelector("#log")?.textContent || "null");
  } catch (error) {
    log = { parseError: String(error) };
  }
  return {
    title: document.title,
    href: location.href,
    isSecureContext: window.isSecureContext,
    hasMediaDevices: Boolean(navigator.mediaDevices),
    bodyText: document.body.innerText,
    log
  };
})()
"@
    $ProbeDom = Wait-CdpValue -WebSocketDebuggerUrl $ProbePage.webSocketDebuggerUrl -Expression $ProbeExpression -Seconds 18 -Ready {
      param($Value)
      if (-not $Value.log -or -not $Value.log.results) {
        return $false
      }
      $Names = @($Value.log.results | ForEach-Object { $_.name })
      $HasMic = $Names -contains "microphone permission" -or $Names -contains "microphone API"
      $HasCamera = $Names -contains "camera permission" -or $Names -contains "camera API"
      return $HasMic -and $HasCamera
    }

    $ProbeRows = @()
    if ($ProbeDom.log -and $ProbeDom.log.results) {
      $ProbeRows = @($ProbeDom.log.results)
    }
    $ProbeByName = @{}
    foreach ($Row in $ProbeRows) {
      $ProbeByName[$Row.name] = $Row
    }

    Add-Check "Phone secure context" ([bool]$ProbeDom.isSecureContext) ("isSecureContext={0}" -f $ProbeDom.isSecureContext)
    Add-Check "Phone mediaDevices" ([bool]$ProbeDom.hasMediaDevices) ("mediaDevices={0}" -f $ProbeDom.hasMediaDevices)
    Add-Check "Phone probe API" ($ProbeByName.ContainsKey("API /health") -and $ProbeByName["API /health"].status -eq "ok") "probe /health"
    Add-Check "Phone microphone" ($ProbeByName.ContainsKey("microphone permission") -and $ProbeByName["microphone permission"].status -eq "ok") "getUserMedia audio"
    Add-Check "Phone camera" ($ProbeByName.ContainsKey("camera permission") -and $ProbeByName["camera permission"].status -eq "ok") "getUserMedia video"

    $PhoneResult = [ordered]@{
      adbDevice = (($AdbDevices -split "`n") | Where-Object { $_ -match "\sdevice\s" } | Select-Object -First 1)
      main = $MainDom
      probe = $ProbeDom
    }
  } catch {
    Add-Check "Phone Chrome flow" $false $_.Exception.Message
    $PhoneResult = [ordered]@{
      error = $_.Exception.Message
    }
  }
} else {
  Add-Check "Phone Chrome flow" $true "skipped by parameter" $false
}

$Esp32Result = $null
if (-not $SkipEsp32) {
  try {
    Ensure-ParentDirectory $Esp32LogPath
    Ensure-ParentDirectory $Esp32CheckJsonPath
    $SerialArgs = @{
      Port = $Esp32Port
      Seconds = $Esp32Seconds
      SkipReset = $true
      RequireInteraction = $true
      AutoSerialLevel4 = $true
      SerialCommandIndex = 0
      ExpectedActionCount = 5
      SaveLogPath = $Esp32LogPath
      ResultJsonPath = $Esp32CheckJsonPath
    }
    if ($Required) {
      $SerialArgs["Required"] = $true
    }
    & (Join-Path $PSScriptRoot "check-esp32-serial-log.ps1") @SerialArgs
    $Esp32Result = Get-Content -Raw $Esp32CheckJsonPath | ConvertFrom-Json
    Add-Check "ESP32 plan execute" (@($Esp32Result.failures).Count -eq 0) "serial AutoSerialLevel4"
  } catch {
    Add-Check "ESP32 plan execute" $false $_.Exception.Message
    $Esp32Result = [ordered]@{
      error = $_.Exception.Message
    }
  }
} else {
  Add-Check "ESP32 plan execute" $true "skipped by parameter" $false
}

$DevicesAfter = Invoke-HttpJson -Name "Devices after loop" -Uri "$($ApiBase.TrimEnd('/'))/devices"

$ResultStatus = if ($Failures.Count -eq 0) { "ok" } else { "fail" }
$Result = [ordered]@{
  checkedAt = (Get-Date).ToString("o")
  status = $ResultStatus
  failures = @($Failures)
  inputs = [ordered]@{
    apiBase = $ApiBase
    webBase = $WebBase
    phoneApiBase = $PhoneApiBase
    phoneWebBase = $PhoneWebBase
    esp32Port = $Esp32Port
    esp32Seconds = $Esp32Seconds
    skipPhone = [bool]$SkipPhone
    skipEsp32 = [bool]$SkipEsp32
  }
  apiHealth = $ApiHealth
  webRoot = $WebRoot
  phoneProbeStatic = $ProbeStatic
  phone = $PhoneResult
  esp32 = $Esp32Result
  devicesAfter = $DevicesAfter
  checks = @($Checks.ToArray())
  evidenceFiles = @(
    $ResultJsonPath,
    $Esp32LogPath,
    $Esp32CheckJsonPath
  )
}

Ensure-ParentDirectory $ResultJsonPath
$Result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ""
Write-Host ("Result : {0}" -f $ResultJsonPath)

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Available-hardware check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host (" - {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Available-hardware check complete."
