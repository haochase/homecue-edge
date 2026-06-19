import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const evidenceFile = process.argv[2] ?? path.join(repoRoot, 'assets', 'demo', 'phone-loop.json')
const expectedAppUrl = process.argv[3] ?? null
const expectedApiBase = process.argv[4] ?? null
const expectedCdpEndpoint = process.argv[5] ?? null
const MIN_LOCALIZED_PHRASE_COUNT = 7

const evidence = JSON.parse(await readFile(evidenceFile, 'utf8'))
const errors = validatePhoneEvidence(evidence, { expectedAppUrl, expectedApiBase, expectedCdpEndpoint })

if (errors.length) {
  console.error(`Phone loop evidence validation failed: ${evidenceFile}`)
  for (const error of errors) {
    console.error(`- ${error}`)
  }
  process.exit(1)
}

console.log(`Phone loop evidence validation passed: ${evidenceFile}`)

function validatePhoneEvidence(value, { expectedAppUrl, expectedApiBase, expectedCdpEndpoint }) {
  const errors = []

  if (!value || typeof value !== 'object') {
    return ['Phone evidence root must be an object.']
  }

  if (value.success !== true) errors.push('success must be true.')
  assertString(errors, value.startedAt, 'startedAt')
  assertString(errors, value.finishedAt, 'finishedAt')
  assertString(errors, value.appUrl, 'appUrl')
  assertString(errors, value.apiBase, 'apiBase')
  assertString(errors, value.cdpEndpoint, 'cdpEndpoint')
  assertString(errors, value.pageUrl, 'pageUrl')

  if (expectedAppUrl !== null && value.appUrl !== expectedAppUrl) {
    errors.push(`appUrl must match expected value (${expectedAppUrl}).`)
  }
  if (expectedApiBase !== null && value.apiBase !== expectedApiBase) {
    errors.push(`apiBase must match expected value (${expectedApiBase}).`)
  }
  if (expectedCdpEndpoint !== null && value.cdpEndpoint !== expectedCdpEndpoint) {
    errors.push(`cdpEndpoint must match expected value (${expectedCdpEndpoint}).`)
  }

  validatePageUrl(errors, value.pageUrl, value.appUrl, value.apiBase)
  validateTiming(errors, value.startedAt, value.finishedAt)

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
  const missingChecks = requiredChecks.filter((name) => !checks[name])
  if (missingChecks.length) errors.push(`missing checks: ${missingChecks.join(', ')}.`)

  validateLocalizedUi(errors, checks.localizedUi)
  validateFrontCamera(errors, checks.frontCamera)
  validateScene(errors, checks.scene)
  validateScenePromptHandoff(errors, checks.scenePromptHandoff)
  validateSpeechInput(errors, checks.speechInput)
  validateExternalExecution(errors, checks.externalExecution)
  validateRuntimeHealth(errors, checks.runtimeHealth)

  return errors
}

function validatePageUrl(errors, pageUrl, appUrl, apiBase) {
  if (typeof pageUrl !== 'string' || typeof appUrl !== 'string' || typeof apiBase !== 'string') return

  let page
  let app
  try {
    page = new URL(pageUrl)
    app = new URL(appUrl)
  } catch {
    errors.push('pageUrl and appUrl must be valid URLs.')
    return
  }

  if (page.origin !== app.origin) errors.push('pageUrl origin must match appUrl origin.')
  if (page.searchParams.get('apiBase') !== apiBase) errors.push('pageUrl apiBase search param must match apiBase.')
}

function validateTiming(errors, startedAt, finishedAt) {
  const start = Date.parse(startedAt)
  const finish = Date.parse(finishedAt)

  if (!Number.isFinite(start)) errors.push('startedAt must be a valid timestamp.')
  if (!Number.isFinite(finish)) errors.push('finishedAt must be a valid timestamp.')
  if (Number.isFinite(start) && Number.isFinite(finish) && finish < start) {
    errors.push('finishedAt must not be earlier than startedAt.')
  }
}

function validateLocalizedUi(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.localizedUi is missing.')
    return
  }

  if (value.title !== '家庭智能管家') errors.push('checks.localizedUi.title must be 家庭智能管家.')
  if (value.voiceButton !== '语音输入') errors.push('checks.localizedUi.voiceButton must be 语音输入.')
  if (value.frontCameraButton !== '优先打开前置摄像头') {
    errors.push('checks.localizedUi.frontCameraButton must be 优先打开前置摄像头.')
  }
  validateTextIntegrity(errors, value.textIntegrity, 'checks.localizedUi.textIntegrity')
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

function validateFrontCamera(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.frontCamera is missing.')
    return
  }

  if (value.ready !== true) errors.push('checks.frontCamera.ready must be true.')
  if (value.facingMode !== 'user') errors.push('checks.frontCamera.facingMode must be user.')
  if (!positiveNumber(value.width) || !positiveNumber(value.height)) {
    errors.push('checks.frontCamera dimensions must be positive.')
  }
  if (value.active !== true) errors.push('checks.frontCamera.active must be true.')
  if (value.trackState !== 'live') errors.push('checks.frontCamera.trackState must be live.')
  if (typeof value.status !== 'string' || !value.status.includes('前置摄像头已就绪')) {
    errors.push('checks.frontCamera.status must confirm the front camera is ready.')
  }
  if (value.mirrored !== true) errors.push('checks.frontCamera.mirrored must be true.')
  if (!Array.isArray(value.classList) || !value.classList.includes('mirror')) {
    errors.push('checks.frontCamera.classList must include mirror.')
  }
  if (value.objectFit !== 'cover') errors.push('checks.frontCamera.objectFit must be cover.')
  if (value.error !== '') errors.push('checks.frontCamera.error must be empty.')
}

function validateScene(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.scene is missing.')
    return
  }

  assertString(errors, value.frameSize, 'checks.scene.frameSize')
  assertString(errors, value.sceneText, 'checks.scene.sceneText')
  if (value.rawImageRetained !== false) errors.push('checks.scene.rawImageRetained must be false.')
  if (value.rawImageNotRetained !== true) errors.push('checks.scene.rawImageNotRetained must be true.')
  if (typeof value.privacyText !== 'string' || !value.privacyText.includes('保留原始图像：否')) {
    errors.push('checks.scene.privacyText must prove raw image non-retention.')
  }
  if (!Array.isArray(value.observations) || !value.observations.includes('输入摄像头：手机')) {
    errors.push('checks.scene.observations must include the phone camera source.')
  }
  if (!Array.isArray(value.observations) || !value.observations.includes('已提供图像帧')) {
    errors.push('checks.scene.observations must include captured frame evidence.')
  }
}

function validateScenePromptHandoff(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.scenePromptHandoff is missing.')
    return
  }

  if (value.proposeOnly !== true) errors.push('checks.scenePromptHandoff.proposeOnly must be true.')
  if (typeof value.prompt !== 'string' || !value.prompt.includes('低负担')) {
    errors.push('checks.scenePromptHandoff.prompt must include the scene-derived low-effort request.')
  }
}

function validateSpeechInput(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.speechInput is missing.')
    return
  }

  if (!(value.support?.SpeechRecognition || value.support?.webkitSpeechRecognition)) {
    errors.push('checks.speechInput must prove Android Chrome speech recognition availability.')
  }
  if (value.skipped === true) errors.push('checks.speechInput.skipped must not be true.')
  if (value.listeningState?.buttonText !== '停止语音') {
    errors.push('checks.speechInput.listeningState.buttonText must be 停止语音.')
  }
  if (value.listeningState?.status !== '正在听...') {
    errors.push('checks.speechInput.listeningState.status must be 正在听...')
  }
  if (value.listeningState?.error !== '') {
    errors.push('checks.speechInput.listeningState.error must be empty.')
  }
}

function validateExternalExecution(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.externalExecution is missing.')
    return
  }

  if (!positiveNumber(value.acceptedActionCount)) {
    errors.push('checks.externalExecution.acceptedActionCount must be positive.')
  }
  if (value.apiSource !== 'esp32-serial') errors.push('checks.externalExecution.apiSource must be esp32-serial.')
  if (value.latestSource !== 'esp32-serial') errors.push('checks.externalExecution.latestSource must be esp32-serial.')
  if (!positiveNumber(value.apiSequence) || !positiveNumber(value.latestSequence)) {
    errors.push('checks.externalExecution sequence values must be positive.')
  }
  if (value.apiSequence !== value.latestSequence) {
    errors.push('checks.externalExecution apiSequence must match latestSequence.')
  }
  if (value.syncedState?.planStatus !== '已本地执行') {
    errors.push('checks.externalExecution.syncedState.planStatus must be 已本地执行.')
  }
  if (typeof value.syncedState?.sourceText !== 'string' || !value.syncedState.sourceText.includes('ESP32 串口')) {
    errors.push('checks.externalExecution.syncedState.sourceText must identify ESP32 串口.')
  }
}

function validateRuntimeHealth(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('checks.runtimeHealth is missing.')
    return
  }

  if (value.success !== true) errors.push('checks.runtimeHealth.success must be true.')
  if (value.issueCount !== 0) errors.push('checks.runtimeHealth.issueCount must be 0.')
  for (const key of ['consoleErrors', 'pageErrors', 'requestFailures', 'httpErrors']) {
    if (value.counts?.[key] !== 0) errors.push(`checks.runtimeHealth.counts.${key} must be 0.`)
  }
}

function assertString(errors, value, label) {
  if (typeof value !== 'string' || !value.trim()) errors.push(`${label} must be a non-empty string.`)
}

function positiveNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
}
