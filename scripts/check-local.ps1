param(
  [switch]$SkipFirmware
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Command
  )

  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed: $Command"
  }
}

Write-Host "Checking HomeCue Edge API..."
Push-Location "$PSScriptRoot\..\apps\api"
try {
  if (-not (Test-Path ".venv")) {
    Invoke-Checked { python -m venv .venv }
  }
  Invoke-Checked { .\.venv\Scripts\python -m pip install -r requirements.txt }
  Invoke-Checked { .\.venv\Scripts\python -m compileall app }
  Invoke-Checked { .\.venv\Scripts\python -m pytest }
}
finally {
  Pop-Location
}

if (-not $SkipFirmware) {
  Write-Host "Checking HomeCue Edge firmware flow..."
  Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-firmware-flow.ps1" -Required }
}

Write-Host "Checking HomeCue Edge web console..."
Push-Location "$PSScriptRoot\..\apps\web"
try {
  Invoke-Checked { npm install }
  Invoke-Checked { npm run lint }
  Invoke-Checked { npm run build }
}
finally {
  Pop-Location
}

Write-Host "HomeCue Edge local checks passed."
