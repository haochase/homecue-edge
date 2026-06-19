import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { recomputeBrowserParity } from './summary-parity.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')

const outputFile = process.argv[2] ?? path.join(repoRoot, 'assets', 'demo', 'full-loop-report.md')
const desktopFile = process.argv[3] ?? path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const phoneFile = process.argv[4] ?? path.join(repoRoot, 'assets', 'demo', 'phone-loop.json')
// argv[5] is the legacy desktop screenshot directory slot. Screenshots are now read from loop JSON.
const chromeFile = process.argv[6] ?? path.join(repoRoot, 'assets', 'demo', 'chrome-loop.json')
const summaryFile = process.argv[7] ?? defaultSummaryFile(outputFile)
const devEnvFile = process.argv[8] ?? path.join(repoRoot, 'assets', 'tmp', 'dev-env-check.json')

const desktop = await readJsonIfExists(desktopFile)
const phone = await readJsonIfExists(phoneFile)
const chrome = await readJsonIfExists(chromeFile)
const devEnv = await readJsonIfExists(devEnvFile)
const loops = {
  desktop: summarizeDesktopLoop(desktop),
  windowsChrome: summarizeDesktopLoop(chrome),
  phone: summarizePhoneLoop(phone),
}
const browserParity = summarizeBrowserParity(loops.desktop, loops.windowsChrome)
const requiredEvidence = validateEvidence({ desktop, phone, chrome, devEnv, browserParity })
const screenshots = collectScreenshots([desktop, chrome])
const manifest = await buildEvidenceManifest({ desktop, phone, chrome, devEnv, screenshots })
const generatedAt = new Date().toISOString()
const summary = buildSummary({ generatedAt, desktop, phone, chrome, devEnv, loops, browserParity, requiredEvidence, manifest })

const report = [
  '# Home AI Companion Loop Report',
  '',
  `Generated: ${generatedAt}`,
  '',
  '## Summary',
  '',
  `- Desktop loop: ${formatStatus(desktop?.success)}`,
  `- Windows Chrome loop: ${chrome ? formatStatus(chrome.success) : 'not run'}`,
  `- Phone loop: ${phone ? formatStatus(phone.success) : 'not run'}`,
  `- Run ID: ${requiredEvidence.runId ?? 'not set'}`,
  `- Dev environment preflight: ${formatDevEnvPreflight(devEnv)}`,
  `- Browser parity: ${formatParity(browserParity)}`,
  `- App URL: ${desktop?.appUrl ?? phone?.appUrl ?? 'unknown'}`,
  `- API base: ${desktop?.apiBase ?? phone?.apiBase ?? 'unknown'}`,
  '',
  '## Desktop Browser',
  '',
  ...formatDesktop(desktop),
  '',
  '## Windows Chrome',
  '',
  ...formatDesktop(chrome),
  '',
  '## Android Chrome Phone',
  '',
  ...formatPhone(phone),
  '',
  '## Evidence Files',
  '',
  ...formatManifest(manifest),
  '',
  '## Demo Talking Points',
  '',
  ...formatDemoTalkingPoints({ desktop, phone, chrome, devEnv, browserParity }),
  '',
].join('\n')

await mkdir(path.dirname(outputFile), { recursive: true })
await mkdir(path.dirname(summaryFile), { recursive: true })
await writeFile(outputFile, report, 'utf8')
await writeFile(summaryFile, `${JSON.stringify(summary, null, 2)}\n`, 'utf8')
console.log(`Full loop report: ${outputFile}`)
console.log(`Full loop summary: ${summaryFile}`)
if (!requiredEvidence.success) {
  console.error(`Full loop report evidence validation failed:\n${requiredEvidence.errors.map((item) => `- ${item}`).join('\n')}`)
  process.exit(1)
}

async function readJsonIfExists(file) {
  try {
    return JSON.parse(await readFile(file, 'utf8'))
  } catch (error) {
    if (error?.code === 'ENOENT') return null
    throw error
  }
}

function defaultSummaryFile(file) {
  const parsed = path.parse(file)
  const baseName = parsed.ext.toLowerCase() === '.md' ? parsed.name : parsed.base
  return path.join(parsed.dir, `${baseName}.json`)
}

function buildSummary({ generatedAt, desktop, phone, chrome, devEnv, loops, browserParity, requiredEvidence, manifest }) {
  return {
    generatedAt,
    success: requiredEvidence.success,
    runId: requiredEvidence.runId,
    appUrl: desktop?.appUrl ?? chrome?.appUrl ?? phone?.appUrl ?? null,
    apiBase: desktop?.apiBase ?? chrome?.apiBase ?? phone?.apiBase ?? null,
    environment: {
      preflight: summarizeDevEnv(devEnv),
    },
    loops,
    browserParity,
    evidence: {
      validationErrors: requiredEvidence.errors,
      files: manifest,
    },
  }
}

function summarizeDesktopLoop(value) {
  if (!value) {
    return { run: false, success: null }
  }

  const checks = value.checks ?? {}
  return {
    run: true,
    success: value.success === true,
    runId: value.runId ?? null,
    startedAt: value.startedAt ?? null,
    finishedAt: value.finishedAt ?? null,
    browserName: value.browserName ?? null,
    pageUrl: value.pageUrl ?? null,
    title: checks.localizedUi?.title ?? null,
    textIntegrity: summarizeTextIntegrity(checks.localizedUi?.textIntegrity),
    localizedUi: summarizeDesktopLocalizedUi(checks.localizedUi),
    firstViewportVisibility: summarizeFirstViewportVisibility(checks.firstViewportVisibility),
    hostEnvironment: summarizeHostEnvironment(checks.hostEnvironment),
    browserEnvironment: summarizeBrowserEnvironment(checks.browserEnvironment),
    responsiveLayout: summarizeResponsiveLayout(checks.responsiveLayout),
    runtimeHealth: summarizeRuntimeHealth(checks.runtimeHealth),
    screenshotEvidence: summarizeScreenshotEvidence(checks.screenshotEvidence),
    scenePromptHandoff: summarizePromptHandoff(checks.scenePromptHandoff),
    proposeOnly: {
      status: checks.proposeOnly?.status ?? null,
      latestSource: checks.proposeOnly?.latestSource ?? null,
      latestExecuted: checks.proposeOnly?.latestExecuted ?? null,
    },
    webConfirmExecute: {
      latestSource: checks.webConfirmExecute?.latestSource ?? null,
      latestSequence: checks.webConfirmExecute?.latestSequence ?? null,
      acceptedRows: checks.webConfirmExecute?.acceptedRows ?? null,
    },
    offlineFallback: {
      latestSource: checks.offlineFallback?.latestSource ?? null,
      latestSequence: checks.offlineFallback?.latestSequence ?? null,
      executionCount: checks.offlineFallback?.executionCount ?? null,
    },
    externalExecutionSync: {
      latestSource: checks.externalExecutionSync?.latestSource ?? null,
      latestSequence: checks.externalExecutionSync?.latestSequence ?? null,
      acceptedActionCount: checks.externalExecutionSync?.acceptedActionCount ?? null,
    },
  }
}

function summarizePhoneLoop(value) {
  if (!value) {
    return { run: false, success: null }
  }

  const checks = value.checks ?? {}
  const speechSupport = checks.speechInput?.support ?? {}
  return {
    run: true,
    success: value.success === true,
    runId: value.runId ?? null,
    startedAt: value.startedAt ?? null,
    finishedAt: value.finishedAt ?? null,
    pageUrl: value.pageUrl ?? null,
    title: checks.localizedUi?.title ?? null,
    textIntegrity: summarizeTextIntegrity(checks.localizedUi?.textIntegrity),
    frontCamera: {
      ready: checks.frontCamera?.ready ?? null,
      facingMode: checks.frontCamera?.facingMode ?? null,
      width: checks.frontCamera?.width ?? null,
      height: checks.frontCamera?.height ?? null,
      status: checks.frontCamera?.status ?? null,
      mirrored: checks.frontCamera?.mirrored ?? null,
      objectFit: checks.frontCamera?.objectFit ?? null,
    },
    speechInput: {
      available: Boolean(speechSupport.SpeechRecognition || speechSupport.webkitSpeechRecognition),
      skipped: checks.speechInput?.skipped === true,
      status: checks.speechInput?.listeningState?.status ?? null,
    },
    scene: {
      frameSize: checks.scene?.frameSize ?? null,
      rawImageRetained: checks.scene?.rawImageRetained ?? null,
      rawImageNotRetained: checks.scene?.rawImageNotRetained ?? null,
    },
    scenePromptHandoff: summarizePromptHandoff(checks.scenePromptHandoff),
    externalExecution: {
      latestSource: checks.externalExecution?.latestSource ?? null,
      latestSequence: checks.externalExecution?.latestSequence ?? null,
      acceptedActionCount: checks.externalExecution?.acceptedActionCount ?? null,
    },
    runtimeHealth: summarizeRuntimeHealth(checks.runtimeHealth),
  }
}

function summarizePromptHandoff(value) {
  if (!value) {
    return {
      ready: false,
      proposeOnly: null,
      promptPresent: false,
      scene: null,
      rawImageRetained: null,
      rawImageEchoed: null,
    }
  }

  return {
    ready: Boolean(value.proposeOnly && value.prompt),
    proposeOnly: value.proposeOnly ?? null,
    promptPresent: Boolean(value.prompt),
    scene: value.scene ?? null,
    rawImageRetained: value.rawImageRetained ?? null,
    rawImageEchoed: value.rawImageEchoed ?? null,
  }
}

function summarizeDevEnv(value) {
  if (!value) {
    return { run: false, success: null }
  }

  const checks = Array.isArray(value.checks) ? value.checks : []
  return {
    run: true,
    success: value.success === true,
    generatedAt: value.generatedAt ?? null,
    required: value.required ?? null,
    requirePhone: value.requirePhone ?? null,
    okCount: checks.filter((check) => check?.ok === true).length,
    warnCount: checks.filter((check) => check?.status === 'WARN').length,
    failCount: checks.filter((check) => check?.status === 'FAIL').length,
    checks: checks.map((check) => ({
      name: check?.name ?? null,
      category: check?.category ?? null,
      ok: check?.ok ?? null,
      required: check?.required ?? null,
      status: check?.status ?? null,
      detail: check?.detail ?? null,
    })),
  }
}

function summarizeResponsiveLayout(value) {
  if (!Array.isArray(value)) {
    return []
  }

  return value.map((item) => ({
    label: item.label ?? null,
    width: item.width ?? null,
    height: item.height ?? null,
    overflowX: item.overflowX ?? null,
    overflowingButtonCount: item.overflowingButtons?.length ?? 0,
    overlappingPanelPairCount: item.overlappingPanelPairs?.length ?? 0,
    panelCount: item.panelCount ?? null,
    minPanelWidth: item.minPanelWidth ?? null,
    minPanelHeight: item.minPanelHeight ?? null,
  }))
}

function summarizeBrowserEnvironment(value) {
  if (!value) {
    return null
  }

  return {
    browserName: value.browserName ?? null,
    userAgent: value.userAgent ?? null,
    language: value.language ?? null,
    viewport: value.viewport ?? null,
    getUserMedia: value.getUserMedia ?? null,
    speechRecognition: value.speechRecognition ?? null,
    headed: value.headed ?? null,
    executablePath: value.executablePath ?? null,
    executableFileName: value.executableFileName ?? null,
    executableSource: value.executableSource ?? null,
    executableProductName: value.executableProductName ?? null,
    executableCompanyName: value.executableCompanyName ?? null,
    executableProductVersion: value.executableProductVersion ?? null,
    runtimeMajorVersion: chromeMajorVersion(value.userAgent),
    executableMajorVersion: chromeMajorVersion(value.executableProductVersion),
    channel: value.channel ?? null,
  }
}

function summarizeHostEnvironment(value) {
  if (!value) {
    return null
  }

  return {
    platform: value.platform ?? null,
    arch: value.arch ?? null,
    nodeVersion: value.nodeVersion ?? null,
    nodeMajorVersion: value.nodeMajorVersion ?? null,
    ci: value.ci ?? null,
  }
}

function summarizeRuntimeHealth(value) {
  if (!value) {
    return null
  }

  const details = value.details ?? value
  const counts = details.counts ?? {}
  const issueCount =
    details.issueCount ??
    Object.values(counts).reduce((total, count) => total + (typeof count === 'number' ? count : 0), 0)

  return {
    success: value.success !== false && details.success !== false && issueCount === 0,
    issueCount,
    counts,
  }
}

function summarizeTextIntegrity(value) {
  if (!value) {
    return null
  }

  return {
    requiredPhraseCount: value.requiredPhraseCount ?? null,
    missingPhraseCount: value.missingPhraseCount ?? null,
    mojibakeCount: value.mojibakeCount ?? null,
  }
}

function summarizeDesktopLocalizedUi(value) {
  if (!value) {
    return null
  }

  return {
    title: value.title ?? null,
    runButton: value.runButton ?? null,
    resetButtonCount: value.resetButtonCount ?? null,
    textIntegrity: summarizeTextIntegrity(value.textIntegrity),
  }
}

function summarizeFirstViewportVisibility(value) {
  if (!value) {
    return null
  }

  return {
    minVisibleRatio: value.minVisibleRatio ?? null,
    panelCount: Array.isArray(value.panels) ? value.panels.length : null,
    hiddenPanelCount: Array.isArray(value.panels)
      ? value.panels.filter((panel) => panel.present !== true || panel.visibleRatio < 0.9).length
      : null,
  }
}

function summarizeScreenshotEvidence(value) {
  if (!value) {
    return null
  }

  return {
    success: value.success !== false,
    count: value.count ?? null,
    expectedFiles: Array.isArray(value.expectedFiles) ? value.expectedFiles : [],
    uniqueDigestCount: value.uniqueDigestCount ?? null,
    minWidth: value.minWidth ?? null,
    minHeight: value.minHeight ?? null,
    minBytes: value.minBytes ?? null,
    minImageDataBytes: value.minImageDataBytes ?? null,
  }
}

async function buildEvidenceManifest({ desktop, phone, chrome, devEnv, screenshots }) {
  const entries = []
  const jsonFiles = [
    ['Desktop JSON', desktopFile, Boolean(desktop)],
    ['Windows Chrome JSON', chromeFile, Boolean(chrome)],
    ['Phone JSON', phoneFile, Boolean(phone)],
    ['Dev Environment JSON', devEnvFile, Boolean(devEnv)],
  ]

  for (const [label, file, present] of jsonFiles) {
    if (!present) {
      entries.push({ label, present: false })
      continue
    }
    entries.push(await fileManifestEntry(label, file))
  }

  for (const screenshot of screenshots) {
    entries.push(await fileManifestEntry('Screenshot', path.resolve(repoRoot, screenshot)))
  }

  return entries
}

async function fileManifestEntry(label, file) {
  const buffer = await readFile(file)
  return {
    label,
    file: relativePath(file),
    present: true,
    bytes: buffer.length,
    sha256: createHash('sha256').update(buffer).digest('hex').slice(0, 12),
  }
}

function formatManifest(entries) {
  return entries.map((entry) => {
    if (!entry.present) {
      return `- ${entry.label}: not run`
    }
    return `- ${entry.label}: ${entry.file} (${entry.bytes} bytes, sha256:${entry.sha256})`
  })
}

function formatDemoTalkingPoints({ desktop, phone, chrome, devEnv, browserParity }) {
  const points = []
  const runTargets = [
    desktop ? 'desktop web' : null,
    chrome ? 'Windows Chrome' : null,
    phone ? 'Android Chrome' : null,
  ].filter(Boolean)
  const runScope = runTargets.length ? runTargets.join(', ') : 'the configured browser target'

  points.push(
    `- The loop verifies the HomeCue assistant path across ${runScope}, the edge API, and simulated room-terminal execution.`,
  )

  if (phone) {
    points.push(
      '- The phone proof covers front-camera preference, Web Speech readiness, visual scene capture, and guarded execution sync.',
    )
  } else {
    points.push('- Phone proof was not run in this report; run the full loop with phone enabled for Android camera and speech coverage.')
  }

  if (desktop || chrome) {
    points.push(
      '- The desktop proof covers propose-only planning, web confirmation, offline fallback, and ESP32-style external confirmation sync.',
    )
  }

  if (browserParity.checked) {
    points.push(`- Browser parity is ${formatParity(browserParity)} between the desktop browser targets.`)
  }

  points.push(
    '- The report is generated from local ignored evidence artifacts, keeping the public repository free of private screenshots and runtime logs.',
  )

  if (devEnv) {
    points.push('- The environment preflight records host, browser, port, ADB, and authorized-phone readiness before browser automation starts.')
  }

  return points
}

function formatDesktop(value) {
  if (!value) {
    return ['- Not run.']
  }

  const checks = value.checks ?? {}
  return [
    `- Title: ${checks.localizedUi?.title ?? 'unknown'}`,
    `- Chinese text integrity: ${formatTextIntegrity(checks.localizedUi?.textIntegrity)}`,
    `- First viewport visibility: ${formatFirstViewportVisibility(checks.firstViewportVisibility)}`,
    `- Host environment: ${formatHostEnvironment(checks.hostEnvironment)}`,
    `- Browser environment: ${formatBrowserEnvironment(checks.browserEnvironment)}`,
    `- Responsive layout: ${formatResponsiveLayout(checks.responsiveLayout)}`,
    `- Runtime health: ${formatRuntimeHealth(checks.runtimeHealth)}`,
    `- Screenshot evidence: ${formatScreenshotEvidence(checks.screenshotEvidence)}`,
    `- Scene prompt handoff: ${formatPromptHandoff(checks.scenePromptHandoff)}`,
    `- Raw image retained: ${formatBoolean(checks.scenePromptHandoff?.rawImageRetained)}`,
    `- Raw image echoed: ${formatBoolean(checks.scenePromptHandoff?.rawImageEchoed)}`,
    `- Propose-only status: ${checks.proposeOnly?.status ?? 'unknown'}`,
    `- Web confirmation source: ${checks.webConfirmExecute?.latestSource ?? 'unknown'}`,
    `- Offline fallback source: ${checks.offlineFallback?.latestSource ?? 'unknown'}`,
    `- External sync source: ${checks.externalExecutionSync?.latestSource ?? 'unknown'}`,
    `- External accepted actions: ${checks.externalExecutionSync?.acceptedActionCount ?? 'unknown'}`,
  ]
}

function validateEvidence({ desktop, phone, chrome, devEnv, browserParity }) {
  const errors = []
  const requiredItems = []

  if (isRequiredFile(desktopFile)) {
    validateDesktopEvidence('Desktop', desktop, errors)
    requiredItems.push(['Desktop', desktop])
  }
  if (isRequiredFile(phoneFile)) {
    validatePhoneEvidence(phone, errors)
    requiredItems.push(['Phone', phone])
  }
  if (isRequiredFile(chromeFile)) {
    validateDesktopEvidence('Windows Chrome', chrome, errors)
    requiredItems.push(['Windows Chrome', chrome])
  }
  if (isRequiredFile(devEnvFile)) {
    validateDevEnvEvidence(devEnv, errors)
  }

  const runIds = requiredItems
    .map(([label, value]) => [label, value?.runId])
    .filter(([, runId]) => typeof runId === 'string' && runId.length > 0)
  const missingRunIds = requiredItems.filter(([, value]) => !value?.runId).map(([label]) => label)
  const uniqueRunIds = Array.from(new Set(runIds.map(([, runId]) => runId)))

  if (missingRunIds.length) {
    errors.push(`Missing run id in evidence: ${missingRunIds.join(', ')}.`)
  }
  if (uniqueRunIds.length > 1) {
    errors.push(`Evidence run ids do not match: ${runIds.map(([label, runId]) => `${label}=${runId}`).join(', ')}.`)
  }
  if (isRequiredFile(desktopFile) && isRequiredFile(chromeFile) && !browserParity.success) {
    errors.push(`Browser parity failed: ${browserParity.errors.join('; ')}.`)
  }

  return {
    success: errors.length === 0,
    errors,
    runId: uniqueRunIds[0] ?? null,
  }
}

function validateDevEnvEvidence(value, errors) {
  if (!value) {
    errors.push('Dev environment evidence file is missing.')
    return
  }
  if (value.success !== true) {
    errors.push('Dev environment preflight success is not true.')
  }
  if (value.required !== true) {
    errors.push('Dev environment preflight must run in required mode.')
  }
  if (!Array.isArray(value.checks) || value.checks.length === 0) {
    errors.push('Dev environment preflight checks are missing.')
    return
  }

  const failingRequired = value.checks.filter((check) => check?.required === true && check.ok !== true)
  if (failingRequired.length) {
    errors.push(`Dev environment required checks failed: ${failingRequired.map((check) => check.name).join(', ')}.`)
  }
}

function summarizeBrowserParity(desktop, chrome) {
  if (!desktop?.run || !chrome?.run || !isRequiredFile(desktopFile) || !isRequiredFile(chromeFile)) {
    return {
      checked: false,
      success: null,
      errors: [],
    }
  }

  return recomputeBrowserParity(desktop, chrome)
}

function validateDesktopEvidence(label, value, errors) {
  if (!value) {
    errors.push(`${label} evidence file is missing.`)
    return
  }
  if (value.success !== true) {
    errors.push(`${label} loop success is not true.`)
  }

  const checks = value.checks ?? {}
  const requiredChecks = [
    'hostEnvironment',
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
  const missing = requiredChecks.filter((name) => !checks[name])
  if (missing.length) {
    errors.push(`${label} missing checks: ${missing.join(', ')}.`)
  }
  validateHostEnvironment(checks.hostEnvironment, errors, label)

  if (!Array.isArray(value.screenshots) || value.screenshots.length !== 6) {
    errors.push(`${label} expected 6 screenshots, got ${value.screenshots?.length ?? 0}.`)
  }
  if (checks.runtimeHealth && checks.runtimeHealth.success !== true) {
    errors.push(`${label} runtime health is not clean.`)
  }
  if (checks.screenshotEvidence && checks.screenshotEvidence.count !== 6) {
    errors.push(`${label} screenshot evidence count is ${checks.screenshotEvidence.count}.`)
  }
  if (
    checks.screenshotEvidence &&
    checks.screenshotEvidence.uniqueDigestCount !== checks.screenshotEvidence.count
  ) {
    errors.push(`${label} screenshot evidence contains duplicate images.`)
  }
  if (checks.scenePromptHandoff?.rawImageRetained !== false || checks.scenePromptHandoff?.rawImageEchoed !== false) {
    errors.push(`${label} scene privacy proof is incomplete.`)
  }
  if (checks.localizedUi?.textIntegrity?.missingPhraseCount !== 0 || checks.localizedUi?.textIntegrity?.mojibakeCount !== 0) {
    errors.push(`${label} localized text integrity proof is incomplete.`)
  }
  if (checks.firstViewportVisibility?.minVisibleRatio < 0.9) {
    errors.push(`${label} first viewport visibility ratio is too low.`)
  }
  if (checks.firstViewportVisibility?.panels?.length !== 5) {
    errors.push(`${label} first viewport visibility panel count is not 5.`)
  }
  if (Array.isArray(checks.responsiveLayout)) {
    const overlapping = checks.responsiveLayout.filter((item) => item.overlappingPanelPairs?.length)
    if (overlapping.length) {
      errors.push(`${label} responsive layout has overlapping panels.`)
    }
  }
}

function validateHostEnvironment(value, errors, label) {
  if (!value || typeof value !== 'object') {
    return
  }

  if (!['win32', 'darwin', 'linux'].includes(value.platform)) {
    errors.push(`${label} host platform must identify a supported desktop OS.`)
  }
  if (!['x64', 'arm64'].includes(value.arch)) {
    errors.push(`${label} host architecture must identify a supported desktop CPU architecture.`)
  }
  if (typeof value.nodeVersion !== 'string' || !/^\d+\.\d+\.\d+$/u.test(value.nodeVersion)) {
    errors.push(`${label} host Node.js version must be semantic.`)
  }
  if (!Number.isInteger(value.nodeMajorVersion) || value.nodeMajorVersion < 20) {
    errors.push(`${label} host Node.js major version must be at least 20.`)
  }
  if (typeof value.ci !== 'boolean') {
    errors.push(`${label} host CI flag must be boolean.`)
  }
}

function validatePhoneEvidence(value, errors) {
  if (!value) {
    errors.push('Phone evidence file is missing.')
    return
  }
  if (value.success !== true) {
    errors.push('Phone loop success is not true.')
  }

  const checks = value.checks ?? {}
  const requiredChecks = [
    'localizedUi',
    'frontCamera',
    'scene',
    'scenePromptHandoff',
    'speechInput',
    'externalExecution',
    'runtimeHealth',
  ]
  const missing = requiredChecks.filter((name) => !checks[name])
  if (missing.length) {
    errors.push(`Phone missing checks: ${missing.join(', ')}.`)
  }
  validatePhoneFrontCamera(checks.frontCamera, errors)
  if (checks.localizedUi?.textIntegrity?.missingPhraseCount !== 0 || checks.localizedUi?.textIntegrity?.mojibakeCount !== 0) {
    errors.push('Phone localized text integrity proof is incomplete.')
  }
  if (checks.runtimeHealth && checks.runtimeHealth.success !== true) {
    errors.push('Phone runtime health is not clean.')
  }
  if (checks.scene && checks.scene.rawImageNotRetained !== true) {
    errors.push('Phone scene privacy proof is incomplete.')
  }
}

function validatePhoneFrontCamera(value, errors) {
  if (!value || typeof value !== 'object') {
    return
  }

  if (value.ready !== true) errors.push('Phone front camera is not ready.')
  if (value.facingMode !== 'user') {
    errors.push(`Phone front camera facingMode must be user, got ${value.facingMode ?? 'missing'}.`)
  }
  if (!positiveNumber(value.width) || !positiveNumber(value.height)) {
    errors.push('Phone front camera dimensions must be positive.')
  }
  if (value.active !== true) errors.push('Phone front camera stream must be active.')
  if (value.trackState !== 'live') {
    errors.push(`Phone front camera trackState must be live, got ${value.trackState ?? 'missing'}.`)
  }
  if (typeof value.status !== 'string' || !value.status.includes('前置摄像头已就绪')) {
    errors.push('Phone front camera status must confirm the front camera is ready.')
  }
  if (value.mirrored !== true) errors.push('Phone front camera preview must be mirrored.')
  if (value.objectFit !== 'cover') errors.push('Phone front camera preview objectFit must be cover.')
  if (value.error !== '') errors.push('Phone front camera error must be empty.')
}

function isRequiredFile(file) {
  return !path.basename(file).startsWith('__')
}

function formatPhone(value) {
  if (!value) {
    return ['- Not run.']
  }

  const checks = value.checks ?? {}
  const camera = checks.frontCamera ?? {}
  const speech = checks.speechInput ?? {}
  return [
    `- Title: ${checks.localizedUi?.title ?? 'unknown'}`,
    `- Chinese text integrity: ${formatTextIntegrity(checks.localizedUi?.textIntegrity)}`,
    `- Front camera: ${camera.ready ? 'ready' : 'not ready'} (${camera.facingMode ?? 'unknown'}, ${camera.width ?? '?'}x${camera.height ?? '?'}, mirrored=${formatBoolean(camera.mirrored)})`,
    `- Front camera status: ${camera.status ?? 'unknown'}`,
    `- Speech recognition: ${speech.support?.webkitSpeechRecognition || speech.support?.SpeechRecognition ? 'available' : 'unavailable'}`,
    `- Speech status: ${speech.listeningState?.status ?? 'unknown'}`,
    `- Runtime health: ${formatRuntimeHealth(checks.runtimeHealth)}`,
    `- Scene frame: ${checks.scene?.frameSize ?? 'not captured'}`,
    `- Scene prompt handoff: ${formatPromptHandoff(checks.scenePromptHandoff)}`,
    `- Raw image retained: ${formatBoolean(checks.scene?.rawImageRetained)}`,
    `- External sync source: ${checks.externalExecution?.latestSource ?? 'unknown'}`,
    `- External accepted actions: ${checks.externalExecution?.acceptedActionCount ?? 'unknown'}`,
  ]
}

function formatDevEnvPreflight(value) {
  if (!value) return 'not run'
  const checks = Array.isArray(value.checks) ? value.checks : []
  const okCount = checks.filter((check) => check?.ok === true).length
  const warnCount = checks.filter((check) => check?.status === 'WARN').length
  const failCount = checks.filter((check) => check?.status === 'FAIL').length
  const phone = value.requirePhone ? 'phone required' : 'phone optional'

  return `${formatStatus(value.success)} (${okCount} ok, ${warnCount} warn, ${failCount} fail, ${phone})`
}

function formatPromptHandoff(value) {
  if (!value) return 'not checked'
  return value.proposeOnly && value.prompt ? 'ready' : 'incomplete'
}

function formatResponsiveLayout(value) {
  if (!Array.isArray(value)) return 'not checked'
  const labels = value.map(
    (item) =>
      `${item.label}:${item.overflowX}px buttons:${item.overflowingButtons?.length ?? 0} overlaps:${
        item.overlappingPanelPairs?.length ?? 0
      }`,
  )
  return labels.length ? labels.join(', ') : 'unknown'
}

function formatBrowserEnvironment(value) {
  if (!value) return 'not checked'
  if (value.success === false) return `fail (${value.error ?? 'unknown error'})`

  const viewport = value.viewport ?? {}
  const browserFamily = value.userAgent?.includes('Edg/')
    ? 'Edge'
    : value.userAgent?.includes('Chrome/')
      ? 'Chrome'
      : value.userAgent?.includes('Chromium/')
        ? 'Chromium'
        : 'unknown'
  const mode = value.executablePath === 'custom' ? 'installed' : 'bundled'
  const executable = value.executableFileName
    ? `${value.executableFileName}, ${value.executableProductName ?? 'unknown product'}, ${
        value.executableSource ?? 'unknown source'
      }`
    : null
  const media = value.getUserMedia ? 'media:on' : 'media:off'
  const speech = value.speechRecognition ? 'speech:on' : 'speech:off'

  return `${value.browserName ?? browserFamily} (${browserFamily}, ${mode}${
    executable ? `, ${executable}` : ''
  }, ${viewport.innerWidth ?? '?'}x${viewport.innerHeight ?? '?'}, dpr ${viewport.devicePixelRatio ?? '?'}, ${media}, ${speech})`
}

function formatHostEnvironment(value) {
  if (!value) return 'not checked'

  return `${value.platform ?? '?'} ${value.arch ?? '?'} / Node ${value.nodeVersion ?? '?'} / ci:${
    value.ci === true ? 'yes' : 'no'
  }`
}

function chromeMajorVersion(value) {
  if (typeof value !== 'string') return null

  const match = value.match(/(?:HeadlessChrome|Chrome|Chromium)\/(\d+)\./u) ?? value.match(/^(\d+)\./u)
  return match ? Number(match[1]) : null
}

function formatParity(value) {
  if (!value?.checked) return 'not checked'
  if (value.success) return 'pass'
  return `fail (${value.errors.join('; ')})`
}

function formatRuntimeHealth(value) {
  if (!value) return 'not checked'
  const details = value.details ?? value
  const counts = details.counts ?? {}
  const issueCount =
    details.issueCount ??
    Object.values(counts).reduce((total, count) => total + (typeof count === 'number' ? count : 0), 0)
  const summary = [
    `console:${counts.consoleErrors ?? 0}`,
    `page:${counts.pageErrors ?? 0}`,
    `request:${counts.requestFailures ?? 0}`,
    `http:${counts.httpErrors ?? 0}`,
  ].join(', ')

  if (value.success === false || details.success === false || issueCount > 0) {
    return `fail (${summary})`
  }

  return `clean (${summary})`
}

function formatTextIntegrity(value) {
  if (!value) return 'not checked'
  return `${value.requiredPhraseCount ?? 0} phrases, missing:${value.missingPhraseCount ?? '?'} mojibake:${value.mojibakeCount ?? '?'}`
}

function formatFirstViewportVisibility(value) {
  if (!value) return 'not checked'
  const hidden = Array.isArray(value.panels)
    ? value.panels.filter((panel) => panel.present !== true || panel.visibleRatio < 0.9).length
    : '?'
  return `min visible ratio:${value.minVisibleRatio ?? '?'}, hidden panels:${hidden}`
}

function formatScreenshotEvidence(value) {
  if (!value) return 'not checked'
  if (value.success === false) return `fail (${value.error ?? 'unknown error'})`

  return `${value.count ?? 0} PNGs, unique:${value.uniqueDigestCount ?? '?'}, min ${value.minWidth ?? '?'}x${
    value.minHeight ?? '?'
  }, ${value.minBytes ?? '?'} bytes`
}

function formatBoolean(value) {
  if (value === true) return 'yes'
  if (value === false) return 'no'
  return 'unknown'
}

function formatStatus(success) {
  if (success === true) return 'pass'
  if (success === false) return 'fail'
  return 'unknown'
}

function positiveNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
}

function collectScreenshots(values) {
  return values.flatMap((value) => (Array.isArray(value?.screenshots) ? value.screenshots : []))
}

function relativePath(file) {
  return path.relative(repoRoot, path.resolve(file)).replaceAll(path.sep, '/')
}
