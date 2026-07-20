param(
  [ValidateSet("pass", "fail", "not_measured")]
  [string]$SpeakerHeaderConnector = "not_measured",
  [ValidateSet("pass", "fail", "not_measured")]
  [string]$SpeakerCable = "not_measured",
  [ValidateSet("pass", "fail", "not_measured")]
  [string]$KnownGoodSpeaker = "not_measured",
  [ValidateSet("present", "absent", "not_measured")]
  [string]$SpeakerHeaderAcSignal = "not_measured",
  [ValidateSet("audible", "silent", "not_run")]
  [string]$WaveshareFactoryDemo = "not_run",
  [ValidateSet("yes", "no", "not_confirmed")]
  [string]$HumanAudible = "not_confirmed",
  [string]$MeasurementNotes = "",
  [string]$EvidencePath = "",
  [string]$CollectorJsonPath = ".\assets\demo\speaker-physical-evidence-current-20260618.json",
  [string]$ResultJsonPath = ".\assets\demo\speaker-physical-check-decision.json"
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
  return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function New-Decision {
  $Missing = New-Object System.Collections.Generic.List[string]
  if ($SpeakerHeaderConnector -eq "not_measured") { $Missing.Add("speaker header/connector check") }
  if ($SpeakerCable -eq "not_measured") { $Missing.Add("speaker cable replacement or rework") }
  if ($KnownGoodSpeaker -eq "not_measured") { $Missing.Add("known-good same-spec speaker test") }
  if ($SpeakerHeaderAcSignal -eq "not_measured") { $Missing.Add("speaker-header AC measurement") }
  if ($HumanAudible -eq "not_confirmed") { $Missing.Add("human audible confirmation") }

  if ($HumanAudible -eq "yes") {
    return [pscustomobject]@{
      status = "complete"
      nextAction = "Speaker chain is audible. Continue Jarvis voice-chat testing."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $false
      factoryDemoRecommended = $false
    }
  }

  if ($SpeakerHeaderConnector -eq "fail") {
    return [pscustomobject]@{
      status = "fix_physical_connection"
      nextAction = "Repair or reseat the speaker header/connector, then repeat bounded HomeCue playback."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $false
      factoryDemoRecommended = $false
    }
  }

  if ($SpeakerCable -eq "fail") {
    return [pscustomobject]@{
      status = "replace_or_rework_cable"
      nextAction = "Replace, re-crimp, or re-solder the speaker cable, then repeat bounded HomeCue playback."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $false
      factoryDemoRecommended = $false
    }
  }

  if ($KnownGoodSpeaker -eq "fail") {
    return [pscustomobject]@{
      status = "replace_speaker"
      nextAction = "Use a same-spec known-good speaker before further firmware or factory-demo testing."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $false
      factoryDemoRecommended = $false
    }
  }

  if ($SpeakerHeaderAcSignal -eq "present" -and $HumanAudible -eq "no") {
    return [pscustomobject]@{
      status = "downstream_speaker_or_cable_issue"
      nextAction = "AC signal is present but no sound is heard. Replace the speaker/cable path and repeat."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $false
      factoryDemoRecommended = $false
    }
  }

  if ($SpeakerHeaderAcSignal -eq "absent" -and $WaveshareFactoryDemo -eq "not_run") {
    return [pscustomobject]@{
      status = "run_factory_demo_ab"
      nextAction = "Speaker-header AC output is absent. Run Waveshare factory demo A/B under controlled acoustic conditions."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $false
      factoryDemoRecommended = $true
    }
  }

  if ($SpeakerHeaderAcSignal -eq "absent" -and $WaveshareFactoryDemo -eq "silent") {
    return [pscustomobject]@{
      status = "switch_edge_hardware"
      nextAction = "Factory demo is also silent. Stop spending time on this board and switch to verified mic/speaker edge hardware."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $true
      factoryDemoRecommended = $false
    }
  }

  if ($WaveshareFactoryDemo -eq "audible" -and $HumanAudible -eq "no") {
    return [pscustomobject]@{
      status = "compare_homecue_vs_factory"
      nextAction = "Factory demo is audible but HomeCue is not. Compare HomeCue I2S/codec/PA settings against factory behavior."
      missing = [string[]]$Missing.ToArray()
      hardwareSwitchRecommended = $false
      factoryDemoRecommended = $false
    }
  }

  return [pscustomobject]@{
    status = "physical_evidence_incomplete"
    nextAction = "Finish the missing physical checks before changing firmware volume or switching hardware."
    missing = [string[]]$Missing.ToArray()
    hardwareSwitchRecommended = $false
    factoryDemoRecommended = $false
  }
}

New-ParentDirectory -Path $ResultJsonPath
$Collector = Read-JsonFile -Path $CollectorJsonPath
$Decision = New-Decision

$Result = [pscustomobject]@{
  checkedAt = (Get-Date).ToString("o")
  inputs = @{
    speakerHeaderConnector = $SpeakerHeaderConnector
    speakerCable = $SpeakerCable
    knownGoodSpeaker = $KnownGoodSpeaker
    speakerHeaderAcSignal = $SpeakerHeaderAcSignal
    waveshareFactoryDemo = $WaveshareFactoryDemo
    humanAudible = $HumanAudible
    measurementNotes = $MeasurementNotes
    evidencePath = $EvidencePath
  }
  softwareBoundary = if ($Collector) {
    @{
      okForSoftwareBoundary = [bool]$Collector.okForSoftwareBoundary
      collectorJsonPath = $CollectorJsonPath
      boardHealthOk = [bool]$Collector.boardHealthOk
      reminderOk = [bool]$Collector.reminderOk
      waveshareAbOk = [bool]$Collector.waveshareAbOk
    }
  } else {
    @{
      okForSoftwareBoundary = $false
      collectorJsonPath = $CollectorJsonPath
      missingCollectorJson = $true
    }
  }
  decision = $Decision
  complete = [bool]($Decision.status -eq "complete")
}

$Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ("Result: {0}" -f (Resolve-Path -LiteralPath $ResultJsonPath).Path)
Write-Host ("decision: {0}" -f $Decision.status)
Write-Host ("next: {0}" -f $Decision.nextAction)

exit 0
