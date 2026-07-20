param(
  [Parameter(Mandatory = $true)]
  [string]$PortStateJsonPath,
  [Parameter(Mandatory = $true)]
  [string]$PortStateMarkdownPath,
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

$Checks = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]
$AllowedStates = @("unknown", "missing", "busy", "hung", "usb-error", "writable", "openable")

Write-Host "HomeCue Edge ESP32 port report schema check"
Write-Host ("JSON    : {0}" -f $PortStateJsonPath)
Write-Host ("Markdown: {0}" -f $PortStateMarkdownPath)
Write-Host ""

$JsonPath = if (Test-Path -LiteralPath $PortStateJsonPath) {
  (Resolve-Path -LiteralPath $PortStateJsonPath).Path
} else {
  $PortStateJsonPath
}
$MarkdownPath = if (Test-Path -LiteralPath $PortStateMarkdownPath) {
  (Resolve-Path -LiteralPath $PortStateMarkdownPath).Path
} else {
  $PortStateMarkdownPath
}

$PortState = Read-JsonFile -Path $JsonPath
$Markdown = ""
if (Test-Path -LiteralPath $MarkdownPath) {
  $Markdown = Get-Content -LiteralPath $MarkdownPath -Raw
}

Add-Check "port state json parsed" ($null -ne $PortState) ""
Add-Check "port state markdown read" ([bool]$Markdown) ""

if ($PortState) {
  $State = [string](Get-PropertyValue -Object $PortState -Name "state" -Default "")
  $Port = [string](Get-PropertyValue -Object $PortState -Name "port" -Default "")
  $RequestedPort = [string](Get-PropertyValue -Object $PortState -Name "requestedPort" -Default "")
  $Hint = [string](Get-PropertyValue -Object $PortState -Name "hint" -Default "")
  $NextAction = [string](Get-PropertyValue -Object $PortState -Name "nextAction" -Default "")
  $RecoverySteps = @((Get-PropertyValue -Object $PortState -Name "recoverySteps" -Default @()))
  $ChecksFromJson = @((Get-PropertyValue -Object $PortState -Name "checks" -Default @()))
  $DetectedPorts = @((Get-PropertyValue -Object $PortState -Name "detectedPorts" -Default @()))

  Add-Check -Name "state is allowed" -Ok ($AllowedStates -contains $State) -Detail ("state={0}" -f $State)
  Add-Check -Name "selected port exists" -Ok ([bool]$Port) -Detail ("port={0}" -f $Port)
  Add-Check -Name "requested port exists" -Ok ([bool]$RequestedPort) -Detail ("requested={0}" -f $RequestedPort)
  Add-Check -Name "hint exists" -Ok ([bool]$Hint) -Detail ("hint_length={0}" -f $Hint.Length)
  Add-Check -Name "next action exists" -Ok ([bool]$NextAction) -Detail ("next_action_length={0}" -f $NextAction.Length)
  Add-Check -Name "recovery steps property exists" -Ok (Test-HasProperty -Object $PortState -Name "recoverySteps") -Detail ("steps={0}" -f $RecoverySteps.Count)
  Add-Check -Name "recovery steps populated" -Ok ($RecoverySteps.Count -gt 0) -Detail ("steps={0}" -f $RecoverySteps.Count)
  Add-Check -Name "checks array populated" -Ok ($ChecksFromJson.Count -ge 2) -Detail ("checks={0}" -f $ChecksFromJson.Count)
  Add-Check -Name "detectedPorts property exists" -Ok (Test-HasProperty -Object $PortState -Name "detectedPorts") -Detail ("detected={0}" -f $DetectedPorts.Count)

  if ($Markdown) {
    $SelectedPortNeedle = '- Selected port: `{0}`' -f $Port
    $RequestedPortNeedle = '- Requested port: `{0}`' -f $RequestedPort
    $StateNeedle = "- State: **{0}**" -f $State
    $HintNeedle = "- Hint: {0}" -f $Hint
    Add-Check -Name "markdown has title" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle "# ESP32 Port State Report")
    Add-Check -Name "markdown selected port matches json" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle $SelectedPortNeedle) -Detail ("port={0}" -f $Port)
    Add-Check -Name "markdown requested port matches json" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle $RequestedPortNeedle) -Detail ("requested={0}" -f $RequestedPort)
    Add-Check -Name "markdown state matches json" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle $StateNeedle) -Detail ("state={0}" -f $State)
    Add-Check -Name "markdown hint matches json" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle $HintNeedle)
    Add-Check -Name "markdown has checks section" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle "## Checks")
    Add-Check -Name "markdown has usb section" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle "## USB Problem Devices")
    Add-Check -Name "markdown has next action section" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle "## Next Action")
    Add-Check -Name "markdown next action matches json" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle $NextAction)
    Add-Check -Name "markdown has recovery steps section" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle "## Recovery Steps")
    foreach ($Step in $RecoverySteps) {
      Add-Check -Name "markdown includes recovery step" -Ok (Test-MarkdownContains -Markdown $Markdown -Needle ([string]$Step)) -Detail ([string]$Step)
    }

    foreach ($Check in $ChecksFromJson) {
      $CheckName = [string](Get-PropertyValue -Object $Check -Name "name" -Default "")
      if ($CheckName) {
        Add-Check -Name ("markdown includes check '{0}'" -f $CheckName) -Ok (Test-MarkdownContains -Markdown $Markdown -Needle $CheckName)
      }
    }
  }
}

$SchemaOk = $Failures.Count -eq 0
Write-Host ""
Write-Host ("Summary: {0}" -f $(if ($SchemaOk) { "port report schema ok" } else { "port report schema warning" }))

if ($ResultJsonPath) {
  New-ParentDirectory -Path $ResultJsonPath
  $Result = @{
    checkedAt = (Get-Date).ToString("o")
    portStateJsonPath = $JsonPath
    portStateMarkdownPath = $MarkdownPath
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
  Write-Host "ESP32 port report schema check failed." -ForegroundColor Red
  foreach ($Failure in $Failures) {
    Write-Host ("- {0}" -f $Failure) -ForegroundColor Red
  }
  exit 1
}

Write-Host "ESP32 port report schema check complete."
exit 0
