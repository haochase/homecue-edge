import { createHash } from 'node:crypto'
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'
import {
  buildDemoUrl,
  fetchJson,
  getAcceptedActions,
  labels,
  postJson,
  setProposeOnly,
} from './demo-flow.mjs'
import { assertRuntimeHealth, createRuntimeHealthCollector } from './runtime-health.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')

const outputFile = process.argv[2] ?? path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const appUrl = process.argv[3] ?? 'http://127.0.0.1:5173'
const apiBase = process.argv[4] ?? 'http://127.0.0.1:8723'
const browserName = process.env.DESKTOP_LOOP_BROWSER_NAME ?? 'playwright-chromium'
const launchOptions = buildLaunchOptions()
const userDataDir = process.env.DESKTOP_LOOP_USER_DATA_DIR ?? path.join(repoRoot, 'assets', 'tmp', `desktop-loop-${Date.now()}`)
const screenshotDir =
  process.env.DESKTOP_LOOP_SCREENSHOT_DIR ?? path.join(repoRoot, 'assets', 'demo', `${browserName}-screens`)

const evidence = {
  success: false,
  runId: process.env.FULL_LOOP_RUN_ID ?? process.env.DESKTOP_LOOP_RUN_ID ?? null,
  startedAt: new Date().toISOString(),
  appUrl,
  apiBase,
  browserName,
  checks: {},
  screenshots: [],
}

let browser
let context
let runtimeHealth

try {
  await runCheck('hostEnvironment', () => verifyHostEnvironment())
  await postJson(`${apiBase}/devices/reset`, undefined)

  context = await chromium.launchPersistentContext(userDataDir, {
    ...launchOptions,
    viewport: { width: 1440, height: 1000 },
    deviceScaleFactor: 1,
  })
  browser = context.browser()
  const page = context.pages()[0] ?? await context.newPage()
  runtimeHealth = createRuntimeHealthCollector(page)

  await page.goto(buildDemoUrl(appUrl, apiBase), { waitUntil: 'networkidle' })
  await page.waitForSelector('.context-grid', { timeout: 10000 })
  evidence.pageUrl = page.url()
  await captureScreenshot(page, '01-control-console.png')

  await runCheck('browserEnvironment', () => verifyBrowserEnvironment(page))
  await runCheck('localizedUi', () => verifyLocalizedUi(page))
  await runCheck('firstViewportVisibility', () => verifyFirstViewportVisibility(page))
  await runCheck('responsiveLayout', () => verifyResponsiveLayout(page))
  await runCheck('scenePromptHandoff', () => verifyScenePromptHandoff(page))
  await captureScreenshot(page, '02-scene-prompt-handoff.png')
  await runCheck('proposeOnly', () => verifyProposeOnly(page))
  await captureScreenshot(page, '03-propose-only.png')
  await runCheck('webConfirmExecute', () => verifyWebConfirmExecute(page))
  await captureScreenshot(page, '04-web-confirmation.png')
  await runCheck('offlineFallback', () => verifyOfflineFallback(page))
  await captureScreenshot(page, '05-offline-fallback.png')
  await runCheck('externalExecutionSync', () => verifyExternalExecutionSync(page))
  await captureScreenshot(page, '06-external-sync.png')
  await runCheck('screenshotEvidence', () => verifyScreenshotEvidence(evidence.screenshots))
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
  await context?.close()
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

async function verifyLocalizedUi(page) {
  const bodyText = await page.locator('body').innerText()
  const requiredText = [labels.title, labels.runPlan, labels.resetHome, '\u5bb6\u5ead\u573a\u666f']
  const missing = requiredText.filter((text) => !bodyText.includes(text))
  const textIntegrity = verifyChineseTextIntegrity(bodyText)

  if (missing.length) {
    throw new Error(`Localized UI text missing: ${missing.join(', ')}`)
  }

  return {
    title: await page.locator('h1').innerText(),
    runButton: await page.getByRole('button', { name: labels.runPlan }).innerText(),
    resetButtonCount: await page.getByRole('button', { name: labels.resetHome }).count(),
    textIntegrity,
  }
}

function verifyChineseTextIntegrity(bodyText) {
  const requiredPhrases = [
    labels.title,
    '家庭场景',
    '本地上下文',
    '边缘侧保留',
    '手机视觉摘要',
    '优先打开前置摄像头',
    '结构化动作会先通过本地策略校验。',
  ]
  const missingPhrases = requiredPhrases.filter((phrase) => !bodyText.includes(phrase))
  const mojibakeMatches = Array.from(new Set(bodyText.match(/\uFFFD|锟|Ã|Â|â€|âœ|ä¸|å®|ç”|è¾|绛\?|鎽|璇|鍓|寰/g) ?? []))

  if (missingPhrases.length || mojibakeMatches.length) {
    throw new Error(
      `Chinese text integrity failed: ${JSON.stringify({
        missingPhrases,
        mojibakeMatches,
      })}`,
    )
  }

  return {
    requiredPhraseCount: requiredPhrases.length,
    missingPhraseCount: missingPhrases.length,
    mojibakeCount: mojibakeMatches.length,
  }
}

function verifyHostEnvironment() {
  const nodeMajorVersion = Number(process.versions.node.split('.')[0])
  const host = {
    platform: process.platform,
    arch: process.arch,
    nodeVersion: process.versions.node,
    nodeMajorVersion,
    ci: process.env.CI === 'true',
  }

  if (!Number.isFinite(nodeMajorVersion) || nodeMajorVersion < 20) {
    throw new Error(`Unexpected Node.js version for desktop loop: ${process.versions.node}`)
  }
  if (!['win32', 'darwin', 'linux'].includes(host.platform)) {
    throw new Error(`Unexpected host platform for desktop loop: ${host.platform}`)
  }
  if (!['x64', 'arm64'].includes(host.arch)) {
    throw new Error(`Unexpected host architecture for desktop loop: ${host.arch}`)
  }

  return host
}

async function verifyFirstViewportVisibility(page) {
  const result = await page.evaluate(() => {
    const selectors = [
      ['topbar', '.topbar'],
      ['prompt', '.prompt-panel'],
      ['context', '.context-panel'],
      ['scene', '.scene-panel'],
      ['plan', '.plan-panel'],
    ]

    return selectors.map(([label, selector]) => {
      const element = document.querySelector(selector)
      if (!element) {
        return { label, selector, present: false }
      }

      const rect = element.getBoundingClientRect()
      const visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0))
      const visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0))
      const area = rect.width * rect.height
      const visibleArea = visibleWidth * visibleHeight

      return {
        label,
        selector,
        present: true,
        left: Math.round(rect.left),
        top: Math.round(rect.top),
        right: Math.round(rect.right),
        bottom: Math.round(rect.bottom),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        visibleRatio: area > 0 ? Number((visibleArea / area).toFixed(3)) : 0,
      }
    })
  })

  const failing = result.filter(
    (item) => !item.present || item.width <= 0 || item.height <= 0 || item.top < 0 || item.visibleRatio < 0.9,
  )
  if (failing.length) {
    throw new Error(`First viewport visibility failed: ${JSON.stringify(failing)}`)
  }

  return {
    minVisibleRatio: Math.min(...result.map((item) => item.visibleRatio)),
    panels: result,
  }
}

async function verifyBrowserEnvironment(page) {
  const environment = await page.evaluate(() => ({
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    language: navigator.language,
    languages: Array.from(navigator.languages ?? []),
    webdriver: navigator.webdriver,
    mediaDevices: Boolean(navigator.mediaDevices),
    getUserMedia: Boolean(navigator.mediaDevices?.getUserMedia),
    speechRecognition: Boolean(window.SpeechRecognition || window.webkitSpeechRecognition),
    locationOrigin: window.location.origin,
    viewport: {
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
    },
  }))
  const contextInfo = {
    browserName,
    executablePath: process.env.DESKTOP_LOOP_EXECUTABLE_PATH ? 'custom' : 'bundled',
    executableFileName: process.env.DESKTOP_LOOP_EXECUTABLE_FILE_NAME ?? null,
    executableSource: process.env.DESKTOP_LOOP_EXECUTABLE_SOURCE ?? null,
    executableProductName: process.env.DESKTOP_LOOP_EXECUTABLE_PRODUCT_NAME ?? null,
    executableCompanyName: process.env.DESKTOP_LOOP_EXECUTABLE_COMPANY_NAME ?? null,
    executableProductVersion: process.env.DESKTOP_LOOP_EXECUTABLE_PRODUCT_VERSION ?? null,
    channel: process.env.DESKTOP_LOOP_CHANNEL ?? null,
    headed: process.env.DESKTOP_LOOP_HEADED === 'true',
  }

  if (!environment.userAgent.includes('Chrome') && !environment.userAgent.includes('Chromium')) {
    throw new Error(`Unexpected browser userAgent: ${environment.userAgent}`)
  }

  if (!environment.mediaDevices) {
    throw new Error('Browser did not expose navigator.mediaDevices.')
  }

  if (environment.viewport.innerWidth < 1000 || environment.viewport.innerHeight < 700) {
    throw new Error(`Unexpected initial desktop viewport: ${JSON.stringify(environment.viewport)}`)
  }

  return {
    ...contextInfo,
    ...environment,
  }
}

async function verifyResponsiveLayout(page) {
  const viewports = [
    { width: 390, height: 900, label: 'mobile' },
    { width: 768, height: 1000, label: 'tablet' },
    { width: 1440, height: 1000, label: 'desktop' },
  ]
  const results = []

  for (const viewport of viewports) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height })
    await page.waitForTimeout(250)
    const result = await page.evaluate((currentViewport) => {
      const documentElement = document.documentElement
      const overflowX = documentElement.scrollWidth - documentElement.clientWidth
      const requiredSelectors = ['.workspace', '.prompt-panel', '.scene-panel', '.plan-panel', '.lower-grid']
      const missingSelectors = requiredSelectors.filter((selector) => !document.querySelector(selector))
      const panelRects = Array.from(document.querySelectorAll('.workspace > .panel, .lower-grid > .panel')).map(
        (panel, index) => {
          const rect = panel.getBoundingClientRect()
          return {
            label: panel.className || `panel-${index}`,
            left: Math.round(rect.left),
            top: Math.round(rect.top),
            right: Math.round(rect.right),
            bottom: Math.round(rect.bottom),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
          }
        },
      )
      const overlappingPanelPairs = []
      const overflowingButtons = Array.from(document.querySelectorAll('button'))
        .map((button) => {
          const rect = button.getBoundingClientRect()
          return {
            text: button.textContent?.trim() ?? '',
            width: Math.round(rect.width),
            scrollWidth: button.scrollWidth,
            clientWidth: button.clientWidth,
          }
        })
        .filter((button) => button.scrollWidth > button.clientWidth + 1)

      for (let leftIndex = 0; leftIndex < panelRects.length; leftIndex += 1) {
        for (let rightIndex = leftIndex + 1; rightIndex < panelRects.length; rightIndex += 1) {
          const left = panelRects[leftIndex]
          const right = panelRects[rightIndex]
          const overlapWidth = Math.max(0, Math.min(left.right, right.right) - Math.max(left.left, right.left))
          const overlapHeight = Math.max(0, Math.min(left.bottom, right.bottom) - Math.max(left.top, right.top))
          const overlapArea = overlapWidth * overlapHeight
          if (overlapArea > 1) {
            overlappingPanelPairs.push({
              left: left.label,
              right: right.label,
              overlapWidth,
              overlapHeight,
              overlapArea,
            })
          }
        }
      }

      return {
        ...currentViewport,
        clientWidth: documentElement.clientWidth,
        scrollWidth: documentElement.scrollWidth,
        overflowX,
        missingSelectors,
        panelCount: panelRects.length,
        minPanelWidth: panelRects.length ? Math.min(...panelRects.map((panel) => panel.width)) : 0,
        minPanelHeight: panelRects.length ? Math.min(...panelRects.map((panel) => panel.height)) : 0,
        overlappingPanelPairs,
        overflowingButtons,
      }
    }, viewport)

    if (
      result.overflowX > 1 ||
      result.missingSelectors.length ||
      result.overflowingButtons.length ||
      result.overlappingPanelPairs.length
    ) {
      throw new Error(`Responsive layout failed: ${JSON.stringify(result)}`)
    }

    results.push(result)
  }

  await page.setViewportSize({ width: 1440, height: 1000 })
  return results
}

async function verifyScenePromptHandoff(page) {
  await page.getByRole('button', { name: labels.analyzeScene }).click()
  await page.waitForSelector('.scene-result', { timeout: 10000 })
  await page.getByRole('button', { name: labels.writeRequest }).click()

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

  const sceneResponse = await postJson(`${apiBase}/vision/scene`, {
    room: 'living room',
    camera: 'desktop',
    text_hint: '晚上有点累，坐在客厅沙发上，室内光线偏暗',
    image_base64: 'desktop-loop-frame-sentinel',
  })

  if (sceneResponse.privacy_summary?.raw_image_retained !== false) {
    throw new Error('Vision response did not mark raw_image_retained=false.')
  }

  const rawImageEchoed = JSON.stringify(sceneResponse).includes('desktop-loop-frame-sentinel')
  if (rawImageEchoed) {
    throw new Error('Vision response echoed the raw image payload.')
  }

  return {
    prompt: promptState.prompt,
    proposeOnly: promptState.proposeOnly,
    scene: sceneResponse.scene,
    rawImageRetained: sceneResponse.privacy_summary?.raw_image_retained,
    rawImageEchoed,
    observations: sceneResponse.observations,
  }
}

async function verifyProposeOnly(page) {
  await page.getByRole('button', { name: labels.resetHome }).first().click()
  await setProposeOnly(page, true)
  await page.getByRole('button', { name: labels.runPlan }).click()
  await page.waitForSelector('.execution-row.pending.accepted', { timeout: 10000 })

  const status = await page.locator('.status-badge').innerText()
  const precheckRows = await page.locator('.execution-row.pending.accepted').count()
  const latest = await fetchJson(`${apiBase}/execution/latest`)

  if (!status.includes(labels.pendingHardware)) {
    throw new Error(`Expected pending hardware status, got: ${status}`)
  }

  if (latest.executed) {
    throw new Error('Propose-only plan should not update latest execution as executed.')
  }

  return {
    status,
    precheckRows,
    latestSource: latest.source,
    latestExecuted: latest.executed,
  }
}

async function verifyWebConfirmExecute(page) {
  await page.getByRole('button', { name: labels.confirmActions }).click()
  await page.waitForSelector('.execution-row.accepted:not(.pending)', { timeout: 10000 })

  const status = await page.locator('.status-badge').innerText()
  const syncSource = await page.locator('.sync-source').innerText()
  const latest = await fetchJson(`${apiBase}/execution/latest`)

  if (!status.includes(labels.executed) || latest.source !== 'web') {
    throw new Error(`Web confirmation did not sync correctly: ${status}, source=${latest.source}`)
  }

  return {
    status,
    syncSource,
    latestSource: latest.source,
    latestSequence: latest.sequence,
    acceptedRows: await page.locator('.execution-row.accepted:not(.pending)').count(),
  }
}

async function verifyOfflineFallback(page) {
  await page.getByRole('button', { name: labels.resetHome }).first().click()
  await page.getByRole('button', { name: labels.offline }).click()
  await setProposeOnly(page, false)
  await page.getByRole('button', { name: labels.runPlan }).click()
  await page.waitForSelector('text=\u79bb\u7ebf\u515c\u5e95', { timeout: 10000 })

  const summary = await page.locator('.plan-panel').innerText()
  const latest = await fetchJson(`${apiBase}/execution/latest`)

  if (!latest.executed || latest.source !== 'plan') {
    throw new Error(`Offline fallback should execute through /plan, got ${latest.source}/${latest.executed}`)
  }

  return {
    containsFallbackLabel: summary.includes('\u79bb\u7ebf\u515c\u5e95'),
    latestSource: latest.source,
    latestSequence: latest.sequence,
    executionCount: latest.execution.length,
  }
}

async function verifyExternalExecutionSync(page) {
  await page.getByRole('button', { name: labels.resetHome }).first().click()
  await page.getByRole('button', { name: labels.online }).click()
  await setProposeOnly(page, true)
  await page.getByRole('button', { name: labels.runPlan }).click()
  await page.waitForSelector('.execution-row.pending.accepted', { timeout: 10000 })

  const proposedPlan = await postJson(`${apiBase}/plan`, {
    prompt: 'Desktop loop simulates a room terminal confirming the proposed routine.',
    network_mode: 'online',
    agent_mode: true,
    execute: false,
  })
  const acceptedActions = getAcceptedActions(proposedPlan)

  if (!acceptedActions.length) {
    throw new Error('No accepted actions were available for external execution.')
  }

  const execution = await postJson(`${apiBase}/execute`, {
    source: 'esp32-serial',
    actions: acceptedActions,
  })

  const syncedState = await page
    .waitForFunction(
      ({ executedLabel, sourceLabel }) => {
        const sourceText = document.querySelector('.sync-source')?.textContent?.trim() ?? ''
        const status = document.querySelector('.status-badge')?.textContent?.trim() ?? ''
        if (status.includes(executedLabel) && sourceText.includes(sourceLabel)) {
          return {
            status,
            sourceText,
            rows: Array.from(document.querySelectorAll('.execution-row')).map((row) => row.textContent?.trim()),
          }
        }
        return null
      },
      { executedLabel: labels.executed, sourceLabel: labels.esp32Serial },
      { timeout: 10000 },
    )
    .then((handle) => handle.jsonValue())

  const latest = await fetchJson(`${apiBase}/execution/latest`)

  return {
    acceptedActionCount: acceptedActions.length,
    apiSource: execution.source,
    apiSequence: execution.sequence,
    latestSource: latest.source,
    latestSequence: latest.sequence,
    syncedState,
  }
}

async function writeEvidence(file, value) {
  await mkdir(path.dirname(file), { recursive: true })
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

async function captureScreenshot(page, filename) {
  await mkdir(screenshotDir, { recursive: true })
  const file = path.join(screenshotDir, filename)
  await page.screenshot({ path: file, fullPage: true })
  evidence.screenshots.push(relativePath(file))
}

async function verifyScreenshotEvidence(screenshots) {
  const expectedFiles = [
    '01-control-console.png',
    '02-scene-prompt-handoff.png',
    '03-propose-only.png',
    '04-web-confirmation.png',
    '05-offline-fallback.png',
    '06-external-sync.png',
  ]
  const expectedCount = expectedFiles.length
  if (screenshots.length !== expectedCount) {
    throw new Error(`Expected ${expectedCount} screenshots, got ${screenshots.length}.`)
  }

  const results = []
  for (const [index, screenshot] of screenshots.entries()) {
    const expectedFile = expectedFiles[index]
    if (path.basename(screenshot) !== expectedFile) {
      throw new Error(`Unexpected screenshot order: expected ${expectedFile}, got ${screenshot}.`)
    }

    const absolutePath = path.resolve(repoRoot, screenshot)
    const fileStat = await stat(absolutePath)
    const buffer = await readFile(absolutePath)
    const metadata = parsePngMetadata(buffer)
    const result = {
      path: screenshot,
      bytes: fileStat.size,
      sha256: createHash('sha256').update(buffer).digest('hex').slice(0, 12),
      ...metadata,
    }

    if (result.width < 390 || result.height < 300 || result.bytes < 5000 || result.imageDataBytes < 1000) {
      throw new Error(`Screenshot evidence is too small or blank-like: ${JSON.stringify(result)}`)
    }

    results.push(result)
  }

  const uniqueDigests = new Set(results.map((item) => item.sha256))
  if (uniqueDigests.size !== results.length) {
    throw new Error(`Screenshot evidence contains duplicate images: ${JSON.stringify(results)}`)
  }

  return {
    count: results.length,
    expectedFiles,
    uniqueDigestCount: uniqueDigests.size,
    minWidth: Math.min(...results.map((item) => item.width)),
    minHeight: Math.min(...results.map((item) => item.height)),
    minBytes: Math.min(...results.map((item) => item.bytes)),
    minImageDataBytes: Math.min(...results.map((item) => item.imageDataBytes)),
    files: results,
  }
}

function parsePngMetadata(buffer) {
  const signature = buffer.subarray(0, 8).toString('hex')
  if (signature !== '89504e470d0a1a0a') {
    throw new Error('Screenshot is not a PNG file.')
  }

  const width = buffer.readUInt32BE(16)
  const height = buffer.readUInt32BE(20)
  let offset = 8
  let imageDataBytes = 0

  while (offset + 12 <= buffer.length) {
    const length = buffer.readUInt32BE(offset)
    const type = buffer.subarray(offset + 4, offset + 8).toString('ascii')
    if (type === 'IDAT') {
      imageDataBytes += length
    }
    offset += 12 + length
    if (type === 'IEND') break
  }

  return {
    width,
    height,
    imageDataBytes,
  }
}

function relativePath(file) {
  return path.relative(repoRoot, path.resolve(file)).replaceAll(path.sep, '/')
}

function buildLaunchOptions() {
  const options = {}

  if (process.env.DESKTOP_LOOP_HEADED === 'true') {
    options.headless = false
  }

  if (process.env.DESKTOP_LOOP_CHANNEL) {
    options.channel = process.env.DESKTOP_LOOP_CHANNEL
  }

  if (process.env.DESKTOP_LOOP_EXECUTABLE_PATH) {
    options.executablePath = process.env.DESKTOP_LOOP_EXECUTABLE_PATH
  }

  return options
}
