$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"

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

Push-Location $ApiDir
try {
  if (-not (Test-Path ".venv")) {
    Invoke-Checked { python -m venv .venv }
  }

  Invoke-Checked { .\.venv\Scripts\python -m pip install -r requirements.txt }
  Invoke-Checked { .\.venv\Scripts\python scripts\verify_qwen.py }
}
finally {
  Pop-Location
}
