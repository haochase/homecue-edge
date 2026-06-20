param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArguments = @()
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$LatestResultJsonPath = Join-Path $Root "assets\tmp\computer-loop-check-latest.json"

if ($RemainingArguments -contains "-ResultJsonPath") {
  throw "check-computer-loop-latest.ps1 always writes assets/tmp/computer-loop-check-latest.json; omit -ResultJsonPath."
}

if ($RemainingArguments -contains "-DryRun") {
  throw "Use check-computer-loop.ps1 -DryRun to inspect the plan without overwriting latest result evidence."
}

& "$PSScriptRoot\check-computer-loop.ps1" @RemainingArguments -ResultJsonPath $LatestResultJsonPath
exit $LASTEXITCODE
