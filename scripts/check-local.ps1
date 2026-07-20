param(
  [switch]$SkipFirmware
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$RuntimeRoot = Join-Path $RepoRoot ".runtime\check-local"
$ApiPytestBaseTemp = Join-Path $RuntimeRoot "pytest-api-tmp"
$ApiPytestCacheDir = Join-Path $RuntimeRoot "pytest-api-cache"

New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null

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
  Invoke-Checked { .\.venv\Scripts\python -m pytest --basetemp $ApiPytestBaseTemp -o "cache_dir=$ApiPytestCacheDir" }
}
finally {
  Pop-Location
}

if (-not $SkipFirmware) {
  Write-Host "Checking HomeCue Edge firmware flow..."
  Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\check-firmware-flow.ps1" -Required }
}

Write-Host "Checking HomeCue Edge software demo profile..."
Invoke-Checked { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\test-software-demo-profile.ps1" }

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
