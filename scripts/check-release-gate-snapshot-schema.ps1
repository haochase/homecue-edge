param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseSnapshotJsonPath,
  [string]$ReleaseSnapshotMarkdownPath = "",
  [string]$ResultJsonPath = "",
  [switch]$Required
)

$ErrorActionPreference = "Stop"
$ExpectedSnapshotSchemaName = "homecue-release-gate-snapshot"
$ExpectedSnapshotSchemaVersion = 1
$ExpectedSnapshotGenerator = "check-release-gate-snapshot.ps1"

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

function Test-MarkdownContains {
  param(
    [string]$Markdown,
    [string]$Needle
  )

  if (-not $Needle) {
    return $true
  }

  return $Markdown.Contains($Needle)
}

function Get-MarkdownSectionLines {
  param(
    [string]$Markdown,
    [string]$Heading
  )

  $SectionLines = New-Object System.Collections.Generic.List[string]
  if (-not $Markdown -or -not $Heading) {
    return [string[]]@()
  }

  $InSection = $false
  foreach ($Line in @($Markdown -split "`r?`n")) {
    if ($Line -eq $Heading) {
      $InSection = $true
      continue
    }

    if ($InSection -and $Line.StartsWith("## ")) {
      break
    }

    if ($InSection) {
      $SectionLines.Add([string]$Line)
    }
  }

  return [string[]]$SectionLines.ToArray()
}

function Get-MarkdownBacktickListItems {
  param([string[]]$Lines)

  $Items = New-Object System.Collections.Generic.List[string]
  foreach ($Line in @($Lines)) {
    $Trimmed = ([string]$Line).Trim()
    if ($Trimmed -match '^- `([^`]+)`$') {
      $Items.Add([string]$Matches[1])
    }
  }

  return [string[]]$Items.ToArray()
}

function Get-MarkdownNextActionEntries {
  param([string[]]$Lines)

  $Entries = New-Object System.Collections.Generic.List[object]
  foreach ($Line in @($Lines)) {
    $Trimmed = ([string]$Line).Trim()
    if ($Trimmed -match '^\d+\. `\[(release|operational)/([^\]]+)\]` (.+)$') {
      $Entries.Add([pscustomobject]@{
          key = ("{0}:{1}" -f [string]$Matches[1], [string]$Matches[2])
          action = [string]$Matches[3]
        })
    }
  }

  return [object[]]$Entries.ToArray()
}

function Get-MarkdownBacktickKeyValueEntries {
  param([string[]]$Lines)

  $Entries = New-Object System.Collections.Generic.List[object]
  foreach ($Line in @($Lines)) {
    $Trimmed = ([string]$Line).Trim()
    if ($Trimmed -match '^- ([^:]+): `([^`]+)`$') {
      $Entries.Add([pscustomobject]@{
          key = [string]$Matches[1]
          value = [string]$Matches[2]
          pair = ("{0}={1}" -f [string]$Matches[1], [string]$Matches[2])
        })
    }
  }

  return [object[]]$Entries.ToArray()
}

function Get-MarkdownCheckEntries {
  param([string[]]$Lines)

  $Entries = New-Object System.Collections.Generic.List[object]
  foreach ($Line in @($Lines)) {
    $Trimmed = ([string]$Line).Trim()
    if ($Trimmed -match '^- \[(OK|WARN)\] `([^`]+)`(?: - (.*))?$') {
      $Detail = ""
      if ($Matches.Count -ge 4) {
        $Detail = [string]$Matches[3]
      }
      $Entries.Add([pscustomobject]@{
          name = [string]$Matches[2]
          status = [string]$Matches[1]
          detail = $Detail
          pair = ("{0}`t{1}`t{2}" -f [string]$Matches[2], [string]$Matches[1], $Detail)
        })
    }
  }

  return [object[]]$Entries.ToArray()
}

function Get-MarkdownAlibabaInvalidImageEntries {
  param([string[]]$Lines)

  $Entries = New-Object System.Collections.Generic.List[object]
  foreach ($Line in @($Lines)) {
    $Trimmed = ([string]$Line).Trim()
    if ($Trimmed -match '^- `([^`]+)` length `([0-9]+)` reason `([^`]+)`$') {
      $Entries.Add([pscustomobject]@{
          name = [string]$Matches[1]
          length = [int64]$Matches[2]
          reason = [string]$Matches[3]
          pair = ("{0}`t{1}`t{2}" -f [string]$Matches[1], [int64]$Matches[2], [string]$Matches[3])
        })
    }
  }

  return [object[]]$Entries.ToArray()
}

function Get-MarkdownAlibabaValidImageEntries {
  param([string[]]$Lines)

  $Entries = New-Object System.Collections.Generic.List[object]
  foreach ($Line in @($Lines)) {
    $Trimmed = ([string]$Line).Trim()
    if ($Trimmed -match '^- `([^`]+)` length `([0-9]+)`$') {
      $Entries.Add([pscustomobject]@{
          name = [string]$Matches[1]
          length = [int64]$Matches[2]
          pair = ("{0}`t{1}" -f [string]$Matches[1], [int64]$Matches[2])
        })
    }
  }

  return [object[]]$Entries.ToArray()
}

function Test-UniqueNonEmptyStrings {
  param([object[]]$Values)

  $Seen = @{}
  foreach ($Value in @($Values)) {
    $Text = [string]$Value
    if (-not $Text) {
      return $false
    }
    if ($Seen.ContainsKey($Text)) {
      return $false
    }
    $Seen[$Text] = $true
  }

  return $true
}

function Add-UniqueString {
  param(
    [System.Collections.Generic.List[string]]$List,
    [string]$Value
  )

  if ($Value -and -not $List.Contains($Value)) {
    $List.Add($Value)
  }
}

function Get-SortedStringSet {
  param([object[]]$Values)

  return [string[]]@(
    @($Values | ForEach-Object { [string]$_ } | Where-Object { $_ }) |
      Sort-Object -Unique
  )
}

function Test-SameStringSet {
  param(
    [object[]]$Actual,
    [object[]]$Expected
  )

  $ActualSet = Get-SortedStringSet -Values $Actual
  $ExpectedSet = Get-SortedStringSet -Values $Expected
  return (($ActualSet -join "`n") -eq ($ExpectedSet -join "`n"))
}

function Get-NormalizedPathForCompare {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  try {
    if (Test-Path -LiteralPath $Path) {
      return (Resolve-Path -LiteralPath $Path).Path.ToLowerInvariant()
    }
  } catch {
    return $Path.ToLowerInvariant()
  }

  return $Path.ToLowerInvariant()
}

function Get-NumericPropertyEntries {
  param([object]$Object)

  $Entries = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Object) {
    return [object[]]@()
  }

  foreach ($Property in @($Object.PSObject.Properties | Sort-Object Name)) {
    $Value = 0
    $ParseOk = [int]::TryParse([string]$Property.Value, [ref]$Value)
    $Entries.Add([pscustomobject]@{
        name = [string]$Property.Name
        value = [int]$Value
        parseOk = [bool]$ParseOk
      })
  }

  return [object[]]$Entries.ToArray()
}

function Get-NumericEntrySum {
  param([object[]]$Entries)

  $Sum = 0
  foreach ($Entry in @($Entries)) {
    $Sum += [int]$Entry.value
  }

  return $Sum
}

function Test-NumericEntries {
  param([object[]]$Entries)

  foreach ($Entry in @($Entries)) {
    if (-not [bool]$Entry.parseOk -or [int]$Entry.value -lt 0) {
      return $false
    }
  }

  return $true
}

function Get-NumericEntryValue {
  param(
    [object[]]$Entries,
    [string]$Name
  )

  foreach ($Entry in @($Entries)) {
    if ($Entry.name -eq $Name) {
      return [int]$Entry.value
    }
  }

  return 0
}

function Test-AbsolutePath {
  param([string]$Path)

  if (-not $Path) {
    return $false
  }

  return [System.IO.Path]::IsPathRooted($Path)
}

function Test-RoundTripTimestamp {
  param([string]$Value)

  if (-not $Value) {
    return $false
  }

  $Parsed = [System.DateTimeOffset]::MinValue
  return [System.DateTimeOffset]::TryParseExact(
    $Value,
    "o",
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::None,
    [ref]$Parsed
  )
}

function Test-NextActionCoversId {
  param(
    [object[]]$Actions,
    [string]$Id
  )

  $LowerActions = @($Actions | ForEach-Object { ([string]$_).ToLowerInvariant() })
  foreach ($Action in $LowerActions) {
    if ($Action.Contains($Id.ToLowerInvariant())) {
      return $true
    }

    if ($Id -eq "git-worktree" -and $Action.Contains("repo") -and ($Action.Contains("stage") -or $Action.Contains("bucket"))) {
      return $true
    }
    if ($Id -eq "alibaba-usage-image" -and $Action.Contains("alibaba") -and ($Action.Contains("usage") -or $Action.Contains("screenshot"))) {
      return $true
    }
    if ($Id -eq "proof-inventory-external-release" -and $Action.Contains("proof inventory") -and ($Action.Contains("external") -or $Action.Contains("cloud"))) {
      return $true
    }
    if ($Id -eq "esp32-port-state" -and $Action.Contains("esp32") -and ($Action.Contains("serial") -or $Action.Contains("com"))) {
      return $true
    }
  }

  return $false
}

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]

Write-Host "HomeCue Edge release snapshot schema check"
Write-Host ("JSON    : {0}" -f $ReleaseSnapshotJsonPath)
if ($ReleaseSnapshotMarkdownPath) {
  Write-Host ("Markdown: {0}" -f $ReleaseSnapshotMarkdownPath)
}
Write-Host ""

$JsonPath = if (Test-Path -LiteralPath $ReleaseSnapshotJsonPath) {
  (Resolve-Path -LiteralPath $ReleaseSnapshotJsonPath).Path
} else {
  $ReleaseSnapshotJsonPath
}

$MarkdownPath = ""
if ($ReleaseSnapshotMarkdownPath) {
  $MarkdownPath = if (Test-Path -LiteralPath $ReleaseSnapshotMarkdownPath) {
    (Resolve-Path -LiteralPath $ReleaseSnapshotMarkdownPath).Path
  } else {
    $ReleaseSnapshotMarkdownPath
  }
}

$Snapshot = Read-JsonFile -Path $JsonPath
$Markdown = ""
if ($MarkdownPath -and (Test-Path -LiteralPath $MarkdownPath)) {
  $Markdown = Get-Content -LiteralPath $MarkdownPath -Raw
}

Add-Check "release snapshot json parsed" ($null -ne $Snapshot) ""
if ($ReleaseSnapshotMarkdownPath) {
  Add-Check "release snapshot markdown read" ([bool]$Markdown) ""
}

if ($Snapshot) {
  $Schema = Get-PropertyValue -Object $Snapshot -Name "schema"
  $ReadyForSubmit = [bool](Get-PropertyValue -Object $Snapshot -Name "readyForSubmit" -Default $false)
  $CheckedAt = [string](Get-PropertyValue -Object $Snapshot -Name "checkedAt" -Default "")
  $RequiredMode = [bool](Get-PropertyValue -Object $Snapshot -Name "requiredMode" -Default $false)
  $Blockers = @((Get-PropertyValue -Object $Snapshot -Name "blockers" -Default @()))
  $OperationalBlockers = @((Get-PropertyValue -Object $Snapshot -Name "operationalBlockers" -Default @()))
  $NextActions = @((Get-PropertyValue -Object $Snapshot -Name "nextActions" -Default @()))
  $NextActionItems = @((Get-PropertyValue -Object $Snapshot -Name "nextActionItems" -Default @()))
  $BlockerSummary = Get-PropertyValue -Object $Snapshot -Name "blockerSummary"
  $Repo = Get-PropertyValue -Object $Snapshot -Name "repo"
  $Proof = Get-PropertyValue -Object $Snapshot -Name "proof"
  $Readiness = Get-PropertyValue -Object $Snapshot -Name "readiness"
    $Hardware = Get-PropertyValue -Object $Snapshot -Name "hardware"
    $SourcePaths = Get-PropertyValue -Object $Snapshot -Name "sourcePaths"
    $ChecksFromSnapshot = @((Get-PropertyValue -Object $Snapshot -Name "checks" -Default @()))
    $SnapshotCheckNames = New-Object System.Collections.Generic.List[string]
    $SnapshotCheckPairs = New-Object System.Collections.Generic.List[string]
    foreach ($Check in $ChecksFromSnapshot) {
      $CheckName = [string](Get-PropertyValue -Object $Check -Name "name" -Default "")
      $CheckStatus = [string](Get-PropertyValue -Object $Check -Name "status" -Default "")
      $CheckDetail = [string](Get-PropertyValue -Object $Check -Name "detail" -Default "")
      $SnapshotCheckNames.Add($CheckName)
      $SnapshotCheckPairs.Add(("{0}`t{1}`t{2}" -f $CheckName, $CheckStatus, $CheckDetail))
    }
    $SnapshotOk = [bool](Get-PropertyValue -Object $Snapshot -Name "ok" -Default $false)
  $SnapshotFailureCount = [int](Get-PropertyValue -Object $Snapshot -Name "failureCount" -Default -1)
  $SnapshotFailures = @((Get-PropertyValue -Object $Snapshot -Name "failures" -Default @()))
  $FailedChecksFromSnapshot = @($ChecksFromSnapshot | Where-Object {
      ((Test-HasProperty -Object $_ -Name "ok") -and -not [bool]$_.ok) -or
      ([string](Get-PropertyValue -Object $_ -Name "status" -Default "") -eq "WARN")
    })
  $ExpectedBlockers = New-Object System.Collections.Generic.List[string]
  $ExpectedOperationalBlockers = New-Object System.Collections.Generic.List[string]
  $RepoDirtyCount = -1
  $RepoWarningCount = -1
  $ProofReadyForExternalRelease = $false
  $ProofReadyForExternalReleasePresent = $false
  $ReadinessReadyForRelease = $false
  $ReadinessReadyForReleasePresent = $false
  $ReadinessBlockingGapCount = -1
  $RepoBucketCountEntries = @()
  $RepoBucketReviewCountEntries = @()

  Add-Check "schema section exists" ($null -ne $Schema) ""
  if ($Schema) {
    $SchemaName = [string](Get-PropertyValue -Object $Schema -Name "name" -Default "")
    $SchemaVersion = [int](Get-PropertyValue -Object $Schema -Name "version" -Default 0)
    $SchemaGenerator = [string](Get-PropertyValue -Object $Schema -Name "generator" -Default "")
    Add-Check "schema name matches" ($SchemaName -eq $ExpectedSnapshotSchemaName) ("name={0}" -f $SchemaName)
    Add-Check "schema version matches" ($SchemaVersion -eq $ExpectedSnapshotSchemaVersion) ("version={0}" -f $SchemaVersion)
    Add-Check "schema generator matches" ($SchemaGenerator -eq $ExpectedSnapshotGenerator) ("generator={0}" -f $SchemaGenerator)
  }
  Add-Check "checkedAt property exists" (Test-HasProperty -Object $Snapshot -Name "checkedAt") ("checkedAt={0}" -f $CheckedAt)
  Add-Check "checkedAt is round-trip timestamp" (Test-RoundTripTimestamp -Value $CheckedAt) ("checkedAt={0}" -f $CheckedAt)
  Add-Check "requiredMode property exists" (Test-HasProperty -Object $Snapshot -Name "requiredMode") ("requiredMode={0}" -f $RequiredMode)
  Add-Check "readyForSubmit property exists" (Test-HasProperty -Object $Snapshot -Name "readyForSubmit") ("ready={0}" -f $ReadyForSubmit)
  Add-Check "blockers property exists" (Test-HasProperty -Object $Snapshot -Name "blockers") ("count={0}" -f $Blockers.Count)
  Add-Check "operationalBlockers property exists" (Test-HasProperty -Object $Snapshot -Name "operationalBlockers") ("count={0}" -f $OperationalBlockers.Count)
  Add-Check "nextActions property exists" (Test-HasProperty -Object $Snapshot -Name "nextActions") ("count={0}" -f $NextActions.Count)
  Add-Check "nextActionItems property exists" (Test-HasProperty -Object $Snapshot -Name "nextActionItems") ("count={0}" -f $NextActionItems.Count)
  Add-Check "blockerSummary property exists" (Test-HasProperty -Object $Snapshot -Name "blockerSummary") ""
  Add-Check "nextActions populated" ($NextActions.Count -gt 0) ("count={0}" -f $NextActions.Count)
  Add-Check "nextActionItems populated" ($NextActionItems.Count -gt 0) ("count={0}" -f $NextActionItems.Count)
  Add-Check "blockers are unique non-empty strings" (Test-UniqueNonEmptyStrings -Values $Blockers) ("count={0}" -f $Blockers.Count)
  Add-Check "operational blockers are unique non-empty strings" (Test-UniqueNonEmptyStrings -Values $OperationalBlockers) ("count={0}" -f $OperationalBlockers.Count)
  Add-Check "next actions are non-empty strings" (Test-UniqueNonEmptyStrings -Values $NextActions) ("count={0}" -f $NextActions.Count)
  $ActionItemKeys = New-Object System.Collections.Generic.List[string]
  $ActionItemActions = New-Object System.Collections.Generic.List[string]
  $ActionItemShapeOk = $true
  foreach ($Item in $NextActionItems) {
    $ItemId = [string](Get-PropertyValue -Object $Item -Name "id" -Default "")
    $ItemCategory = [string](Get-PropertyValue -Object $Item -Name "category" -Default "")
    $ItemAction = [string](Get-PropertyValue -Object $Item -Name "action" -Default "")
    if (-not $ItemId -or -not $ItemCategory -or -not $ItemAction) {
      $ActionItemShapeOk = $false
    }
    if ($ItemCategory -ne "release" -and $ItemCategory -ne "operational") {
      $ActionItemShapeOk = $false
    }
    $ActionItemKeys.Add(("{0}:{1}" -f $ItemCategory, $ItemId))
    $ActionItemActions.Add($ItemAction)
  }
  Add-Check "nextActionItems include id category action" $ActionItemShapeOk ("items={0}" -f $NextActionItems.Count)
  Add-Check "nextActionItems are unique by category/id" (Test-UniqueNonEmptyStrings -Values ([object[]]$ActionItemKeys.ToArray())) ("count={0}" -f $ActionItemKeys.Count)
  Add-Check "nextActionItems actions match nextActions" (Test-SameStringSet -Actual ([object[]]$ActionItemActions.ToArray()) -Expected $NextActions) ("items={0}; actions={1}" -f $ActionItemActions.Count, $NextActions.Count)
  if ($BlockerSummary) {
    Add-Check "blockerSummary release count exists" (Test-HasProperty -Object $BlockerSummary -Name "releaseBlockerCount") ""
    Add-Check "blockerSummary operational count exists" (Test-HasProperty -Object $BlockerSummary -Name "operationalBlockerCount") ""
    Add-Check "blockerSummary total count exists" (Test-HasProperty -Object $BlockerSummary -Name "totalBlockerCount") ""
    Add-Check "blockerSummary next action item count exists" (Test-HasProperty -Object $BlockerSummary -Name "nextActionItemCount") ""
    Add-Check "blockerSummary release bool exists" (Test-HasProperty -Object $BlockerSummary -Name "hasReleaseBlockers") ""
    Add-Check "blockerSummary operational bool exists" (Test-HasProperty -Object $BlockerSummary -Name "hasOperationalBlockers") ""
    Add-Check "blockerSummary blocked bool exists" (Test-HasProperty -Object $BlockerSummary -Name "blocked") ""
    Add-Check "blockerSummary readyForSubmit exists" (Test-HasProperty -Object $BlockerSummary -Name "readyForSubmit") ""

    $ReleaseBlockerCount = [int](Get-PropertyValue -Object $BlockerSummary -Name "releaseBlockerCount" -Default -1)
    $OperationalBlockerCount = [int](Get-PropertyValue -Object $BlockerSummary -Name "operationalBlockerCount" -Default -1)
    $TotalBlockerCount = [int](Get-PropertyValue -Object $BlockerSummary -Name "totalBlockerCount" -Default -1)
    $NextActionItemCount = [int](Get-PropertyValue -Object $BlockerSummary -Name "nextActionItemCount" -Default -1)
    $HasReleaseBlockers = [bool](Get-PropertyValue -Object $BlockerSummary -Name "hasReleaseBlockers" -Default $false)
    $HasOperationalBlockers = [bool](Get-PropertyValue -Object $BlockerSummary -Name "hasOperationalBlockers" -Default $false)
    $Blocked = [bool](Get-PropertyValue -Object $BlockerSummary -Name "blocked" -Default $false)
    $SummaryReadyForSubmit = [bool](Get-PropertyValue -Object $BlockerSummary -Name "readyForSubmit" -Default $false)
    $ExpectedTotalBlockerCount = $Blockers.Count + $OperationalBlockers.Count

    Add-Check "blockerSummary release count matches blockers" ($ReleaseBlockerCount -eq $Blockers.Count) ("summary={0}; blockers={1}" -f $ReleaseBlockerCount, $Blockers.Count)
    Add-Check "blockerSummary operational count matches blockers" ($OperationalBlockerCount -eq $OperationalBlockers.Count) ("summary={0}; blockers={1}" -f $OperationalBlockerCount, $OperationalBlockers.Count)
    Add-Check "blockerSummary total count matches blockers" ($TotalBlockerCount -eq $ExpectedTotalBlockerCount) ("summary={0}; blockers={1}" -f $TotalBlockerCount, $ExpectedTotalBlockerCount)
    Add-Check "blockerSummary next action item count matches" ($NextActionItemCount -eq $NextActionItems.Count) ("summary={0}; items={1}" -f $NextActionItemCount, $NextActionItems.Count)
    Add-Check "blockerSummary release bool matches" ($HasReleaseBlockers -eq ($Blockers.Count -gt 0)) ("summary={0}; blockers={1}" -f $HasReleaseBlockers, $Blockers.Count)
    Add-Check "blockerSummary operational bool matches" ($HasOperationalBlockers -eq ($OperationalBlockers.Count -gt 0)) ("summary={0}; blockers={1}" -f $HasOperationalBlockers, $OperationalBlockers.Count)
    Add-Check "blockerSummary blocked bool matches" ($Blocked -eq ($ExpectedTotalBlockerCount -gt 0)) ("summary={0}; blockers={1}" -f $Blocked, $ExpectedTotalBlockerCount)
    Add-Check "blockerSummary readyForSubmit matches" ($SummaryReadyForSubmit -eq $ReadyForSubmit) ("summary={0}; ready={1}" -f $SummaryReadyForSubmit, $ReadyForSubmit)
  }
  Add-Check "ready snapshot has no release blockers" ((-not $ReadyForSubmit) -or $Blockers.Count -eq 0) ("ready={0}, blockers={1}" -f $ReadyForSubmit, $Blockers.Count)
  foreach ($Blocker in $Blockers) {
    Add-Check ("next actions cover blocker '{0}'" -f $Blocker) (Test-NextActionCoversId -Actions $NextActions -Id ([string]$Blocker))
    $MatchingItem = @($NextActionItems | Where-Object {
        [string](Get-PropertyValue -Object $_ -Name "category" -Default "") -eq "release" -and
        [string](Get-PropertyValue -Object $_ -Name "id" -Default "") -eq [string]$Blocker
      })
    Add-Check ("nextActionItems cover release blocker '{0}'" -f $Blocker) ($MatchingItem.Count -eq 1)
  }
  foreach ($Blocker in $OperationalBlockers) {
    Add-Check ("next actions cover operational blocker '{0}'" -f $Blocker) (Test-NextActionCoversId -Actions $NextActions -Id ([string]$Blocker))
    $MatchingItem = @($NextActionItems | Where-Object {
        [string](Get-PropertyValue -Object $_ -Name "category" -Default "") -eq "operational" -and
        [string](Get-PropertyValue -Object $_ -Name "id" -Default "") -eq [string]$Blocker
      })
    Add-Check ("nextActionItems cover operational blocker '{0}'" -f $Blocker) ($MatchingItem.Count -eq 1)
  }
  $ExpectedActionItemKeys = New-Object System.Collections.Generic.List[string]
  foreach ($Blocker in $Blockers) {
    $ExpectedActionItemKeys.Add(("release:{0}" -f [string]$Blocker))
  }
  foreach ($Blocker in $OperationalBlockers) {
    $ExpectedActionItemKeys.Add(("operational:{0}" -f [string]$Blocker))
  }
  if ($ExpectedActionItemKeys.Count -eq 0) {
    $ExpectedActionItemKeys.Add("release:final-release-checks")
  }
  Add-Check "nextActionItems match current blocker set" `
    (Test-SameStringSet -Actual ([object[]]$ActionItemKeys.ToArray()) -Expected ([object[]]$ExpectedActionItemKeys.ToArray())) `
    ("actual={0}; expected={1}" -f ($ActionItemKeys.ToArray() -join ","), ($ExpectedActionItemKeys.ToArray() -join ","))

  Add-Check "repo section exists" ($null -ne $Repo) ""
  Add-Check "proof section exists" ($null -ne $Proof) ""
  Add-Check "readiness section exists" ($null -ne $Readiness) ""
  Add-Check "hardware section exists" ($null -ne $Hardware) ""
  Add-Check "sourcePaths section exists" ($null -ne $SourcePaths) ""
  $SourcePathChecks = @(
    @{ name = "Intent"; property = "intentJsonPath" },
    @{ name = "Proof inventory"; property = "proofInventoryJsonPath" },
    @{ name = "Readiness"; property = "readinessJsonPath" },
    @{ name = "Port state"; property = "portStateJsonPath" },
    @{ name = "Port schema"; property = "portSchemaJsonPath" }
  )
  if ($SourcePaths) {
    $SourcePathValues = New-Object System.Collections.Generic.List[string]
    foreach ($SourceCheck in $SourcePathChecks) {
      $SourcePath = [string](Get-PropertyValue -Object $SourcePaths -Name $SourceCheck.property -Default "")
      $SourcePathValues.Add((Get-NormalizedPathForCompare -Path $SourcePath))
      Add-Check ("source path is absolute '{0}'" -f $SourceCheck.property) (Test-AbsolutePath -Path $SourcePath) $SourcePath
      Add-Check ("source path exists '{0}'" -f $SourceCheck.property) ([bool]$SourcePath -and (Test-Path -LiteralPath $SourcePath -PathType Leaf)) $SourcePath
    }
    Add-Check "source paths are unique" (Test-UniqueNonEmptyStrings -Values ([object[]]$SourcePathValues.ToArray())) ("count={0}" -f $SourcePathValues.Count)
  }
  Add-Check "checks array populated" ($ChecksFromSnapshot.Count -gt 0) ("checks={0}" -f $ChecksFromSnapshot.Count)
  Add-Check "checks have unique names" (Test-UniqueNonEmptyStrings -Values ([object[]]$SnapshotCheckNames.ToArray())) ("checks={0}" -f $SnapshotCheckNames.Count)
  Add-Check "snapshot ok property exists" (Test-HasProperty -Object $Snapshot -Name "ok") ("ok={0}" -f $SnapshotOk)
  Add-Check "snapshot failure count exists" ($SnapshotFailureCount -ge 0) ("failureCount={0}" -f $SnapshotFailureCount)
  Add-Check "snapshot failures match failure count" ($SnapshotFailures.Count -eq $SnapshotFailureCount) ("failures={0}, failureCount={1}" -f $SnapshotFailures.Count, $SnapshotFailureCount)
  Add-Check "snapshot checks match failure count" ($FailedChecksFromSnapshot.Count -eq $SnapshotFailureCount) ("failedChecks={0}, failureCount={1}" -f $FailedChecksFromSnapshot.Count, $SnapshotFailureCount)
  Add-Check "snapshot ok matches failures" ($SnapshotOk -eq ($SnapshotFailureCount -eq 0 -and $FailedChecksFromSnapshot.Count -eq 0)) ("ok={0}, failureCount={1}, failedChecks={2}" -f $SnapshotOk, $SnapshotFailureCount, $FailedChecksFromSnapshot.Count)

  if ($Repo) {
    $DirtyCount = [int](Get-PropertyValue -Object $Repo -Name "dirtyCount" -Default -1)
    $WarningCount = [int](Get-PropertyValue -Object $Repo -Name "warningCount" -Default -1)
    $Ahead = [int](Get-PropertyValue -Object $Repo -Name "ahead" -Default -1)
    $RepoBucketCountEntries = @(Get-NumericPropertyEntries -Object (Get-PropertyValue -Object $Repo -Name "bucketCounts"))
    $RepoBucketReviewCountEntries = @(Get-NumericPropertyEntries -Object (Get-PropertyValue -Object $Repo -Name "bucketReviewCounts"))
    $BucketCountSum = Get-NumericEntrySum -Entries $RepoBucketCountEntries
    $BucketReviewCountSum = Get-NumericEntrySum -Entries $RepoBucketReviewCountEntries
    $RepoDirtyCount = $DirtyCount
    $RepoWarningCount = $WarningCount
    Add-Check "repo dirty count exists" ($DirtyCount -ge 0) ("dirty={0}" -f $DirtyCount)
    Add-Check "repo warning count exists" ($WarningCount -ge 0) ("warnings={0}" -f $WarningCount)
    Add-Check "repo ahead count exists" ($Ahead -ge 0) ("ahead={0}" -f $Ahead)
    Add-Check "repo bucket counts exist" ($RepoBucketCountEntries.Count -gt 0) ("buckets={0}" -f $RepoBucketCountEntries.Count)
    Add-Check "repo bucket counts are numeric" (Test-NumericEntries -Entries $RepoBucketCountEntries) ("buckets={0}" -f $RepoBucketCountEntries.Count)
    Add-Check "repo bucket counts match dirty count" ($BucketCountSum -eq $DirtyCount) ("bucketSum={0}; dirty={1}" -f $BucketCountSum, $DirtyCount)
    Add-Check "repo bucket review counts exist" ($RepoBucketReviewCountEntries.Count -gt 0) ("buckets={0}" -f $RepoBucketReviewCountEntries.Count)
    Add-Check "repo bucket review counts are numeric" (Test-NumericEntries -Entries $RepoBucketReviewCountEntries) ("buckets={0}" -f $RepoBucketReviewCountEntries.Count)
    Add-Check "repo bucket review counts match warning count" ($BucketReviewCountSum -eq $WarningCount) ("reviewSum={0}; warnings={1}" -f $BucketReviewCountSum, $WarningCount)
    if ($DirtyCount -gt 0) {
      Add-UniqueString -List $ExpectedBlockers -Value "git-worktree"
      Add-Check "dirty repo adds git-worktree blocker" ($Blockers -contains "git-worktree") ("dirty={0}" -f $DirtyCount)
    }
  }

  if ($Proof) {
    $ProofReadyForExternalReleasePresent = Test-HasProperty -Object $Proof -Name "readyForExternalRelease"
    $ProofReadyForExternalRelease = [bool](Get-PropertyValue -Object $Proof -Name "readyForExternalRelease" -Default $false)
    $AlibabaUsageImageCount = [int](Get-PropertyValue -Object $Proof -Name "alibabaUsageImageCount" -Default -1)
    $AlibabaUsageCandidateCount = [int](Get-PropertyValue -Object $Proof -Name "alibabaUsageCandidateCount" -Default -1)
    $AlibabaUsageInvalidImageCount = [int](Get-PropertyValue -Object $Proof -Name "alibabaUsageInvalidImageCount" -Default -1)
    $AlibabaUsageImagesPresent = Test-HasProperty -Object $Proof -Name "alibabaUsageImages"
    $AlibabaUsageImages = @((Get-PropertyValue -Object $Proof -Name "alibabaUsageImages" -Default @()))
    $AlibabaUsageInvalidImagesPresent = Test-HasProperty -Object $Proof -Name "alibabaUsageInvalidImages"
    $AlibabaUsageInvalidImages = @((Get-PropertyValue -Object $Proof -Name "alibabaUsageInvalidImages" -Default @()))
    $AlibabaUsageMinimumBytes = [int](Get-PropertyValue -Object $Proof -Name "alibabaUsageMinimumBytes" -Default -1)
    $AlibabaUsageSignatureRequired = [bool](Get-PropertyValue -Object $Proof -Name "alibabaUsageSignatureRequired" -Default $false)
    $AlibabaUsageSignatureRequiredPresent = Test-HasProperty -Object $Proof -Name "alibabaUsageSignatureRequired"
    $AlibabaManualReview = [string](Get-PropertyValue -Object $Proof -Name "alibabaManualReview" -Default "")
    $AlibabaManualReviewPath = [string](Get-PropertyValue -Object $Proof -Name "alibabaManualReviewPath" -Default "")
    $AlibabaManualReviewImageName = [string](Get-PropertyValue -Object $Proof -Name "alibabaManualReviewImageName" -Default "")
    $AlibabaManualReviewReason = [string](Get-PropertyValue -Object $Proof -Name "alibabaManualReviewReason" -Default "")
    $AlibabaManualReviewMissingFields = @((Get-PropertyValue -Object $Proof -Name "alibabaManualReviewMissingFields" -Default @()))
    $QwenVerification = [string](Get-PropertyValue -Object $Proof -Name "qwenVerification" -Default "")
    $XiaoqianWakeModel = [string](Get-PropertyValue -Object $Proof -Name "xiaoqianWakeModel" -Default "")
    $AlibabaImageNames = New-Object System.Collections.Generic.List[string]
    $AlibabaImagePairs = New-Object System.Collections.Generic.List[string]
    $AlibabaImageShapeOk = $true
    $AlibabaImageLengthsMeetMinimum = $true
    foreach ($Image in $AlibabaUsageImages) {
      $ImageName = [string](Get-PropertyValue -Object $Image -Name "name" -Default "")
      $ImageLength = [int64](Get-PropertyValue -Object $Image -Name "length" -Default -1)
      if (-not $ImageName -or $ImageLength -lt 0) {
        $AlibabaImageShapeOk = $false
      }
      if ($AlibabaUsageMinimumBytes -gt 0 -and $ImageLength -lt $AlibabaUsageMinimumBytes) {
        $AlibabaImageLengthsMeetMinimum = $false
      }
      $AlibabaImageNames.Add($ImageName)
      $AlibabaImagePairs.Add(("{0}`t{1}" -f $ImageName, $ImageLength))
    }
    $AlibabaInvalidImageNames = New-Object System.Collections.Generic.List[string]
    $AlibabaInvalidImagePairs = New-Object System.Collections.Generic.List[string]
    $AlibabaInvalidImageShapeOk = $true
    foreach ($InvalidImage in $AlibabaUsageInvalidImages) {
      $InvalidImageName = [string](Get-PropertyValue -Object $InvalidImage -Name "name" -Default "")
      $InvalidImageLength = [int64](Get-PropertyValue -Object $InvalidImage -Name "length" -Default -1)
      $InvalidImageReason = [string](Get-PropertyValue -Object $InvalidImage -Name "reason" -Default "")
      if (-not $InvalidImageName -or $InvalidImageLength -lt 0 -or -not $InvalidImageReason) {
        $AlibabaInvalidImageShapeOk = $false
      }
      $AlibabaInvalidImageNames.Add($InvalidImageName)
      $AlibabaInvalidImagePairs.Add(("{0}`t{1}`t{2}" -f $InvalidImageName, $InvalidImageLength, $InvalidImageReason))
    }
    $AlibabaImageNameOverlap = @($AlibabaImageNames.ToArray() | Where-Object {
      $_ -and $AlibabaInvalidImageNames.Contains($_)
    })
    Add-Check "proof external release readiness exists" $ProofReadyForExternalReleasePresent ("ready={0}" -f $ProofReadyForExternalRelease)
    Add-Check "proof alibaba image count exists" ($AlibabaUsageImageCount -ge 0) ("images={0}" -f $AlibabaUsageImageCount)
    Add-Check "proof alibaba candidate count exists" ($AlibabaUsageCandidateCount -ge 0) ("candidates={0}" -f $AlibabaUsageCandidateCount)
    Add-Check "proof alibaba invalid image count exists" ($AlibabaUsageInvalidImageCount -ge 0) ("invalid={0}" -f $AlibabaUsageInvalidImageCount)
    Add-Check "proof alibaba valid image details exist" $AlibabaUsageImagesPresent ("valid_details={0}" -f $AlibabaUsageImages.Count)
    Add-Check "proof alibaba valid image details match count" ($AlibabaUsageImages.Count -eq $AlibabaUsageImageCount) ("details={0}; images={1}" -f $AlibabaUsageImages.Count, $AlibabaUsageImageCount)
    Add-Check "proof alibaba valid image details have shape" $AlibabaImageShapeOk ("details={0}" -f $AlibabaUsageImages.Count)
    Add-Check "proof alibaba valid image names are unique" (Test-UniqueNonEmptyStrings -Values ([object[]]$AlibabaImageNames.ToArray())) ("details={0}" -f $AlibabaUsageImages.Count)
    Add-Check "proof alibaba valid image lengths meet minimum" $AlibabaImageLengthsMeetMinimum ("details={0}; minimum={1}" -f $AlibabaUsageImages.Count, $AlibabaUsageMinimumBytes)
    Add-Check "proof alibaba invalid image details exist" $AlibabaUsageInvalidImagesPresent ("invalid_details={0}" -f $AlibabaUsageInvalidImages.Count)
    Add-Check "proof alibaba invalid image details match count" ($AlibabaUsageInvalidImages.Count -eq $AlibabaUsageInvalidImageCount) ("details={0}; invalid={1}" -f $AlibabaUsageInvalidImages.Count, $AlibabaUsageInvalidImageCount)
    Add-Check "proof alibaba invalid image details have shape" $AlibabaInvalidImageShapeOk ("details={0}" -f $AlibabaUsageInvalidImages.Count)
    Add-Check "proof alibaba invalid image names are unique" (Test-UniqueNonEmptyStrings -Values ([object[]]$AlibabaInvalidImageNames.ToArray())) ("details={0}" -f $AlibabaUsageInvalidImages.Count)
    Add-Check "proof alibaba valid and invalid image names are disjoint" ($AlibabaImageNameOverlap.Count -eq 0) ("overlap={0}" -f ($AlibabaImageNameOverlap -join ","))
    Add-Check "proof alibaba minimum bytes exists" ($AlibabaUsageMinimumBytes -gt 0) ("minimum_bytes={0}" -f $AlibabaUsageMinimumBytes)
    Add-Check "proof alibaba signature required exists" $AlibabaUsageSignatureRequiredPresent ("signature_required={0}" -f $AlibabaUsageSignatureRequired)
    Add-Check "proof alibaba signature required true" ($AlibabaUsageSignatureRequiredPresent -and $AlibabaUsageSignatureRequired) ("signature_required={0}" -f $AlibabaUsageSignatureRequired)
    Add-Check "proof alibaba manual review exists" ([bool]$AlibabaManualReview) ("status={0}" -f $AlibabaManualReview)
    Add-Check "proof alibaba manual review status is known" (@("OK", "WARN") -contains $AlibabaManualReview) ("status={0}" -f $AlibabaManualReview)
    Add-Check "proof alibaba manual review path exists" (Test-HasProperty -Object $Proof -Name "alibabaManualReviewPath") $AlibabaManualReviewPath
    Add-Check "proof alibaba manual review image exists" (Test-HasProperty -Object $Proof -Name "alibabaManualReviewImageName") $AlibabaManualReviewImageName
    Add-Check "proof alibaba manual review reason exists" (Test-HasProperty -Object $Proof -Name "alibabaManualReviewReason") $AlibabaManualReviewReason
    Add-Check "proof alibaba manual review missing fields exist" (Test-HasProperty -Object $Proof -Name "alibabaManualReviewMissingFields") ("missing={0}" -f $AlibabaManualReviewMissingFields.Count)
    if ($AlibabaManualReview -eq "OK") {
      Add-Check "proof alibaba manual review references valid image" ($AlibabaImageNames.Contains($AlibabaManualReviewImageName)) ("image={0}" -f $AlibabaManualReviewImageName)
      Add-Check "proof alibaba manual review has no missing fields" ($AlibabaManualReviewMissingFields.Count -eq 0) ("missing={0}" -f ($AlibabaManualReviewMissingFields -join ","))
    }
    Add-Check "proof alibaba candidate count partitions images" `
      ($AlibabaUsageCandidateCount -ge 0 -and $AlibabaUsageImageCount -ge 0 -and $AlibabaUsageInvalidImageCount -ge 0 -and $AlibabaUsageCandidateCount -eq ($AlibabaUsageImageCount + $AlibabaUsageInvalidImageCount)) `
      ("candidates={0}; images={1}; invalid={2}" -f $AlibabaUsageCandidateCount, $AlibabaUsageImageCount, $AlibabaUsageInvalidImageCount)
    Add-Check "proof qwen verification exists" ([bool]$QwenVerification) ("status={0}" -f $QwenVerification)
    Add-Check "proof xiaoqian wake model exists" ([bool]$XiaoqianWakeModel) ("status={0}" -f $XiaoqianWakeModel)
    Add-Check "proof qwen verification status is known" (@("OK", "WARN") -contains $QwenVerification) ("status={0}" -f $QwenVerification)
    Add-Check "proof xiaoqian wake model status is known" (@("OK", "WARN") -contains $XiaoqianWakeModel) ("status={0}" -f $XiaoqianWakeModel)
    $ExpectedProofReadyForExternalRelease = ($QwenVerification -eq "OK" -and $AlibabaUsageImageCount -gt 0 -and $AlibabaManualReview -eq "OK")
    Add-Check "proof external release readiness matches evidence" `
      ($ProofReadyForExternalRelease -eq $ExpectedProofReadyForExternalRelease) `
      ("actual={0}; expected={1}; qwen={2}; alibaba_images={3}; manual_review={4}" -f $ProofReadyForExternalRelease, $ExpectedProofReadyForExternalRelease, $QwenVerification, $AlibabaUsageImageCount, $AlibabaManualReview)
    if ($AlibabaUsageImageCount -eq 0) {
      Add-UniqueString -List $ExpectedBlockers -Value "alibaba-usage-image"
      Add-Check "missing alibaba image adds blocker" ($Blockers -contains "alibaba-usage-image") ""
    }
    if ($AlibabaUsageImageCount -gt 0 -and $AlibabaManualReview -ne "OK") {
      Add-UniqueString -List $ExpectedBlockers -Value "alibaba-proof-review"
      Add-Check "missing alibaba manual review adds blocker" ($Blockers -contains "alibaba-proof-review") ("status={0}" -f $AlibabaManualReview)
    }
  }

  if ($Readiness) {
    $ReadinessReadyForReleasePresent = Test-HasProperty -Object $Readiness -Name "readyForRelease"
    $ReadinessReadyForRelease = [bool](Get-PropertyValue -Object $Readiness -Name "readyForRelease" -Default $false)
    $ReleaseGapTotalCount = [int](Get-PropertyValue -Object $Readiness -Name "releaseGapTotalCount" -Default -1)
    $BlockingGapCount = [int](Get-PropertyValue -Object $Readiness -Name "blockingGapCount" -Default -1)
    $FollowUpGapCount = [int](Get-PropertyValue -Object $Readiness -Name "followUpGapCount" -Default -1)
    $BlockingGapIds = @((Get-PropertyValue -Object $Readiness -Name "blockingGapIds" -Default @()))
    $FollowUpGapIds = @((Get-PropertyValue -Object $Readiness -Name "followUpGapIds" -Default @()))
    $ReadinessGapIds = New-Object System.Collections.Generic.List[string]
    foreach ($GapId in @($BlockingGapIds + $FollowUpGapIds)) {
      $ReadinessGapIds.Add([string]$GapId)
    }
    $ReadinessGapOverlap = @($BlockingGapIds | Where-Object {
      $_ -and $FollowUpGapIds -contains $_
    })
    $ReadinessBlockingGapCount = $BlockingGapCount
    Add-Check "readiness release readiness exists" $ReadinessReadyForReleasePresent ("ready={0}" -f $ReadinessReadyForRelease)
    Add-Check "readiness release gap total count exists" ($ReleaseGapTotalCount -ge 0) ("total={0}" -f $ReleaseGapTotalCount)
    Add-Check "readiness blocking gap count exists" ($BlockingGapCount -ge 0) ("blocking={0}" -f $BlockingGapCount)
    Add-Check "readiness follow-up gap count exists" ($FollowUpGapCount -ge 0) ("follow_up={0}" -f $FollowUpGapCount)
    Add-Check "readiness release gap total matches parts" `
      ($ReleaseGapTotalCount -ge 0 -and $BlockingGapCount -ge 0 -and $FollowUpGapCount -ge 0 -and $ReleaseGapTotalCount -eq ($BlockingGapCount + $FollowUpGapCount)) `
      ("total={0}; blocking={1}; follow_up={2}" -f $ReleaseGapTotalCount, $BlockingGapCount, $FollowUpGapCount)
    Add-Check "readiness release readiness matches blocking gaps" `
      ($BlockingGapCount -ge 0 -and $ReadinessReadyForRelease -eq ($BlockingGapCount -eq 0)) `
      ("ready={0}; blocking={1}" -f $ReadinessReadyForRelease, $BlockingGapCount)
    Add-Check "readiness blocking ids match count" ($BlockingGapCount -eq $BlockingGapIds.Count) ("ids={0}; count={1}" -f $BlockingGapIds.Count, $BlockingGapCount)
    Add-Check "readiness follow-up ids match count" ($FollowUpGapCount -eq $FollowUpGapIds.Count) ("ids={0}; count={1}" -f $FollowUpGapIds.Count, $FollowUpGapCount)
    Add-Check "readiness gap ids are unique" (Test-UniqueNonEmptyStrings -Values ([object[]]$ReadinessGapIds.ToArray())) ("ids={0}" -f $ReadinessGapIds.Count)
    Add-Check "readiness blocking and follow-up ids are disjoint" ($ReadinessGapOverlap.Count -eq 0) ("overlap={0}" -f ($ReadinessGapOverlap -join ","))
    foreach ($GapId in $BlockingGapIds) {
      Add-UniqueString -List $ExpectedBlockers -Value ([string]$GapId)
      Add-Check ("blockers include readiness gap '{0}'" -f $GapId) ($Blockers -contains [string]$GapId)
    }
  }

  if ($Hardware) {
    $PortState = [string](Get-PropertyValue -Object $Hardware -Name "portState" -Default "")
    $PortSchemaOk = [bool](Get-PropertyValue -Object $Hardware -Name "portSchemaOk" -Default $false)
    $HardwareNextAction = [string](Get-PropertyValue -Object $Hardware -Name "nextAction" -Default "")
    $RecoverySteps = @((Get-PropertyValue -Object $Hardware -Name "recoverySteps" -Default @()))
    Add-Check "hardware port state exists" ([bool]$PortState) ("state={0}" -f $PortState)
    Add-Check "hardware port schema ok" $PortSchemaOk ("ok={0}" -f $PortSchemaOk)
    Add-Check "hardware next action exists" ([bool]$HardwareNextAction) ("length={0}" -f $HardwareNextAction.Length)
    Add-Check "hardware recovery steps populated" ($RecoverySteps.Count -gt 0) ("steps={0}" -f $RecoverySteps.Count)
    if ($PortState -and $PortState -ne "writable" -and $PortState -ne "openable") {
      Add-UniqueString -List $ExpectedOperationalBlockers -Value "esp32-port-state"
      Add-Check "non-ready port adds operational blocker" ($OperationalBlockers -contains "esp32-port-state") ("state={0}" -f $PortState)
    }
  }

  $CanModelReadyForSubmit = (
    $RepoDirtyCount -ge 0 -and
    $RepoWarningCount -ge 0 -and
    $ProofReadyForExternalReleasePresent -and
    $ReadinessReadyForReleasePresent -and
    $ReadinessBlockingGapCount -ge 0
  )
  $ExpectedReadyForSubmit = (
    $CanModelReadyForSubmit -and
    $ProofReadyForExternalRelease -and
    $ReadinessReadyForRelease -and
    $RepoWarningCount -eq 0 -and
    $RepoDirtyCount -eq 0 -and
    $ReadinessBlockingGapCount -eq 0
  )
  Add-Check "readyForSubmit matches modeled release evidence" (
    (-not $CanModelReadyForSubmit) -or $ReadyForSubmit -eq $ExpectedReadyForSubmit
  ) ("actual={0}; expected={1}; modeled={2}" -f $ReadyForSubmit, $ExpectedReadyForSubmit, $CanModelReadyForSubmit)
  Add-Check "release blockers match modeled evidence" (Test-SameStringSet -Actual $Blockers -Expected ([object[]]$ExpectedBlockers.ToArray())) ("actual={0}; expected={1}" -f ($Blockers -join ","), ($ExpectedBlockers.ToArray() -join ","))
  Add-Check "operational blockers match modeled evidence" (Test-SameStringSet -Actual $OperationalBlockers -Expected ([object[]]$ExpectedOperationalBlockers.ToArray())) ("actual={0}; expected={1}" -f ($OperationalBlockers -join ","), ($ExpectedOperationalBlockers.ToArray() -join ","))

  if (-not $ReadyForSubmit) {
    Add-Check "not-ready snapshot explains why" (($Blockers.Count + $OperationalBlockers.Count) -gt 0) ("blockers={0}, operational={1}" -f $Blockers.Count, $OperationalBlockers.Count)
  }

  if ($Markdown) {
    Add-Check "markdown has title" (Test-MarkdownContains -Markdown $Markdown -Needle "# HomeCue Release Gate Snapshot")
    Add-Check "markdown schema marker matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Schema: `{0}/v{1}` generated by `{2}`' -f $ExpectedSnapshotSchemaName, $ExpectedSnapshotSchemaVersion, $ExpectedSnapshotGenerator))
    Add-Check "markdown checkedAt matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Checked at: `{0}`' -f $CheckedAt))
    Add-Check "markdown requiredMode matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Required mode: `{0}`' -f $RequiredMode))
    Add-Check "markdown ready flag matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ("- Ready for submit: **{0}**" -f $ReadyForSubmit))
    Add-Check "markdown has release blockers section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Release Blockers")
    Add-Check "markdown has operational blockers section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Operational Blockers")
    Add-Check "markdown has next actions section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Next Actions")
    Add-Check "markdown has blocker summary section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Blocker Summary")
    Add-Check "markdown has snapshot section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Snapshot")
    Add-Check "markdown has checks section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Checks")
    $MarkdownReleaseBlockers = Get-MarkdownBacktickListItems -Lines (Get-MarkdownSectionLines -Markdown $Markdown -Heading "## Release Blockers")
    $MarkdownOperationalBlockers = Get-MarkdownBacktickListItems -Lines (Get-MarkdownSectionLines -Markdown $Markdown -Heading "## Operational Blockers")
    $MarkdownNextActionEntries = @(Get-MarkdownNextActionEntries -Lines (Get-MarkdownSectionLines -Markdown $Markdown -Heading "## Next Actions"))
    $MarkdownNextActionKeys = @($MarkdownNextActionEntries | ForEach-Object { [string]$_.key })
    $MarkdownNextActionActions = @($MarkdownNextActionEntries | ForEach-Object { [string]$_.action })
    $MarkdownBlockerSummaryEntries = @(Get-MarkdownBacktickKeyValueEntries -Lines (Get-MarkdownSectionLines -Markdown $Markdown -Heading "## Blocker Summary"))
    $MarkdownBlockerSummaryKeys = @($MarkdownBlockerSummaryEntries | ForEach-Object { [string]$_.key })
    $MarkdownBlockerSummaryPairs = @($MarkdownBlockerSummaryEntries | ForEach-Object { [string]$_.pair })
    $MarkdownCheckEntries = @(Get-MarkdownCheckEntries -Lines (Get-MarkdownSectionLines -Markdown $Markdown -Heading "## Checks"))
    $MarkdownCheckNames = @($MarkdownCheckEntries | ForEach-Object { [string]$_.name })
    $MarkdownCheckPairs = @($MarkdownCheckEntries | ForEach-Object { [string]$_.pair })
    Add-Check "markdown release blockers match json" (Test-SameStringSet -Actual $MarkdownReleaseBlockers -Expected $Blockers) ("markdown={0}; json={1}" -f ($MarkdownReleaseBlockers -join ","), ($Blockers -join ","))
    Add-Check "markdown operational blockers match json" (Test-SameStringSet -Actual $MarkdownOperationalBlockers -Expected $OperationalBlockers) ("markdown={0}; json={1}" -f ($MarkdownOperationalBlockers -join ","), ($OperationalBlockers -join ","))
    Add-Check "markdown next action item count matches json" ($MarkdownNextActionEntries.Count -eq $NextActionItems.Count) ("markdown={0}; json={1}" -f $MarkdownNextActionEntries.Count, $NextActionItems.Count)
    Add-Check "markdown next action items are unique" (Test-UniqueNonEmptyStrings -Values $MarkdownNextActionKeys) ("count={0}" -f $MarkdownNextActionKeys.Count)
    Add-Check "markdown next action item keys match json" `
      (Test-SameStringSet -Actual $MarkdownNextActionKeys -Expected ([object[]]$ActionItemKeys.ToArray())) `
      ("markdown={0}; json={1}" -f ($MarkdownNextActionKeys -join ","), ($ActionItemKeys.ToArray() -join ","))
    Add-Check "markdown next action item actions match json" `
      (Test-SameStringSet -Actual $MarkdownNextActionActions -Expected $NextActions) `
      ("markdown={0}; json={1}" -f ($MarkdownNextActionActions -join " | "), ($NextActions -join " | "))
    if ($BlockerSummary) {
      $ExpectedBlockerSummaryPairs = @(
        ("Release blockers={0}" -f $BlockerSummary.releaseBlockerCount),
        ("Operational blockers={0}" -f $BlockerSummary.operationalBlockerCount),
        ("Total blockers={0}" -f $BlockerSummary.totalBlockerCount),
        ("Next action items={0}" -f $BlockerSummary.nextActionItemCount),
        ("Blocked={0}" -f $BlockerSummary.blocked),
        ("Ready for submit={0}" -f $BlockerSummary.readyForSubmit)
      )
      Add-Check "markdown blocker summary item count matches json" `
        ($MarkdownBlockerSummaryEntries.Count -eq $ExpectedBlockerSummaryPairs.Count) `
        ("markdown={0}; json={1}" -f $MarkdownBlockerSummaryEntries.Count, $ExpectedBlockerSummaryPairs.Count)
      Add-Check "markdown blocker summary keys are unique" `
        (Test-UniqueNonEmptyStrings -Values $MarkdownBlockerSummaryKeys) `
        ("count={0}" -f $MarkdownBlockerSummaryKeys.Count)
      Add-Check "markdown blocker summary matches json" `
        (Test-SameStringSet -Actual $MarkdownBlockerSummaryPairs -Expected $ExpectedBlockerSummaryPairs) `
        ("markdown={0}; json={1}" -f ($MarkdownBlockerSummaryPairs -join " | "), ($ExpectedBlockerSummaryPairs -join " | "))
    }
    Add-Check "markdown check item count matches json" `
      ($MarkdownCheckEntries.Count -eq $ChecksFromSnapshot.Count) `
      ("markdown={0}; json={1}" -f $MarkdownCheckEntries.Count, $ChecksFromSnapshot.Count)
    Add-Check "markdown check names are unique" `
      (Test-UniqueNonEmptyStrings -Values $MarkdownCheckNames) `
      ("count={0}" -f $MarkdownCheckNames.Count)
    Add-Check "markdown checks match json" `
      (Test-SameStringSet -Actual $MarkdownCheckPairs -Expected ([object[]]$SnapshotCheckPairs.ToArray())) `
      ("markdown={0}; json={1}" -f ($MarkdownCheckPairs -join " | "), ($SnapshotCheckPairs.ToArray() -join " | "))
    if ($Repo) {
      Add-Check "markdown snapshot repo summary matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Repo: ahead `{0}`, dirty `{1}`, warnings `{2}`' -f $Repo.ahead, $Repo.dirtyCount, $Repo.warningCount))
    }
    if ($Proof) {
      Add-Check "markdown snapshot proof summary matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Proof: external release ready `{0}`, Alibaba usage images `{1}`, candidates `{2}`, invalid `{3}`, min bytes `{4}`, signature required `{5}`, manual review `{6}`' -f $Proof.readyForExternalRelease, $Proof.alibabaUsageImageCount, $Proof.alibabaUsageCandidateCount, $Proof.alibabaUsageInvalidImageCount, $Proof.alibabaUsageMinimumBytes, $Proof.alibabaUsageSignatureRequired, $Proof.alibabaManualReview))
    }
    if ($Readiness) {
      Add-Check "markdown snapshot readiness summary matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Readiness: gate `{0}`, blocking gaps `{1}`, follow-up gaps `{2}`' -f $Readiness.gateStatus, $Readiness.blockingGapCount, $Readiness.followUpGapCount))
    }
    if ($Hardware) {
      Add-Check "markdown snapshot hardware summary matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Hardware: `{0}` state `{1}`, port schema OK `{2}`' -f $Hardware.requestedPort, $Hardware.portState, $Hardware.portSchemaOk))
    }
    Add-Check "markdown has proof signals section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Proof Signals")
    if ($Proof) {
      Add-Check "markdown proof signal qwen matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Qwen verification: `{0}`' -f $Proof.qwenVerification))
      Add-Check "markdown proof signal alibaba candidates matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba image candidates: `{0}`' -f $Proof.alibabaUsageCandidateCount))
      Add-Check "markdown proof signal alibaba valid matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba valid images: `{0}`' -f $Proof.alibabaUsageImageCount))
      Add-Check "markdown proof signal alibaba invalid matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba invalid images: `{0}`' -f $Proof.alibabaUsageInvalidImageCount))
      Add-Check "markdown proof signal alibaba minimum bytes matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba image minimum bytes: `{0}`' -f $Proof.alibabaUsageMinimumBytes))
      Add-Check "markdown proof signal alibaba signature matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba signature required: `{0}`' -f $Proof.alibabaUsageSignatureRequired))
      Add-Check "markdown proof signal alibaba manual review matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba manual review: `{0}`' -f $Proof.alibabaManualReview))
      Add-Check "markdown proof signal alibaba manual review image matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba manual review image: `{0}`' -f $Proof.alibabaManualReviewImageName))
      Add-Check "markdown proof signal alibaba manual review missing fields matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Alibaba manual review missing fields: `{0}`' -f (@($Proof.alibabaManualReviewMissingFields) -join ",")))
      Add-Check "markdown proof signal xiaoqian matches json" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Xiaoqian wake model: `{0}`' -f $Proof.xiaoqianWakeModel))
    }
    Add-Check "markdown has alibaba valid images section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Alibaba Valid Images")
    if ($Proof) {
      $MarkdownAlibabaImageEntries = @(Get-MarkdownAlibabaValidImageEntries -Lines (Get-MarkdownSectionLines -Markdown $Markdown -Heading "## Alibaba Valid Images"))
      $MarkdownAlibabaImagePairs = @($MarkdownAlibabaImageEntries | ForEach-Object { [string]$_.pair })
      Add-Check "markdown alibaba valid image count matches json" `
        ($MarkdownAlibabaImageEntries.Count -eq $AlibabaUsageImages.Count) `
        ("markdown={0}; json={1}" -f $MarkdownAlibabaImageEntries.Count, $AlibabaUsageImages.Count)
      Add-Check "markdown alibaba valid images match json" `
        (Test-SameStringSet -Actual $MarkdownAlibabaImagePairs -Expected ([object[]]$AlibabaImagePairs.ToArray())) `
        ("markdown={0}; json={1}" -f ($MarkdownAlibabaImagePairs -join " | "), ($AlibabaImagePairs.ToArray() -join " | "))
      if ($AlibabaUsageImages.Count -eq 0) {
        Add-Check "markdown alibaba valid images none marker" (Test-MarkdownContains -Markdown $Markdown -Needle "- (none)")
      }
    }
    Add-Check "markdown has alibaba invalid images section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Alibaba Invalid Images")
    if ($Proof) {
      $MarkdownAlibabaInvalidImageEntries = @(Get-MarkdownAlibabaInvalidImageEntries -Lines (Get-MarkdownSectionLines -Markdown $Markdown -Heading "## Alibaba Invalid Images"))
      $MarkdownAlibabaInvalidImagePairs = @($MarkdownAlibabaInvalidImageEntries | ForEach-Object { [string]$_.pair })
      Add-Check "markdown alibaba invalid image count matches json" `
        ($MarkdownAlibabaInvalidImageEntries.Count -eq $AlibabaUsageInvalidImages.Count) `
        ("markdown={0}; json={1}" -f $MarkdownAlibabaInvalidImageEntries.Count, $AlibabaUsageInvalidImages.Count)
      Add-Check "markdown alibaba invalid images match json" `
        (Test-SameStringSet -Actual $MarkdownAlibabaInvalidImagePairs -Expected ([object[]]$AlibabaInvalidImagePairs.ToArray())) `
        ("markdown={0}; json={1}" -f ($MarkdownAlibabaInvalidImagePairs -join " | "), ($AlibabaInvalidImagePairs.ToArray() -join " | "))
      if ($AlibabaUsageInvalidImages.Count -eq 0) {
        Add-Check "markdown alibaba invalid images none marker" (Test-MarkdownContains -Markdown $Markdown -Needle "- (none)")
      }
    }
    Add-Check "markdown has repo buckets section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Repo Buckets")
    Add-Check "markdown has source files section" (Test-MarkdownContains -Markdown $Markdown -Needle "## Source Files")
    foreach ($Blocker in $Blockers) {
      Add-Check ("markdown includes blocker '{0}'" -f $Blocker) (Test-MarkdownContains -Markdown $Markdown -Needle ('- `{0}`' -f $Blocker))
      Add-Check ("markdown includes release action item '{0}'" -f $Blocker) (Test-MarkdownContains -Markdown $Markdown -Needle ('`[release/{0}]`' -f $Blocker))
    }
    foreach ($Blocker in $OperationalBlockers) {
      Add-Check ("markdown includes operational blocker '{0}'" -f $Blocker) (Test-MarkdownContains -Markdown $Markdown -Needle ('- `{0}`' -f $Blocker))
      Add-Check ("markdown includes operational action item '{0}'" -f $Blocker) (Test-MarkdownContains -Markdown $Markdown -Needle ('`[operational/{0}]`' -f $Blocker))
    }
    foreach ($Action in $NextActions) {
      Add-Check "markdown includes next action" (Test-MarkdownContains -Markdown $Markdown -Needle ([string]$Action)) ([string]$Action)
    }
    if ($BlockerSummary) {
      Add-Check "markdown includes release blocker count" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Release blockers: `{0}`' -f $BlockerSummary.releaseBlockerCount))
      Add-Check "markdown includes operational blocker count" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Operational blockers: `{0}`' -f $BlockerSummary.operationalBlockerCount))
      Add-Check "markdown includes total blocker count" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Total blockers: `{0}`' -f $BlockerSummary.totalBlockerCount))
      Add-Check "markdown includes next action item count" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Next action items: `{0}`' -f $BlockerSummary.nextActionItemCount))
      Add-Check "markdown includes blocked flag" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Blocked: `{0}`' -f $BlockerSummary.blocked))
      Add-Check "markdown includes summary ready flag" (Test-MarkdownContains -Markdown $Markdown -Needle ('- Ready for submit: `{0}`' -f $BlockerSummary.readyForSubmit))
    }
    foreach ($BucketEntry in @($RepoBucketCountEntries)) {
      $ReviewCount = Get-NumericEntryValue -Entries $RepoBucketReviewCountEntries -Name $BucketEntry.name
      Add-Check ("markdown includes repo bucket '{0}'" -f $BucketEntry.name) (Test-MarkdownContains -Markdown $Markdown -Needle ('- `{0}`: dirty `{1}`, review `{2}`' -f $BucketEntry.name, $BucketEntry.value, $ReviewCount))
    }
    if ($SourcePaths) {
      foreach ($SourceCheck in $SourcePathChecks) {
        $SourcePath = [string](Get-PropertyValue -Object $SourcePaths -Name $SourceCheck.property -Default "")
        Add-Check ("markdown includes source path '{0}'" -f $SourceCheck.property) (Test-MarkdownContains -Markdown $Markdown -Needle ('- {0}: `{1}`' -f $SourceCheck.name, $SourcePath)) $SourcePath
      }
    }
  }
}

$SchemaOk = $Failures.Count -eq 0
Write-Host ""
Write-Host ("Summary: {0}" -f $(if ($SchemaOk) { "release snapshot schema ok" } else { "release snapshot schema warning" }))

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result = @{
    checkedAt = (Get-Date).ToString("o")
    releaseSnapshotJsonPath = $JsonPath
    releaseSnapshotMarkdownPath = $MarkdownPath
    ok = [bool]$SchemaOk
    requiredMode = [bool]$Required
    failureCount = $Failures.Count
    failures = [string[]]$Failures.ToArray()
    checks = [object[]]$Checks.ToArray()
  }
  $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
  Write-Host ("Result  : {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
}

if ($Required -and -not $SchemaOk) {
  Write-Host "Release snapshot schema check failed." -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "Release snapshot schema check complete."
exit 0
