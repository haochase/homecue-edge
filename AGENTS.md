# AGENTS.md — Contributor & AI-Agent Security Rules

> This repository is **PUBLIC**. Everything committed here is visible to anyone.
> These rules apply to every human contributor and every AI coding agent that
> touches this repo. They are deliberately strict to keep the public history
> clean of secrets and non-technical/private material.

## 1. Two-zone isolation (the most important rule)

There are two separate zones. Never mix them.

| Zone | Location | Visibility | Allowed content |
| --- | --- | --- | --- |
| **Private workspace** | the parent working directory (outside this repo) | never published | planning, career, and personal documents |
| **Public repo** | this repository (`homecue-edge/`) | public on GitHub | technical content only (code, firmware, technical docs, security tooling) |

- **Never copy any private/planning document from the parent workspace into this repo.**
- Only technical artifacts belong here: application code, firmware, tests, CI,
  technical READMEs, and the security tooling in `scripts/`.

## 2. Run the scanner before every commit / push

```powershell
pwsh ./scripts/scan-secrets.ps1 -All -IncludeUntracked  # scan tracked + new files
pwsh ./scripts/scan-secrets.ps1 -Staged                  # scan staged changes (what the hook runs)
```

A non-zero exit means **do not commit**. Fix the finding first. See
`CONTRIBUTING.md` for the full pre-commit flow and how to install the hook.

## 3. Hard prohibitions

- **Do not** hard-code real API keys, access tokens, or passwords anywhere.
  Secrets live only in git-ignored files (`apps/api/.env`, `firmware/**/secrets.h`).
- **Do not** commit `.env`, `.env.*`, or `secrets.h` (they are git-ignored; the
  scanner also blocks them if force-staged).
- **Do not** write personal identifiers into the repo: real email addresses,
  real personal domains, local absolute filesystem paths, or real names.
- **Do not** add career-, hiring-, or competition-submission-related content.
  The exact blocked keyword list is maintained in `scripts/scan-secrets.ps1`.
- **Do not** `git push --force` to `main` or rewrite shared history without an
  explicit human instruction.
- **Do not** push any local backup/mirror of the old repository history.

## 4. Commit & push discipline

- Do not `commit` or `push` automatically. Propose the commands and let a human
  decide when to run them.
- Use placeholders (e.g. `your-key-here`, `192.168.x.x`, `example.com`) in any
  example/config template you add (`*.example` files).
- After adding or editing files, re-run
  `scripts/scan-secrets.ps1 -All -IncludeUntracked` and confirm it reports
  **clean** before handing back.

## 5. Project invariants (don't break these)

- Backend port is **8723** everywhere (README, firmware, scripts).
- The active LLM provider is selected by the `ACTIVE_PROVIDER` env var; the
  planner is OpenAI-compatible. Keys stay in the git-ignored `.env`.
- `main` must always be demoable. Default `POST /plan` behaviour (without
  `agent_mode`) must not change. The device guard (`ALLOWED_ACTIONS`) is the
  single source of truth for execution.
