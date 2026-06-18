import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'
import { buildDemoUrl, pause } from './demo-flow.mjs'
import { assertRuntimeHealth, createRuntimeHealthCollector } from './runtime-health.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')

const appUrl = process.argv[2] ?? 'http://127.0.0.1:5173'
const apiBase = process.argv[3] ?? 'http://127.0.0.1:8723'
const cdpEndpoint = process.argv[4] ?? 'http://127.0.0.1:9222'
const outputFile = process.argv[5] ?? path.join(repoRoot, 'assets', 'demo', 'phone-loop.json')
const requireSpeech = process.env.PHONE_LOOP_REQUIRE_SPEECH !== 'false'

const labels = {
  title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
  voiceInput: '\u8bed\u97f3\u8f93\u5165',
  stopVoice: '\u505c\u6b62\u8bed\u97f3',
  openFrontCamera: '\u4f18\u5148\u6253\u5f00\u524d\u7f6e\u6444\u50cf\u5934',
  captureFrame: '\u622a\u53d6\u753b\u9762',
  analyzeScene: '\u5206\u6790\u573a\u666f',
  writeRequest: '\u5199\u5165\u8bf7\u6c42',
  proposeOnly: '\u53ea\u751f\u6210\u5efa\u8bae',
  runPlan: '\u751f\u6210\u8ba1\u5212',
  pendingHardware: '\u7b49\u5f85\u786c\u4ef6\u786e\u8ba4',
  executed: '\u5df2\u672c\u5730\u6267\u884c',
  esp32Serial: 'ESP32 \u4e32\u53e3',
}

const evidence = {
  success: false,
  runId: process.env.FULL_LOOP_RUN_ID ?? null,
  startedAt: new Date().toISOString(),
  appUrl,
  apiBase,
  cdpEndpoint,
  checks: {},
}

let browser
let page
let runtimeHealth

try {
  await resetDevices(apiBase)

  browser = await chromium.connectOverCDP(cdpEndpoint)
  const context = browser.contexts()[0]
  if (!context) {
    throw new Error(`No browser context was exposed by ${cdpEndpoint}`)
  }

  const targetUrl = buildDemoUrl(appUrl, apiBase)
  page = await getPhonePage(context, targetUrl)
  runtimeHealth = createRuntimeHealthCollector(page)
  await page.goto(targetUrl, { waitUntil: 'networkidle' })
  await page.waitForSelector('.context-grid', { timeout: 15000 })
  evidence.pageUrl = page.url()

  await runCheck('localizedUi', () => verifyLocalizedUi(page))
  await runCheck('frontCamera', () => verifyFrontCamera(page))
  await runCheck('scene', () => verifySceneSummary(page))
  await runCheck('scenePromptHandoff', () => verifyScenePromptHandoff(page))
  await runCheck('speechInput', () => verifySpeechInput(page, requireSpeech))
  await runCheck('externalExecution', () => verifyExternalExecution(page, apiBase))
  await runCheck('runtimeHealth', () => assertRuntimeHealth(runtimeHealth))

  evidence.success = true
  evidence.finishedAt = new Date().toISOString()
  await writeEvidence(outputFile, evidence)
} catch (error) {
  if (runtimeHealth && !evidence.checks.runtimeHealth) {
    evidence.checks.runtimeHealth = runtimeHealth.snapshot()
  }
  evidence.error = error instanceof Error ? error.message : String(error)
  evidence.finishedAt = new Date().toISOString()
  await writeEvidence(outputFile, evidence)
  throw error
} finally {
  if (page) {
    await cleanupPage(page)
  }
  if (browser?.isConnected()) {
    await browser.close()
  }
}

async function runCheck(name, task) {
  try {
    const result = await task()
    evidence.checks[name] = result
    return result
  } catch (error) {
    const details = error && typeof error === 'object' && 'details' in error ? error.details : undefined
    evidence.checks[name] = {
      success: false,
      error: error instanceof Error ? error.message : String(error),
      ...(details ? { details } : {}),
    }
    throw error
  }
}

async function getPhonePage(context, targetUrl) {
  const targetOrigin = new URL(targetUrl).origin
  const pages = context.pages()
  const currentPage =
    pages.find((page) => page.url().startsWith(targetOrigin)) ??
    pages.find((page) => page.url().includes('phone-probe') || page.url().includes('127.0.0.1')) ??
    pages[0]

  return currentPage ?? context.newPage()
}

async function verifyLocalizedUi(page) {
  const text = await page.locator('body').innerText()
  const requiredText = [labels.title, labels.voiceInput, labels.openFrontCamera, labels.runPlan]
  const missing = requiredText.filter((item) => !text.includes(item))

  if (missing.length) {
    throw new Error(`Localized UI text missing: ${missing.join(', ')}`)
  }

  return {
    title: await page.locator('h1').innerText(),
    voiceButton: await page.getByRole('button', { name: labels.voiceInput }).innerText(),
    frontCameraButton: await page.getByRole('button', { name: labels.openFrontCamera }).innerText(),
  }
}

async function verifySpeechInput(page, shouldRequireSpeech) {
  const support = await page.evaluate(() => ({
    SpeechRecognition: Boolean(window.SpeechRecognition),
    webkitSpeechRecognition: Boolean(window.webkitSpeechRecognition),
  }))

  if (!support.SpeechRecognition && !support.webkitSpeechRecognition) {
    if (shouldRequireSpeech) {
      throw new Error('Android Chrome did not expose SpeechRecognition or webkitSpeechRecognition.')
    }

    return {
      support,
      skipped: true,
    }
  }

  await tapButton(page, labels.voiceInput)
  const listeningState = await page
    .waitForFunction(
      (stopVoiceLabel) => {
        const row = document.querySelector('.voice-input-row')
        const buttonText = row?.querySelector('button')?.textContent?.trim() ?? ''
        const status = row?.querySelector('span')?.textContent?.trim() ?? ''
        const error = document.querySelector('.voice-error')?.textContent?.trim() ?? ''
        if (buttonText.includes(stopVoiceLabel) || error) {
          return { buttonText, status, error }
        }
        return null
      },
      labels.stopVoice,
      { timeout: 8000 },
    )
    .then((handle) => handle.jsonValue())

  if (listeningState.error) {
    throw new Error(`Speech input failed: ${listeningState.error}`)
  }

  await tapButton(page, labels.stopVoice)
  await pause(500)

  return {
    support,
    listeningState,
  }
}

async function verifyFrontCamera(page) {
  await tapButton(page, labels.openFrontCamera)

  const cameraState = await waitForCameraResult(page, 20000)

  if (!cameraState.ready) {
    throw new Error(`Camera did not produce a video frame: ${JSON.stringify(cameraState)}`)
  }

  if (cameraState.facingMode && cameraState.facingMode !== 'user') {
    throw new Error(`Expected front camera facingMode=user, got ${cameraState.facingMode}`)
  }

  return cameraState
}

async function verifySceneSummary(page) {
  await tapButton(page, labels.captureFrame)
  const frameSize = await page
    .waitForFunction(() => document.querySelector('.camera-status-row strong')?.textContent?.trim() || null, null, {
      timeout: 8000,
    })
    .then((handle) => handle.jsonValue())

  await tapButton(page, labels.analyzeScene)
  await page.waitForSelector('.scene-result', { timeout: 10000 })

  const sceneState = await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('.scene-result .source-row'))
    const scene = rows[0]?.querySelector('strong')?.textContent?.trim() ?? ''
    const privacyText = document.querySelector('.scene-result .privacy')?.textContent?.trim() ?? ''
    const observations = Array.from(document.querySelectorAll('.scene-observations li')).map((item) =>
      item.textContent?.trim(),
    )
    return {
      scene,
      privacyText,
      observations,
      rawImageRetained: privacyText.includes('保留原始图像：是'),
      rawImageNotRetained: privacyText.includes('保留原始图像：否'),
    }
  })

  if (!sceneState.rawImageNotRetained || sceneState.rawImageRetained) {
    throw new Error(`Scene privacy state did not prove raw image non-retention: ${JSON.stringify(sceneState)}`)
  }

  return {
    frameSize,
    sceneText: await page.locator('.scene-result').innerText(),
    ...sceneState,
  }
}

async function verifyScenePromptHandoff(page) {
  await tapButton(page, labels.writeRequest)

  const promptState = await page
    .waitForFunction(() => {
      const textarea = document.querySelector('.prompt-panel textarea')
      const proposeOnly = document.querySelectorAll('.agent-toggle input')[1]
      if (!(textarea instanceof HTMLTextAreaElement) || !(proposeOnly instanceof HTMLInputElement)) {
        return null
      }

      const value = textarea.value.trim()
      if (value.includes('低负担') && proposeOnly.checked) {
        return {
          prompt: value,
          proposeOnly: proposeOnly.checked,
        }
      }

      return null
    }, null, { timeout: 8000 })
    .then((handle) => handle.jsonValue())

  return {
    prompt: promptState.prompt,
    proposeOnly: promptState.proposeOnly,
  }
}

async function verifyExternalExecution(page, currentApiBase) {
  await tapButton(page, labels.runPlan)
  await page.waitForSelector('.execution-row.pending.accepted', { timeout: 10000 })

  const proposedPlan = await postJson(`${currentApiBase}/plan`, {
    prompt: 'User is home and tired. Propose a reversible comfort routine.',
    network_mode: 'online',
    agent_mode: true,
    execute: false,
  })
  const acceptedActions = getAcceptedActions(proposedPlan)

  if (!acceptedActions.length) {
    throw new Error('No accepted actions were available for external execution.')
  }

  const execution = await postJson(`${currentApiBase}/execute`, {
    source: 'esp32-serial',
    actions: acceptedActions,
  })

  const syncedState = await page
    .waitForFunction(
      ({ executedLabel, sourceLabel }) => {
        const bodyText = document.body.textContent ?? ''
        const sourceText = document.querySelector('.sync-source')?.textContent?.trim() ?? ''
        if (bodyText.includes(executedLabel) && sourceText.includes(sourceLabel)) {
          return {
            sourceText,
            planStatus: document.querySelector('.status-badge')?.textContent?.trim() ?? '',
            executionRows: Array.from(document.querySelectorAll('.execution-row')).map((row) =>
              row.textContent?.trim(),
            ),
          }
        }
        return null
      },
      { executedLabel: labels.executed, sourceLabel: labels.esp32Serial },
      { timeout: 10000 },
    )
    .then((handle) => handle.jsonValue())

  const latest = await fetchJson(`${currentApiBase}/execution/latest`)

  return {
    acceptedActionCount: acceptedActions.length,
    apiSource: execution.source,
    apiSequence: execution.sequence,
    latestSource: latest.source,
    latestSequence: latest.sequence,
    syncedState,
  }
}

function getAcceptedActions(plan) {
  const precheck = Array.isArray(plan.precheck) ? plan.precheck : []
  const actions = Array.isArray(plan.routine?.actions) ? plan.routine.actions : []

  if (!precheck.length) {
    return actions
  }

  return actions.filter((action) =>
    precheck.some(
      (item) =>
        item.accepted &&
        item.device === action.device &&
        item.command === action.command &&
        item.value === action.value,
    ),
  )
}

async function resetDevices(currentApiBase) {
  await postJson(`${currentApiBase}/devices/reset`, undefined)
}

async function postJson(url, body) {
  const response = await fetch(url, {
    method: 'POST',
    headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })

  if (!response.ok) {
    throw new Error(`${url} returned HTTP ${response.status}`)
  }

  return response.json()
}

async function fetchJson(url) {
  const response = await fetch(url)
  if (!response.ok) {
    throw new Error(`${url} returned HTTP ${response.status}`)
  }
  return response.json()
}

async function writeEvidence(file, value) {
  await mkdir(path.dirname(file), { recursive: true })
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

async function tapButton(page, name) {
  const point = await page.evaluate((buttonName) => {
    const buttons = Array.from(document.querySelectorAll('button'))
    const button = buttons.find((item) => item.textContent?.trim() === buttonName)
    if (!button) return null

    button.scrollIntoView({ block: 'center', inline: 'nearest' })
    const rect = button.getBoundingClientRect()
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
    }
  }, name)

  if (!point) {
    throw new Error(`Button not found: ${name}`)
  }

  try {
    await page.touchscreen.tap(point.x, point.y)
    return
  } catch {
    // Fall back to DOM click for non-permission controls if CDP touch dispatch
    // is unavailable for a given Android Chrome target.
  }

  await page.evaluate((buttonName) => {
    const buttons = Array.from(document.querySelectorAll('button'))
    const button = buttons.find((item) => item.textContent?.trim() === buttonName)
    button?.click()
  }, name)
}

async function setProposeOnly(page) {
  const checked = await page.evaluate(() => {
    const input = document.querySelectorAll('.agent-toggle input')[1]
    if (!(input instanceof HTMLInputElement)) return false
    if (!input.checked) {
      input.click()
    }
    return input.checked
  })

  if (!checked) {
    throw new Error('Could not enable propose-only mode.')
  }
}

async function waitForCameraResult(page, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  let latest = await readCameraState(page)

  while (Date.now() < deadline) {
    latest = await readCameraState(page)
    if (latest.ready || latest.error) {
      return latest
    }
    await pause(500)
  }

  return latest
}

async function readCameraState(page) {
  return page.evaluate(() => {
    const video = document.querySelector('.camera-preview')
    const error = document.querySelector('.camera-error')?.textContent?.trim() ?? ''
    const status = document.querySelector('.camera-status-row span')?.textContent?.trim() ?? ''

    if (!(video instanceof HTMLVideoElement)) {
      return {
        ready: false,
        status,
        error: error || 'camera video element not found',
      }
    }

    const track = video.srcObject?.getVideoTracks?.()[0]
    const settings = track?.getSettings?.() ?? {}
    return {
      ready: video.videoWidth > 0 && video.videoHeight > 0,
      width: video.videoWidth,
      height: video.videoHeight,
      readyState: video.readyState,
      active: Boolean(video.srcObject),
      trackState: track?.readyState ?? null,
      facingMode: settings.facingMode ?? null,
      status,
      error,
    }
  })
}

async function cleanupPage(page) {
  try {
    await page.evaluate(() => {
      const video = document.querySelector('.camera-preview')
      if (video instanceof HTMLVideoElement) {
        video.srcObject?.getTracks?.().forEach((track) => track.stop())
        video.srcObject = null
      }
    })
  } catch {
    // Best effort cleanup only.
  }
}
