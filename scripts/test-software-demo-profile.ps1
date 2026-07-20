$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$Target = Join-Path $PSScriptRoot "start-software-demo.ps1"

if (-not (Test-Path -LiteralPath $Target)) {
  throw "Software demo launcher is missing: $Target"
}

$raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -DryRun -FreshState
if ($LASTEXITCODE -ne 0) {
  throw "Software demo launcher dry-run failed with exit code $LASTEXITCODE."
}

$profile = $raw | ConvertFrom-Json
$expectedDatabase = Join-Path $Root ".runtime\software-demo\voice-chat.sqlite"

$checks = @(
  @{ Name = "profile name"; Actual = $profile.profile; Expected = "software-demo" },
  @{ Name = "dotenv disabled"; Actual = $profile.environment.HOMECUE_DISABLE_DOTENV; Expected = "1" },
  @{ Name = "mock planner"; Actual = $profile.environment.PLANNER_PROVIDER; Expected = "mock" },
  @{ Name = "local TTS"; Actual = $profile.environment.VOICE_CHAT_TTS_PROVIDER; Expected = "windows" },
  @{ Name = "ASR disabled"; Actual = $profile.environment.VOICE_CHAT_ASR_PROVIDER; Expected = "disabled" },
  @{ Name = "isolated database"; Actual = $profile.environment.VOICE_CHAT_MEMORY_DB; Expected = $expectedDatabase },
  @{ Name = "fresh state requested"; Actual = [bool]$profile.fresh_state; Expected = $true },
  @{ Name = "dry run has no side effects"; Actual = [bool]$profile.started; Expected = $false }
)

foreach ($check in $checks) {
  if ($check.Actual -ne $check.Expected) {
    throw ("{0}: expected '{1}', got '{2}'." -f $check.Name, $check.Expected, $check.Actual)
  }
  Write-Host ("[OK] {0}" -f $check.Name)
}

Write-Host "Software demo profile contract passed."
