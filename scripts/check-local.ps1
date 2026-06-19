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

Write-Host "Checking HomeCue Edge public-repo scan..."
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\scan-secrets.ps1" -All -IncludeUntracked }
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\selftest-scan-secrets.ps1" }
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\selftest-dev-env.ps1" }

Write-Host "Checking patch whitespace..."
Invoke-Checked { git diff --check }

Write-Host "Checking HomeCue Edge API..."
$PytestTempRoot = Join-Path $PSScriptRoot "..\assets\tmp\pytest"
$PytestCacheDir = Join-Path $PytestTempRoot "cache"
$PytestBaseTemp = Join-Path $PytestTempRoot "basetemp"
New-Item -ItemType Directory -Force -Path $PytestCacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $PytestBaseTemp | Out-Null
Push-Location "$PSScriptRoot\..\apps\api"
try {
  if (-not (Test-Path ".venv")) {
    Invoke-Checked { python -m venv .venv }
  }
  Invoke-Checked { .\.venv\Scripts\python -m pip install -r requirements.txt }
  Invoke-Checked { .\.venv\Scripts\python -m compileall app }
  Invoke-Checked { .\.venv\Scripts\python -m pytest -o "cache_dir=$PytestCacheDir" "--basetemp=$PytestBaseTemp" }
}
finally {
  Pop-Location
}

if (-not $SkipFirmware) {
  Write-Host "Checking HomeCue Edge firmware flow..."
  Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-firmware-flow.ps1" -Required }
}

Write-Host "Checking HomeCue Edge full-loop path planning..."
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\selftest-full-loop-path-plan.ps1" }
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\selftest-browser-wrapper-paths.ps1" }
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\selftest-computer-loop-plan.ps1" }
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\selftest-browser-evidence-plan.ps1" }
Push-Location "$PSScriptRoot\..\apps\web"
try {
  Invoke-Checked { npm run summary:parity:selftest }
  Invoke-Checked { npm run desktop:evidence:selftest }
  Invoke-Checked { npm run phone:evidence:selftest }
  Invoke-Checked { npm run summary:selftest }
  Invoke-Checked { npm run report:selftest }
  Invoke-Checked { npm run browser:evidence-result:selftest }
  Invoke-Checked { npm run computer:result:selftest }
}
finally {
  Pop-Location
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
