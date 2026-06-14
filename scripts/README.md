# Scripts

Local helper scripts for HomeCue Edge.

```powershell
.\scripts\check-local.ps1
```

Runs API dependency install, Python compile, API tests, then web dependency install, lint, and build. This is the main local gate and mirrors CI.

```powershell
.\scripts\start-dev.ps1
```

Starts the FastAPI edge gateway on `http://127.0.0.1:8723` and the Vite web console on `http://127.0.0.1:5173`.

```powershell
.\scripts\verify-qwen.ps1
```

Runs the configured OpenAI-compatible planner path against the active provider and prints a verification result. Requires a valid key in `apps/api/.env`.
