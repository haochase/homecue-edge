# Qwen Cloud Build Journey Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a standalone English HomeCue Edge build-journey article on the existing GitHub Pages site.

**Architecture:** A self-contained semantic HTML page lives under the Vite public directory, so the existing build copies it to a stable nested URL without adding React routing. The existing Pages workflow deploys the verified branch after web lint/build, and the article uses a real static-demo screenshot as its primary visual.

**Tech Stack:** HTML5, CSS, Vite public assets, PowerShell checks, GitHub Actions Pages.

## Global Constraints

- Target URL is `https://haochase.github.io/homecue-edge/building-homecue-edge-with-qwen-cloud/`.
- Keep the main React console and default `/plan` behavior unchanged.
- Publish technical content only; exclude secrets, account data, billing data, local paths, private planning, and personal material.
- Describe `qwen3.7-plus`, 100 confirmed calls, 73 API tests, 24 firmware-flow checks, human confirmation, guarded execution, and offline fallback accurately.
- Publish only an actual HomeCue Edge product screenshot; do not publish cloud-console images.
- Preserve the unrelated untracked `AlibabaCloudDeployment.png` file.

---

### Task 1: Standalone English Article

**Files:**
- Create: `apps/web/public/building-homecue-edge-with-qwen-cloud/index.html`
- Modify: `README.md`

**Interfaces:**
- Consumes: Vite public-directory copying and the `/homecue-edge/` Pages base.
- Produces: A static page at `building-homecue-edge-with-qwen-cloud/index.html` and a repository link to the public URL.

- [ ] **Step 1: Verify the target page does not exist**

Run:

```powershell
Test-Path .\apps\web\public\building-homecue-edge-with-qwen-cloud\index.html
```

Expected: `False`.

- [ ] **Step 2: Create the article page**

Create semantic HTML with these exact visible sections:

```text
Building HomeCue Edge with Qwen Cloud
The Product Problem
The Edge-to-Cloud Loop
Connecting Qwen Cloud
What Broke, and What Fixed It
Why the Model Never Executes Devices Directly
Evidence, Not Just a Demo
What I Learned
What Comes Next
```

Include metadata for title, description, Open Graph title/description, canonical URL, and a responsive viewport. Link to `https://github.com/haochase/homecue-edge` and `https://haochase.github.io/homecue-edge/`.

Use an embedded `<style>` block with a restrained white/ink/green/amber palette, maximum article width of `1120px`, square evidence metrics, an unframed architecture flow, and a mobile breakpoint at `720px`. Reference `./homecue-edge-console.png` as the primary product image.

- [ ] **Step 3: Add repository discoverability**

Add this README section before `## Local Development`:

```markdown
## Build Journey

Read [Building HomeCue Edge with Qwen Cloud](https://haochase.github.io/homecue-edge/building-homecue-edge-with-qwen-cloud/) for the engineering story behind the Qwen planner, local safety boundary, human confirmation flow, and offline fallback.
```

- [ ] **Step 4: Verify article contracts**

Run a PowerShell assertion that the HTML contains the canonical URL, all nine headings, the repository URL, the live-demo URL, and `homecue-edge-console.png`.

Expected: all assertions pass with exit code 0.

### Task 2: Actual Product Screenshot

**Files:**
- Create: `apps/web/public/building-homecue-edge-with-qwen-cloud/homecue-edge-console.png`

**Interfaces:**
- Consumes: HomeCue Edge static demo at `?demo=static`.
- Produces: A 1440px-wide product image referenced by the article.

- [ ] **Step 1: Start the existing static demo**

Run the Vite development server from `apps/web` on an available local port with `VITE_STATIC_DEMO=true`.

- [ ] **Step 2: Capture real product state**

Use Playwright at a 1440x1000 viewport, open `/?demo=static`, enable Agent mode and Propose only, generate the evening routine, and capture the console after the explainable trace and pending guard are visible but before confirmation.

Save the cropped product screenshot as:

```text
apps/web/public/building-homecue-edge-with-qwen-cloud/homecue-edge-console.png
```

- [ ] **Step 3: Validate the image**

Verify PNG signature, width at least 1200px, height at least 650px, file size above 50KB, and nonblank canvas pixels.

Expected: all image checks pass.

### Task 3: Automatic Pages Deployment

**Files:**
- Modify: `.github/workflows/pages.yml`

**Interfaces:**
- Consumes: `apps/web/dist` from `npm run build`.
- Produces: A Pages deployment on pushes to `codex/software-demo-closure` while retaining manual dispatch.

- [ ] **Step 1: Add the branch trigger**

Change the workflow trigger to:

```yaml
on:
  push:
    branches:
      - codex/software-demo-closure
  workflow_dispatch:
```

- [ ] **Step 2: Run web quality gates**

Run from `apps/web`:

```powershell
npm run lint
$env:VITE_STATIC_DEMO='true'; $env:VITE_BASE='/homecue-edge/'; npm run build
```

Expected: ESLint exit 0 and Vite build exit 0.

- [ ] **Step 3: Verify build output**

Check that both files exist:

```text
apps/web/dist/building-homecue-edge-with-qwen-cloud/index.html
apps/web/dist/building-homecue-edge-with-qwen-cloud/homecue-edge-console.png
```

### Task 4: Visual QA and Publication

**Files:**
- Verify: `apps/web/public/building-homecue-edge-with-qwen-cloud/index.html`
- Verify: `apps/web/public/building-homecue-edge-with-qwen-cloud/homecue-edge-console.png`
- Verify: `.github/workflows/pages.yml`
- Verify: `README.md`

**Interfaces:**
- Consumes: built `apps/web/dist` and the Pages workflow.
- Produces: A public HTTP 200 article URL and a clean published branch.

- [ ] **Step 1: Serve and inspect the production build**

Serve `apps/web/dist` locally. Use Playwright screenshots at 1440x1000 and 390x844. Verify no horizontal overflow, text overlap, clipped navigation, blank product image, or illegible evidence metrics.

- [ ] **Step 2: Run repository gates**

Run:

```powershell
.\scripts\check-local.ps1
git diff --check
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-secrets.ps1 -All -IncludeUntracked
```

Expected: local checks pass, whitespace check passes, secret scan reports clean.

- [ ] **Step 3: Stage the exact publication set**

Stage only:

```text
.github/workflows/pages.yml
README.md
apps/web/public/building-homecue-edge-with-qwen-cloud/index.html
apps/web/public/building-homecue-edge-with-qwen-cloud/homecue-edge-console.png
docs/superpowers/plans/2026-07-21-qwen-cloud-build-journey-pages.md
```

Run the staged secret scan and confirm clean.

- [ ] **Step 4: Commit and push**

Run:

```powershell
git commit -m "docs: publish qwen cloud build journey"
git push
```

- [ ] **Step 5: Verify deployment**

Confirm the Pages workflow completes successfully, then request:

```text
https://haochase.github.io/homecue-edge/building-homecue-edge-with-qwen-cloud/
```

Expected: HTTP 200 with the article title and product image.
