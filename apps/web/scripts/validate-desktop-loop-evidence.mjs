import { createHash } from 'node:crypto'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const defaultEvidenceFile = path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const { evidenceFile, optionArgs } = parseCliArgs(process.argv.slice(2), defaultEvidenceFile)
const EXPECTED_SCREENSHOT_FILES = [
  '01-control-console.png',
  '02-scene-prompt-handoff.png',
  '03-propose-only.png',
  '04-web-confirmation.png',
  '05-offline-fallback.png',
  '06-external-sync.png',
]
const EXPECTED_LOCALIZED_UI = {
  title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
  runButton: '\u751f\u6210\u8ba1\u5212',
  minResetButtonCount: 1,
}
const MIN_LOCALIZED_PHRASE_COUNT = 7
const options = parseOptions(optionArgs)
const evidence = JSON.parse(await readFile(evidenceFile, 'utf8'))
const errors = await validateEvidence(evidence, options)

if (errors.length) {
  console.error(`Desktop loop evidence validation failed: ${evidenceFile}`)
  for (const error of errors) {
    console.error(`- ${error}`)
  }
  process.exit(1)
}

console.log(`Desktop loop evidence validation passed: ${evidenceFile}`)

function parseCliArgs(args, defaultFile) {
  const [firstArg, ...remainingArgs] = args
  if (firstArg && !firstArg.startsWith('--')) {
    return { evidenceFile: firstArg, optionArgs: remainingArgs }
  }

  return { evidenceFile: defaultFile, optionArgs: args }
}

function parseOptions(args) {
  return {
    expectedBrowserName: optionValue(args, '--browser-name') ?? 'playwright-chromium',
    expectedExecutablePath: optionValue(args, '--executable-path') ?? 'bundled',
    expectedScreenshotDir: optionValue(args, '--screenshot-dir') ?? null,
    requireInstalledChrome: args.includes('--require-installed-chrome'),
  }
}

function optionValue(args, name) {
  const index = args.indexOf(name)
  if (index < 0) return null
  const value = args[index + 1]
  return value && !value.startsWith('--') ? value : null
}

async function validateEvidence(value, options) {
  const errors = []

  if (!value || typeof value !== 'object') {
    return ['Evidence root must be an object.']
  }

  if (value.success !== true) errors.push('success must be true.')
  assertString(errors, value.startedAt, 'startedAt')
  assertString(errors, value.finishedAt, 'finishedAt')
  validateTiming(errors, value)
  assertString(errors, value.appUrl, 'appUrl')
  assertString(errors, value.apiBase, 'apiBase')
  assertString(errors, value.pageUrl, 'pageUrl')
  validatePageUrl(errors, value)

  if (value.browserName !== options.expectedBrowserName) {
    errors.push(`browserName must be ${options.expectedBrowserName}.`)
  }

  validateBrowserEnvironment(errors, value.checks?.browserEnvironment, options)
  validateHostEnvironment(errors, value.checks?.hostEnvironment)
  validateRequiredChecks(errors, value.checks)
  validateLocalizedUi(errors, value.checks?.localizedUi)
  validateFirstViewportVisibility(errors, value.checks?.firstViewportVisibility)
  validateResponsiveLayout(errors, value.checks?.responsiveLayout)
  await validateScreenshotEvidence(errors, value, options)
  validateRuntimeHealth(errors, value.checks?.runtimeHealth)
  validateExecutionChecks(errors, value.checks)

  return errors
}

function validateTiming(errors, value) {
  const startedMs = Date.parse(value.startedAt)
  const finishedMs = Date.parse(value.finishedAt)

  if (!Number.isFinite(startedMs)) errors.push('startedAt must be a valid timestamp.')
  if (!Number.isFinite(finishedMs)) errors.push('finishedAt must be a valid timestamp.')
  if (Number.isFinite(startedMs) && Number.isFinite(finishedMs) && finishedMs < startedMs) {
    errors.push('finishedAt must not be earlier than startedAt.')
  }
}

function validatePageUrl(errors, value) {
  const page = parseUrl(value.pageUrl)
  const app = parseUrl(value.appUrl)
  const expectedApiBase = typeof value.apiBase === 'string' ? value.apiBase : null

  if (!page) errors.push('pageUrl must be a valid URL.')
  if (!app) errors.push('appUrl must be a valid URL.')
  if (page && app && page.origin !== app.origin) {
    errors.push('pageUrl origin must match appUrl origin.')
  }
  if (page && expectedApiBase && page.searchParams.get('apiBase') !== expectedApiBase) {
    errors.push('pageUrl apiBase query must match apiBase.')
  }
}

function validateBrowserEnvironment(errors, value, options) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.browserEnvironment is missing.')
    return
  }

  if (value.browserName !== options.expectedBrowserName) {
    errors.push(`checks.browserEnvironment.browserName must be ${options.expectedBrowserName}.`)
  }
  if (value.executablePath !== options.expectedExecutablePath) {
    errors.push(`checks.browserEnvironment.executablePath must be ${options.expectedExecutablePath}.`)
  }
  if (typeof value.userAgent !== 'string' || !/Chrome|Chromium/u.test(value.userAgent)) {
    errors.push('checks.browserEnvironment.userAgent must identify Chrome or Chromium.')
  }
  if (value.getUserMedia !== true) errors.push('checks.browserEnvironment.getUserMedia must be true.')
  if (value.speechRecognition !== true) errors.push('checks.browserEnvironment.speechRecognition must be true.')
  if (value.locationOrigin !== parseUrl(evidence.appUrl)?.origin) {
    errors.push('checks.browserEnvironment.locationOrigin must match appUrl origin.')
  }
  if (!positiveNumber(value.viewport?.innerWidth) || !positiveNumber(value.viewport?.innerHeight)) {
    errors.push('checks.browserEnvironment viewport dimensions must be positive.')
  }

  if (options.requireInstalledChrome) {
    validateInstalledChromeIdentity(errors, value)
  }
}

function validateHostEnvironment(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.hostEnvironment is missing.')
    return
  }

  if (!['win32', 'darwin', 'linux'].includes(value.platform)) {
    errors.push('checks.hostEnvironment.platform must identify a supported desktop OS.')
  }
  if (!['x64', 'arm64'].includes(value.arch)) {
    errors.push('checks.hostEnvironment.arch must identify a supported desktop CPU architecture.')
  }
  if (typeof value.nodeVersion !== 'string' || !/^\d+\.\d+\.\d+$/u.test(value.nodeVersion)) {
    errors.push('checks.hostEnvironment.nodeVersion must be a semantic Node.js version.')
  }
  if (!Number.isInteger(value.nodeMajorVersion) || value.nodeMajorVersion < 20) {
    errors.push('checks.hostEnvironment.nodeMajorVersion must be at least 20.')
  }
  if (typeof value.ci !== 'boolean') {
    errors.push('checks.hostEnvironment.ci must be boolean.')
  }
}

function validateInstalledChromeIdentity(errors, value) {
  if (value.executableFileName !== 'chrome.exe') {
    errors.push('checks.browserEnvironment.executableFileName must be chrome.exe.')
  }
  if (!['program-files', 'program-files-x86', 'local-app-data', 'custom-path'].includes(value.executableSource)) {
    errors.push('checks.browserEnvironment.executableSource must identify the Chrome executable source kind.')
  }
  if (typeof value.executableProductName !== 'string' || !value.executableProductName.includes('Google Chrome')) {
    errors.push('checks.browserEnvironment.executableProductName must identify Google Chrome.')
  }
  if (typeof value.executableCompanyName !== 'string' || !value.executableCompanyName.includes('Google')) {
    errors.push('checks.browserEnvironment.executableCompanyName must identify Google.')
  }
  if (chromeMajorVersion(value.userAgent) !== chromeMajorVersion(value.executableProductVersion)) {
    errors.push('checks.browserEnvironment userAgent and executable product major versions must match.')
  }
}

function validateRequiredChecks(errors, checks) {
  const requiredChecks = [
    'browserEnvironment',
    'localizedUi',
    'firstViewportVisibility',
    'responsiveLayout',
    'scenePromptHandoff',
    'proposeOnly',
    'webConfirmExecute',
    'offlineFallback',
    'externalExecutionSync',
    'screenshotEvidence',
    'runtimeHealth',
  ]

  for (const name of requiredChecks) {
    if (!checks?.[name]) errors.push(`checks.${name} is missing.`)
    if (checks?.[name]?.success === false) errors.push(`checks.${name} must not report failure.`)
  }
}

async function validateScreenshotEvidence(errors, value, options) {
  const screenshotEvidence = value.checks?.screenshotEvidence
  const screenshots = value.screenshots

  if (!Array.isArray(screenshots)) {
    errors.push('screenshots must be an array.')
    return
  }
  if (!screenshotEvidence || typeof screenshotEvidence !== 'object') {
    errors.push('checks.screenshotEvidence is missing.')
    return
  }

  if (screenshotEvidence.count !== 6) errors.push('checks.screenshotEvidence.count must be 6.')
  if (screenshotFilesSignature(screenshotEvidence.expectedFiles) !== EXPECTED_SCREENSHOT_FILES.join('|')) {
    errors.push('checks.screenshotEvidence.expectedFiles must match the required six-step screenshot set.')
  }
  if (screenshotEvidence.uniqueDigestCount !== screenshotEvidence.count) {
    errors.push('checks.screenshotEvidence.uniqueDigestCount must match count.')
  }
  if (screenshots.length !== screenshotEvidence.count) {
    errors.push('screenshots length must match checks.screenshotEvidence.count.')
  }
  if (Array.isArray(screenshotEvidence.files) && screenshotEvidence.files.length !== screenshots.length) {
    errors.push('checks.screenshotEvidence.files length must match screenshots length.')
  }

  const evidenceFilesByPath = new Map((screenshotEvidence.files ?? []).map((entry) => [entry?.path, entry]))
  for (const [index, screenshot] of screenshots.entries()) {
    const expectedFile = EXPECTED_SCREENSHOT_FILES[index]
    if (path.basename(screenshot) !== expectedFile) {
      errors.push(`screenshots[${index}] must be ${expectedFile}.`)
    }
    if (options.expectedScreenshotDir && !screenshot.startsWith(options.expectedScreenshotDir)) {
      errors.push(`screenshots must use ${options.expectedScreenshotDir}: ${screenshot}.`)
    }

    const entry = evidenceFilesByPath.get(screenshot)
    if (!entry) {
      errors.push(`checks.screenshotEvidence.files missing ${screenshot}.`)
      continue
    }

    await validateScreenshotFile(errors, screenshot, entry)
  }
}

async function validateScreenshotFile(errors, screenshot, entry) {
  const absolutePath = path.resolve(repoRoot, screenshot)
  const relativePath = path.relative(repoRoot, absolutePath)
  if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    errors.push(`screenshot path must stay inside repository root: ${screenshot}.`)
    return
  }

  let fileStat
  let buffer
  try {
    fileStat = await stat(absolutePath)
    buffer = await readFile(absolutePath)
  } catch (error) {
    errors.push(`screenshot cannot be read: ${screenshot} (${error?.code ?? error.message ?? error}).`)
    return
  }

  if (!fileStat.isFile()) errors.push(`screenshot is not a file: ${screenshot}.`)
  const metadata = parsePngMetadata(buffer)
  const digest = createHash('sha256').update(buffer).digest('hex').slice(0, 12)

  if (fileStat.size !== entry.bytes) {
    errors.push(`screenshot byte mismatch for ${screenshot} (${fileStat.size} != ${entry.bytes}).`)
  }
  if (digest !== entry.sha256) {
    errors.push(`screenshot sha256 mismatch for ${screenshot} (${digest} != ${entry.sha256}).`)
  }
  if (metadata.width !== entry.width || metadata.height !== entry.height) {
    errors.push(`screenshot dimensions mismatch for ${screenshot}.`)
  }
  if (metadata.imageDataBytes !== entry.imageDataBytes) {
    errors.push(`screenshot image data byte mismatch for ${screenshot}.`)
  }
  if (!positiveNumber(entry.width) || !positiveNumber(entry.height) || !positiveNumber(entry.imageDataBytes)) {
    errors.push(`screenshot metadata must be positive for ${screenshot}.`)
  }
}

function parsePngMetadata(buffer) {
  const signature = buffer.subarray(0, 8).toString('hex')
  if (signature !== '89504e470d0a1a0a') {
    return { width: null, height: null, imageDataBytes: null }
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

  return { width, height, imageDataBytes }
}

function validateRuntimeHealth(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.runtimeHealth is missing.')
    return
  }

  if (value.success !== true) errors.push('checks.runtimeHealth.success must be true.')
  if (value.issueCount !== 0) errors.push('checks.runtimeHealth.issueCount must be 0.')
}

function validateLocalizedUi(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.localizedUi is missing.')
    return
  }

  if (value.title !== EXPECTED_LOCALIZED_UI.title) {
    errors.push(`checks.localizedUi.title must be ${EXPECTED_LOCALIZED_UI.title}.`)
  }
  if (value.runButton !== EXPECTED_LOCALIZED_UI.runButton) {
    errors.push(`checks.localizedUi.runButton must be ${EXPECTED_LOCALIZED_UI.runButton}.`)
  }
  if (!Number.isInteger(value.resetButtonCount) || value.resetButtonCount < EXPECTED_LOCALIZED_UI.minResetButtonCount) {
    errors.push(`checks.localizedUi.resetButtonCount must be at least ${EXPECTED_LOCALIZED_UI.minResetButtonCount}.`)
  }
  validateTextIntegrity(errors, value.textIntegrity)
}

function validateTextIntegrity(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.localizedUi.textIntegrity is missing.')
    return
  }

  if (!Number.isInteger(value.requiredPhraseCount) || value.requiredPhraseCount < MIN_LOCALIZED_PHRASE_COUNT) {
    errors.push(
      `checks.localizedUi.textIntegrity.requiredPhraseCount must be at least ${MIN_LOCALIZED_PHRASE_COUNT}.`,
    )
  }
  if (value.missingPhraseCount !== 0) {
    errors.push('checks.localizedUi.textIntegrity.missingPhraseCount must be 0.')
  }
  if (value.mojibakeCount !== 0) {
    errors.push('checks.localizedUi.textIntegrity.mojibakeCount must be 0.')
  }
}

function validateFirstViewportVisibility(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.firstViewportVisibility is missing.')
    return
  }

  if (typeof value.minVisibleRatio !== 'number' || value.minVisibleRatio < 0.9 || value.minVisibleRatio > 1) {
    errors.push('checks.firstViewportVisibility.minVisibleRatio must be between 0.9 and 1.')
  }
  if (!Array.isArray(value.panels) || value.panels.length !== 5) {
    errors.push('checks.firstViewportVisibility.panels must include the five first-viewport targets.')
    return
  }

  const expectedLabels = ['topbar', 'prompt', 'context', 'scene', 'plan']
  const actualLabels = value.panels.map((panel) => panel?.label)
  if (actualLabels.join('|') !== expectedLabels.join('|')) {
    errors.push(`checks.firstViewportVisibility.panels labels must be ${expectedLabels.join(', ')}.`)
  }

  for (const panel of value.panels) {
    if (panel?.present !== true) errors.push(`checks.firstViewportVisibility.${panel?.label ?? 'unknown'} must be present.`)
    if (!positiveNumber(panel?.width) || !positiveNumber(panel?.height)) {
      errors.push(`checks.firstViewportVisibility.${panel?.label ?? 'unknown'} dimensions must be positive.`)
    }
    if (typeof panel?.top === 'number' && panel.top < 0) {
      errors.push(`checks.firstViewportVisibility.${panel.label} top must be non-negative.`)
    }
    if (typeof panel?.visibleRatio !== 'number' || panel.visibleRatio < 0.9 || panel.visibleRatio > 1) {
      errors.push(`checks.firstViewportVisibility.${panel?.label ?? 'unknown'} visibleRatio must be between 0.9 and 1.`)
    }
  }
}

function validateResponsiveLayout(errors, value) {
  if (!Array.isArray(value) || value.length !== 3) {
    errors.push('checks.responsiveLayout must include mobile, tablet, and desktop results.')
    return
  }

  const expectedLabels = ['mobile', 'tablet', 'desktop']
  const actualLabels = value.map((item) => item?.label)
  if (actualLabels.join('|') !== expectedLabels.join('|')) {
    errors.push(`checks.responsiveLayout labels must be ${expectedLabels.join(', ')}.`)
  }

  for (const item of value) {
    const label = item?.label ?? 'unknown'
    if (!positiveNumber(item?.width) || !positiveNumber(item?.height)) {
      errors.push(`checks.responsiveLayout.${label} viewport dimensions must be positive.`)
    }
    if (item?.overflowX !== 0) errors.push(`checks.responsiveLayout.${label}.overflowX must be 0.`)
    if (Array.isArray(item?.missingSelectors) && item.missingSelectors.length) {
      errors.push(`checks.responsiveLayout.${label}.missingSelectors must be empty.`)
    }
    if (!positiveNumber(item?.panelCount)) errors.push(`checks.responsiveLayout.${label}.panelCount must be positive.`)
    if (!positiveNumber(item?.minPanelWidth) || !positiveNumber(item?.minPanelHeight)) {
      errors.push(`checks.responsiveLayout.${label} min panel dimensions must be positive.`)
    }
    if (Array.isArray(item?.overlappingPanelPairs) && item.overlappingPanelPairs.length) {
      errors.push(`checks.responsiveLayout.${label}.overlappingPanelPairs must be empty.`)
    }
    if (Array.isArray(item?.overflowingButtons) && item.overflowingButtons.length) {
      errors.push(`checks.responsiveLayout.${label}.overflowingButtons must be empty.`)
    }
  }
}

function validateExecutionChecks(errors, checks) {
  if (checks?.scenePromptHandoff?.rawImageRetained !== false) {
    errors.push('checks.scenePromptHandoff.rawImageRetained must be false.')
  }
  if (checks?.scenePromptHandoff?.rawImageEchoed !== false) {
    errors.push('checks.scenePromptHandoff.rawImageEchoed must be false.')
  }
  if (checks?.proposeOnly?.latestExecuted !== false) {
    errors.push('checks.proposeOnly.latestExecuted must be false.')
  }
  if (checks?.webConfirmExecute?.latestSource !== 'web') {
    errors.push('checks.webConfirmExecute.latestSource must be web.')
  }
  if (checks?.offlineFallback?.latestSource !== 'plan') {
    errors.push('checks.offlineFallback.latestSource must be plan.')
  }
  if (checks?.externalExecutionSync?.latestSource !== 'esp32-serial') {
    errors.push('checks.externalExecutionSync.latestSource must be esp32-serial.')
  }
  if (!positiveNumber(checks?.externalExecutionSync?.acceptedActionCount)) {
    errors.push('checks.externalExecutionSync.acceptedActionCount must be positive.')
  }
}

function parseUrl(value) {
  if (typeof value !== 'string' || value.length === 0) return null
  try {
    return new URL(value)
  } catch {
    return null
  }
}

function chromeMajorVersion(value) {
  if (typeof value !== 'string') return null
  const match = value.match(/(?:HeadlessChrome|Chrome|Chromium)\/(\d+)\./u) ?? value.match(/^(\d+)\./u)
  return match ? Number(match[1]) : null
}

function screenshotFilesSignature(value) {
  if (!Array.isArray(value)) return null
  return value.join('|')
}

function positiveNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
}

function assertString(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    errors.push(`${label} must be a non-empty string.`)
  }
}
