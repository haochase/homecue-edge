# HomeCue Edge Web Console

React + Vite control console for the HomeCue Edge demo.

## Local Run

```powershell
npm install
npm run dev
```

The console expects the FastAPI gateway at `http://localhost:8723` by default.

## API Base

Use either an environment variable:

```powershell
$env:VITE_API_BASE="http://127.0.0.1:8723"
npm run dev
```

Or a URL query parameter for scripted capture:

```text
http://127.0.0.1:5173/?apiBase=http://127.0.0.1:18000
```

The query parameter takes precedence over `VITE_API_BASE`.

## Static Demo Mode

For public demos without a running API server, open:

```text
http://127.0.0.1:5173/?demo=static
```

Or build a static-only demo:

```powershell
$env:VITE_STATIC_DEMO="true"
$env:VITE_BASE="/homecue-edge/"
npm run build
```

This mode uses the same UI, local action policy, and demo scenario with static in-browser data. The FastAPI path remains the technical source of truth for local development.

## Production Build

```powershell
npm run build
```

The build output is written to `dist/`.
