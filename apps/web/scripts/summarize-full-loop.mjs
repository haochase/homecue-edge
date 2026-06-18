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
