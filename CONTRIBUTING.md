# Contributing to HomeCue Edge

This repository is **public** and must contain **technical content only**.
Before contributing, read [`AGENTS.md`](AGENTS.md) — it defines the security
rules for both human contributors and AI agents.

## Pre-commit flow (required)

Run the privacy/secret scanner before every commit and before any push:

```powershell
# scan everything currently tracked
pwsh ./scripts/scan-secrets.ps1

# scan only what you are about to commit
pwsh ./scripts/scan-secrets.ps1 -Staged
```

The scanner exits non-zero and lists `file:line` findings if it detects:

- secret-shaped tokens (`sk-…`, `tp-…`, `ghp_…`, `AKIA…`), or
- non-technical / personal keywords that must not appear in a public repo.

If it reports a finding, **do not commit** — remove the content first.

## Install the git hook (recommended)

Wire the scanner into git so it runs automatically on every commit:

```powershell
# versioned hooks path (applies the repo's scripts/hooks/*)
git config core.hooksPath scripts/hooks
```

Or copy the hook into your local hooks directory:

```powershell
Copy-Item scripts/hooks/pre-commit .git/hooks/pre-commit
```

```sh
cp scripts/hooks/pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

The hook requires PowerShell (`pwsh` on Linux/macOS, or `powershell.exe` on
Windows). If PowerShell is unavailable the hook skips (run the scanner manually).

## Local checks

```powershell
.\scripts\check-local.ps1      # API tests + web lint/build
.\scripts\verify-qwen.ps1      # real provider verification (needs a key)
```

## Secrets & config

- Never hard-code keys. Copy `apps/api/.env.example` to `apps/api/.env`
  (git-ignored) and `firmware/esp32-audio/secrets.h.example` to `secrets.h`
  (git-ignored).
- Use placeholder values in any `*.example` file you add.
