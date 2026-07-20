param(
  [string]$Remote = "ubuntu-host",
  [string]$RemoteDir = "~/homecue-edge-api",
  [string]$ServiceName = "homecue-edge-api",
  [int]$Port = 8723,
  [string]$BindHost = "0.0.0.0",
  [string]$EnvSource = ".\apps\api\.env",
  [string]$MemoryDbPath = "",
  [string]$PipIndexUrl = "",
  [string]$VerifyBaseUrl = "",
  [string]$VerifyAccessToken = "",
  [string]$VerifyResultJsonPath = "",
  [switch]$SkipEnvUpload,
  [switch]$SkipVerify,
  [switch]$NoStart
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$ApiDir = Join-Path $Root "apps\api"
$AppDir = Join-Path $ApiDir "app"
$RequirementsPath = Join-Path $ApiDir "requirements.txt"

function Quote-Sh {
  param([string]$Value)
  return "'" + ($Value -replace "'", "'`"`"`'") + "'"
}

function Invoke-Remote {
  param([string]$Command)

  $TempScriptPath = Join-Path $env:TEMP "homecue-edge-remote-$([guid]::NewGuid().ToString('N')).sh"
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($TempScriptPath, $Command, $Utf8NoBom)
  try {
    $Process = Start-Process `
      -FilePath "ssh" `
      -ArgumentList @($Remote, "bash -s") `
      -RedirectStandardInput $TempScriptPath `
      -NoNewWindow `
      -Wait `
      -PassThru
    if ($Process.ExitCode -ne 0) {
      throw "Remote command failed with exit code $($Process.ExitCode): $Command"
    }
  } finally {
    Remove-Item -LiteralPath $TempScriptPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-RemoteCapture {
  param([string]$Command)

  $TempScriptPath = Join-Path $env:TEMP "homecue-edge-remote-$([guid]::NewGuid().ToString('N')).sh"
  $TempOutPath = Join-Path $env:TEMP "homecue-edge-remote-out-$([guid]::NewGuid().ToString('N')).txt"
  $TempErrPath = Join-Path $env:TEMP "homecue-edge-remote-err-$([guid]::NewGuid().ToString('N')).txt"
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($TempScriptPath, $Command, $Utf8NoBom)
  try {
    $Process = Start-Process `
      -FilePath "ssh" `
      -ArgumentList @($Remote, "bash -s") `
      -RedirectStandardInput $TempScriptPath `
      -RedirectStandardOutput $TempOutPath `
      -RedirectStandardError $TempErrPath `
      -NoNewWindow `
      -Wait `
      -PassThru
    $Output = if (Test-Path -LiteralPath $TempOutPath) { Get-Content -LiteralPath $TempOutPath -Raw -Encoding UTF8 } else { "" }
    $ErrorOutput = if (Test-Path -LiteralPath $TempErrPath) { Get-Content -LiteralPath $TempErrPath -Raw -Encoding UTF8 } else { "" }
    if ($Process.ExitCode -ne 0) {
      throw "Remote command failed with exit code $($Process.ExitCode): $ErrorOutput"
    }
    return $Output
  } finally {
    Remove-Item -LiteralPath $TempScriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TempOutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TempErrPath -Force -ErrorAction SilentlyContinue
  }
}

function Copy-FileToRemote {
  param(
    [string]$LocalPath,
    [string]$RemotePath
  )

  $QuotedRemotePath = Quote-Sh $RemotePath
  $Process = Start-Process `
    -FilePath "ssh" `
    -ArgumentList @($Remote, "cat > $QuotedRemotePath") `
    -RedirectStandardInput $LocalPath `
    -NoNewWindow `
    -Wait `
    -PassThru
  if ($Process.ExitCode -ne 0) {
    throw "Failed to copy $LocalPath to ${Remote}:$RemotePath"
  }
}

function Get-EnvValue {
  param(
    [string]$Text,
    [string]$Name
  )

  foreach ($Line in ($Text -split "`r?`n")) {
    if ($Line -match "^\s*#" -or $Line -notmatch "^\s*$([regex]::Escape($Name))\s*=") {
      continue
    }
    $Value = $Line.Substring($Line.IndexOf("=") + 1).Trim()
    if (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
        ($Value.StartsWith("'") -and $Value.EndsWith("'"))) {
      $Value = $Value.Substring(1, $Value.Length - 2)
    }
    return $Value
  }
  return ""
}

function New-ParentDirectory {
  param([string]$Path)
  $Parent = Split-Path -Parent $Path
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent | Out-Null
  }
}

function Set-EnvValue {
  param(
    [string]$Text,
    [string]$Name,
    [string]$Value
  )

  $Line = "$Name=$Value"
  if ($Text -match "(?m)^$([regex]::Escape($Name))=") {
    return [regex]::Replace($Text, "(?m)^$([regex]::Escape($Name))=.*$", $Line, 1)
  }
  if ($Text.Trim().Length -eq 0) {
    return "$Line`n"
  }
  return $Text.TrimEnd() + "`n$Line`n"
}

if (-not (Test-Path -LiteralPath $AppDir)) {
  throw "API app directory not found: $AppDir"
}
if (-not (Test-Path -LiteralPath $RequirementsPath)) {
  throw "API requirements file not found: $RequirementsPath"
}
if ($ServiceName -notmatch "^[A-Za-z0-9_.@-]+$") {
  throw "-ServiceName contains unsupported characters."
}
if ($BindHost -notmatch "^[A-Za-z0-9_.:-]+$") {
  throw "-BindHost contains unsupported characters."
}
if ($Port -lt 1 -or $Port -gt 65535) {
  throw "-Port must be 1..65535."
}
if ($PipIndexUrl -and $PipIndexUrl -notmatch "^[A-Za-z0-9_.:/-]+$") {
  throw "-PipIndexUrl contains unsupported characters."
}
if ($VerifyBaseUrl -and $VerifyBaseUrl -notmatch "^[A-Za-z0-9_.:/-]+$") {
  throw "-VerifyBaseUrl contains unsupported characters."
}
if ($VerifyAccessToken -match "[`r`n]") {
  throw "-VerifyAccessToken must not contain newline characters."
}

$ResolveRemoteBaseScript = "import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))"
$RemoteBaseCommand = "python3 -c $(Quote-Sh $ResolveRemoteBaseScript) $(Quote-Sh $RemoteDir)"
$RemoteBase = (& ssh $Remote $RemoteBaseCommand).Trim()
if ($LASTEXITCODE -ne 0 -or -not $RemoteBase) {
  throw "Could not resolve remote deploy directory."
}

$RemoteZip = "/tmp/homecue-edge-api-$([guid]::NewGuid().ToString('N')).zip"
$TempRoot = Join-Path $env:TEMP "homecue-edge-api-deploy-$([guid]::NewGuid().ToString('N'))"
$ArchivePath = Join-Path $env:TEMP "homecue-edge-api-$([guid]::NewGuid().ToString('N')).zip"

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
$DeploymentEnvText = ""
$DeploymentVoiceToken = $VerifyAccessToken
try {
  Copy-Item -LiteralPath $AppDir -Destination (Join-Path $TempRoot "app") -Recurse
  Copy-Item -LiteralPath $RequirementsPath -Destination (Join-Path $TempRoot "requirements.txt")
  Copy-Item -LiteralPath (Join-Path $ApiDir "README.md") -Destination (Join-Path $TempRoot "README.md") -ErrorAction SilentlyContinue
  Get-ChildItem -Path $TempRoot -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force
  Get-ChildItem -Path $TempRoot -Recurse -File -Filter "*.pyc" | Remove-Item -Force

  Compress-Archive -Path (Join-Path $TempRoot "*") -DestinationPath $ArchivePath -CompressionLevel Fastest
  Invoke-Remote "mkdir -p $(Quote-Sh $RemoteBase)"
  Copy-FileToRemote -LocalPath $ArchivePath -RemotePath $RemoteZip

  $RemoteZipQuoted = Quote-Sh $RemoteZip
  $RemoteBaseQuoted = Quote-Sh $RemoteBase
  Invoke-Remote @"
set -eu
BASE=$RemoteBaseQuoted
ZIP=$RemoteZipQuoted
rm -rf "`$BASE/current.new"
mkdir -p "`$BASE/current.new" "`$BASE/data" "`$BASE/logs"
python3 - "`$ZIP" "`$BASE/current.new" <<'PY'
import pathlib
import shutil
import sys
import zipfile

zip_path = sys.argv[1]
target = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(zip_path) as archive:
    for member in archive.infolist():
        name = member.filename.replace(chr(92), chr(47))
        parts = [
            part
            for part in pathlib.PurePosixPath(name).parts
            if part not in {"", ".", ".."}
        ]
        if not parts:
            continue
        destination = target.joinpath(*parts)
        if member.is_dir() or name.endswith("/"):
            destination.mkdir(parents=True, exist_ok=True)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(member) as source, destination.open("wb") as output:
            shutil.copyfileobj(source, output)
PY
rm -rf "`$BASE/current.old"
if [ -d "`$BASE/current" ]; then mv "`$BASE/current" "`$BASE/current.old"; fi
mv "`$BASE/current.new" "`$BASE/current"
rm -f "`$ZIP"
if [ ! -x "`$BASE/.venv/bin/python" ]; then
  rm -rf "`$BASE/.venv"
  python3 -m venv --without-pip "`$BASE/.venv"
fi
if ! "`$BASE/.venv/bin/python" -m pip --version >/dev/null 2>&1; then
  GET_PIP="`$BASE/get-pip.py"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "`$GET_PIP"
  else
    wget -qO "`$GET_PIP" https://bootstrap.pypa.io/get-pip.py
  fi
  "`$BASE/.venv/bin/python" "`$GET_PIP"
  rm -f "`$GET_PIP"
fi
PIP_INDEX=$(Quote-Sh $PipIndexUrl)
PIP_ARGS="--timeout 120"
if [ -n "`$PIP_INDEX" ]; then
  PIP_ARGS="`$PIP_ARGS -i `$PIP_INDEX"
fi
"`$BASE/.venv/bin/python" -m pip install `$PIP_ARGS --upgrade pip
"`$BASE/.venv/bin/python" -m pip install `$PIP_ARGS -r "`$BASE/current/requirements.txt"
"@

  if (-not $SkipEnvUpload) {
    $EnvPath = Resolve-Path $EnvSource -ErrorAction SilentlyContinue
    $EnvText = if ($EnvPath) { Get-Content -LiteralPath $EnvPath.Path -Raw -Encoding UTF8 } else { "" }
    $ResolvedMemoryDbPath = if ($MemoryDbPath) { $MemoryDbPath } else { "$RemoteBase/data/voice-chat.sqlite" }
    $EnvText = Set-EnvValue -Text $EnvText -Name "VOICE_CHAT_MEMORY_DB" -Value $ResolvedMemoryDbPath
    $EnvText = Set-EnvValue -Text $EnvText -Name "HOMECUE_VOICE_CHAT_AUDIO_DIR" -Value "$RemoteBase/data"
    $DeploymentEnvText = $EnvText
    if (-not $DeploymentVoiceToken) {
      $DeploymentVoiceToken = Get-EnvValue -Text $EnvText -Name "VOICE_CHAT_ACCESS_TOKEN"
    }
    $TempEnvPath = Join-Path $env:TEMP "homecue-edge-api-env-$([guid]::NewGuid().ToString('N'))"
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($TempEnvPath, $EnvText, $Utf8NoBom)
    try {
      Copy-FileToRemote -LocalPath $TempEnvPath -RemotePath "$RemoteBase/.env"
      Invoke-Remote "chmod 600 $(Quote-Sh "$RemoteBase/.env")"
    } finally {
      Remove-Item -LiteralPath $TempEnvPath -Force -ErrorAction SilentlyContinue
    }
  } elseif (-not $DeploymentVoiceToken) {
    $EnvPath = Resolve-Path $EnvSource -ErrorAction SilentlyContinue
    if ($EnvPath) {
      $DeploymentEnvText = Get-Content -LiteralPath $EnvPath.Path -Raw -Encoding UTF8
      $DeploymentVoiceToken = Get-EnvValue -Text $DeploymentEnvText -Name "VOICE_CHAT_ACCESS_TOKEN"
    }
  }

  $ServicePath = "$RemoteBase/$ServiceName.service"
  $ServiceText = @"
[Unit]
Description=HomeCue Edge API
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$RemoteBase/current
EnvironmentFile=$RemoteBase/.env
Environment=PYTHONUNBUFFERED=1
ExecStart=$RemoteBase/.venv/bin/python -m uvicorn app.main:app --host $BindHost --port $Port
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
"@
  $TempServicePath = Join-Path $env:TEMP "homecue-edge-api-service-$([guid]::NewGuid().ToString('N'))"
  Set-Content -LiteralPath $TempServicePath -Value $ServiceText -Encoding ASCII
  try {
    Copy-FileToRemote -LocalPath $TempServicePath -RemotePath $ServicePath
  } finally {
    Remove-Item -LiteralPath $TempServicePath -Force -ErrorAction SilentlyContinue
  }

  Invoke-Remote @"
set -eu
BASE=$RemoteBaseQuoted
SERVICE=$(Quote-Sh "$ServiceName.service")
mkdir -p "`$HOME/.config/systemd/user"
cp "`$BASE/`$SERVICE" "`$HOME/.config/systemd/user/`$SERVICE"
loginctl enable-linger "`$(id -un)" >/dev/null 2>&1 || true
export XDG_RUNTIME_DIR="/run/user/`$(id -u)"
systemctl --user daemon-reload
systemctl --user enable "$ServiceName.service"
"@

  if (-not $NoStart) {
    Invoke-Remote @"
set -eu
export XDG_RUNTIME_DIR="/run/user/`$(id -u)"
systemctl --user restart "$ServiceName.service"
sleep 2
systemctl --user --no-pager --full status "$ServiceName.service" | sed -n '1,18p'
"@
  }

  if (-not $NoStart -and -not $SkipVerify) {
    $EffectiveVerifyBaseUrl = if ($VerifyBaseUrl) { $VerifyBaseUrl.TrimEnd("/") } else { "http://127.0.0.1:$Port" }
    $VerifyJson = Invoke-RemoteCapture @"
set -eu
python3 - $(Quote-Sh $EffectiveVerifyBaseUrl) $(Quote-Sh $DeploymentVoiceToken) <<'PY'
import json
import sys
import urllib.error
import urllib.request

base_url = sys.argv[1].rstrip("/")
token = sys.argv[2]


def fetch(path):
    request = urllib.request.Request(base_url + path)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            raw = response.read(65536).decode("utf-8", "replace")
            try:
                body = json.loads(raw)
            except Exception:
                body = raw[:500]
            return {"ok": 200 <= response.status < 300, "status": response.status, "body": body}
    except urllib.error.HTTPError as error:
        raw = error.read(4096).decode("utf-8", "replace")
        return {"ok": False, "status": error.code, "body": raw[:500]}
    except Exception as error:
        return {"ok": False, "status": None, "error": str(error)}


health = fetch("/health")
voice_status = fetch("/voice-chat/status")
runtime = voice_status.get("body") if isinstance(voice_status.get("body"), dict) else {}
result = {
    "base_url": base_url,
    "health": health,
    "voice_chat_status": voice_status,
    "voice_token_provided": bool(token),
    "provider": runtime.get("provider", ""),
    "model": runtime.get("model", ""),
    "tts": runtime.get("tts", {}),
    "memory": runtime.get("memory", {}),
    "realtime": runtime.get("realtime", {}),
}
result["ok"] = bool(health.get("ok") and voice_status.get("ok"))
print(json.dumps(result, ensure_ascii=False))
PY
"@
    if ($VerifyResultJsonPath) {
      New-ParentDirectory -Path $VerifyResultJsonPath
      Set-Content -LiteralPath $VerifyResultJsonPath -Value $VerifyJson.Trim() -Encoding UTF8
    }
    $VerifyResult = $VerifyJson | ConvertFrom-Json
    Write-Host ("Verify : health={0} voice_status={1} provider={2} model={3} token={4}" -f `
        $VerifyResult.health.status,
        $VerifyResult.voice_chat_status.status,
        $VerifyResult.provider,
        $VerifyResult.model,
        $(if ($VerifyResult.voice_token_provided) { "provided" } else { "not-provided" }))
    if (-not $VerifyResult.ok) {
      throw "Deployment verification failed. Check -VerifyResultJsonPath output or remote service logs."
    }
  }
} finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
}

Write-Host "HomeCue Edge API deployment prepared."
Write-Host ("Remote : {0}" -f $Remote)
Write-Host ("Base   : {0}" -f $RemoteBase)
Write-Host ("URL    : http://<ubuntu-lan-ip>:{0}" -f $Port)
Write-Host ("Status : curl http://<ubuntu-lan-ip>:{0}/voice-chat/status" -f $Port)
