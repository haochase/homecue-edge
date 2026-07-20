param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseSnapshotJsonPath,
  [string]$ReleaseSnapshotMarkdownPath = "",
  [datetime]$MinimumSourceWriteTime = [datetime]::MinValue,
  [string]$ResultJsonPath = "",
  [switch]$Required
)

$ErrorActionPreference = "Stop"

function New-ParentDirectory {
  param([string]$Path)
  $Parent = Split-Path -Parent $Path
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent | Out-Null
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Test-HasProperty {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $false
  }

  return $Object.PSObject.Properties.Name -contains $Name
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )

  if (Test-HasProperty -Object $Object -Name $Name) {
    return $Object.$Name
  }

  return $Default
}

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = ""
  )

  $Status = if ($Ok) { "OK" } else { "WARN" }
  $DetailSuffix = if ($Detail) { " - $Detail" } else { "" }
  Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $DetailSuffix)

  $script:Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      ok = [bool]$Ok
      detail = $Detail
    })

  if (-not $Ok) {
    $script:Failures.Add($Name)
  }
}

function Add-SourcePathCheck {
  param(
    [string]$Name,
    [string]$Path
  )

  $ResolvedPath = ""
  $Exists = [bool]($Path -and (Test-Path -LiteralPath $Path))
  if ($Exists) {
    $ResolvedPath = (Resolve-Path -LiteralPath $Path).Path
  }

  $LastWriteTime = $null
  $Fresh = $false
  if ($Exists) {
    $LastWriteTime = (Get-Item -LiteralPath $ResolvedPath).LastWriteTime
    $Fresh = $LastWriteTime -ge $MinimumSourceWriteTime
  }

  Add-Check ("source path exists: {0}" -f $Name) $Exists $Path
  Add-Check ("source path fresh: {0}" -f $Name) $Fresh ("lastWrite={0:o}; minimum={1:o}" -f $LastWriteTime, $MinimumSourceWriteTime)
  Add-Check ("source path not newer than snapshot: {0}" -f $Name) ($script:SnapshotCheckedAtParsed -and $Exists -and $LastWriteTime -le $script:SnapshotCheckedAt) ("lastWrite={0:o}; checkedAt={1:o}" -f $LastWriteTime, $script:SnapshotCheckedAt)

  $script:Sources.Add([pscustomobject]@{
      name = $Name
      path = $Path
      resolvedPath = $ResolvedPath
      exists = [bool]$Exists
      fresh = [bool]$Fresh
      notNewerThanSnapshot = [bool]($script:SnapshotCheckedAtParsed -and $Exists -and $LastWriteTime -le $script:SnapshotCheckedAt)
      lastWriteTime = if ($LastWriteTime) { $LastWriteTime.ToString("o") } else { "" }
    })
}

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$Sources = New-Object System.Collections.Generic.List[object]
$SnapshotCheckedAt = [datetime]::MinValue
$SnapshotCheckedAtParsed = $false

Write-Host "HomeCue Edge release snapshot freshness check"
Write-Host ("JSON             : {0}" -f $ReleaseSnapshotJsonPath)
if ($ReleaseSnapshotMarkdownPath) {
  Write-Host ("Markdown         : {0}" -f $ReleaseSnapshotMarkdownPath)
}
Write-Host ("Minimum source ts: {0:o}" -f $MinimumSourceWriteTime)
Write-Host ""

$Snapshot = Read-JsonFile -Path $ReleaseSnapshotJsonPath
Add-Check "release snapshot json parsed" ($null -ne $Snapshot) ""

$SnapshotExists = Test-Path -LiteralPath $ReleaseSnapshotJsonPath
Add-Check "release snapshot json exists" $SnapshotExists $ReleaseSnapshotJsonPath
if ($SnapshotExists) {
  $SnapshotWriteTime = (Get-Item -LiteralPath $ReleaseSnapshotJsonPath).LastWriteTime
  Add-Check "release snapshot json fresh" ($SnapshotWriteTime -ge $MinimumSourceWriteTime) ("lastWrite={0:o}; minimum={1:o}" -f $SnapshotWriteTime, $MinimumSourceWriteTime)
}

if ($ReleaseSnapshotMarkdownPath) {
  $MarkdownExists = Test-Path -LiteralPath $ReleaseSnapshotMarkdownPath
  Add-Check "release snapshot markdown exists" $MarkdownExists $ReleaseSnapshotMarkdownPath
  if ($MarkdownExists) {
    $MarkdownWriteTime = (Get-Item -LiteralPath $ReleaseSnapshotMarkdownPath).LastWriteTime
    Add-Check "release snapshot markdown fresh" ($MarkdownWriteTime -ge $MinimumSourceWriteTime) ("lastWrite={0:o}; minimum={1:o}" -f $MarkdownWriteTime, $MinimumSourceWriteTime)
  }
}

if ($Snapshot) {
  $CheckedAtText = [string](Get-PropertyValue -Object $Snapshot -Name "checkedAt" -Default "")
  $script:SnapshotCheckedAt = [datetime]::MinValue
  $script:SnapshotCheckedAtParsed = [datetime]::TryParse($CheckedAtText, [ref]$script:SnapshotCheckedAt)
  Add-Check "release snapshot checkedAt exists" ([bool]$CheckedAtText) $CheckedAtText
  Add-Check "release snapshot checkedAt parses" $script:SnapshotCheckedAtParsed $CheckedAtText
  if ($script:SnapshotCheckedAtParsed) {
    Add-Check "release snapshot checkedAt fresh" ($script:SnapshotCheckedAt -ge $MinimumSourceWriteTime) ("checkedAt={0:o}; minimum={1:o}" -f $script:SnapshotCheckedAt, $MinimumSourceWriteTime)
  }

  $SourcePaths = Get-PropertyValue -Object $Snapshot -Name "sourcePaths"
  Add-Check "sourcePaths section exists" ($null -ne $SourcePaths) ""

  if ($SourcePaths) {
    Add-SourcePathCheck -Name "intentJsonPath" -Path ([string](Get-PropertyValue -Object $SourcePaths -Name "intentJsonPath" -Default ""))
    Add-SourcePathCheck -Name "proofInventoryJsonPath" -Path ([string](Get-PropertyValue -Object $SourcePaths -Name "proofInventoryJsonPath" -Default ""))
    Add-SourcePathCheck -Name "readinessJsonPath" -Path ([string](Get-PropertyValue -Object $SourcePaths -Name "readinessJsonPath" -Default ""))
    Add-SourcePathCheck -Name "portStateJsonPath" -Path ([string](Get-PropertyValue -Object $SourcePaths -Name "portStateJsonPath" -Default ""))
    Add-SourcePathCheck -Name "portSchemaJsonPath" -Path ([string](Get-PropertyValue -Object $SourcePaths -Name "portSchemaJsonPath" -Default ""))
  }
}

$FreshnessOk = $Failures.Count -eq 0
Write-Host ""
Write-Host ("Summary: {0}" -f $(if ($FreshnessOk) { "release snapshot sources fresh" } else { "release snapshot freshness warning" }))

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result = @{
    checkedAt = (Get-Date).ToString("o")
    releaseSnapshotJsonPath = $ReleaseSnapshotJsonPath
    releaseSnapshotMarkdownPath = $ReleaseSnapshotMarkdownPath
    minimumSourceWriteTime = $MinimumSourceWriteTime.ToString("o")
    ok = [bool]$FreshnessOk
    requiredMode = [bool]$Required
    failureCount = $Failures.Count
    failures = [string[]]$Failures.ToArray()
    sources = [object[]]$Sources.ToArray()
    checks = [object[]]$Checks.ToArray()
  }
  $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result  : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($Required -and -not $FreshnessOk) {
  Write-Host "Release snapshot freshness check failed." -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Release snapshot freshness check complete."
exit 0
