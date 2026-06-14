# HomeCue Edge API

FastAPI edge gateway for the HomeCue Edge prototype.

## Local Run

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --reload --port 8723
```

## Endpoints

- `GET /health`
- `GET /context`
- `GET /devices`
- `POST /plan`
- `POST /devices/reset`

## Planner Configuration

Create `.env` from `.env.example`.

```text
QWEN_API_KEY=
QWEN_API_BASE=https://dashscope.aliyuncs.com/compatible-mode/v1
QWEN_MODEL=qwen-plus
PLANNER_PROVIDER=auto
```

Planner providers:

- `auto`: use Qwen when an API key exists; otherwise use mock.
- `mock`: deterministic local demo planner.
- `qwen`: require Qwen Cloud.

The API keeps offline fallback separate from planner provider so the demo can always show EdgeAgent reliability.

## Qwen Verification

After adding a real API key to `.env`, run from the repository root:

```powershell
.\scripts\verify-qwen.ps1
```

The verifier calls the same `/plan` route used by the demo and confirms the returned routine provider is `qwen`. It writes the result to `assets/demo/qwen-verification/latest.json`, which is ignored by Git because it depends on local credentials and runtime output.

## Tests

```powershell
.\.venv\Scripts\python -m pytest
```

The current tests cover health, mock planning, weak-network mode, offline fallback, and device reset behavior.
