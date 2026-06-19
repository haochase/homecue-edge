import { createHash } from 'node:crypto'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parityErrorsSignature, recomputeBrowserParity } from './summary-parity.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const defaultSummaryFile = path.join(repoRoot, 'assets', 'demo', 'full-loop-report.json')
const { summaryFile, optionArgs } = parseCliArgs(process.argv.slice(2), defaultSummaryFile)
const EXPECTED_SCREENSHOT_FILES = [
  '01-control-console.png',
  '02-scene-prompt-handoff.png',
  '03-propose-only.png',
  '04-web-confirmation.png',
  '05-offline-fallback.png',
  '06-external-sync.png',
]
const MIN_LOCALIZED_PHRASE_COUNT = 7
const options = parseOptions(optionArgs)
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

function parseCliArgs(args, defaultFile) {
  const [firstArg, ...remainingArgs] = args
  if (firstArg && !firstArg.startsWith('--')) {
    return { summaryFile: firstArg, optionArgs: remainingArgs }
  }

  return { summaryFile: defaultFile, optionArgs: args }
}

function parseOptions(args) {
  return {
    requirePhone: args.includes('--require-phone'),
    requireChrome: args.includes('--require-chrome'),
    requireDesktop: !args.includes('--allow-skip-desktop'),
  }
}

async function validateSummary(value, { requirePhone, requireChrome, requireDesktop }) {
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
  validateDevEnvPreflight(errors, value.environment?.preflight, 'environment.preflight', {
    generatedAt: value.generatedAt,
    requirePhone: requirePhone || value.loops?.phone?.run === true,
  })
  validatePreflightBeforeLoops(errors, value)
  assertArray(errors, value.evidence?.files, 'evidence.files')
  assertArray(errors, value.evidence?.validationErrors, 'evidence.validationErrors')

  if (Array.isArray(value.evidence?.validationErrors) && value.evidence.validationErrors.length) {
    errors.push(`summary contains validation errors: ${value.evidence.validationErrors.join('; ')}`)
  }

  validateDesktopLoop(errors, value.loops?.desktop, 'loops.desktop', {
    required: requireDesktop,
    expectedRunId: value.runId,
    generatedAt: value.generatedAt,
    appUrl: value.appUrl,
    apiBase: value.apiBase,
    expectedBrowserName: 'playwright-chromium',
    expectedExecutablePath: 'bundled',
  })
  validateDesktopLoop(errors, value.loops?.windowsChrome, 'loops.windowsChrome', {
    required: requireChrome,
    expectedRunId: value.runId,
    generatedAt: value.generatedAt,
    appUrl: value.appUrl,
    apiBase: value.apiBase,
    expectedBrowserName: 'windows-chrome',
    expectedExecutablePath: 'custom',
  })
  validatePhoneLoop(errors, value.loops?.phone, 'loops.phone', {
    required: requirePhone,
    expectedRunId: value.runId,
    generatedAt: value.generatedAt,
    appUrl: value.appUrl,
    apiBase: value.apiBase,
  })
  validateBrowserParity(errors, value.browserParity, { required: requireChrome && requireDesktop })
  validateBrowserParityAgainstLoops(errors, value, { required: requireChrome && requireDesktop })
  await validateEvidenceManifest(errors, value.evidence?.files, {
    requireDesktop,
    requirePhone,
    requireChrome,
    requireDevEnv: value.environment?.preflight?.run === true,
  })
  await validateRawEvidence(errors, value, { requireDesktop, requirePhone, requireChrome })

  return errors
}

function validateDesktopLoop(
  errors,
  loop,
  label,
  { required, expectedRunId, generatedAt, appUrl, apiBase, expectedBrowserName, expectedExecutablePath },
) {
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
  validateDesktopLocalizedUi(errors, loop.localizedUi, `${label}.localizedUi`, {
    title: loop.title,
    textIntegrity: loop.textIntegrity,
  })
  validateLoopTiming(errors, loop, label, generatedAt)
  validateLoopUrls(errors, loop, label, { appUrl, apiBase })

  if (expectedBrowserName && loop.browserName !== expectedBrowserName) {
    errors.push(`${label}.browserName must be ${expectedBrowserName}.`)
  }

  validateBrowserEnvironment(errors, loop.browserEnvironment, `${label}.browserEnvironment`, {
    expectedBrowserName,
    expectedExecutablePath,
    expectedInstalledChromeIdentity: expectedBrowserName === 'windows-chrome',
  })
  validateHostEnvironment(errors, loop.hostEnvironment, `${label}.hostEnvironment`)
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

function validatePhoneLoop(errors, loop, label, { required, expectedRunId, generatedAt, appUrl, apiBase }) {
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
  validateLoopTiming(errors, loop, label, generatedAt)
  validateLoopUrls(errors, loop, label, { appUrl, apiBase })
  validateRuntimeHealth(errors, loop.runtimeHealth, `${label}.runtimeHealth`)
  validateTextIntegrity(errors, loop.textIntegrity, `${label}.textIntegrity`)

  if (loop.frontCamera?.ready !== true) errors.push(`${label}.frontCamera.ready must be true.`)
  if (loop.frontCamera?.facingMode !== 'user') errors.push(`${label}.frontCamera.facingMode must be user.`)
  if (!positiveNumber(loop.frontCamera?.width) || !positiveNumber(loop.frontCamera?.height)) {
    errors.push(`${label}.frontCamera dimensions must be positive.`)
  }
  if (loop.frontCamera?.mirrored !== true) errors.push(`${label}.frontCamera.mirrored must be true.`)
  if (loop.frontCamera?.objectFit !== 'cover') errors.push(`${label}.frontCamera.objectFit must be cover.`)
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

function validateBrowserParityAgainstLoops(errors, summary, { required }) {
  if (!required) return

  const expected = recomputeBrowserParity(summary.loops?.desktop, summary.loops?.windowsChrome)
  const actual = summary.browserParity ?? {}
  if (actual.checked !== expected.checked) {
    errors.push(`browserParity.checked mismatch (${expected.checked} != ${actual.checked ?? 'missing'}).`)
  }
  if (actual.success !== expected.success) {
    errors.push(`browserParity.success mismatch (${expected.success} != ${actual.success ?? 'missing'}).`)
  }
  if (parityErrorsSignature(actual.errors) !== parityErrorsSignature(expected.errors)) {
    errors.push(
      `browserParity.errors mismatch (${parityErrorsSignature(expected.errors)} != ${parityErrorsSignature(
        actual.errors,
      )}).`,
    )
  }
}

function validateDesktopLocalizedUi(errors, value, label, { title, textIntegrity }) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  compareValue(errors, value.title ?? null, title ?? null, `${label}.title legacy field`)
  if (value.runButton !== '\u751f\u6210\u8ba1\u5212') errors.push(`${label}.runButton must be \u751f\u6210\u8ba1\u5212.`)
  if (!Number.isInteger(value.resetButtonCount) || value.resetButtonCount < 1) {
    errors.push(`${label}.resetButtonCount must be at least 1.`)
  }
  compareValue(
    errors,
    value.textIntegrity?.missingPhraseCount ?? null,
    textIntegrity?.missingPhraseCount ?? null,
    `${label}.textIntegrity.missingPhraseCount legacy field`,
  )
  compareValue(
    errors,
    value.textIntegrity?.mojibakeCount ?? null,
    textIntegrity?.mojibakeCount ?? null,
    `${label}.textIntegrity.mojibakeCount legacy field`,
  )
  validateTextIntegrity(errors, value.textIntegrity, `${label}.textIntegrity`)
}

async function validateEvidenceManifest(errors, files, { requireDesktop, requirePhone, requireChrome, requireDevEnv }) {
  if (!Array.isArray(files)) return

  const presentFiles = files.filter((entry) => entry?.present)
  if (!presentFiles.length) errors.push('evidence.files must contain present entries.')

  validateUniquePresentManifestFiles(errors, presentFiles)
  validateUniqueManifestJsonLabels(errors, files, [
    'Desktop JSON',
    'Windows Chrome JSON',
    'Phone JSON',
    'Dev Environment JSON',
  ])

  for (const entry of presentFiles) {
    assertString(errors, entry.label, 'evidence.files[].label')
    assertString(errors, entry.file, `evidence entry ${entry.label ?? 'unknown'} file`)
    if (!positiveNumber(entry.bytes)) errors.push(`evidence entry ${entry.file ?? entry.label} bytes must be positive.`)
    if (typeof entry.sha256 !== 'string' || !/^[a-f0-9]{12}$/u.test(entry.sha256)) {
      errors.push(`evidence entry ${entry.file ?? entry.label} sha256 must be a 12-char hex digest.`)
    }
    await validateManifestFile(errors, entry)
  }

  if (requireDesktop) {
    requireManifestLabel(errors, files, 'Desktop JSON')
  }
  if (requireDevEnv) {
    requireManifestLabel(errors, files, 'Dev Environment JSON')
  } else {
    forbidManifestLabel(errors, files, 'Dev Environment JSON')
  }
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

function validateUniquePresentManifestFiles(errors, files) {
  const labelsByFile = new Map()

  for (const entry of files) {
    if (typeof entry?.file !== 'string') continue

    const labels = labelsByFile.get(entry.file) ?? []
    labels.push(entry.label ?? 'unknown')
    labelsByFile.set(entry.file, labels)
  }

  for (const [file, labels] of labelsByFile) {
    if (labels.length > 1) {
      errors.push(`evidence manifest file ${file} appears ${labels.length} times (${labels.join(', ')}).`)
    }
  }
}

function validateUniqueManifestJsonLabels(errors, files, labels) {
  for (const label of labels) {
    const entries = files.filter((entry) => entry?.present && entry.label === label)
    if (entries.length > 1) {
      errors.push(`evidence manifest label ${label} appears ${entries.length} times.`)
    }
  }
}

function requireManifestLabel(errors, files, label) {
  const entry = files.find((item) => item?.present && item.label === label)
  if (!entry) {
    errors.push(`evidence manifest missing present ${label}.`)
  }
}

function forbidManifestLabel(errors, files, label) {
  const entry = files.find((item) => item?.present && item.label === label)
  if (entry) {
    errors.push(`evidence manifest must not include present ${label} when preflight did not run.`)
  }
}

async function validateRawEvidence(errors, summary, { requireDesktop, requirePhone, requireChrome }) {
  const manifest = manifestByLabel(summary.evidence?.files)
  const screenshots = manifestByLabel(summary.evidence?.files, 'Screenshot')
  const rawDesktop = requireDesktop
    ? await validateRawDesktopEvidence(
        errors,
        summary.loops?.desktop,
        manifest.get('Desktop JSON'),
        screenshots,
        'loops.desktop',
        {
          appUrl: summary.appUrl,
          apiBase: summary.apiBase,
          expectedManifestLabel: 'Desktop JSON',
          expectedBrowserName: 'playwright-chromium',
          expectedExecutablePath: 'bundled',
        },
      )
    : null

  let rawChrome = null
  if (requireChrome || summary.loops?.windowsChrome?.run) {
    rawChrome = await validateRawDesktopEvidence(
      errors,
      summary.loops?.windowsChrome,
      manifest.get('Windows Chrome JSON'),
      screenshots,
      'loops.windowsChrome',
      {
        appUrl: summary.appUrl,
        apiBase: summary.apiBase,
        expectedManifestLabel: 'Windows Chrome JSON',
        expectedBrowserName: 'windows-chrome',
        expectedExecutablePath: 'custom',
      },
    )
  }

  if (requireDesktop && (requireChrome || summary.loops?.windowsChrome?.run)) {
    validateIndependentBrowserScreenshots(errors, rawDesktop, rawChrome)
  }

  if (requirePhone || summary.loops?.phone?.run) {
    await validateRawPhoneEvidence(errors, summary.loops?.phone, manifest.get('Phone JSON'), 'loops.phone', {
      appUrl: summary.appUrl,
      apiBase: summary.apiBase,
    })
  }

  if (summary.environment?.preflight?.run === true) {
    await validateRawDevEnvEvidence(
      errors,
      summary.environment?.preflight,
      manifest.get('Dev Environment JSON'),
      'environment.preflight',
    )
  }
}

function manifestByLabel(files, labelFilter = null) {
  const map = new Map()
  if (!Array.isArray(files)) return labelFilter ? [] : map

  if (labelFilter) {
    return files.filter((entry) => entry?.present && entry.label === labelFilter && typeof entry.file === 'string')
  }

  for (const entry of files) {
    if (entry?.present && typeof entry.label === 'string') {
      map.set(entry.label, entry)
    }
  }
  return map
}

async function validateRawDesktopEvidence(
  errors,
  loop,
  manifestEntry,
  screenshotEntries,
  label,
  { appUrl, apiBase, expectedManifestLabel, expectedBrowserName, expectedExecutablePath },
) {
  if (!manifestEntry?.present || !loop?.run) return null

  const raw = await readManifestJson(errors, manifestEntry, label)
  if (!raw) return null

  validateRawBrowserIdentity(errors, raw, manifestEntry, label, {
    expectedManifestLabel,
    expectedBrowserName,
    expectedExecutablePath,
  })

  compareValue(errors, raw.success === true, loop.success, `${label}.success raw evidence`)
  compareValue(errors, raw.runId ?? null, loop.runId ?? null, `${label}.runId raw evidence`)
  compareValue(errors, raw.appUrl ?? null, appUrl ?? null, `${label}.appUrl raw evidence`)
  compareValue(errors, raw.apiBase ?? null, apiBase ?? null, `${label}.apiBase raw evidence`)
  compareValue(errors, raw.startedAt ?? null, loop.startedAt ?? null, `${label}.startedAt raw evidence`)
  compareValue(errors, raw.finishedAt ?? null, loop.finishedAt ?? null, `${label}.finishedAt raw evidence`)
  compareValue(errors, raw.browserName ?? null, loop.browserName ?? null, `${label}.browserName raw evidence`)
  compareValue(errors, raw.pageUrl ?? null, loop.pageUrl ?? null, `${label}.pageUrl raw evidence`)

  const checks = raw.checks ?? {}
  compareValue(
    errors,
    hostEnvironmentSignature(checks.hostEnvironment),
    hostEnvironmentSignature(loop.hostEnvironment),
    `${label}.hostEnvironment raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.browserName ?? null,
    loop.browserEnvironment?.browserName ?? null,
    `${label}.browserEnvironment.browserName raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.executablePath ?? null,
    loop.browserEnvironment?.executablePath ?? null,
    `${label}.browserEnvironment.executablePath raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.userAgent ?? null,
    loop.browserEnvironment?.userAgent ?? null,
    `${label}.browserEnvironment.userAgent raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.language ?? null,
    loop.browserEnvironment?.language ?? null,
    `${label}.browserEnvironment.language raw evidence`,
  )
  compareValue(
    errors,
    browserViewportSignature(checks.browserEnvironment?.viewport),
    browserViewportSignature(loop.browserEnvironment?.viewport),
    `${label}.browserEnvironment.viewport raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.headed ?? null,
    loop.browserEnvironment?.headed ?? null,
    `${label}.browserEnvironment.headed raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.channel ?? null,
    loop.browserEnvironment?.channel ?? null,
    `${label}.browserEnvironment.channel raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.executableFileName ?? null,
    loop.browserEnvironment?.executableFileName ?? null,
    `${label}.browserEnvironment.executableFileName raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.executableSource ?? null,
    loop.browserEnvironment?.executableSource ?? null,
    `${label}.browserEnvironment.executableSource raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.executableProductName ?? null,
    loop.browserEnvironment?.executableProductName ?? null,
    `${label}.browserEnvironment.executableProductName raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.executableCompanyName ?? null,
    loop.browserEnvironment?.executableCompanyName ?? null,
    `${label}.browserEnvironment.executableCompanyName raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.executableProductVersion ?? null,
    loop.browserEnvironment?.executableProductVersion ?? null,
    `${label}.browserEnvironment.executableProductVersion raw evidence`,
  )
  compareValue(
    errors,
    chromeMajorVersion(checks.browserEnvironment?.userAgent),
    loop.browserEnvironment?.runtimeMajorVersion ?? null,
    `${label}.browserEnvironment.runtimeMajorVersion raw evidence`,
  )
  compareValue(
    errors,
    chromeMajorVersion(checks.browserEnvironment?.executableProductVersion),
    loop.browserEnvironment?.executableMajorVersion ?? null,
    `${label}.browserEnvironment.executableMajorVersion raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.getUserMedia ?? null,
    loop.browserEnvironment?.getUserMedia ?? null,
    `${label}.browserEnvironment.getUserMedia raw evidence`,
  )
  compareValue(
    errors,
    checks.browserEnvironment?.speechRecognition ?? null,
    loop.browserEnvironment?.speechRecognition ?? null,
    `${label}.browserEnvironment.speechRecognition raw evidence`,
  )
  validateRawBrowserOrigin(errors, checks.browserEnvironment, appUrl, label)
  compareValue(errors, checks.localizedUi?.title ?? null, loop.title ?? null, `${label}.title raw evidence`)
  compareValue(
    errors,
    checks.localizedUi?.title ?? null,
    loop.localizedUi?.title ?? null,
    `${label}.localizedUi.title raw evidence`,
  )
  compareValue(
    errors,
    checks.localizedUi?.runButton ?? null,
    loop.localizedUi?.runButton ?? null,
    `${label}.localizedUi.runButton raw evidence`,
  )
  compareValue(
    errors,
    checks.localizedUi?.resetButtonCount ?? null,
    loop.localizedUi?.resetButtonCount ?? null,
    `${label}.localizedUi.resetButtonCount raw evidence`,
  )
  compareValue(
    errors,
    checks.localizedUi?.textIntegrity?.requiredPhraseCount ?? null,
    loop.textIntegrity?.requiredPhraseCount ?? null,
    `${label}.textIntegrity.requiredPhraseCount raw evidence`,
  )
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
    checks.localizedUi?.textIntegrity?.requiredPhraseCount ?? null,
    loop.localizedUi?.textIntegrity?.requiredPhraseCount ?? null,
    `${label}.localizedUi.textIntegrity.requiredPhraseCount raw evidence`,
  )
  compareValue(
    errors,
    checks.localizedUi?.textIntegrity?.missingPhraseCount ?? null,
    loop.localizedUi?.textIntegrity?.missingPhraseCount ?? null,
    `${label}.localizedUi.textIntegrity.missingPhraseCount raw evidence`,
  )
  compareValue(
    errors,
    checks.localizedUi?.textIntegrity?.mojibakeCount ?? null,
    loop.localizedUi?.textIntegrity?.mojibakeCount ?? null,
    `${label}.localizedUi.textIntegrity.mojibakeCount raw evidence`,
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
  validateRawScreenshotsInManifest(
    errors,
    raw.screenshots,
    checks.screenshotEvidence?.files,
    screenshotEntries,
    label,
    { expectedBrowserName },
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

  return raw
}

function validateRawBrowserIdentity(
  errors,
  raw,
  manifestEntry,
  label,
  { expectedManifestLabel, expectedBrowserName, expectedExecutablePath },
) {
  if (expectedManifestLabel && manifestEntry.label !== expectedManifestLabel) {
    errors.push(`${label} raw evidence manifest label must be ${expectedManifestLabel}.`)
  }
  if (expectedBrowserName && raw.browserName !== expectedBrowserName) {
    errors.push(`${label}.browserName raw evidence must be ${expectedBrowserName}.`)
  }

  const browserEnvironment = raw.checks?.browserEnvironment
  if (expectedBrowserName && browserEnvironment?.browserName !== expectedBrowserName) {
    errors.push(`${label}.browserEnvironment.browserName raw evidence must be ${expectedBrowserName}.`)
  }
  if (expectedExecutablePath && browserEnvironment?.executablePath !== expectedExecutablePath) {
    errors.push(`${label}.browserEnvironment.executablePath raw evidence must be ${expectedExecutablePath}.`)
  }
  if (expectedBrowserName === 'windows-chrome') {
    validateInstalledChromeExecutableIdentity(errors, browserEnvironment, `${label}.browserEnvironment raw evidence`)
  }
}

function validateIndependentBrowserScreenshots(errors, desktop, chrome) {
  if (!Array.isArray(desktop?.screenshots) || !Array.isArray(chrome?.screenshots)) return

  const chromeScreenshots = new Set(chrome.screenshots)
  const sharedScreenshots = desktop.screenshots.filter((screenshot) => chromeScreenshots.has(screenshot))

  if (sharedScreenshots.length) {
    errors.push(`desktop and Windows Chrome screenshots must be independent: ${sharedScreenshots.join(', ')}.`)
  }
}

function validateRawScreenshotsInManifest(
  errors,
  screenshots,
  rawScreenshotFiles,
  screenshotEntries,
  label,
  { expectedBrowserName },
) {
  if (!Array.isArray(screenshots)) {
    errors.push(`${label}.screenshots raw evidence must be an array.`)
    return
  }

  const manifestEntriesByFile = new Map(screenshotEntries.map((entry) => [entry.file, entry]))
  const missingFiles = screenshots.filter((screenshot) => !manifestEntriesByFile.has(screenshot))
  const expectedDirectory = inferCommonScreenshotDirectory(screenshots)
  const wrongDirectoryFiles = expectedDirectory
    ? screenshots.filter((screenshot) => !screenshot.startsWith(expectedDirectory))
    : screenshots
  const wrongBrowserDirectoryFiles = expectedBrowserName
    ? screenshots.filter((screenshot) => !screenshot.includes(`/${expectedBrowserName}-screens/`))
    : []

  if (missingFiles.length) {
    errors.push(`${label}.screenshots missing from evidence manifest: ${missingFiles.join(', ')}.`)
  }
  if (wrongDirectoryFiles.length) {
    errors.push(
      `${label}.screenshots must share one screenshot directory: ${wrongDirectoryFiles.join(', ')}.`,
    )
  }
  if (wrongBrowserDirectoryFiles.length) {
    errors.push(
      `${label}.screenshots must use a ${expectedBrowserName}-screens directory: ${wrongBrowserDirectoryFiles.join(', ')}.`,
    )
  }

  if (!Array.isArray(rawScreenshotFiles)) {
    errors.push(`${label}.screenshotEvidence.files raw evidence must be an array.`)
    return
  }

  if (rawScreenshotFiles.length !== screenshots.length) {
    errors.push(
      `${label}.screenshotEvidence.files length mismatch (${rawScreenshotFiles.length} != ${screenshots.length}).`,
    )
  }

  const rawScreenshots = new Set(screenshots)
  const invalidRawFiles = rawScreenshotFiles.filter(
    (entry) => typeof entry?.path !== 'string' || !rawScreenshots.has(entry.path),
  )

  if (invalidRawFiles.length) {
    const labels = invalidRawFiles.map((entry) => entry?.path ?? 'missing').join(', ')
    errors.push(`${label}.screenshotEvidence.files missing from raw screenshots: ${labels}.`)
  }

  for (const rawFile of rawScreenshotFiles) {
    if (!rawFile || typeof rawFile.path !== 'string') continue

    const manifestEntry = manifestEntriesByFile.get(rawFile.path)
    if (!manifestEntry) {
      errors.push(`${label}.screenshotEvidence.files missing from evidence manifest: ${rawFile.path}.`)
      continue
    }

    if (rawFile.bytes !== manifestEntry.bytes) {
      errors.push(`${label}.screenshotEvidence.files ${rawFile.path} byte mismatch (${manifestEntry.bytes} != ${rawFile.bytes}).`)
    }
    if (rawFile.sha256 !== manifestEntry.sha256) {
      errors.push(`${label}.screenshotEvidence.files ${rawFile.path} sha256 mismatch (${manifestEntry.sha256} != ${rawFile.sha256}).`)
    }
  }
}

async function validateRawPhoneEvidence(errors, loop, manifestEntry, label, { appUrl, apiBase }) {
  if (!manifestEntry?.present || !loop?.run) return

  const raw = await readManifestJson(errors, manifestEntry, label)
  if (!raw) return

  compareValue(errors, raw.success === true, loop.success, `${label}.success raw evidence`)
  compareValue(errors, raw.runId ?? null, loop.runId ?? null, `${label}.runId raw evidence`)
  compareValue(errors, raw.appUrl ?? null, appUrl ?? null, `${label}.appUrl raw evidence`)
  compareValue(errors, raw.apiBase ?? null, apiBase ?? null, `${label}.apiBase raw evidence`)
  compareValue(errors, raw.startedAt ?? null, loop.startedAt ?? null, `${label}.startedAt raw evidence`)
  compareValue(errors, raw.finishedAt ?? null, loop.finishedAt ?? null, `${label}.finishedAt raw evidence`)
  compareValue(errors, raw.pageUrl ?? null, loop.pageUrl ?? null, `${label}.pageUrl raw evidence`)

  const checks = raw.checks ?? {}
  compareValue(errors, checks.localizedUi?.title ?? null, loop.title ?? null, `${label}.title raw evidence`)
  compareValue(
    errors,
    checks.localizedUi?.textIntegrity?.requiredPhraseCount ?? null,
    loop.textIntegrity?.requiredPhraseCount ?? null,
    `${label}.textIntegrity.requiredPhraseCount raw evidence`,
  )
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
    checks.frontCamera?.mirrored ?? null,
    loop.frontCamera?.mirrored ?? null,
    `${label}.frontCamera.mirrored raw evidence`,
  )
  compareValue(
    errors,
    checks.frontCamera?.objectFit ?? null,
    loop.frontCamera?.objectFit ?? null,
    `${label}.frontCamera.objectFit raw evidence`,
  )
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

async function validateRawDevEnvEvidence(errors, preflight, manifestEntry, label) {
  if (!manifestEntry?.present) {
    errors.push(`${label} manifest entry is missing.`)
    return
  }
  if (!preflight?.run) return

  const raw = await readManifestJson(errors, manifestEntry, label)
  if (!raw) return

  compareValue(errors, raw.success === true, preflight.success, `${label}.success raw evidence`)
  compareValue(errors, raw.generatedAt ?? null, preflight.generatedAt ?? null, `${label}.generatedAt raw evidence`)
  compareValue(errors, raw.required ?? null, preflight.required ?? null, `${label}.required raw evidence`)
  compareValue(errors, raw.requirePhone ?? null, preflight.requirePhone ?? null, `${label}.requirePhone raw evidence`)
  compareValue(
    errors,
    devEnvChecksSignature(raw.checks),
    devEnvChecksSignature(preflight.checks),
    `${label}.checks raw evidence`,
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

function inferCommonScreenshotDirectory(screenshots) {
  if (!Array.isArray(screenshots) || screenshots.length === 0) return null
  const directories = Array.from(new Set(screenshots.map((screenshot) => screenshot.slice(0, screenshot.lastIndexOf('/') + 1))))
  return directories.length === 1 ? directories[0] : null
}

function browserViewportSignature(value) {
  if (!value || typeof value !== 'object') return null
  return [value.innerWidth ?? null, value.innerHeight ?? null, value.devicePixelRatio ?? null].join(':')
}

function hostEnvironmentSignature(value) {
  if (!value || typeof value !== 'object') return null
  return [
    value.platform ?? null,
    value.arch ?? null,
    value.nodeVersion ?? null,
    value.nodeMajorVersion ?? null,
    value.ci ?? null,
  ].join(':')
}

function devEnvChecksSignature(value) {
  if (!Array.isArray(value)) return null
  return value
    .map((check) =>
      [
        check?.name ?? null,
        check?.category ?? null,
        check?.ok ?? null,
        check?.required ?? null,
        check?.status ?? null,
        check?.detail ?? null,
      ].join(':'),
    )
    .join('|')
}

function validateDevEnvPreflight(errors, value, label, { generatedAt, requirePhone }) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (value.run !== true) {
    if (requirePhone) {
      errors.push(`${label}.run must be true when phone loop is required or present.`)
    }
    if (value.success !== null) errors.push(`${label}.success must be null when preflight did not run.`)
    return
  }

  if (value.success !== true) errors.push(`${label}.success must be true.`)
  if (value.required !== true) errors.push(`${label}.required must be true.`)
  if (requirePhone && value.requirePhone !== true) {
    errors.push(`${label}.requirePhone must be true when phone loop is required or present.`)
  }
  assertString(errors, value.generatedAt, `${label}.generatedAt`)
  assertArray(errors, value.checks, `${label}.checks`)
  if (!positiveNumber(value.okCount)) errors.push(`${label}.okCount must be positive.`)
  if (value.failCount !== 0) errors.push(`${label}.failCount must be 0.`)

  const preflightMs = timestampMs(value.generatedAt)
  const summaryMs = timestampMs(generatedAt)
  if (!Number.isFinite(preflightMs)) errors.push(`${label}.generatedAt must be a valid timestamp.`)
  if (Number.isFinite(preflightMs) && Number.isFinite(summaryMs) && summaryMs < preflightMs) {
    errors.push(`generatedAt must not be earlier than ${label}.generatedAt.`)
  }

  const checks = Array.isArray(value.checks) ? value.checks : []
  const requiredNames = ['node', 'npm', 'api directory', 'api requirements', 'api env template', 'web package', 'web package lock', 'Windows Chrome']
  for (const name of requiredNames) {
    const check = checks.find((item) => item?.name === name)
    if (!check) {
      errors.push(`${label}.checks missing ${name}.`)
    } else if (check.ok !== true) {
      errors.push(`${label}.checks ${name} must be ok.`)
    }
  }

  if (value.requirePhone === true || requirePhone) {
    for (const name of ['adb.exe', 'authorized Android device']) {
      const check = checks.find((item) => item?.name === name)
      if (!check) {
        errors.push(`${label}.checks missing ${name}.`)
      } else if (check.ok !== true) {
        errors.push(`${label}.checks ${name} must be ok when phone is required.`)
      }
    }
  }

  for (const check of checks) {
    if (check?.required === true && check.ok !== true) {
      errors.push(`${label}.checks ${check.name ?? 'unknown'} is required but not ok.`)
    }
  }
}

function validatePreflightBeforeLoops(errors, summary) {
  const preflightAt = timestampMs(summary.environment?.preflight?.generatedAt)
  if (!Number.isFinite(preflightAt)) return

  const loops = [
    ['loops.desktop', summary.loops?.desktop],
    ['loops.windowsChrome', summary.loops?.windowsChrome],
    ['loops.phone', summary.loops?.phone],
  ]

  for (const [label, loop] of loops) {
    if (!loop?.run) continue
    const startedAt = timestampMs(loop.startedAt)
    if (!Number.isFinite(startedAt)) continue
    if (preflightAt > startedAt) {
      errors.push(`environment.preflight.generatedAt must not be later than ${label}.startedAt.`)
    }
  }
}

function validateRuntimeHealth(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (value.success !== true) errors.push(`${label}.success must be true.`)
  if (value.issueCount !== 0) errors.push(`${label}.issueCount must be 0.`)
}

function validateLoopTiming(errors, loop, label, generatedAt) {
  assertString(errors, loop.startedAt, `${label}.startedAt`)
  assertString(errors, loop.finishedAt, `${label}.finishedAt`)

  const startedMs = timestampMs(loop.startedAt)
  const finishedMs = timestampMs(loop.finishedAt)
  const generatedMs = timestampMs(generatedAt)

  if (!Number.isFinite(startedMs)) errors.push(`${label}.startedAt must be a valid timestamp.`)
  if (!Number.isFinite(finishedMs)) errors.push(`${label}.finishedAt must be a valid timestamp.`)
  if (!Number.isFinite(generatedMs)) errors.push('generatedAt must be a valid timestamp.')

  if (Number.isFinite(startedMs) && Number.isFinite(finishedMs) && finishedMs < startedMs) {
    errors.push(`${label}.finishedAt must not be earlier than startedAt.`)
  }
  if (Number.isFinite(finishedMs) && Number.isFinite(generatedMs) && generatedMs < finishedMs) {
    errors.push(`generatedAt must not be earlier than ${label}.finishedAt.`)
  }
}

function validateLoopUrls(errors, loop, label, { appUrl, apiBase }) {
  const page = parseUrl(loop.pageUrl)
  const app = parseUrl(appUrl)
  const expectedApiBase = typeof apiBase === 'string' ? apiBase : null

  if (!page) errors.push(`${label}.pageUrl must be a valid URL.`)
  if (!app) errors.push('appUrl must be a valid URL.')
  if (page && app && page.origin !== app.origin) {
    errors.push(`${label}.pageUrl origin must match appUrl origin.`)
  }
  if (page && expectedApiBase && page.searchParams.get('apiBase') !== expectedApiBase) {
    errors.push(`${label}.pageUrl apiBase query must match summary apiBase.`)
  }
}

function validateRawBrowserOrigin(errors, value, appUrl, label) {
  const app = parseUrl(appUrl)
  const rawOrigin = typeof value?.locationOrigin === 'string' ? value.locationOrigin : null

  if (!rawOrigin) {
    errors.push(`${label}.browserEnvironment.locationOrigin raw evidence must be present.`)
    return
  }
  if (app && rawOrigin !== app.origin) {
    errors.push(`${label}.browserEnvironment.locationOrigin raw evidence must match appUrl origin.`)
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

function timestampMs(value) {
  if (typeof value !== 'string' || value.length === 0) return Number.NaN
  const time = Date.parse(value)
  return Number.isFinite(time) ? time : Number.NaN
}

function validateBrowserEnvironment(
  errors,
  value,
  label,
  { expectedBrowserName, expectedExecutablePath, expectedInstalledChromeIdentity = false },
) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (expectedBrowserName && value.browserName !== expectedBrowserName) {
    errors.push(`${label}.browserName must be ${expectedBrowserName}.`)
  }
  if (expectedExecutablePath && value.executablePath !== expectedExecutablePath) {
    errors.push(`${label}.executablePath must be ${expectedExecutablePath}.`)
  }
  if (value.getUserMedia !== true) errors.push(`${label}.getUserMedia must be true.`)
  if (value.speechRecognition !== true) errors.push(`${label}.speechRecognition must be true.`)
  if (typeof value.userAgent !== 'string' || !/Chrome|Chromium/u.test(value.userAgent)) {
    errors.push(`${label}.userAgent must identify Chrome or Chromium.`)
  }
  if (value.runtimeMajorVersion !== chromeMajorVersion(value.userAgent)) {
    errors.push(`${label}.runtimeMajorVersion must match the Chrome userAgent major version.`)
  }
  if (value.executableMajorVersion !== chromeMajorVersion(value.executableProductVersion)) {
    errors.push(`${label}.executableMajorVersion must match the executable product major version.`)
  }
  if (expectedInstalledChromeIdentity) {
    validateInstalledChromeExecutableIdentity(errors, value, label)
  }
}

function validateHostEnvironment(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (!['win32', 'darwin', 'linux'].includes(value.platform)) {
    errors.push(`${label}.platform must identify a supported desktop OS.`)
  }
  if (!['x64', 'arm64'].includes(value.arch)) {
    errors.push(`${label}.arch must identify a supported desktop CPU architecture.`)
  }
  if (typeof value.nodeVersion !== 'string' || !/^\d+\.\d+\.\d+$/u.test(value.nodeVersion)) {
    errors.push(`${label}.nodeVersion must be a semantic Node.js version.`)
  }
  if (!Number.isInteger(value.nodeMajorVersion) || value.nodeMajorVersion < 20) {
    errors.push(`${label}.nodeMajorVersion must be at least 20.`)
  }
  if (typeof value.ci !== 'boolean') {
    errors.push(`${label}.ci must be boolean.`)
  }
}

function validateInstalledChromeExecutableIdentity(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} executable identity is missing.`)
    return
  }

  const productName = value.executableProductName ?? ''
  const companyName = value.executableCompanyName ?? ''

  if (value.executableFileName !== 'chrome.exe') {
    errors.push(`${label}.executableFileName must be chrome.exe.`)
  }
  if (!['program-files', 'program-files-x86', 'local-app-data', 'custom-path'].includes(value.executableSource)) {
    errors.push(`${label}.executableSource must identify the Chrome executable source kind.`)
  }
  if (typeof productName !== 'string' || !productName.includes('Google Chrome')) {
    errors.push(`${label}.executableProductName must identify Google Chrome.`)
  }
  if (typeof companyName !== 'string' || !companyName.includes('Google')) {
    errors.push(`${label}.executableCompanyName must identify Google.`)
  }
  if (typeof value.executableProductVersion !== 'string' || !/^\d+\./u.test(value.executableProductVersion)) {
    errors.push(`${label}.executableProductVersion must start with a numeric Chrome version.`)
  }
  if (value.runtimeMajorVersion !== value.executableMajorVersion) {
    errors.push(`${label}.runtimeMajorVersion must match executableMajorVersion.`)
  }
}

function chromeMajorVersion(value) {
  if (typeof value !== 'string') return null

  const match = value.match(/(?:HeadlessChrome|Chrome|Chromium)\/(\d+)\./u) ?? value.match(/^(\d+)\./u)
  return match ? Number(match[1]) : null
}

function validateTextIntegrity(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (!Number.isInteger(value.requiredPhraseCount) || value.requiredPhraseCount < MIN_LOCALIZED_PHRASE_COUNT) {
    errors.push(`${label}.requiredPhraseCount must be at least ${MIN_LOCALIZED_PHRASE_COUNT}.`)
  }
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
