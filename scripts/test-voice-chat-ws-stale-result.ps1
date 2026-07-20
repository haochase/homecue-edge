param(
  [string]$TargetScript = (Join-Path $PSScriptRoot "test-voice-chat-ws.ps1")
)

$ErrorActionPreference = "Stop"

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("homecue-ws-stale-result-{0}" -f $PID)
$ResultJsonPath = Join-Path $TempRoot "result.json"

try {
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  @{
    status = "passed"
    provider = "stale-provider"
    sessionId = "stale-session"
    turnIndex = 1
  } | ConvertTo-Json | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8

  & $TargetScript `
    -WsUrl "ws://127.0.0.1:1/voice-chat/ws" `
    -ResultJsonPath $ResultJsonPath `
    -Required
  $ExitCode = $LASTEXITCODE
  $Result = Get-Content -Raw -LiteralPath $ResultJsonPath | ConvertFrom-Json

  if ($ExitCode -eq 0) {
    throw "Expected a failed WebSocket invocation to return a non-zero exit code."
  }
  if ($Result.status -ne "failed") {
    throw ("Expected the stale result to be replaced with status=failed, got status={0}." -f $Result.status)
  }

  Write-Host "[OK] stale WebSocket result cannot mask a failed invocation"
} finally {
  if (Test-Path -LiteralPath $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force
  }
}
