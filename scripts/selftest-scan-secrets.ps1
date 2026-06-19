param()

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$TestFile = Join-Path $Root ".scan-secrets-selftest-untracked.txt"

function Invoke-Scan {
  param([string[]]$Arguments)

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\scan-secrets.ps1" @Arguments 2>&1
  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = ($Output -join [Environment]::NewLine)
  }
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

try {
  $Marker = "dev" + "post"
  [System.IO.File]::WriteAllText($TestFile, "temporary $Marker marker for scan self-test`n", [System.Text.Encoding]::UTF8)

  $DefaultAll = Invoke-Scan @("-All", "-Quiet")
  Assert-True ($DefaultAll.ExitCode -eq 0) "Default -All should ignore the temporary untracked self-test file."

  $AllWithUntracked = Invoke-Scan @("-All", "-IncludeUntracked", "-Quiet")
  Assert-True ($AllWithUntracked.ExitCode -ne 0) "-All -IncludeUntracked should fail on the temporary untracked self-test file."
  Assert-True ($AllWithUntracked.Output -match "\.scan-secrets-selftest-untracked\.txt") "Failure output should include the temporary self-test file path."
  Assert-True ($AllWithUntracked.Output -match "keyword:hackathon-portal") "Failure output should include the expected keyword finding."
}
finally {
  Remove-Item -LiteralPath $TestFile -Force -ErrorAction SilentlyContinue
}

$PostCleanup = Invoke-Scan @("-All", "-IncludeUntracked", "-Quiet")
Assert-True ($PostCleanup.ExitCode -eq 0) "Post-cleanup -All -IncludeUntracked scan should pass."

Write-Host "scan-secrets self-test passed."
