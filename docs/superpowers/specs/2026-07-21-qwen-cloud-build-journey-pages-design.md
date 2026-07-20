# Qwen Cloud Build Journey Page Design

## Goal

Publish a standalone English technical article on the existing HomeCue Edge
GitHub Pages site. The page explains how the project combines local context,
Qwen Cloud planning, human confirmation, local policy enforcement, and offline
fallback.

Target URL:

```text
https://haochase.github.io/homecue-edge/building-homecue-edge-with-qwen-cloud/
```

## Publication Shape

The article is a standalone static page at:

```text
apps/web/public/building-homecue-edge-with-qwen-cloud/index.html
```

Vite copies the page into `dist` during the existing web build. The article
does not add React routing or change the main HomeCue Edge console.

The Pages workflow keeps manual dispatch support and also deploys on pushes to
`codex/software-demo-closure`. This makes publication deterministic from the
verified branch without changing the default application flow.

## Article Structure

1. Product problem: useful home automation needs context, privacy, and local
   control rather than direct model-to-device execution.
2. System loop: local context, privacy summary, Qwen Cloud proposal, local
   policy precheck, human confirmation, guarded execution, and offline fallback.
3. Qwen Cloud integration: OpenAI-compatible planning with `qwen3.7-plus`.
4. Engineering journey: proxy diagnosis, per-model free quota selection,
   thinking latency, and the scoped `enable_thinking=false` compatibility fix.
5. Safety design: propose-only planning, action allowlist, and explicit user
   confirmation.
6. Evidence: fresh Qwen verification, 100 confirmed successful calls, 73 API
   tests, 24 firmware-flow checks, and web lint/build.
7. Lessons and next steps: observable agent traces, real device integration,
   and stronger local inference.

The article links to the public repository and the live HomeCue Edge demo.

## Visual Design

The page uses a quiet technical editorial layout rather than the control-console
UI. It includes:

- a compact product header and plain-language summary;
- an actual HomeCue Edge console screenshot captured from the static demo;
- an unframed architecture flow rendered with semantic HTML and CSS;
- compact evidence metrics and code excerpts;
- responsive typography and a single-column mobile layout.

The page avoids decorative gradients, nested cards, oversized marketing type,
and private cloud-console screenshots.

## Public Boundary

The page contains technical material only. It excludes account identifiers,
API keys, billing data, local filesystem paths, private planning, and personal
material. Only the generated product screenshot is published; cloud-console
images remain outside the article assets.

## Verification

Before publication:

- run the web lint and production build;
- confirm the article and screenshot exist in `apps/web/dist`;
- inspect desktop and mobile screenshots for overflow and overlap;
- run `git diff --check`;
- run tracked and staged secret scans;
- stage only the article, its product screenshot, workflow update, and related
  public documentation;
- push the current branch and verify the Pages deployment and public URL.

## Success Criteria

- The public URL returns HTTP 200.
- The page identifies Qwen Cloud and `qwen3.7-plus` accurately.
- The article describes the real engineering journey without overstating
  hardware or external deployment readiness.
- The page is readable at desktop and mobile widths.
- Repository safety scans and project checks pass.
