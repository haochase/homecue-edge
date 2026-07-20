param(
  [switch]$DryRun,
  [switch]$FreshState
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$RuntimeDir = Join-Path $Root ".runtime\software-demo"
$DatabasePath = Join-Path $RuntimeDir "voice-chat.sqlite"
$StartDevScript = Join-Path $PSScriptRoot "start-dev.ps1"

$Environment = [ordered]@{
  HOMECUE_DISABLE_DOTENV = "1"
  ACTIVE_PROVIDER = ""
  PLANNER_PROVIDER = "mock"
  QWEN_API_KEY = ""
  MIMO_API_KEY = ""
  VOICE_CHAT_TTS_PROVIDER = "windows"
  VOICE_CHAT_TTS_API_KEY = ""
  VOICE_CHAT_ASR_PROVIDER = "disabled"
  VOICE_CHAT_MEMORY_DB = $DatabasePath
  VOICE_CHAT_ACCESS_TOKEN = ""
}

if ($DryRun) {
  [pscustomobject]@{
    profile = "software-demo"
    fresh_state = [bool]$FreshState
    started = $false
    environment = $Environment
  } | ConvertTo-Json -Depth 4
  exit 0
}

New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null

if ($FreshState) {
  foreach ($path in @($DatabasePath, "$DatabasePath-wal", "$DatabasePath-shm")) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }
}

$PreviousEnvironment = @{}
foreach ($entry in $Environment.GetEnumerator()) {
  $PreviousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, "Process")
  Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
}

try {
  & $StartDevScript
}
finally {
  foreach ($entry in $Environment.GetEnumerator()) {
    $previousValue = $PreviousEnvironment[$entry.Key]
    if ($null -eq $previousValue) {
      Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue
    }
    else {
      Set-Item -Path "Env:$($entry.Key)" -Value $previousValue
    }
  }
}

Write-Host "Software demo profile: local mock planner, Windows TTS, isolated SQLite state."
Write-Host "Use -FreshState before a recording rehearsal to clear demo memories, tasks, and moods."
