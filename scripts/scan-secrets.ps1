<#
.SYNOPSIS
  Pre-commit privacy / secret scanner for the HomeCue Edge public repository.

.DESCRIPTION
  This repository is PUBLIC. It must contain technical content only. This script
  scans repository files for two classes of problems before a commit/push:

    1. Secret-shaped tokens (API keys / access keys).
    2. Non-technical keywords that must never appear in a public repo
       (career / job-seeking material, target-company references, personal
       identifiers, local absolute paths, etc.).

  On any hit it prints the offending file:line and exits with a NON-ZERO code,
  so it can be wired into a git pre-commit hook (see scripts/hooks/pre-commit).

  NOTES:
  - This script is the single place that legitimately holds the keyword list, so
    it excludes its own path (and the hook) from the scan to avoid self-flagging.
  - The genuinely private literals (a personal email local-part, a personal demo
    subdomain id) and the CJK keywords are assembled from fragments / Unicode
    code points at runtime, so the verbatim sensitive values never appear in this
    file. This also keeps the file pure ASCII (Windows PowerShell 5.1 reads .ps1
    in the system codepage; non-ASCII without a BOM would corrupt parsing).

.PARAMETER Staged
  Scan only the git staged blobs (use this in the pre-commit hook).

.PARAMETER All
  Scan every tracked file (default when neither -Staged nor -All is given).

.PARAMETER IncludeUntracked
  When scanning all files, also scan untracked non-ignored files from the working
  tree. This is useful before staging new scripts or docs.

.PARAMETER Quiet
  Suppress the "clean" success banner (still prints findings).

.PARAMETER ResultJsonPath
  Optional path for a structured JSON scan summary.

.EXAMPLE
  powershell -File ./scripts/scan-secrets.ps1
  powershell -File ./scripts/scan-secrets.ps1 -All -IncludeUntracked
  powershell -File ./scripts/scan-secrets.ps1 -Staged
#>
[CmdletBinding()]
param(
    [switch]$Staged,
    [switch]$All,
    [switch]$IncludeUntracked,
    [switch]$Quiet,
    [string]$ResultJsonPath = ''
)

$ErrorActionPreference = 'Stop'

# --- locate repo root --------------------------------------------------------
$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) {
    Write-Error 'scan-secrets: not inside a git repository.'
    exit 2
}
Set-Location -LiteralPath $repoRoot

function New-ParentDirectory {
    param([string]$Path)
    $Parent = Split-Path -Parent $Path
    if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
        New-Item -ItemType Directory -Path $Parent | Out-Null
    }
}

# --- sensitive literals (fragmented so the verbatim value is NOT in this file)
$emailLocalPart = 'ylh' + '1122c'   # personal email local-part
$demoSubdomainId = '112' + '318'    # personal demo subdomain id

# CJK keywords built from Unicode code points (file stays pure ASCII):
$kwInterviewCn = [string]([char]0x9762 + [char]0x8BD5)  # interview (CN)
$kwJobHuntCn   = [string]([char]0x6C42 + [char]0x804C)  # job-hunting (CN)
$kwResumeCn    = [string]([char]0x7B80 + [char]0x5386)  # resume (CN)
$kwTargetCoCn  = [string]([char]0x5C0F + [char]0x7C73)  # target company (CN)

# --- keyword patterns (case-insensitive regex) ------------------------------
# Non-technical content that must never ship in the public repo.
$keywordPatterns = @(
    [pscustomobject]@{ Name = 'cn-interview';      Pattern = [regex]::Escape($kwInterviewCn) }
    [pscustomobject]@{ Name = 'cn-jobhunt';        Pattern = [regex]::Escape($kwJobHuntCn) }
    [pscustomobject]@{ Name = 'cn-resume';         Pattern = [regex]::Escape($kwResumeCn) }
    [pscustomobject]@{ Name = 'cn-targetco';       Pattern = [regex]::Escape($kwTargetCoCn) }
    [pscustomobject]@{ Name = 'en-targetco';       Pattern = 'xiaomi' }
    [pscustomobject]@{ Name = 'en-interview';      Pattern = 'interview' }
    [pscustomobject]@{ Name = 'hackathon-portal';  Pattern = 'devpost' }
    [pscustomobject]@{ Name = 'role-incubation';   Pattern = 'incubation' }
    [pscustomobject]@{ Name = 'judging-reviewer';  Pattern = 'reviewer' }
    [pscustomobject]@{ Name = 'personal-mailhost'; Pattern = '163\.com' }
    [pscustomobject]@{ Name = 'personal-email';    Pattern = [regex]::Escape($emailLocalPart) }
    [pscustomobject]@{ Name = 'local-path';        Pattern = 'new_job' }
    [pscustomobject]@{ Name = 'personal-demo-id';  Pattern = [regex]::Escape($demoSubdomainId) }
)

# --- secret-shaped patterns (length-bounded to avoid e.g. svg "mask-type") ---
$secretPatterns = @(
    [pscustomobject]@{ Name = 'openai-compatible-key'; Pattern = 'sk-[A-Za-z0-9_\-]{16,}' }
    [pscustomobject]@{ Name = 'tp-key';                Pattern = 'tp-[A-Za-z0-9_\-]{16,}' }
    [pscustomobject]@{ Name = 'github-pat';            Pattern = 'ghp_[A-Za-z0-9]{20,}' }
    [pscustomobject]@{ Name = 'aws-access-key';        Pattern = 'AKIA[0-9A-Z]{16}' }
)

# --- files this scanner must NOT scan (it owns the keyword list) -------------
$selfExclude = @(
    'scripts/scan-secrets.ps1',
    'scripts/hooks/pre-commit'
)

# --- binary / asset extensions to skip (avoids svg "mask-type" etc.) ---------
$skipExtRegex = '\.(png|jpe?g|gif|ico|svg|webp|bmp|pdf|woff2?|ttf|eot|otf|mp4|mov|webm|zip|gz|tar|7z|whl|pyc|lock)$'

# --- secret files that must never be staged at all ---------------------------
$forbiddenFileRegex = '(^|/)(\.env$|\.env\.(?!example$).+|secrets\.h$)'

# --- collect the file list ---------------------------------------------------
if ($Staged) {
    $fileItems = @(& git diff --cached --name-only --diff-filter=ACM | ForEach-Object {
        [pscustomobject]@{ Path = $_; Source = 'staged' }
    })
} else {
    $fileItems = @(& git ls-files | ForEach-Object {
        [pscustomobject]@{ Path = $_; Source = 'tracked' }
    })
    if ($IncludeUntracked) {
        $fileItems += @(& git ls-files --others --exclude-standard | ForEach-Object {
            [pscustomobject]@{ Path = $_; Source = 'untracked' }
        })
    }
}
$fileItems = @($fileItems | Where-Object { $_.Path -and $_.Path.Trim() })

$findings = New-Object System.Collections.Generic.List[object]
$scannedFiles = New-Object System.Collections.Generic.List[string]
$skippedFiles = New-Object System.Collections.Generic.List[string]

function Add-Finding {
    param(
        [string]$Path,
        [int]$Line,
        [string]$Category,
        [string]$Name,
        [string]$Message
    )

    $script:findings.Add([pscustomobject]@{
        path = $Path
        line = $Line
        category = $Category
        name = $Name
        message = $Message
        text = ("{0}:{1} : [{2}:{3}] {4}" -f $Path, $Line, $Category, $Name, $Message)
    })
}

# --- guard: forbidden secret files staged ------------------------------------
if ($Staged) {
    foreach ($item in $fileItems) {
        $f = $item.Path
        if ($f -match $forbiddenFileRegex) {
            Add-Finding -Path $f -Line 0 -Category 'staged-secret-file' -Name 'forbidden-file' -Message 'this file is git-ignored and must never be committed'
        }
    }
}

# --- scan file contents ------------------------------------------------------
foreach ($item in $fileItems) {
    $f = $item.Path
    $norm = $f -replace '\\', '/'
    if ($selfExclude -contains $norm) {
        $skippedFiles.Add($norm)
        continue
    }
    if ($norm -imatch $skipExtRegex) {
        $skippedFiles.Add($norm)
        continue
    }

    # Staged scans read the exact blobs to be committed; all-file scans read the
    # current working-tree content so new edits are checked before staging.
    $text = $null
    try {
        if ($Staged) {
            $text = & git show ":$f" 2>$null
        } elseif (Test-Path -LiteralPath $f) {
            $text = Get-Content -LiteralPath $f -Raw -ErrorAction Stop
        }
    } catch {
        $skippedFiles.Add($norm)
        continue
    }
    if (-not $text) {
        $skippedFiles.Add($norm)
        continue
    }

    $scannedFiles.Add($norm)

    $lines = $text -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line) { continue }
        $lineNo = $i + 1

        foreach ($kw in $keywordPatterns) {
            if ($line -imatch $kw.Pattern) {
                Add-Finding -Path $norm -Line $lineNo -Category 'keyword' -Name $kw.Name -Message 'non-technical keyword detected'
            }
        }
        foreach ($sp in $secretPatterns) {
            if ($line -imatch $sp.Pattern) {
                Add-Finding -Path $norm -Line $lineNo -Category 'secret' -Name $sp.Name -Message 'secret-shaped token detected'
            }
        }
    }
}

# --- report ------------------------------------------------------------------
$clean = $findings.Count -eq 0
if ($ResultJsonPath) {
    New-ParentDirectory -Path $ResultJsonPath
    $mode = if ($Staged) { 'staged' } else { 'all' }
    $result = @{
        checkedAt = (Get-Date).ToString('o')
        repoRoot = $repoRoot
        mode = $mode
        includeUntracked = [bool]$IncludeUntracked
        clean = [bool]$clean
        findingCount = $findings.Count
        scannedCount = $scannedFiles.Count
        skippedCount = $skippedFiles.Count
        sources = [string[]]@($fileItems | Select-Object -ExpandProperty Source -Unique)
        findings = [object[]]$findings.ToArray()
        scannedFiles = [string[]]$scannedFiles.ToArray()
        skippedFiles = [string[]]$skippedFiles.ToArray()
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
}

if ($findings.Count -gt 0) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host (" scan-secrets: {0} issue(s) found -- commit BLOCKED" -f $findings.Count) -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    foreach ($hit in $findings) {
        Write-Host "  $($hit.text)" -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Fix or remove the content above before committing.' -ForegroundColor Red
    Write-Host 'If a hit is a genuine false positive, narrow the pattern in scripts/scan-secrets.ps1.' -ForegroundColor DarkGray
    exit 1
}

if (-not $Quiet) {
    Write-Host 'scan-secrets: clean -- no secrets or non-technical keywords found.' -ForegroundColor Green
}
exit 0
