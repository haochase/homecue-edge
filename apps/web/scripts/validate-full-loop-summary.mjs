import { createHash } from 'node:crypto'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const summaryFile = process.argv[2] ?? path.join(repoRoot, 'assets', 'demo', 'full-loop-report.json')
const EXPECTED_SCREENSHOT_FILES = [
  '01-control-console.png',
  '02-scene-prompt-handoff.png',
  '03-propose-only.png',
  '04-web-confirmation.png',
  '05-offline-fallback.png',
  '06-external-sync.png',
]
const options = parseOptions(process.argv.slice(3))
const summary = JSON.parse(await readFile(summaryFile, 'utf8'))
const errors = await validateSummary(summary, options)

if (errors.length) {
  console.error(`Full loop summary validation failed: ${summaryFile}`)
  for (const error of errors) {
    console.error(`- ${error}`)
  }
  process.exit(1)
}

console.log(`Full loop summary validation passed: ${summaryFile}`)

function parseOptions(args) {
  return {
    requirePhone: args.includes('--require-phone'),
    requireChrome: args.includes('--require-chrome'),
  }
}

async function validateSummary(value, { requirePhone, requireChrome }) {
  const errors = []

  if (!value || typeof value !== 'object') {
    return ['Summary root must be an object.']
  }

  assertString(errors, value.generatedAt, 'generatedAt')
  assertBoolean(errors, value.success, 'success')
  if (value.success !== true) {
    errors.push('summary success must be true.')
  }
  assertString(errors, value.runId, 'runId')
  assertString(errors, value.appUrl, 'appUrl')
  assertString(errors, value.apiBase, 'apiBase')
  assertArray(errors, value.evidence?.files, 'evidence.files')
  assertArray(errors, value.evidence?.validationErrors, 'evidence.validationErrors')

  if (Array.isArray(value.evidence?.validationErrors) && value.evidence.validationErrors.length) {
    errors.push(`summary contains validation errors: ${value.evidence.validationErrors.join('; ')}`)
  }

  validateDesktopLoop(errors, value.loops?.desktop, 'loops.desktop', { required: true, expectedRunId: value.runId })
  validateDesktopLoop(errors, value.loops?.windowsChrome, 'loops.windowsChrome', {
    required: requireChrome,
    expectedRunId: value.runId,
  })
  validatePhoneLoop(errors, value.loops?.phone, 'loops.phone', { required: requirePhone, expectedRunId: value.runId })
  validateBrowserParity(errors, value.browserParity, { required: requireChrome })
  await validateEvidenceManifest(errors, value.evidence?.files, { requirePhone, requireChrome })
  await validateRawEvidence(errors, value, { requirePhone, requireChrome })

  return errors
}

function validateDesktopLoop(errors, loop, label, { required, expectedRunId }) {
  if (!loop || typeof loop !== 'object') {
    if (required) errors.push(`${label} is missing.`)
    return
  }

  if (!loop.run) {
    if (required) errors.push(`${label}.run must be true.`)
    return
  }

  if (loop.success !== true) errors.push(`${label}.success must be true.`)
  if (loop.runId !== expectedRunId) errors.push(`${label}.runId does not match summary runId.`)
  assertString(errors, loop.title, `${label}.title`)
  assertString(errors, loop.browserName, `${label}.browserName`)
  assertString(errors, loop.pageUrl, `${label}.pageUrl`)

  validateTextIntegrity(errors, loop.textIntegrity, `${label}.textIntegrity`)
  validateFirstViewportVisibility(errors, loop.firstViewportVisibility, `${label}.firstViewportVisibility`)
  validateRuntimeHealth(errors, loop.runtimeHealth, `${label}.runtimeHealth`)
  validateResponsiveLayout(errors, loop.responsiveLayout, `${label}.responsiveLayout`)
  validateScreenshotEvidence(errors, loop.screenshotEvidence, `${label}.screenshotEvidence`)

  if (loop.scenePromptHandoff?.ready !== true) errors.push(`${label}.scenePromptHandoff.ready must be true.`)
  if (loop.scenePromptHandoff?.rawImageRetained !== false) {
    errors.push(`${label}.scenePromptHandoff.rawImageRetained must be false.`)
  }
  if (loop.scenePromptHandoff?.rawImageEchoed !== false) {
    errors.push(`${label}.scenePromptHandoff.rawImageEchoed must be false.`)
  }

  if (loop.proposeOnly?.latestExecuted !== false) errors.push(`${label}.proposeOnly.latestExecuted must be false.`)
  if (loop.webConfirmExecute?.latestSource !== 'web') errors.push(`${label}.webConfirmExecute.latestSource must be web.`)
  if (loop.offlineFallback?.latestSource !== 'plan') errors.push(`${label}.offlineFallback.latestSource must be plan.`)
  if (loop.externalExecutionSync?.latestSource !== 'esp32-serial') {
    errors.push(`${label}.externalExecutionSync.latestSource must be esp32-serial.`)
  }
  if (!positiveNumber(loop.externalExecutionSync?.acceptedActionCount)) {
    errors.push(`${label}.externalExecutionSync.acceptedActionCount must be positive.`)
  }
}

function validatePhoneLoop(errors, loop, label, { required, expectedRunId }) {
  if (!loop || typeof loop !== 'object') {
    if (required) errors.push(`${label} is missing.`)
    return
  }

  if (!loop.run) {
    if (required) errors.push(`${label}.run must be true.`)
    return
  }

  if (loop.success !== true) errors.push(`${label}.success must be true.`)
  if (loop.runId !== expectedRunId) errors.push(`${label}.runId does not match summary runId.`)
  assertString(errors, loop.title, `${label}.title`)
  assertString(errors, loop.pageUrl, `${label}.pageUrl`)
  validateRuntimeHealth(errors, loop.runtimeHealth, `${label}.runtimeHealth`)

  if (loop.frontCamera?.ready !== true) errors.push(`${label}.frontCamera.ready must be true.`)
  if (loop.frontCamera?.facingMode !== 'user') errors.push(`${label}.frontCamera.facingMode must be user.`)
  if (!positiveNumber(loop.frontCamera?.width) || !positiveNumber(loop.frontCamera?.height)) {
    errors.push(`${label}.frontCamera dimensions must be positive.`)
  }
  if (loop.speechInput?.available !== true) errors.push(`${label}.speechInput.available must be true.`)
  if (loop.scene?.rawImageNotRetained !== true) errors.push(`${label}.scene.rawImageNotRetained must be true.`)
  if (loop.scene?.rawImageRetained !== false) errors.push(`${label}.scene.rawImageRetained must be false.`)
  if (loop.scenePromptHandoff?.ready !== true) errors.push(`${label}.scenePromptHandoff.ready must be true.`)
  if (loop.externalExecution?.latestSource !== 'esp32-serial') {
    errors.push(`${label}.externalExecution.latestSource must be esp32-serial.`)
  }
  if (!positiveNumber(loop.externalExecution?.acceptedActionCount)) {
    errors.push(`${label}.externalExecution.acceptedActionCount must be positive.`)
  }
}

function validateBrowserParity(errors, parity, { required }) {
  if (!parity || typeof parity !== 'object') {
    if (required) errors.push('browserParity is missing.')
    return
  }

  if (required) {
    if (parity.checked !== true) errors.push('browserParity.checked must be true.')
    if (parity.success !== true) errors.push('browserParity.success must be true.')
  }
  assertArray(errors, parity.errors, 'browserParity.errors')
  if (Array.isArray(parity.errors) && parity.errors.length) {
    errors.push(`browserParity errors must be empty: ${parity.errors.join('; ')}`)
  }
}

async function validateEvidenceManifest(errors, files, { requirePhone, requireChrome }) {
  if (!Array.isArray(files)) return

  const presentFiles = files.filter((entry) => entry?.present)
  if (!presentFiles.length) errors.push('evidence.files must contain present entries.')

  for (const entry of presentFiles) {
    assertString(errors, entry.label, 'evidence.files[].label')
    assertString(errors, entry.file, `evidence entry ${entry.label ?? 'unknown'} file`)
    if (!positiveNumber(entry.bytes)) errors.push(`evidence entry ${entry.file ?? entry.label} bytes must be positive.`)
    if (typeof entry.sha256 !== 'string' || !/^[a-f0-9]{12}$/u.test(entry.sha256)) {
      errors.push(`evidence entry ${entry.file ?? entry.label} sha256 must be a 12-char hex digest.`)
    }
    await validateManifestFile(errors, entry)
  }

  requireManifestLabel(errors, files, 'Desktop JSON')
  if (requireChrome) requireManifestLabel(errors, files, 'Windows Chrome JSON')
  if (requirePhone) requireManifestLabel(errors, files, 'Phone JSON')
}

async function validateManifestFile(errors, entry) {
  if (typeof entry.file !== 'string' || entry.file.length === 0) return

  const absolutePath = path.resolve(repoRoot, entry.file)
  const relativePath = path.relative(repoRoot, absolutePath)
  if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    errors.push(`evidence entry ${entry.file} must stay inside the repository root.`)
    return
  }

  let fileStat
  let buffer
  try {
    fileStat = await stat(absolutePath)
    buffer = await readFile(absolutePath)
  } catch (error) {
    errors.push(`evidence entry ${entry.file} cannot be read: ${error?.code ?? error.message ?? error}`)
    return
  }

  if (!fileStat.isFile()) {
    errors.push(`evidence entry ${entry.file} is not a file.`)
    return
  }

  if (fileStat.size !== entry.bytes) {
    errors.push(`evidence entry ${entry.file} byte mismatch (${fileStat.size} != ${entry.bytes}).`)
  }

  const digest = createHash('sha256').update(buffer).digest('hex').slice(0, 12)
  if (digest !== entry.sha256) {
    errors.push(`evidence entry ${entry.file} sha256 mismatch (${digest} != ${entry.sha256}).`)
  }
}

function requireManifestLabel(errors, files, label) {
  const entry = files.find((item) => item?.label === label)
  if (!entry?.present) {
    errors.push(`evidence manifest missing present ${label}.`)
  }
}

async function validateRawEvidence(errors, summary, { requirePhone, requireChrome }) {
  const manifest = manifestByLabel(summary.evidence?.files)
  await validateRawDesktopEvidence(errors, summary.loops?.desktop, manifest.get('Desktop JSON'), 'loops.desktop')

  if (requireChrome || summary.loops?.windowsChrome?.run) {
    await validateRawDesktopEvidence(errors, summary.loops?.windowsChrome, manifest.get('Windows Chrome JSON'), 'loops.windowsChrome')
  }

  if (requirePhone || summary.loops?.phone?.run) {
    await validateRawPhoneEvidence(errors, summary.loops?.phone, manifest.get('Phone JSON'), 'loops.phone')
  }
}

function manifestByLabel(files) {
  const map = new Map()
  if (!Array.isArray(files)) return map
  for (const entry of files) {
    if (entry?.present && typeof entry.label === 'string') {
      map.set(entry.label, entry)
    }
  }
  return map
}

async function validateRawDesktopEvidence(errors, loop, manifestEntry, label) {
  if (!manifestEntry?.present || !loop?.run) return

  const raw = await readManifestJson(errors, manifestEntry, label)
  if (!raw) return

  compareValue(errors, raw.success === true, loop.success, `${label}.success raw evidence`)
  compareValue(errors, raw.runId ?? null, loop.runId ?? null, `${label}.runId raw evidence`)
  compareValue(errors, raw.browserName ?? null, loop.browserName ?? null, `${label}.browserName raw evidence`)
  compareValue(errors, raw.pageUrl ?? null, loop.pageUrl ?? null, `${label}.pageUrl raw evidence`)

  const checks = raw.checks ?? {}
  compareValue(errors, checks.localizedUi?.title ?? null, loop.title ?? null, `${label}.title raw evidence`)
  compareValue(
    errors,
    checks.localizedUi?.textIntegrity?.missingPhraseCount ?? null,
    loop.textIntegrity?.missingPhraseCount ?? null,
    `${label}.textIntegrity.missingPhraseCount raw evidence`,
  )
  compareValue(
    errors,
    checks.localizedUi?.textIntegrity?.mojibakeCount ?? null,
    loop.textIntegrity?.mojibakeCount ?? null,
    `${label}.textIntegrity.mojibakeCount raw evidence`,
  )
  compareValue(
    errors,
    checks.firstViewportVisibility?.minVisibleRatio ?? null,
    loop.firstViewportVisibility?.minVisibleRatio ?? null,
    `${label}.firstViewportVisibility.minVisibleRatio raw evidence`,
  )
  compareValue(
    errors,
    checks.firstViewportVisibility?.panels?.length ?? null,
    loop.firstViewportVisibility?.panelCount ?? null,
    `${label}.firstViewportVisibility.panelCount raw evidence`,
  )
  compareValue(
    errors,
    responsiveLayoutSignature(checks.responsiveLayout),
    responsiveLayoutSignature(loop.responsiveLayout),
    `${label}.responsiveLayout raw evidence`,
  )
  compareValue(
    errors,
    checks.runtimeHealth?.issueCount ?? null,
    loop.runtimeHealth?.issueCount ?? null,
    `${label}.runtimeHealth.issueCount raw evidence`,
  )
  compareValue(
    errors,
    checks.screenshotEvidence?.count ?? null,
    loop.screenshotEvidence?.count ?? null,
    `${label}.screenshotEvidence.count raw evidence`,
  )
  compareValue(
    errors,
    checks.screenshotEvidence?.uniqueDigestCount ?? null,
    loop.screenshotEvidence?.uniqueDigestCount ?? null,
    `${label}.screenshotEvidence.uniqueDigestCount raw evidence`,
  )
  compareValue(
    errors,
    screenshotFilesSignature(checks.screenshotEvidence?.expectedFiles),
    screenshotFilesSignature(loop.screenshotEvidence?.expectedFiles),
    `${label}.screenshotEvidence.expectedFiles raw evidence`,
  )
  compareValue(
    errors,
    raw.screenshots?.length ?? null,
    loop.screenshotEvidence?.count ?? null,
    `${label}.screenshots length raw evidence`,
  )
  compareValue(
    errors,
    checks.scenePromptHandoff?.rawImageRetained ?? null,
    loop.scenePromptHandoff?.rawImageRetained ?? null,
    `${label}.rawImageRetained raw evidence`,
  )
  compareValue(
    errors,
    checks.scenePromptHandoff?.rawImageEchoed ?? null,
    loop.scenePromptHandoff?.rawImageEchoed ?? null,
    `${label}.rawImageEchoed raw evidence`,
  )
  compareValue(
    errors,
    checks.proposeOnly?.latestExecuted ?? null,
    loop.proposeOnly?.latestExecuted ?? null,
    `${label}.proposeOnly.latestExecuted raw evidence`,
  )
  compareValue(
    errors,
    checks.webConfirmExecute?.latestSource ?? null,
    loop.webConfirmExecute?.latestSource ?? null,
    `${label}.webConfirmExecute.latestSource raw evidence`,
  )
  compareValue(
    errors,
    checks.offlineFallback?.latestSource ?? null,
    loop.offlineFallback?.latestSource ?? null,
    `${label}.offlineFallback.latestSource raw evidence`,
  )
  compareValue(
    errors,
    checks.externalExecutionSync?.latestSource ?? null,
    loop.externalExecutionSync?.latestSource ?? null,
    `${label}.externalExecutionSync.latestSource raw evidence`,
  )
  compareValue(
    errors,
    checks.externalExecutionSync?.acceptedActionCount ?? null,
    loop.externalExecutionSync?.acceptedActionCount ?? null,
    `${label}.externalExecutionSync.acceptedActionCount raw evidence`,
  )
}

async function validateRawPhoneEvidence(errors, loop, manifestEntry, label) {
  if (!manifestEntry?.present || !loop?.run) return

  const raw = await readManifestJson(errors, manifestEntry, label)
  if (!raw) return

  compareValue(errors, raw.success === true, loop.success, `${label}.success raw evidence`)
  compareValue(errors, raw.runId ?? null, loop.runId ?? null, `${label}.runId raw evidence`)
  compareValue(errors, raw.pageUrl ?? null, loop.pageUrl ?? null, `${label}.pageUrl raw evidence`)

  const checks = raw.checks ?? {}
  compareValue(errors, checks.localizedUi?.title ?? null, loop.title ?? null, `${label}.title raw evidence`)
  compareValue(
    errors,
    checks.runtimeHealth?.issueCount ?? null,
    loop.runtimeHealth?.issueCount ?? null,
    `${label}.runtimeHealth.issueCount raw evidence`,
  )
  compareValue(errors, checks.frontCamera?.ready ?? null, loop.frontCamera?.ready ?? null, `${label}.frontCamera.ready raw evidence`)
  compareValue(
    errors,
    checks.frontCamera?.facingMode ?? null,
    loop.frontCamera?.facingMode ?? null,
    `${label}.frontCamera.facingMode raw evidence`,
  )
  compareValue(errors, checks.frontCamera?.width ?? null, loop.frontCamera?.width ?? null, `${label}.frontCamera.width raw evidence`)
  compareValue(errors, checks.frontCamera?.height ?? null, loop.frontCamera?.height ?? null, `${label}.frontCamera.height raw evidence`)
  compareValue(
    errors,
    Boolean(checks.speechInput?.support?.SpeechRecognition || checks.speechInput?.support?.webkitSpeechRecognition),
    loop.speechInput?.available ?? null,
    `${label}.speechInput.available raw evidence`,
  )
  compareValue(
    errors,
    checks.scene?.rawImageRetained ?? null,
    loop.scene?.rawImageRetained ?? null,
    `${label}.scene.rawImageRetained raw evidence`,
  )
  compareValue(
    errors,
    checks.scene?.rawImageNotRetained ?? null,
    loop.scene?.rawImageNotRetained ?? null,
    `${label}.scene.rawImageNotRetained raw evidence`,
  )
  compareValue(
    errors,
    checks.externalExecution?.latestSource ?? null,
    loop.externalExecution?.latestSource ?? null,
    `${label}.externalExecution.latestSource raw evidence`,
  )
  compareValue(
    errors,
    checks.externalExecution?.acceptedActionCount ?? null,
    loop.externalExecution?.acceptedActionCount ?? null,
    `${label}.externalExecution.acceptedActionCount raw evidence`,
  )
}

async function readManifestJson(errors, manifestEntry, label) {
  try {
    const absolutePath = path.resolve(repoRoot, manifestEntry.file)
    return JSON.parse(await readFile(absolutePath, 'utf8'))
  } catch (error) {
    errors.push(`${label} raw evidence JSON cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

function compareValue(errors, left, right, label) {
  if (left !== right) {
    errors.push(`${label} mismatch (${left ?? 'missing'} != ${right ?? 'missing'}).`)
  }
}

function responsiveLayoutSignature(value) {
  if (!Array.isArray(value)) return null
  return value
    .map((item) =>
      [
        item.label ?? null,
        item.width ?? null,
        item.height ?? null,
        item.overflowX ?? null,
        item.overflowingButtonCount ?? item.overflowingButtons?.length ?? null,
        item.overlappingPanelPairCount ?? item.overlappingPanelPairs?.length ?? null,
        item.panelCount ?? null,
        item.minPanelWidth ?? null,
        item.minPanelHeight ?? null,
      ].join(':'),
    )
    .join('|')
}

function screenshotFilesSignature(value) {
  if (!Array.isArray(value)) return null
  return value.join('|')
}

function validateRuntimeHealth(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (value.success !== true) errors.push(`${label}.success must be true.`)
  if (value.issueCount !== 0) errors.push(`${label}.issueCount must be 0.`)
}

function validateTextIntegrity(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (!positiveNumber(value.requiredPhraseCount)) errors.push(`${label}.requiredPhraseCount must be positive.`)
  if (value.missingPhraseCount !== 0) errors.push(`${label}.missingPhraseCount must be 0.`)
  if (value.mojibakeCount !== 0) errors.push(`${label}.mojibakeCount must be 0.`)
}

function validateFirstViewportVisibility(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (typeof value.minVisibleRatio !== 'number' || value.minVisibleRatio < 0.9 || value.minVisibleRatio > 1) {
    errors.push(`${label}.minVisibleRatio must be between 0.9 and 1.`)
  }
  if (value.panelCount !== 5) errors.push(`${label}.panelCount must be 5.`)
  if (value.hiddenPanelCount !== 0) errors.push(`${label}.hiddenPanelCount must be 0.`)
}

function validateResponsiveLayout(errors, value, label) {
  if (!Array.isArray(value) || value.length < 3) {
    errors.push(`${label} must include mobile, tablet, and desktop results.`)
    return
  }

  for (const item of value) {
    if (item.overflowX !== 0) errors.push(`${label}.${item.label ?? 'unknown'}.overflowX must be 0.`)
    if (item.overflowingButtonCount !== 0) {
      errors.push(`${label}.${item.label ?? 'unknown'}.overflowingButtonCount must be 0.`)
    }
    if (item.overlappingPanelPairCount !== 0) {
      errors.push(`${label}.${item.label ?? 'unknown'}.overlappingPanelPairCount must be 0.`)
    }
    if (!positiveNumber(item.panelCount)) {
      errors.push(`${label}.${item.label ?? 'unknown'}.panelCount must be positive.`)
    }
    if (!positiveNumber(item.minPanelWidth) || !positiveNumber(item.minPanelHeight)) {
      errors.push(`${label}.${item.label ?? 'unknown'} panel dimensions must be positive.`)
    }
  }
}

function validateScreenshotEvidence(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (value.success !== true) errors.push(`${label}.success must be true.`)
  if (value.count !== 6) errors.push(`${label}.count must be 6.`)
  if (value.uniqueDigestCount !== value.count) {
    errors.push(`${label}.uniqueDigestCount must match count.`)
  }
  if (screenshotFilesSignature(value.expectedFiles) !== EXPECTED_SCREENSHOT_FILES.join('|')) {
    errors.push(`${label}.expectedFiles must match the required six-step screenshot set.`)
  }
  if (!positiveNumber(value.minWidth) || !positiveNumber(value.minHeight)) {
    errors.push(`${label} min dimensions must be positive.`)
  }
  if (!positiveNumber(value.minBytes) || !positiveNumber(value.minImageDataBytes)) {
    errors.push(`${label} byte counts must be positive.`)
  }
}

function assertString(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    errors.push(`${label} must be a non-empty string.`)
  }
}

function assertBoolean(errors, value, label) {
  if (typeof value !== 'boolean') {
    errors.push(`${label} must be a boolean.`)
  }
}

function assertArray(errors, value, label) {
  if (!Array.isArray(value)) {
    errors.push(`${label} must be an array.`)
  }
}

function positiveNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
}
