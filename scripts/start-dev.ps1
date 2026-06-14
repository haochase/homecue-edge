$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"
$WebDir = Join-Path $Root "apps\web"

if (-not (Test-Path (Join-Path $ApiDir ".venv"))) {
  Push-Location $ApiDir
  try {
    python -m venv .venv
    .\.venv\Scripts\python -m pip install -r requirements.txt
  }
  finally {
    Pop-Location
  }
}

Start-Process `
  -FilePath (Join-Path $ApiDir ".venv\Scripts\python.exe") `
  -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "8723" `
  -WorkingDirectory $ApiDir `
  -WindowStyle Hidden

Start-Process `
  -FilePath "cmd.exe" `
  -ArgumentList "/c", "npm run dev -- --host 127.0.0.1 --port 5173" `
  -WorkingDirectory $WebDir `
  -WindowStyle Hidden

Write-Host "HomeCue Edge dev services are starting."
Write-Host "API: http://127.0.0.1:8723"
Write-Host "Web: http://127.0.0.1:5173"
Write-Host "Tip: run scripts/check-local.ps1 before recording if dependencies changed."
