param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$ReadWindowMs = 500,
  [int]$WriteTimeoutMs = 1500,
  [string]$ResultJsonPath = "",
  [string]$ResultMarkdownPath = "",
  [switch]$AutoDetectEsp32,
  [switch]$SkipWriteProbe,
  [switch]$Required
)

$ErrorActionPreference = "Stop"

function Write-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $false
  )

  $Status = if ($Ok) { "OK" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)

  $script:Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      required = [bool]$RequiredCheck
      detail = $Detail
    })

  if ($Required -and $RequiredCheck -and -not $Ok) {
    $script:Failures.Add($Name)
  }
}

function New-ParentDirectory {
  param([string]$Path)
  $Parent = Split-Path -Parent $Path
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent | Out-Null
  }
}

function Format-MarkdownCell {
  param([object]$Value)
  if ($null -eq $Value) {
    return ""
  }
  return ([string]$Value).Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
}

function Get-PortRecords {
  $Records = New-Object System.Collections.Generic.List[object]
  foreach ($PortInfo in [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) {
    $Records.Add([pscustomobject]@{
        port = $PortInfo
        description = ""
        hwid = ""
        score = 0
        reason = "serial-port-api"
      })
  }

  try {
    $Ports = Get-CimInstance Win32_PnPEntity |
      Where-Object { $_.Name -match '\(COM\d+\)' -or $_.DeviceID -match 'VID_303A|VID_10C4|VID_1A86|VID_0403' }
    foreach ($Device in $Ports) {
      $Name = [string]$Device.Name
      $DeviceId = [string]$Device.DeviceID
      $Match = [regex]::Match($Name, '\((COM\d+)\)')
      if (-not $Match.Success) {
        continue
      }

      $DevicePort = $Match.Groups[1].Value
      $Existing = $Records | Where-Object { $_.port -eq $DevicePort } | Select-Object -First 1
      if (-not $Existing) {
        $Existing = [pscustomobject]@{
          port = $DevicePort
          description = ""
          hwid = ""
          score = 0
          reason = "pnp-only"
        }
        $Records.Add($Existing)
      }

      $Existing.description = $Name
      $Existing.hwid = $DeviceId
    }
  } catch {
    # CIM can fail on restricted hosts; the SerialPort API list above is enough
    # for the basic missing/openable/writable classification.
  }

  foreach ($Record in $Records) {
    $Text = ("{0} {1} {2}" -f $Record.port, $Record.description, $Record.hwid)
    $Score = 0
    $Reasons = New-Object System.Collections.Generic.List[string]
    if ($Record.port -eq $Port) {
      $Score += 100
      $Reasons.Add("requested")
    }
    if ($Text -match 'VID_303A|PID_1001|ESP32|Espressif|JTAG/serial|USB JTAG') {
      $Score += 80
      $Reasons.Add("esp32")
    }
    if ($Text -match 'USB Serial|USB 串行|CP210|CH340|CH910|Silicon Labs|WCH|UART') {
      $Score += 40
      $Reasons.Add("usb-serial")
    }
    if ($Text -match 'BTHENUM|Bluetooth|蓝牙') {
      $Score -= 80
      $Reasons.Add("bluetooth")
    }
    $Record.score = $Score
    $Record.reason = if ($Reasons.Count -gt 0) { $Reasons -join "," } else { $Record.reason }
  }

  return @($Records | Sort-Object -Property @{ Expression = "score"; Descending = $true }, port)
}

function Get-UsbProblemDevices {
  $Candidates = @()

  try {
    $PnpDevices = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
      Where-Object {
        $ErrorCode = $_.ConfigManagerErrorCode
        $Status = [string]$_.Status
        $IsProblem = $ErrorCode -ne 0 -or $Status -match 'Error|Degraded|Unknown'
        $_.DeviceID -match 'VID_303A|VID_0000|PID_1001|PID_0002|VID_10C4|VID_1A86|VID_0403|ESP|CP210|CH340|CH910|USB Serial|JTAG' -or
        $_.Name -match 'ESP|CP210|CH340|CH910|USB Serial|JTAG|Unknown USB Device' -or
        ($IsProblem -and $_.PNPClass -eq 'USB')
      }
    foreach ($Device in $PnpDevices) {
      $ErrorCode = $Device.ConfigManagerErrorCode
      $Status = [string]$Device.Status
      if ($ErrorCode -eq 0 -and $Status -notmatch 'Error|Degraded|Unknown') {
        continue
      }
      $Candidates += [pscustomobject]@{
        name = [string]$Device.Name
        deviceId = [string]$Device.DeviceID
        pnpClass = [string]$Device.PNPClass
        status = $Status
        configManagerErrorCode = $ErrorCode
      }
    }
  } catch {
    # Keep the serial-port probe usable on systems where CIM is restricted.
  }
  try {
    $PnpDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
      Where-Object {
        $ErrorCode = $null
        try {
          $ErrorCode = ($_ | Select-Object -ExpandProperty ConfigManagerErrorCode -ErrorAction SilentlyContinue)
        } catch {
          $ErrorCode = $null
        }
        $Status = [string]$_.Status
        $IsProblem = ($null -ne $ErrorCode -and $ErrorCode -ne 0) -or $Status -match 'Error|Degraded|Unknown'
        $_.InstanceId -match 'VID_303A|VID_0000|PID_1001|PID_0002|VID_10C4|VID_1A86|VID_0403|ESP|CP210|CH340|CH910|USB Serial|JTAG' -or
        $_.FriendlyName -match 'ESP|CP210|CH340|CH910|USB Serial|JTAG|Unknown USB Device' -or
        ($IsProblem -and $_.Class -eq 'USB')
      }
    foreach ($Device in $PnpDevices) {
      $ErrorCode = $null
      try {
        $ErrorCode = ($Device | Select-Object -ExpandProperty ConfigManagerErrorCode -ErrorAction SilentlyContinue)
      } catch {
        $ErrorCode = $null
      }
      $Status = [string]$Device.Status
      if (($null -eq $ErrorCode -or $ErrorCode -eq 0) -and $Status -notmatch 'Error|Degraded|Unknown') {
        continue
      }
      $Candidates += [pscustomobject]@{
        name = [string]$Device.FriendlyName
        deviceId = [string]$Device.InstanceId
        pnpClass = [string]$Device.Class
        status = $Status
        configManagerErrorCode = $ErrorCode
      }
    }
  } catch {
    # Get-PnpDevice is available on Windows PowerShell hosts; ignore failures on
    # restricted or non-Windows shells.
  }
  try {
    $PnpUtilText = (& pnputil /enum-devices /problem 2>$null) -join "`n"
    $Entries = $PnpUtilText -split "(?m)(?=^Instance ID:\s+)"
    foreach ($Entry in $Entries) {
      if ($Entry -notmatch "(?m)^Instance ID:\s*(.+)$") {
        continue
      }
      $DeviceId = $Matches[1].Trim()
      $Name = ""
      $ClassName = ""
      $Status = "Problem"
      $ErrorCode = $null
      if ($Entry -match "(?m)^Device Description:\s*(.+)$") {
        $Name = $Matches[1].Trim()
      }
      if ($DeviceId -match 'VID_0000&PID_0002') {
        $Name = "Unknown USB Device (Device Descriptor Request Failed)"
      }
      if ($Entry -match "(?m)^Class Name:\s*(.+)$") {
        $ClassName = $Matches[1].Trim()
      }
      if ($Entry -match "(?m)^Status:\s*(.+)$") {
        $Status = $Matches[1].Trim()
      }
      if ($Entry -match "(?m)^Problem Code:\s*(\d+)") {
        $ErrorCode = [int]$Matches[1]
      }
      $LooksRelevant = $DeviceId -match 'VID_303A|VID_0000|PID_1001|PID_0002|VID_10C4|VID_1A86|VID_0403|ESP|CP210|CH340|CH910|USB Serial|JTAG' -or
        $Name -match 'ESP|CP210|CH340|CH910|USB Serial|JTAG|Unknown USB Device' -or
        $ClassName -eq 'USB'
      if (-not $LooksRelevant) {
        continue
      }
      $Candidates += [pscustomobject]@{
        name = $Name
        deviceId = $DeviceId
        pnpClass = $ClassName
        status = $Status
        configManagerErrorCode = $ErrorCode
      }
    }
  } catch {
    # pnputil is a Windows-only fallback; ignore when unavailable.
  }

  $Seen = @{}
  $Devices = @()
  foreach ($Candidate in $Candidates) {
    $DeviceId = [string]$Candidate.deviceId
    if (-not $DeviceId -or $Seen.ContainsKey($DeviceId)) {
      continue
    }
    $Seen[$DeviceId] = $true
    $Devices += $Candidate
  }
  return @($Devices)
}

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]
$RequestedPort = $Port
$PortRecords = @(Get-PortRecords)
$UsbProblemDevices = @(Get-UsbProblemDevices)
$DetectedPorts = @($PortRecords | ForEach-Object { $_.port } | Sort-Object -Unique)
if ($AutoDetectEsp32 -and -not ($DetectedPorts -contains $Port)) {
  $BestPort = $PortRecords | Where-Object { $_.score -gt 0 } | Select-Object -First 1
  if ($BestPort) {
    $Port = [string]$BestPort.port
  }
}
$Detected = $DetectedPorts -contains $Port
$Openable = $false
$Writable = $false
$WriteProbeAttempted = -not [bool]$SkipWriteProbe
$BytesToRead = $null
$OpenError = ""
$WriteError = ""
$State = "unknown"
$Hint = ""

Write-Host "HomeCue Edge ESP32 port state check"
Write-Host ("Port   : {0}" -f $Port)
if ($RequestedPort -ne $Port) {
  Write-Host ("Request: {0} -> auto-detected {1}" -f $RequestedPort, $Port)
}
Write-Host ("Baud   : {0}" -f $Baud)
Write-Host ("Ports  : {0}" -f $(if ($DetectedPorts.Count -gt 0) { $DetectedPorts -join ", " } else { "(none)" }))
if ($UsbProblemDevices.Count -gt 0) {
  Write-Host ("USB err: {0}" -f ($UsbProblemDevices | ForEach-Object {
        "{0} code={1}" -f $_.name, $_.configManagerErrorCode
      } | Select-Object -First 3) -join "; ")
}
Write-Host ""

Write-Check "port detected" $Detected ("available ports: {0}" -f $(if ($DetectedPorts.Count -gt 0) { $DetectedPorts -join ", " } else { "(none)" })) $true
Write-Check "usb pnp problem devices" ($UsbProblemDevices.Count -eq 0) $(if ($UsbProblemDevices.Count -eq 0) {
    "no matching USB problem devices"
  } else {
    ($UsbProblemDevices | ForEach-Object {
        "{0} code={1}" -f $_.name, $_.configManagerErrorCode
      } | Select-Object -First 3) -join "; "
  }) $false

$SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$SerialPort.ReadTimeout = 200
$SerialPort.WriteTimeout = $WriteTimeoutMs
$SerialPort.DtrEnable = $false
$SerialPort.RtsEnable = $true

try {
  try {
    $SerialPort.Open()
    $Openable = $true
    Start-Sleep -Milliseconds $ReadWindowMs
    $BytesToRead = $SerialPort.BytesToRead
  } catch {
    $OpenError = $_.Exception.Message
  }

  Write-Check "port openable" $Openable $(if ($Openable) { "opened for state probe" } else { $OpenError }) $true

  if ($Openable -and $WriteProbeAttempted) {
    try {
      # A single newline is harmless for the HomeCue firmware command parser.
      # A timeout here is the known signature of the hung USB CDC state.
      $SerialPort.Write([byte[]](0x0A), 0, 1)
      $Writable = $true
    } catch {
      $WriteError = $_.Exception.Message
    }
    Write-Check "tiny write probe" $Writable $(if ($Writable) { "one newline accepted" } else { $WriteError }) $true
  } elseif ($Openable) {
    Write-Check "tiny write probe skipped" $true "pass without write probe; cannot classify hung USB CDC" $false
  }
} finally {
  if ($SerialPort.IsOpen) {
    $SerialPort.DtrEnable = $false
    $SerialPort.RtsEnable = $true
    $SerialPort.Close()
  }
}

if (-not $Detected -and $UsbProblemDevices.Count -gt 0) {
  $State = "usb-error"
  $Hint = "Windows sees a matching USB problem device but no serial port. Power-cycle USB, try BOOT+RESET ROM download mode, or change cable/port."
} elseif (-not $Detected) {
  $State = "missing"
  $Hint = "Check USB cable, board power, driver, and Windows Device Manager."
} elseif (-not $Openable) {
  $State = "busy"
  $Hint = "Close Arduino IDE Serial Monitor or any other process using the port."
} elseif ($WriteProbeAttempted -and -not $Writable) {
  $State = "hung"
  $Hint = "The port opens but does not drain writes. Power-cycle the board or enter ROM download mode, then retry."
} elseif ($WriteProbeAttempted -and $Writable) {
  $State = "writable"
  $Hint = "The serial endpoint accepts writes; upload or serial-test commands can be retried."
} else {
  $State = "openable"
  $Hint = "The port opened, but writable state was not tested."
}

Write-Host ""
Write-Host ("State  : {0}" -f $State)
Write-Host ("Hint   : {0}" -f $Hint)

$NextAction = switch ($State) {
  "writable" { "Serial upload or proof capture can be retried. Avoid opening another serial monitor in parallel." }
  "openable" { "The port opens, but write behavior was not checked. Rerun without -SkipWriteProbe before upload or proof capture." }
  "hung" { "Power-cycle the board or enter ROM download mode, then rerun this check before upload or proof capture." }
  "busy" { "Close Arduino IDE Serial Monitor or any other process using the port, then rerun this check." }
  "usb-error" { "Recover USB enumeration first: change cable or port, power-cycle the board, or use BOOT+RESET ROM download mode before rerunning this check." }
  "missing" { "Confirm board power, USB data cable, driver, and Device Manager enumeration, then rerun this check with the actual COM port." }
  default { "Review the JSON result and rerun with the actual ESP32 COM port." }
}
Write-Host ("Next   : {0}" -f $NextAction)

$RecoverySteps = switch ($State) {
  "writable" {
    @(
      "Keep Arduino Serial Monitor and other serial tools closed.",
      "Retry upload or serial proof capture with the selected port.",
      "Capture fresh proof only after HomeCue commands respond on the board."
    )
  }
  "openable" {
    @(
      "Rerun this check without -SkipWriteProbe before upload or proof capture.",
      "If the write probe passes, continue with upload or serial proof capture.",
      "If the write probe hangs, power-cycle the board before retrying."
    )
  }
  "hung" {
    @(
      "Power-cycle the board and wait for Windows to re-enumerate the serial device.",
      "If it remains hung, enter ROM download mode with BOOT+RESET.",
      "Rerun this check before upload or serial proof capture."
    )
  }
  "busy" {
    @(
      "Close Arduino IDE Serial Monitor and any terminal connected to the port.",
      "Stop background scripts that may hold the serial handle.",
      "Rerun this check before upload or serial proof capture."
    )
  }
  "usb-error" {
    @(
      "Swap to a known data-capable USB cable and a different USB port.",
      "Power-cycle the board, then try BOOT+RESET ROM download mode if needed.",
      "Clear the Windows USB problem state before rerunning this check."
    )
  }
  "missing" {
    @(
      "Confirm board power and use a data-capable USB cable.",
      "Check Windows Device Manager for a new COM port or unknown USB device.",
      "Rerun this check with the actual ESP32 COM port after enumeration returns."
    )
  }
  default {
    @(
      "Review detected ports and USB problem devices in the JSON report.",
      "Rerun this check with the actual ESP32 COM port before hardware proof."
    )
  }
}

$Result = @{
  checkedAt = (Get-Date).ToString("o")
  requestedPort = $RequestedPort
  port = $Port
  baud = $Baud
  detectedPorts = [string[]]$DetectedPorts
  portCandidates = [object[]]$PortRecords
  usbProblemDevices = [object[]]$UsbProblemDevices
  autoDetectEsp32 = [bool]$AutoDetectEsp32
  detected = [bool]$Detected
  openable = [bool]$Openable
  bytesToRead = $BytesToRead
  writeProbeAttempted = [bool]$WriteProbeAttempted
  writable = [bool]$Writable
  state = $State
  hint = $Hint
  nextAction = $NextAction
  recoverySteps = [string[]]$RecoverySteps
  openError = $OpenError
  writeError = $WriteError
  requiredMode = [bool]$Required
  failures = [string[]]$Failures.ToArray()
  checks = [object[]]$Checks.ToArray()
}

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($ResultMarkdownPath) {
  New-ParentDirectory -Path $ResultMarkdownPath
  $Lines = New-Object System.Collections.Generic.List[string]
  $Lines.Add("# ESP32 Port State Report")
  $Lines.Add("")
  $Lines.Add(('- Checked at: `{0}`' -f $Result.checkedAt))
  $Lines.Add(('- Requested port: `{0}`' -f $Result.requestedPort))
  $Lines.Add(('- Selected port: `{0}`' -f $Result.port))
  $Lines.Add(("- State: **{0}**" -f $Result.state))
  $Lines.Add(("- Hint: {0}" -f $Result.hint))
  $Lines.Add(('- Detected ports: `{0}`' -f $(if ($DetectedPorts.Count -gt 0) { $DetectedPorts -join ", " } else { "(none)" })))
  $Lines.Add("")
  $Lines.Add("## Checks")
  $Lines.Add("")
  $Lines.Add("| Check | Status | Required | Detail |")
  $Lines.Add("| --- | --- | --- | --- |")
  foreach ($Check in $Checks) {
    $Lines.Add((
        "| {0} | {1} | {2} | {3} |" -f
        (Format-MarkdownCell $Check.name),
        (Format-MarkdownCell $Check.status),
        (Format-MarkdownCell $Check.required),
        (Format-MarkdownCell $Check.detail)
      ))
  }
  $Lines.Add("")
  $Lines.Add("## USB Problem Devices")
  $Lines.Add("")
  if ($UsbProblemDevices.Count -eq 0) {
    $Lines.Add("No matching USB problem devices were detected.")
  } else {
    $Lines.Add("| Name | Code | Status | Class |")
    $Lines.Add("| --- | --- | --- | --- |")
    foreach ($Device in $UsbProblemDevices) {
      $Lines.Add((
          "| {0} | {1} | {2} | {3} |" -f
          (Format-MarkdownCell $Device.name),
          (Format-MarkdownCell $Device.configManagerErrorCode),
          (Format-MarkdownCell $Device.status),
          (Format-MarkdownCell $Device.pnpClass)
        ))
    }
  }
  $Lines.Add("")
  $Lines.Add("## Next Action")
  $Lines.Add("")
  $Lines.Add($NextAction)
  $Lines.Add("")
  $Lines.Add("## Recovery Steps")
  $Lines.Add("")
  for ($Index = 0; $Index -lt $RecoverySteps.Count; $Index++) {
    $Lines.Add(("{0}. {1}" -f ($Index + 1), $RecoverySteps[$Index]))
  }
  $Lines | Set-Content -LiteralPath $ResultMarkdownPath -Encoding UTF8
  Write-Host ("Report : {0}" -f (Resolve-Path -LiteralPath $ResultMarkdownPath).Path)
}

if ($Required -and $Failures.Count -gt 0) {
  Write-Host "ESP32 port state check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "ESP32 port state check complete."
exit 0
