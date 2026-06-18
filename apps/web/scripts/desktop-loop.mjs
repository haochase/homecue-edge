import { mkdir, writeFile } from 'node:fs/promises'
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

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')

const outputFile = process.argv[2] ?? path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const appUrl = process.argv[3] ?? 'http://127.0.0.1:5173'
const apiBase = process.argv[4] ?? 'http://127.0.0.1:8723'
const browserName = process.env.DESKTOP_LOOP_BROWSER_NAME ?? 'playwright-chromium'
const launchOptions = buildLaunchOptions()
const userDataDir = process.env.DESKTOP_LOOP_USER_DATA_DIR ?? path.join(repoRoot, 'assets', 'tmp', `desktop-loop-${Date.now()}`)

const evidence = {
  success: false,
  startedAt: new Date().toISOString(),
  appUrl,
  apiBase,
  browserName,
  checks: {},
}

let browser
let context

try {
  await postJson(`${apiBase}/devices/reset`, undefined)

  context = await chromium.launchPersistentContext(userDataDir, {
    ...launchOptions,
    viewport: { width: 1440, height: 1000 },
    deviceScaleFactor: 1,
  })
  browser = context.browser()
  const page = context.pages()[0] ?? await context.newPage()

  await page.goto(buildDemoUrl(appUrl, apiBase), { waitUntil: 'networkidle' })
  await page.waitForSelector('.context-grid', { timeout: 10000 })
  evidence.pageUrl = page.url()

  await runCheck('localizedUi', () => verifyLocalizedUi(page))
  await runCheck('scenePromptHandoff', () => verifyScenePromptHandoff(page))
  await runCheck('proposeOnly', () => verifyProposeOnly(page))
  await runCheck('webConfirmExecute', () => verifyWebConfirmExecute(page))
  await runCheck('offlineFallback', () => verifyOfflineFallback(page))
  await runCheck('externalExecutionSync', () => verifyExternalExecutionSync(page))

  evidence.success = true
  evidence.finishedAt = new Date().toISOString()
  await writeEvidence(outputFile, evidence)
} catch (error) {
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
    evidence.checks[name] = {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    }
    throw error
  }
}

async function verifyLocalizedUi(page) {
  const bodyText = await page.locator('body').innerText()
  const requiredText = [labels.title, labels.runPlan, labels.resetHome, '\u5bb6\u5ead\u573a\u666f']
  const missing = requiredText.filter((text) => !bodyText.includes(text))

  if (missing.length) {
    throw new Error(`Localized UI text missing: ${missing.join(', ')}`)
  }

  return {
    title: await page.locator('h1').innerText(),
    runButton: await page.getByRole('button', { name: labels.runPlan }).innerText(),
    resetButtonCount: await page.getByRole('button', { name: labels.resetHome }).count(),
  }
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
      if (value.includes('User appears to be settling in after a tiring day') && proposeOnly.checked) {
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
