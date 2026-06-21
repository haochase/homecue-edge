$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$OutputDir = Join-Path $Root "assets\tmp\esp32-serial-result-selftest"
$LogPath = Join-Path $OutputDir "sample.log"
$ResultPath = Join-Path $OutputDir "result.json"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$LogText = @"
[HomeCue Edge] ESP32-S3-AUDIO-Board firmware booting...
[mode] button-route + ESP-SR voice command route (propose only)
[keys] TCA9555 OK - KEY1=plan KEY2=confirm KEY3=reject BOOT=plan-fallback
[WiFi] connected, IP = 192.168.16.100
[/health] HTTP 200
[serial] PLAN -> I'm home
[/plan] proposed 5 action(s) - awaiting confirmation
[serial] CONFIRM
  exec light.set_scene -> accepted
"@

Set-Content -LiteralPath $LogPath -Value $LogText -NoNewline

& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-esp32-serial-log.ps1" -LogPath $LogPath -RequireInteraction -Required -ResultJsonPath $ResultPath | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "check-esp32-serial-log.ps1 saved-log selftest failed."
}

$Bytes = [System.IO.File]::ReadAllBytes($ResultPath)
if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
  throw "ESP32 serial result JSON must be UTF-8 without BOM."
}

$Text = [System.IO.File]::ReadAllText($ResultPath, [System.Text.Encoding]::UTF8)
if ($Text -match '[^\x00-\x7F]') {
  throw "ESP32 serial result JSON must be ASCII-safe."
}

$Result = $Text | ConvertFrom-Json
if ($Result.failures.Count -ne 0) {
  throw "ESP32 serial result selftest should have no failures."
}
if (@($Result.checks).Count -lt 9) {
  throw "ESP32 serial result selftest should include expected checks."
}

Write-Host "ESP32 serial result JSON self-test passed."
