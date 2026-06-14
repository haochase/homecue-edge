param(
  [string]$Port = "COM7",
  [int]$Baud = 115200,
  [int]$Seconds = 8,
  [string[]]$SendCommand = @(),
  [int]$SendAfterSeconds = 2
)

$ErrorActionPreference = "Stop"

$SerialPort = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$SerialPort.ReadTimeout = 500
# DTR held high can leave ESP32-S3 USB CDC boards silent after reset.
$SerialPort.DtrEnable = $false
$SerialPort.RtsEnable = $true

try {
  $SerialPort.Open()
  Write-Host ("Reading {0} at {1} baud for {2}s..." -f $Port, $Baud, $Seconds)

  # Pulse reset on ESP32 USB CDC boards so the boot banner is captured.
  $SerialPort.RtsEnable = $false
  Start-Sleep -Milliseconds 100
  $SerialPort.RtsEnable = $true

  $Deadline = (Get-Date).AddSeconds($Seconds)
  $CommandIndex = 0
  $NextCommandAt = (Get-Date).AddSeconds($SendAfterSeconds)
  while ((Get-Date) -lt $Deadline) {
    try {
      $Text = $SerialPort.ReadExisting()
      if ($Text) {
        Write-Host $Text -NoNewline
      }
    } catch [TimeoutException] {
    }

    if ($CommandIndex -lt $SendCommand.Count -and (Get-Date) -ge $NextCommandAt) {
      $Command = $SendCommand[$CommandIndex]
      Write-Host ("`n> serial {0}" -f $Command)
      $SerialPort.WriteLine($Command)
      $CommandIndex += 1
      $NextCommandAt = (Get-Date).AddSeconds($SendAfterSeconds)
    }

    Start-Sleep -Milliseconds 100
  }
  Write-Host ""
} finally {
  if ($SerialPort.IsOpen) {
    $SerialPort.Close()
  }
}
