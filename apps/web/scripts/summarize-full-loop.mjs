import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')

const outputFile = process.argv[2] ?? path.join(repoRoot, 'assets', 'demo', 'full-loop-report.md')
const desktopFile = process.argv[3] ?? path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const phoneFile = process.argv[4] ?? path.join(repoRoot, 'assets', 'demo', 'phone-loop.json')
const chromeFile = process.argv[6] ?? path.join(repoRoot, 'assets', 'demo', 'chrome-loop.json')

const desktop = await readJsonIfExists(desktopFile)
const phone = await readJsonIfExists(phoneFile)
const chrome = await readJsonIfExists(chromeFile)
const requiredEvidence = validateEvidence({ desktop, phone, chrome })
const screenshots = collectScreenshots([desktop, chrome])

const report = [
  '# Home AI Companion Loop Report',
  '',
  `Generated: ${new Date().toISOString()}`,
  '',
  '## Summary',
  '',
  `- Desktop loop: ${formatStatus(desktop?.success)}`,
  `- Windows Chrome loop: ${chrome ? formatStatus(chrome.success) : 'not run'}`,
  `- Phone loop: ${phone ? formatStatus(phone.success) : 'not run'}`,
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
  `- Desktop JSON: ${relativePath(desktopFile)}`,
  `- Windows Chrome JSON: ${chrome ? relativePath(chromeFile) : 'not run'}`,
  `- Phone JSON: ${phone ? relativePath(phoneFile) : 'not run'}`,
  ...screenshots.map((item) => `- Screenshot: ${item}`),
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
await writeFile(outputFile, report, 'utf8')
console.log(`Full loop report: ${outputFile}`)
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

function formatDesktop(value) {
  if (!value) {
    return ['- Not run.']
  }

  const checks = value.checks ?? {}
  return [
    `- Title: ${checks.localizedUi?.title ?? 'unknown'}`,
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

  if (isRequiredFile(desktopFile)) {
    validateDesktopEvidence('Desktop', desktop, errors)
  }
  if (isRequiredFile(phoneFile)) {
    validatePhoneEvidence(phone, errors)
  }
  if (isRequiredFile(chromeFile)) {
    validateDesktopEvidence('Windows Chrome', chrome, errors)
  }

  return {
    success: errors.length === 0,
    errors,
  }
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
  if (checks.scenePromptHandoff?.rawImageRetained !== false || checks.scenePromptHandoff?.rawImageEchoed !== false) {
    errors.push(`${label} scene privacy proof is incomplete.`)
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
  const labels = value.map((item) => `${item.label}:${item.overflowX}px`)
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

function formatScreenshotEvidence(value) {
  if (!value) return 'not checked'
  if (value.success === false) return `fail (${value.error ?? 'unknown error'})`

  return `${value.count ?? 0} PNGs, min ${value.minWidth ?? '?'}x${value.minHeight ?? '?'}, ${value.minBytes ?? '?'} bytes`
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
