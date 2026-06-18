import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')

const outputFile = process.argv[2] ?? path.join(repoRoot, 'assets', 'demo', 'full-loop-report.md')
const desktopFile = process.argv[3] ?? path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const phoneFile = process.argv[4] ?? path.join(repoRoot, 'assets', 'demo', 'phone-loop.json')
const chromeFile = process.argv[6] ?? path.join(repoRoot, 'assets', 'demo', 'chrome-loop.json')
const summaryFile = process.argv[7] ?? defaultSummaryFile(outputFile)

const desktop = await readJsonIfExists(desktopFile)
const phone = await readJsonIfExists(phoneFile)
const chrome = await readJsonIfExists(chromeFile)
const browserParity = validateBrowserParity(desktop, chrome)
const requiredEvidence = validateEvidence({ desktop, phone, chrome })
const screenshots = collectScreenshots([desktop, chrome])
const manifest = await buildEvidenceManifest({ desktop, phone, chrome, screenshots })
const generatedAt = new Date().toISOString()
const summary = buildSummary({ generatedAt, desktop, phone, chrome, browserParity, requiredEvidence, manifest })

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
  '- The loop verifies a multimodal assistant path across desktop web, Windows Chrome, Android Chrome, edge API, and simulated room-terminal execution.',
  '- The phone proof covers front-camera preference, Web Speech readiness, visual scene capture, and guarded execution sync.',
  '- The desktop proof covers propose-only planning, web confirmation, offline fallback, and ESP32-style external confirmation sync.',
  '- The report is generated from local ignored evidence artifacts, keeping the public repository free of private screenshots and runtime logs.',
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

function buildSummary({ generatedAt, desktop, phone, chrome, browserParity, requiredEvidence, manifest }) {
  return {
    generatedAt,
    success: requiredEvidence.success,
    runId: requiredEvidence.runId,
    appUrl: desktop?.appUrl ?? chrome?.appUrl ?? phone?.appUrl ?? null,
    apiBase: desktop?.apiBase ?? chrome?.apiBase ?? phone?.apiBase ?? null,
    loops: {
      desktop: summarizeDesktopLoop(desktop),
      windowsChrome: summarizeDesktopLoop(chrome),
      phone: summarizePhoneLoop(phone),
    },
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
    firstViewportVisibility: summarizeFirstViewportVisibility(checks.firstViewportVisibility),
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
    frontCamera: {
      ready: checks.frontCamera?.ready ?? null,
      facingMode: checks.frontCamera?.facingMode ?? null,
      width: checks.frontCamera?.width ?? null,
      height: checks.frontCamera?.height ?? null,
      status: checks.frontCamera?.status ?? null,
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
    channel: value.channel ?? null,
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

async function buildEvidenceManifest({ desktop, phone, chrome, screenshots }) {
  const entries = []
  const jsonFiles = [
    ['Desktop JSON', desktopFile, Boolean(desktop)],
    ['Windows Chrome JSON', chromeFile, Boolean(chrome)],
    ['Phone JSON', phoneFile, Boolean(phone)],
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

function formatDesktop(value) {
  if (!value) {
    return ['- Not run.']
  }

  const checks = value.checks ?? {}
  return [
    `- Title: ${checks.localizedUi?.title ?? 'unknown'}`,
    `- Chinese text integrity: ${formatTextIntegrity(checks.localizedUi?.textIntegrity)}`,
    `- First viewport visibility: ${formatFirstViewportVisibility(checks.firstViewportVisibility)}`,
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

function validateEvidence({ desktop, phone, chrome }) {
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

function validateBrowserParity(desktop, chrome) {
  if (!isRequiredFile(desktopFile) || !isRequiredFile(chromeFile)) {
    return {
      checked: false,
      success: null,
      errors: [],
    }
  }

  const errors = []
  const desktopChecks = desktop?.checks ?? {}
  const chromeChecks = chrome?.checks ?? {}
  compareValue(errors, 'title', desktopChecks.localizedUi?.title, chromeChecks.localizedUi?.title)
  compareValue(
    errors,
    'text integrity mojibake count',
    desktopChecks.localizedUi?.textIntegrity?.mojibakeCount,
    chromeChecks.localizedUi?.textIntegrity?.mojibakeCount,
  )
  compareValue(
    errors,
    'text integrity missing phrase count',
    desktopChecks.localizedUi?.textIntegrity?.missingPhraseCount,
    chromeChecks.localizedUi?.textIntegrity?.missingPhraseCount,
  )
  compareValue(
    errors,
    'first viewport panel count',
    desktopChecks.firstViewportVisibility?.panels?.length,
    chromeChecks.firstViewportVisibility?.panels?.length,
  )
  compareValue(
    errors,
    'first viewport min visible ratio',
    desktopChecks.firstViewportVisibility?.minVisibleRatio,
    chromeChecks.firstViewportVisibility?.minVisibleRatio,
  )
  compareValue(errors, 'scene', desktopChecks.scenePromptHandoff?.scene, chromeChecks.scenePromptHandoff?.scene)
  compareValue(
    errors,
    'scene raw image retained',
    desktopChecks.scenePromptHandoff?.rawImageRetained,
    chromeChecks.scenePromptHandoff?.rawImageRetained,
  )
  compareValue(
    errors,
    'scene raw image echoed',
    desktopChecks.scenePromptHandoff?.rawImageEchoed,
    chromeChecks.scenePromptHandoff?.rawImageEchoed,
  )
  compareValue(errors, 'web confirmation source', desktopChecks.webConfirmExecute?.latestSource, chromeChecks.webConfirmExecute?.latestSource)
  compareValue(errors, 'offline fallback source', desktopChecks.offlineFallback?.latestSource, chromeChecks.offlineFallback?.latestSource)
  compareValue(
    errors,
    'external accepted action count',
    desktopChecks.externalExecutionSync?.acceptedActionCount,
    chromeChecks.externalExecutionSync?.acceptedActionCount,
  )
  compareValue(errors, 'external sync source', desktopChecks.externalExecutionSync?.latestSource, chromeChecks.externalExecutionSync?.latestSource)
  compareValue(errors, 'runtime issue count', desktopChecks.runtimeHealth?.issueCount, chromeChecks.runtimeHealth?.issueCount)
  compareValue(errors, 'screenshot count', desktopChecks.screenshotEvidence?.count, chromeChecks.screenshotEvidence?.count)
  compareValue(
    errors,
    'screenshot unique digest count',
    desktopChecks.screenshotEvidence?.uniqueDigestCount,
    chromeChecks.screenshotEvidence?.uniqueDigestCount,
  )

  const desktopLayout = layoutSignature(desktopChecks.responsiveLayout)
  const chromeLayout = layoutSignature(chromeChecks.responsiveLayout)
  compareValue(errors, 'responsive layout', desktopLayout, chromeLayout)

  return {
    checked: true,
    success: errors.length === 0,
    errors,
  }
}

function compareValue(errors, label, left, right) {
  if (left !== right) {
    errors.push(`${label} mismatch (${left ?? 'missing'} != ${right ?? 'missing'})`)
  }
}

function layoutSignature(value) {
  if (!Array.isArray(value)) return null
  return value
    .map(
      (item) =>
        `${item.label}:${item.overflowX}:${item.overflowingButtons?.length ?? 0}:${
          item.overlappingPanelPairs?.length ?? 0
        }:${item.panelCount ?? 'missing'}`,
    )
    .join('|')
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
  if (checks.frontCamera && checks.frontCamera.ready !== true) {
    errors.push('Phone front camera is not ready.')
  }
  if (checks.frontCamera?.facingMode && checks.frontCamera.facingMode !== 'user') {
    errors.push(`Phone camera facingMode is ${checks.frontCamera.facingMode}.`)
  }
  if (checks.runtimeHealth && checks.runtimeHealth.success !== true) {
    errors.push('Phone runtime health is not clean.')
  }
  if (checks.scene && checks.scene.rawImageNotRetained !== true) {
    errors.push('Phone scene privacy proof is incomplete.')
  }
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
    `- Front camera: ${camera.ready ? 'ready' : 'not ready'} (${camera.facingMode ?? 'unknown'}, ${camera.width ?? '?'}x${camera.height ?? '?'})`,
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
  const media = value.getUserMedia ? 'media:on' : 'media:off'
  const speech = value.speechRecognition ? 'speech:on' : 'speech:off'

  return `${value.browserName ?? browserFamily} (${browserFamily}, ${mode}, ${viewport.innerWidth ?? '?'}x${viewport.innerHeight ?? '?'}, dpr ${viewport.devicePixelRatio ?? '?'}, ${media}, ${speech})`
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

function collectScreenshots(values) {
  return values.flatMap((value) => (Array.isArray(value?.screenshots) ? value.screenshots : []))
}

function relativePath(file) {
  return path.relative(repoRoot, path.resolve(file)).replaceAll(path.sep, '/')
}
