param(
  [string]$SketchPath = "",
  [switch]$Required
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
if (-not $SketchPath) {
  $SketchPath = Join-Path $Root "firmware\esp32-audio\esp32-audio.ino"
}

if (-not (Test-Path -LiteralPath $SketchPath)) {
  throw "Firmware sketch not found: $SketchPath"
}

$Source = Get-Content -Raw -LiteralPath $SketchPath
$Failures = New-Object System.Collections.Generic.List[string]

function Write-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [bool]$RequiredCheck = $false
  )

  $Status = if ($Ok) { "OK" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)

  if ($Required -and $RequiredCheck -and -not $Ok) {
    $script:Failures.Add($Name)
  }
}

function Test-Pattern {
  param([string]$Pattern)
  return $Source -match $Pattern
}

Write-Host "HomeCue Edge firmware flow check"
Write-Host ("Sketch: {0}" -f (Resolve-Path -LiteralPath $SketchPath).Path)
Write-Host ""

Write-Check "fixed command table" (Test-Pattern "static\s+const\s+CommandWord\s+COMMAND_WORDS\[\]") "COMMAND_WORDS defines voice/button prompts" $true
Write-Check "command label: I'm home" (Test-Pattern '"I''m home"\s*,') "home arrival prompt is available" $true
Write-Check "command label: Sleep mode" (Test-Pattern '"Sleep mode"\s*,') "sleep prompt is available" $true
Write-Check "command label: Movie time" (Test-Pattern '"Movie time"\s*,') "movie prompt is available" $true

Write-Check "plan is propose-only" (Test-Pattern 'body\["execute"\]\s*=\s*false') "board never auto-runs /plan output" $true
Write-Check "agent mode enabled" (Test-Pattern 'body\["agent_mode"\]\s*=\s*true') "planner trace path remains enabled" $true
Write-Check "execute endpoint present" (Test-Pattern '"/execute"') "confirmed actions use POST /execute" $true

Write-Check "confirm key gates execution" (Test-Pattern '(?s)case\s+KEY_CONFIRM:.*confirmAndExecute\(\)') "physical key is required before execution" $true
Write-Check "reject key discards proposal" (Test-Pattern '(?s)case\s+KEY_REJECT:.*g_hasProposal\s*=\s*false') "user can discard pending actions" $true
Write-Check "BOOT fallback documented" (Test-Pattern 'BOOT=plan-fallback') "single-key fallback remains visible in serial logs" $true
Write-Check "serial test route exists" (Test-Pattern 'homecue:plan') "automation can trigger /plan without physical keys" $true
Write-Check "serial execute route exists" (Test-Pattern 'homecue:execute') "automation can confirm /execute without physical keys" $true

Write-Check "voice hook exists" (Test-Pattern 'static\s+int\s+pollVoiceCommand\(\)') "ESP-SR integration has one function boundary" $true
Write-Check "vendor TODO markers" (Test-Pattern 'TODO\[VENDOR\]') "vendor audio/RGB integration points are explicit" $true
Write-Check "voice placeholder is inert" (Test-Pattern '(?s)static\s+int\s+pollVoiceCommand\(\).*return\s+-1\s*;') "button route stays stable until ESP-SR is wired" $false

Write-Check "health probe" (Test-Pattern 'checkHealth\(\)') "gateway reachability is visible at boot" $false
Write-Check "precheck logging" (Test-Pattern 'resp\["precheck"\]') "edge guard decisions are visible on serial" $false
Write-Check "bounded plan timeout" (Test-Pattern 'HTTP_TIMEOUT_PLAN_MS\s*=\s*60000') "Arduino HTTP timeout fits uint16_t" $false

Write-Host ""
if ($Required -and $Failures.Count -gt 0) {
  Write-Host "Firmware flow check failed required item(s):" -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Firmware flow check complete."
exit 0
