import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { assertAsciiSafeJsonText } from './json-file.mjs'
import { parseResultValidatorCliOptions, validateResultFreshness } from './result-validator-cli.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const defaultResultFile = path.join(repoRoot, 'assets', 'tmp', 'device-loop-check.json')
const cliOptions = parseResultValidatorCliOptions(process.argv.slice(2))
const resultFile = resolveCliPath(cliOptions.resultFile ?? defaultResultFile)
const REQUIRED_SERIAL_CHECKS = [
  'boot banner',
  'button-route mode',
  'BOOT fallback',
  'WiFi connected',
  'gateway health',
  'plan trigger',
  'plan proposal',
  'confirm trigger',
  'execute confirmation',
]
const SERIAL_LOG_MARKERS = [
  '[HomeCue Edge]',
  '[/health] HTTP 200',
  '> serial homecue:plan',
  '[/plan] proposed',
  '> serial homecue:execute',
  'exec ',
  ' -> accepted',
]

const errors = []
const result = await readResultJson(errors, resultFile)
if (result) {
  errors.push(...(await validateDeviceLoopResult(result, resultFile, cliOptions)))
}

if (errors.length) {
  console.error(`Device loop result validation failed: ${resultFile}`)
  for (const error of errors) {
    console.error(`- ${error}`)
  }
  process.exit(1)
}

console.log(`Device loop result validation passed: ${resultFile}`)
if (result.mode === 'validate') {
  console.log(formatProofSummary(result.proofSummary, result.sourceState))
}

async function readResultJson(errors, file) {
  try {
    const text = await readFile(file, 'utf8')
    assertAsciiSafeJsonText(text, 'device loop result')
    return JSON.parse(text)
  } catch (error) {
    errors.push(`device loop result JSON cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

async function validateDeviceLoopResult(value, validatedResultFile, options = {}) {
  const errors = []

  if (!value || typeof value !== 'object') {
    return ['Device loop result root must be an object.']
  }

  validateAllowedKeys(
    errors,
    value,
    [
      'generatedAt',
      'success',
      'mode',
      'runId',
      'sourceState',
      'plan',
      'checks',
      'proofSummary',
      'browserEvidence',
      'esp32Serial',
      'failure',
    ],
    'result root',
  )
  assertString(errors, value.generatedAt, 'generatedAt')
  if (!Number.isFinite(Date.parse(value.generatedAt))) errors.push('generatedAt must be a valid timestamp.')
  validateResultFreshness(errors, value.generatedAt, options.maxAgeMinutes)
  if (!['dry-run', 'validate', 'failed'].includes(value.mode)) errors.push('mode must be dry-run, validate, or failed.')
  if (value.mode === 'failed') {
    if (value.success !== false) errors.push('success must be false in failed mode.')
  } else if (value.success !== true) {
    errors.push('success must be true.')
  }
  assertString(errors, value.runId, 'runId')
  if (value.plan?.runId && value.runId !== value.plan.runId) errors.push('runId must match plan.runId.')

  validateSourceState(errors, value.sourceState)
  validatePlan(errors, value.plan, validatedResultFile)
  validateChecks(errors, value.checks, value.plan)

  if (value.mode === 'validate') {
    await validateValidateMode(errors, value, options)
  } else if (value.mode === 'failed') {
    validateFailedMode(errors, value)
  } else {
    if (value.proofSummary !== null && value.proofSummary !== undefined) {
      errors.push('proofSummary must be null or omitted in dry-run mode.')
    }
    if (value.browserEvidence !== null && value.browserEvidence !== undefined) {
      errors.push('browserEvidence must be null or omitted in dry-run mode.')
    }
    if (
      value.esp32Serial &&
      (value.esp32Serial.liveCapture !== null || value.esp32Serial.savedLogRecheck !== null)
    ) {
      errors.push('esp32Serial liveCapture and savedLogRecheck must be null in dry-run mode.')
    }
  }

  return errors
}

function validateSourceState(errors, sourceState, label = 'sourceState') {
  if (!sourceState || typeof sourceState !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  validateAllowedKeys(errors, sourceState, ['branch', 'commit', 'dirty', 'statusCount', 'statusSha256'], label)
  assertString(errors, sourceState.branch, `${label}.branch`)
  assertString(errors, sourceState.commit, `${label}.commit`)
  if (typeof sourceState.commit === 'string' && !/^[0-9a-f]{40}$/i.test(sourceState.commit)) {
    errors.push(`${label}.commit must be a 40-character git commit hash.`)
  }
  if (typeof sourceState.dirty !== 'boolean') errors.push(`${label}.dirty must be boolean.`)
  if (!Number.isInteger(sourceState.statusCount) || sourceState.statusCount < 0) {
    errors.push(`${label}.statusCount must be a non-negative integer.`)
  }
  assertString(errors, sourceState.statusSha256, `${label}.statusSha256`)
  if (typeof sourceState.statusSha256 === 'string' && !/^[0-9a-f]{12}$/i.test(sourceState.statusSha256)) {
    errors.push(`${label}.statusSha256 must be a 12-character SHA-256 prefix.`)
  }

  const actual = readCurrentSourceState(errors)
  if (!actual) return

  for (const key of ['branch', 'commit', 'dirty', 'statusCount', 'statusSha256']) {
    if (sourceState[key] !== actual[key]) {
      errors.push(`${label}.${key} must match current git ${key}.`)
    }
  }
}

function readCurrentSourceState(errors) {
  try {
    const branch = gitOutput(['rev-parse', '--abbrev-ref', 'HEAD'])
    const commit = gitOutput(['rev-parse', 'HEAD'])
    const statusText = execFileSync('git', ['status', '--short'], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trimEnd()
    const statusLines = statusText ? statusText.split(/\r?\n/) : []

    return {
      branch,
      commit,
      dirty: statusLines.length > 0,
      statusCount: statusLines.length,
      statusSha256: createHash('sha256').update(statusText).digest('hex').slice(0, 12),
    }
  } catch (error) {
    errors.push(`sourceState cannot be checked against current git state: ${error?.message ?? error}`)
    return null
  }
}

function gitOutput(args) {
  return execFileSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim()
}

function validatePlan(errors, plan, validatedResultFile) {
  if (!plan || typeof plan !== 'object') {
    errors.push('plan is missing.')
    return
  }

  validateAllowedKeys(
    errors,
    plan,
    ['runId', 'requestedLoops', 'options', 'outputs', 'expectedEvidence', 'gates', 'hardware', 'commands'],
    'plan',
  )
  assertString(errors, plan.runId, 'plan.runId')
  validateRequestedLoops(errors, plan.requestedLoops)
  validateOptions(errors, plan.options)
  validateOutputs(errors, plan.outputs, validatedResultFile)
  validateExpectedEvidence(errors, plan.expectedEvidence, plan.outputs)
  validateGates(errors, plan.gates)
  validateHardware(errors, plan.hardware)
  validateCommands(errors, plan.commands)
  validatePlanConsistency(errors, plan)
}

function validateRequestedLoops(errors, value) {
  validateAllowedKeys(errors, value, ['desktop', 'phone', 'windowsChrome', 'esp32Serial'], 'plan.requestedLoops')
  for (const key of ['desktop', 'phone', 'windowsChrome', 'esp32Serial']) {
    if (value?.[key] !== true) errors.push(`plan.requestedLoops.${key} must be true.`)
  }
}

function validateOptions(errors, value) {
  validateAllowedKeys(
    errors,
    value,
    [
      'skipPreflight',
      'selfTest',
      'adbPathProvided',
      'startupTimeoutSeconds',
      'stepTimeoutSeconds',
      'browserWrapperSharedStateLockTimeoutSeconds',
      'maxAgeMinutes',
    ],
    'plan.options',
  )
  for (const key of ['skipPreflight', 'selfTest', 'adbPathProvided']) {
    if (typeof value?.[key] !== 'boolean') errors.push(`plan.options.${key} must be boolean.`)
  }
  for (const key of ['startupTimeoutSeconds', 'stepTimeoutSeconds', 'browserWrapperSharedStateLockTimeoutSeconds']) {
    if (!positiveInteger(value?.[key])) errors.push(`plan.options.${key} must be a positive integer.`)
  }
  if (value?.maxAgeMinutes !== null && value?.maxAgeMinutes !== undefined) {
    if (typeof value.maxAgeMinutes !== 'number' || !Number.isFinite(value.maxAgeMinutes) || value.maxAgeMinutes <= 0) {
      errors.push('plan.options.maxAgeMinutes must be null or a positive number.')
    }
  }
}

function validateOutputs(errors, outputs, validatedResultFile) {
  validateAllowedKeys(
    errors,
    outputs,
    [
      'outputDir',
      'reportPath',
      'summaryPath',
      'resultJsonPath',
      'browserEvidenceResultJsonPath',
      'esp32SerialLogPath',
      'esp32SerialResultJsonPath',
      'esp32SerialRecheckResultJsonPath',
    ],
    'plan.outputs',
  )
  for (const key of [
    'outputDir',
    'reportPath',
    'summaryPath',
    'resultJsonPath',
    'browserEvidenceResultJsonPath',
    'esp32SerialLogPath',
    'esp32SerialResultJsonPath',
    'esp32SerialRecheckResultJsonPath',
  ]) {
    assertString(errors, outputs?.[key], `plan.outputs.${key}`)
    validateRepoPath(errors, outputs?.[key], `plan.outputs.${key}`)
    validatePortableRepoPath(errors, outputs?.[key], `plan.outputs.${key}`)
  }
  compareRepoPaths(errors, outputs?.resultJsonPath, validatedResultFile, 'plan.outputs.resultJsonPath', 'validated result file')
  for (const key of [
    'reportPath',
    'summaryPath',
    'browserEvidenceResultJsonPath',
    'esp32SerialLogPath',
    'esp32SerialResultJsonPath',
    'esp32SerialRecheckResultJsonPath',
  ]) {
    if (!isInsidePath(outputs?.[key], outputs?.outputDir)) {
      errors.push(`plan.outputs.${key} must be inside plan.outputs.outputDir.`)
    }
  }
}

function validateExpectedEvidence(errors, expectedEvidence, outputs) {
  validateAllowedKeys(
    errors,
    expectedEvidence,
    ['desktopEvidence', 'phoneEvidence', 'windowsChromeEvidence', 'esp32SerialLog', 'esp32SerialResult'],
    'plan.expectedEvidence',
  )
  for (const key of ['desktopEvidence', 'phoneEvidence', 'windowsChromeEvidence']) {
    if (expectedEvidence?.[key] !== 'required-from-summary') {
      errors.push(`plan.expectedEvidence.${key} must be required-from-summary.`)
    }
  }
  compareRepoPaths(
    errors,
    expectedEvidence?.esp32SerialLog,
    outputs?.esp32SerialLogPath,
    'plan.expectedEvidence.esp32SerialLog',
    'plan.outputs.esp32SerialLogPath',
  )
  compareRepoPaths(
    errors,
    expectedEvidence?.esp32SerialResult,
    outputs?.esp32SerialResultJsonPath,
    'plan.expectedEvidence.esp32SerialResult',
    'plan.outputs.esp32SerialResultJsonPath',
  )
}

function validateGates(errors, gates) {
  validateAllowedKeys(
    errors,
    gates,
    [
      'fullLoopIncludePhone',
      'fullLoopIncludeChrome',
      'fullLoopIncludeEsp32Serial',
      'fullLoopIsolateEvidence',
      'browserEvidenceRequireDesktop',
      'browserEvidenceRequirePhone',
      'browserEvidenceRequireChrome',
      'browserEvidenceSelfTest',
      'browserWrapperSharedStateLock',
      'fullLoopWebReadiness',
      'esp32Serial',
    ],
    'plan.gates',
  )
  for (const key of [
    'fullLoopIncludePhone',
    'fullLoopIncludeChrome',
    'fullLoopIncludeEsp32Serial',
    'fullLoopIsolateEvidence',
    'browserEvidenceRequireDesktop',
    'browserEvidenceRequirePhone',
    'browserEvidenceRequireChrome',
  ]) {
    if (gates?.[key] !== true) errors.push(`plan.gates.${key} must be true.`)
  }
  if (typeof gates?.browserEvidenceSelfTest !== 'boolean') {
    errors.push('plan.gates.browserEvidenceSelfTest must be boolean.')
  }
  validateAllowedKeys(errors, gates?.browserWrapperSharedStateLock, ['name', 'timeoutSeconds'], 'plan.gates.browserWrapperSharedStateLock')
  if (gates?.browserWrapperSharedStateLock?.name !== 'Global\\HCEdgeBrowserLoopGate') {
    errors.push('plan.gates.browserWrapperSharedStateLock.name must be Global\\HCEdgeBrowserLoopGate.')
  }
  if (!positiveInteger(gates?.browserWrapperSharedStateLock?.timeoutSeconds)) {
    errors.push('plan.gates.browserWrapperSharedStateLock.timeoutSeconds must be a positive integer.')
  }
  validateAllowedKeys(
    errors,
    gates?.fullLoopWebReadiness,
    ['httpProbeBeforePortReuse', 'stalePortBlocksDuplicateStart', 'lanReachabilityForEsp32'],
    'plan.gates.fullLoopWebReadiness',
  )
  for (const key of ['httpProbeBeforePortReuse', 'stalePortBlocksDuplicateStart', 'lanReachabilityForEsp32']) {
    if (gates?.fullLoopWebReadiness?.[key] !== true) errors.push(`plan.gates.fullLoopWebReadiness.${key} must be true.`)
  }
  validateAllowedKeys(
    errors,
    gates?.esp32Serial,
    ['run', 'firmwareFlowRequired', 'autoSerialLevel4', 'requireInteraction', 'savedLogRecheck'],
    'plan.gates.esp32Serial',
  )
  for (const key of ['run', 'firmwareFlowRequired', 'autoSerialLevel4', 'requireInteraction', 'savedLogRecheck']) {
    if (gates?.esp32Serial?.[key] !== true) errors.push(`plan.gates.esp32Serial.${key} must be true.`)
  }
}

function validateHardware(errors, hardware) {
  validateAllowedKeys(errors, hardware, ['esp32Serial'], 'plan.hardware')
  validateAllowedKeys(
    errors,
    hardware?.esp32Serial,
    ['run', 'port', 'baud', 'seconds', 'serialCommandIndex', 'skipReset'],
    'plan.hardware.esp32Serial',
  )
  if (hardware?.esp32Serial?.run !== true) errors.push('plan.hardware.esp32Serial.run must be true.')
  assertString(errors, hardware?.esp32Serial?.port, 'plan.hardware.esp32Serial.port')
  for (const key of ['baud', 'seconds', 'serialCommandIndex']) {
    if (!Number.isInteger(hardware?.esp32Serial?.[key]) || hardware.esp32Serial[key] < 0) {
      errors.push(`plan.hardware.esp32Serial.${key} must be a non-negative integer.`)
    }
  }
  if (typeof hardware?.esp32Serial?.skipReset !== 'boolean') {
    errors.push('plan.hardware.esp32Serial.skipReset must be boolean.')
  }
}

function validateCommands(errors, commands) {
  validateAllowedKeys(errors, commands, ['fullLoop', 'browserEvidence', 'esp32SerialRecheck'], 'plan.commands')
  validateCommand(errors, commands?.fullLoop, 'plan.commands.fullLoop')
  validateCommand(errors, commands?.browserEvidence, 'plan.commands.browserEvidence')
  validateCommand(errors, commands?.esp32SerialRecheck, 'plan.commands.esp32SerialRecheck')
}

function validateCommand(errors, command, label) {
  validateAllowedKeys(errors, command, ['executable', 'args', 'display'], label)
  if (command?.executable !== 'powershell') errors.push(`${label}.executable must be powershell.`)
  if (!Array.isArray(command?.args)) errors.push(`${label}.args must be an array.`)
  assertString(errors, command?.display, `${label}.display`)
}

function validatePlanConsistency(errors, plan) {
  const { commands = {}, gates = {}, hardware = {}, options = {}, outputs = {} } = plan

  validateCommandFlag(errors, commands.fullLoop?.args, '-IncludePhone', true, 'plan.commands.fullLoop -IncludePhone')
  validateCommandFlag(errors, commands.fullLoop?.args, '-IncludeChrome', true, 'plan.commands.fullLoop -IncludeChrome')
  validateCommandFlag(errors, commands.fullLoop?.args, '-IncludeEsp32Serial', true, 'plan.commands.fullLoop -IncludeEsp32Serial')
  validateCommandFlag(errors, commands.fullLoop?.args, '-IsolateEvidence', true, 'plan.commands.fullLoop -IsolateEvidence')
  validateCommandFlag(errors, commands.fullLoop?.args, '-SkipPreflight', options.skipPreflight === true, 'plan.commands.fullLoop -SkipPreflight')
  validateCommandArgPath(errors, commands.fullLoop?.args, '-File', 'scripts/check-full-loop.ps1', 'plan.commands.fullLoop -File')
  validateCommandArgPath(errors, commands.fullLoop?.args, '-PartialEvidenceDir', outputs.outputDir, 'plan.commands.fullLoop -PartialEvidenceDir')
  validateCommandArgPath(errors, commands.fullLoop?.args, '-ReportPath', outputs.reportPath, 'plan.commands.fullLoop -ReportPath')
  validateCommandArgPath(errors, commands.fullLoop?.args, '-SummaryPath', outputs.summaryPath, 'plan.commands.fullLoop -SummaryPath')
  validateCommandArgValue(errors, commands.fullLoop?.args, '-StartupTimeoutSeconds', options.startupTimeoutSeconds, 'plan.commands.fullLoop -StartupTimeoutSeconds')
  validateCommandArgValue(errors, commands.fullLoop?.args, '-StepTimeoutSeconds', options.stepTimeoutSeconds, 'plan.commands.fullLoop -StepTimeoutSeconds')
  validateCommandArgValue(
    errors,
    commands.fullLoop?.args,
    '-BrowserWrapperSharedStateLockTimeoutSeconds',
    options.browserWrapperSharedStateLockTimeoutSeconds,
    'plan.commands.fullLoop -BrowserWrapperSharedStateLockTimeoutSeconds',
  )
  validateCommandArgValue(errors, commands.fullLoop?.args, '-Esp32Port', hardware.esp32Serial?.port, 'plan.commands.fullLoop -Esp32Port')
  validateCommandArgValue(errors, commands.fullLoop?.args, '-Esp32Baud', hardware.esp32Serial?.baud, 'plan.commands.fullLoop -Esp32Baud')
  validateCommandArgValue(
    errors,
    commands.fullLoop?.args,
    '-Esp32SerialSeconds',
    hardware.esp32Serial?.seconds,
    'plan.commands.fullLoop -Esp32SerialSeconds',
  )
  validateCommandArgValue(
    errors,
    commands.fullLoop?.args,
    '-Esp32SerialCommandIndex',
    hardware.esp32Serial?.serialCommandIndex,
    'plan.commands.fullLoop -Esp32SerialCommandIndex',
  )
  validateCommandFlag(errors, commands.fullLoop?.args, '-Esp32SkipReset', hardware.esp32Serial?.skipReset === true, 'plan.commands.fullLoop -Esp32SkipReset')

  validateCommandFlag(errors, commands.browserEvidence?.args, '-RequireDesktop', true, 'plan.commands.browserEvidence -RequireDesktop')
  validateCommandFlag(errors, commands.browserEvidence?.args, '-RequirePhone', true, 'plan.commands.browserEvidence -RequirePhone')
  validateCommandFlag(errors, commands.browserEvidence?.args, '-RequireChrome', true, 'plan.commands.browserEvidence -RequireChrome')
  validateCommandFlag(errors, commands.browserEvidence?.args, '-SelfTest', gates.browserEvidenceSelfTest === true, 'plan.commands.browserEvidence -SelfTest')
  validateCommandArgPath(errors, commands.browserEvidence?.args, '-File', 'scripts/check-browser-evidence.ps1', 'plan.commands.browserEvidence -File')
  validateCommandArgPath(errors, commands.browserEvidence?.args, '-SummaryPath', outputs.summaryPath, 'plan.commands.browserEvidence -SummaryPath')
  validateCommandArgPath(
    errors,
    commands.browserEvidence?.args,
    '-ResultJsonPath',
    outputs.browserEvidenceResultJsonPath,
    'plan.commands.browserEvidence -ResultJsonPath',
  )
  validateOptionalPositiveNumberCommandArg(
    errors,
    commands.browserEvidence?.args,
    '-MaxAgeMinutes',
    options.maxAgeMinutes,
    'plan.commands.browserEvidence -MaxAgeMinutes',
  )

  validateCommandFlag(errors, commands.esp32SerialRecheck?.args, '-RequireInteraction', true, 'plan.commands.esp32SerialRecheck -RequireInteraction')
  validateCommandFlag(errors, commands.esp32SerialRecheck?.args, '-Required', true, 'plan.commands.esp32SerialRecheck -Required')
  validateCommandArgPath(errors, commands.esp32SerialRecheck?.args, '-File', 'scripts/check-esp32-serial-log.ps1', 'plan.commands.esp32SerialRecheck -File')
  validateCommandArgPath(errors, commands.esp32SerialRecheck?.args, '-LogPath', outputs.esp32SerialLogPath, 'plan.commands.esp32SerialRecheck -LogPath')
  validateCommandArgPath(
    errors,
    commands.esp32SerialRecheck?.args,
    '-ResultJsonPath',
    outputs.esp32SerialRecheckResultJsonPath,
    'plan.commands.esp32SerialRecheck -ResultJsonPath',
  )
}

function validateChecks(errors, checks, plan) {
  if (!Array.isArray(checks)) {
    errors.push('checks must be an array.')
    return
  }

  if (checks.length !== 3) errors.push('checks must contain exactly 3 entries for device-loop result.')
  const expectedNames = ['full device loop', 'saved browser evidence recheck', 'saved ESP32 serial log recheck']
  const actualNames = checks.map((check) => check?.name)
  if (stableJson(actualNames) !== stableJson(expectedNames)) errors.push('checks order must match device-loop plan.')

  const fullLoop = checks[0] ?? {}
  validateAllowedKeys(errors, fullLoop, ['name', 'command', 'required', 'summaryPath', 'reportPath', 'esp32SerialLogPath', 'esp32SerialResultJsonPath'], 'full device loop check')
  if (fullLoop.required !== true) errors.push('full device loop check must be required.')
  if (fullLoop.command !== plan?.commands?.fullLoop?.display) errors.push('full device loop check command must match plan command.')
  compareRepoPaths(errors, fullLoop.summaryPath, plan?.outputs?.summaryPath, 'full device loop check summaryPath', 'plan.outputs.summaryPath')
  compareRepoPaths(errors, fullLoop.reportPath, plan?.outputs?.reportPath, 'full device loop check reportPath', 'plan.outputs.reportPath')
  compareRepoPaths(errors, fullLoop.esp32SerialLogPath, plan?.outputs?.esp32SerialLogPath, 'full device loop check esp32SerialLogPath', 'plan.outputs.esp32SerialLogPath')
  compareRepoPaths(
    errors,
    fullLoop.esp32SerialResultJsonPath,
    plan?.outputs?.esp32SerialResultJsonPath,
    'full device loop check esp32SerialResultJsonPath',
    'plan.outputs.esp32SerialResultJsonPath',
  )

  const browser = checks[1] ?? {}
  validateAllowedKeys(errors, browser, ['name', 'command', 'required', 'resultJsonPath'], 'saved browser evidence recheck')
  if (browser.required !== true) errors.push('saved browser evidence recheck must be required.')
  if (browser.command !== plan?.commands?.browserEvidence?.display) {
    errors.push('saved browser evidence recheck command must match plan command.')
  }
  compareRepoPaths(errors, browser.resultJsonPath, plan?.outputs?.browserEvidenceResultJsonPath, 'saved browser evidence resultJsonPath', 'plan.outputs.browserEvidenceResultJsonPath')

  const serial = checks[2] ?? {}
  validateAllowedKeys(errors, serial, ['name', 'command', 'required', 'logPath', 'resultJsonPath'], 'saved ESP32 serial log recheck')
  if (serial.required !== true) errors.push('saved ESP32 serial log recheck must be required.')
  if (serial.command !== plan?.commands?.esp32SerialRecheck?.display) {
    errors.push('saved ESP32 serial log recheck command must match plan command.')
  }
  compareRepoPaths(errors, serial.logPath, plan?.outputs?.esp32SerialLogPath, 'saved ESP32 serial log recheck logPath', 'plan.outputs.esp32SerialLogPath')
  compareRepoPaths(
    errors,
    serial.resultJsonPath,
    plan?.outputs?.esp32SerialRecheckResultJsonPath,
    'saved ESP32 serial log recheck resultJsonPath',
    'plan.outputs.esp32SerialRecheckResultJsonPath',
  )
}

async function validateValidateMode(errors, result, options) {
  if (!result.proofSummary || typeof result.proofSummary !== 'object') {
    errors.push('proofSummary is missing in validate mode.')
    return
  }
  if (!result.browserEvidence || typeof result.browserEvidence !== 'object') {
    errors.push('browserEvidence is missing in validate mode.')
    return
  }
  if (!result.esp32Serial || typeof result.esp32Serial !== 'object') {
    errors.push('esp32Serial is missing in validate mode.')
    return
  }

  validateResultFreshness(errors, result.browserEvidence.generatedAt, options.maxAgeMinutes, 'browserEvidence.generatedAt')
  const summary = await readReferencedJson(errors, result.plan.outputs.summaryPath, 'plan.outputs.summaryPath')
  await assertExistingFile(errors, result.plan.outputs.reportPath, 'plan.outputs.reportPath')
  const referencedBrowserEvidence = await readReferencedJson(errors, result.plan.outputs.browserEvidenceResultJsonPath, 'plan.outputs.browserEvidenceResultJsonPath')
  compareStableJson(errors, result.browserEvidence, referencedBrowserEvidence, 'browserEvidence', 'referenced browser evidence result')
  validateBrowserEvidence(errors, result.browserEvidence, result)
  validateProofSummary(errors, result.proofSummary, result.plan, summary, result.browserEvidence)

  const liveSerial = await readReferencedJson(errors, result.plan.outputs.esp32SerialResultJsonPath, 'plan.outputs.esp32SerialResultJsonPath')
  const recheckSerial = await readReferencedJson(errors, result.plan.outputs.esp32SerialRecheckResultJsonPath, 'plan.outputs.esp32SerialRecheckResultJsonPath')
  compareStableJson(errors, result.esp32Serial.liveCapture, liveSerial, 'esp32Serial.liveCapture', 'referenced ESP32 live result')
  compareStableJson(errors, result.esp32Serial.savedLogRecheck, recheckSerial, 'esp32Serial.savedLogRecheck', 'referenced ESP32 saved-log result')
  await validateSerialEvidence(errors, result, result.esp32Serial.liveCapture, result.esp32Serial.savedLogRecheck)
}

function validateBrowserEvidence(errors, browserEvidence, result) {
  validateAllowedKeys(
    errors,
    browserEvidence,
    ['generatedAt', 'success', 'mode', 'sourceState', 'plan', 'checks', 'proofSummary'],
    'browserEvidence',
  )
  if (browserEvidence.success !== true) errors.push('browserEvidence.success must be true.')
  if (browserEvidence.mode !== 'validate') errors.push('browserEvidence.mode must be validate.')
  compareStableJson(errors, browserEvidence.sourceState, result.sourceState, 'browserEvidence.sourceState', 'sourceState')
  if (browserEvidence.plan?.requiredEvidence?.desktop !== true) errors.push('browserEvidence.plan.requiredEvidence.desktop must be true.')
  if (browserEvidence.plan?.requiredEvidence?.phone !== true) errors.push('browserEvidence.plan.requiredEvidence.phone must be true.')
  if (browserEvidence.plan?.requiredEvidence?.windowsChrome !== true) {
    errors.push('browserEvidence.plan.requiredEvidence.windowsChrome must be true.')
  }
  compareRepoPaths(errors, browserEvidence.plan?.summaryPath, result.plan.outputs.summaryPath, 'browserEvidence.plan.summaryPath', 'plan.outputs.summaryPath')
  compareRepoPaths(
    errors,
    browserEvidence.plan?.resultJsonPath,
    result.plan.outputs.browserEvidenceResultJsonPath,
    'browserEvidence.plan.resultJsonPath',
    'plan.outputs.browserEvidenceResultJsonPath',
  )
  if (browserEvidence.plan?.options?.maxAgeMinutes !== result.plan.options?.maxAgeMinutes) {
    errors.push('browserEvidence.plan.options.maxAgeMinutes must match plan.options.maxAgeMinutes.')
  }
  for (const key of ['desktopEvidence', 'desktopScreenshotDir', 'phoneEvidence', 'windowsChromeEvidence', 'windowsChromeScreenshotDir']) {
    const value = browserEvidence.plan?.paths?.[key]
    validateRepoPath(errors, value, `browserEvidence.plan.paths.${key}`)
    validatePortableRepoPath(errors, value, `browserEvidence.plan.paths.${key}`)
    if (!isInsidePath(value, result.plan.outputs.outputDir)) {
      errors.push(`browserEvidence.plan.paths.${key} must be inside plan.outputs.outputDir.`)
    }
  }
}

function validateProofSummary(errors, proofSummary, plan, summary, browserEvidence) {
  validateAllowedKeys(
    errors,
    proofSummary,
    ['summaryRunId', 'appUrl', 'apiBase', 'requestedLoops', 'browserParity', 'webReadiness', 'loops', 'hardware', 'evidence'],
    'proofSummary',
  )
  if (!summary) return
  compareValue(errors, proofSummary.summaryRunId, summary.runId, 'proofSummary.summaryRunId', 'summary.runId')
  compareValue(errors, proofSummary.appUrl, summary.appUrl, 'proofSummary.appUrl', 'summary.appUrl')
  compareValue(errors, proofSummary.apiBase, summary.apiBase, 'proofSummary.apiBase', 'summary.apiBase')
  compareStableJson(errors, proofSummary.requestedLoops, plan.requestedLoops, 'proofSummary.requestedLoops', 'plan.requestedLoops')
  validateProofSummaryParity(errors, proofSummary.browserParity, summary.browserParity)
  validateProofSummaryWebReadiness(errors, proofSummary.webReadiness, summary.environment?.webReadiness)
  validateLoopProof(errors, proofSummary.loops?.desktop, summary.loops?.desktop, 'proofSummary.loops.desktop')
  validateLoopProof(errors, proofSummary.loops?.windowsChrome, summary.loops?.windowsChrome, 'proofSummary.loops.windowsChrome')
  validatePhoneProof(errors, proofSummary.loops?.phone, summary.loops?.phone)
  validateHardwareProof(errors, proofSummary.hardware?.esp32Serial, plan)
  validateProofEvidence(errors, proofSummary.evidence, plan, browserEvidence)
}

function validateProofSummaryParity(errors, proof, summary) {
  validateAllowedKeys(errors, proof, ['checked', 'success', 'errorCount'], 'proofSummary.browserParity')
  compareValue(errors, proof?.checked, summary?.checked, 'proofSummary.browserParity.checked', 'summary.browserParity.checked')
  compareValue(errors, proof?.success, summary?.success, 'proofSummary.browserParity.success', 'summary.browserParity.success')
  compareValue(errors, proof?.errorCount, Array.isArray(summary?.errors) ? summary.errors.length : 0, 'proofSummary.browserParity.errorCount', 'summary.browserParity.errors length')
}

function validateProofSummaryWebReadiness(errors, proof, summary) {
  validateAllowedKeys(errors, proof, ['run', 'success', 'strategy', 'httpReadyAfter', 'duplicateStartAvoided'], 'proofSummary.webReadiness')
  for (const key of ['run', 'success', 'strategy', 'httpReadyAfter', 'duplicateStartAvoided']) {
    compareValue(errors, proof?.[key], summary?.[key], `proofSummary.webReadiness.${key}`, `summary.environment.webReadiness.${key}`)
  }
}

function validateLoopProof(errors, proof, summary, label) {
  validateAllowedKeys(
    errors,
    proof,
    [
      'run',
      'success',
      'title',
      'runButton',
      'textRequiredPhrases',
      'textMissingPhrases',
      'textMojibake',
      'firstViewportMinVisibleRatio',
      'runtimeIssueCount',
      'screenshotCount',
      'uniqueScreenshotDigestCount',
      'externalExecutionSource',
      'acceptedActionCount',
    ],
    label,
  )
  compareValue(errors, proof?.run, summary?.run, `${label}.run`, 'summary loop run')
  compareValue(errors, proof?.success, summary?.success, `${label}.success`, 'summary loop success')
  compareValue(errors, proof?.title, summary?.title, `${label}.title`, 'summary loop title')
  compareValue(errors, proof?.runButton, summary?.localizedUi?.runButton, `${label}.runButton`, 'summary loop run button')
  compareValue(errors, proof?.textRequiredPhrases, summary?.textIntegrity?.requiredPhraseCount, `${label}.textRequiredPhrases`, 'summary loop text required')
  compareValue(errors, proof?.textMissingPhrases, summary?.textIntegrity?.missingPhraseCount, `${label}.textMissingPhrases`, 'summary loop text missing')
  compareValue(errors, proof?.textMojibake, summary?.textIntegrity?.mojibakeCount, `${label}.textMojibake`, 'summary loop mojibake')
  compareValue(
    errors,
    proof?.firstViewportMinVisibleRatio,
    summary?.firstViewportVisibility?.minVisibleRatio,
    `${label}.firstViewportMinVisibleRatio`,
    'summary loop first viewport',
  )
  compareValue(errors, proof?.runtimeIssueCount, summary?.runtimeHealth?.issueCount, `${label}.runtimeIssueCount`, 'summary loop issue count')
  compareValue(errors, proof?.screenshotCount, summary?.screenshotEvidence?.count, `${label}.screenshotCount`, 'summary loop screenshot count')
  compareValue(
    errors,
    proof?.uniqueScreenshotDigestCount,
    summary?.screenshotEvidence?.uniqueDigestCount,
    `${label}.uniqueScreenshotDigestCount`,
    'summary loop unique screenshot digest count',
  )
  compareValue(
    errors,
    proof?.externalExecutionSource,
    summary?.externalExecutionSync?.latestSource,
    `${label}.externalExecutionSource`,
    'summary loop external source',
  )
  compareValue(
    errors,
    proof?.acceptedActionCount,
    summary?.externalExecutionSync?.acceptedActionCount,
    `${label}.acceptedActionCount`,
    'summary loop accepted action count',
  )
}

function validatePhoneProof(errors, proof, summary) {
  const label = 'proofSummary.loops.phone'
  validateAllowedKeys(
    errors,
    proof,
    [
      'run',
      'success',
      'title',
      'textRequiredPhrases',
      'textMissingPhrases',
      'textMojibake',
      'frontCameraReady',
      'frontCameraFacingMode',
      'speechInputAvailable',
      'speechInputSkipped',
      'rawImageNotRetained',
      'runtimeIssueCount',
      'externalExecutionSource',
      'acceptedActionCount',
    ],
    label,
  )
  compareValue(errors, proof?.run, summary?.run, `${label}.run`, 'summary phone run')
  compareValue(errors, proof?.success, summary?.success, `${label}.success`, 'summary phone success')
  compareValue(errors, proof?.title, summary?.title, `${label}.title`, 'summary phone title')
  compareValue(errors, proof?.textRequiredPhrases, summary?.textIntegrity?.requiredPhraseCount, `${label}.textRequiredPhrases`, 'summary phone text required')
  compareValue(errors, proof?.textMissingPhrases, summary?.textIntegrity?.missingPhraseCount, `${label}.textMissingPhrases`, 'summary phone text missing')
  compareValue(errors, proof?.textMojibake, summary?.textIntegrity?.mojibakeCount, `${label}.textMojibake`, 'summary phone mojibake')
  compareValue(errors, proof?.frontCameraReady, summary?.frontCamera?.ready, `${label}.frontCameraReady`, 'summary phone frontCamera.ready')
  compareValue(errors, proof?.frontCameraFacingMode, summary?.frontCamera?.facingMode, `${label}.frontCameraFacingMode`, 'summary phone frontCamera.facingMode')
  compareValue(errors, proof?.speechInputAvailable, summary?.speechInput?.available, `${label}.speechInputAvailable`, 'summary phone speechInput.available')
  compareValue(errors, proof?.speechInputSkipped, summary?.speechInput?.skipped, `${label}.speechInputSkipped`, 'summary phone speechInput.skipped')
  compareValue(errors, proof?.rawImageNotRetained, summary?.scene?.rawImageNotRetained, `${label}.rawImageNotRetained`, 'summary phone raw image retention')
  compareValue(errors, proof?.runtimeIssueCount, summary?.runtimeHealth?.issueCount, `${label}.runtimeIssueCount`, 'summary phone runtime issue count')
  compareValue(
    errors,
    proof?.externalExecutionSource,
    summary?.externalExecution?.latestSource,
    `${label}.externalExecutionSource`,
    'summary phone external source',
  )
  compareValue(errors, proof?.acceptedActionCount, summary?.externalExecution?.acceptedActionCount, `${label}.acceptedActionCount`, 'summary phone accepted count')
}

function validateHardwareProof(errors, proof, plan) {
  validateAllowedKeys(
    errors,
    proof,
    [
      'run',
      'success',
      'port',
      'baud',
      'seconds',
      'serialCommandIndex',
      'skipReset',
      'requireInteraction',
      'requiredMode',
      'liveFailureCount',
      'recheckFailureCount',
      'liveCheckCount',
      'recheckCheckCount',
      'liveResultJsonPath',
      'savedLogPath',
      'savedLogRecheckResultJsonPath',
    ],
    'proofSummary.hardware.esp32Serial',
  )
  if (proof?.run !== true) errors.push('proofSummary.hardware.esp32Serial.run must be true.')
  if (proof?.success !== true) errors.push('proofSummary.hardware.esp32Serial.success must be true.')
  for (const key of ['port', 'baud', 'seconds', 'serialCommandIndex', 'skipReset']) {
    compareValue(errors, proof?.[key], plan.hardware?.esp32Serial?.[key], `proofSummary.hardware.esp32Serial.${key}`, `plan.hardware.esp32Serial.${key}`)
  }
  if (proof?.requireInteraction !== true) errors.push('proofSummary.hardware.esp32Serial.requireInteraction must be true.')
  if (proof?.requiredMode !== true) errors.push('proofSummary.hardware.esp32Serial.requiredMode must be true.')
  if (proof?.liveFailureCount !== 0) errors.push('proofSummary.hardware.esp32Serial.liveFailureCount must be 0.')
  if (proof?.recheckFailureCount !== 0) errors.push('proofSummary.hardware.esp32Serial.recheckFailureCount must be 0.')
  compareRepoPaths(
    errors,
    proof?.liveResultJsonPath,
    plan.outputs?.esp32SerialResultJsonPath,
    'proofSummary.hardware.esp32Serial.liveResultJsonPath',
    'plan.outputs.esp32SerialResultJsonPath',
  )
  compareRepoPaths(errors, proof?.savedLogPath, plan.outputs?.esp32SerialLogPath, 'proofSummary.hardware.esp32Serial.savedLogPath', 'plan.outputs.esp32SerialLogPath')
  compareRepoPaths(
    errors,
    proof?.savedLogRecheckResultJsonPath,
    plan.outputs?.esp32SerialRecheckResultJsonPath,
    'proofSummary.hardware.esp32Serial.savedLogRecheckResultJsonPath',
    'plan.outputs.esp32SerialRecheckResultJsonPath',
  )
}

function validateProofEvidence(errors, evidence, plan, browserEvidence) {
  const expected = {
    reportPath: plan.outputs.reportPath,
    summaryPath: plan.outputs.summaryPath,
    browserEvidenceResultJsonPath: plan.outputs.browserEvidenceResultJsonPath,
    desktopEvidencePath: browserEvidence.proofSummary?.evidence?.desktopEvidencePath,
    windowsChromeEvidencePath: browserEvidence.proofSummary?.evidence?.windowsChromeEvidencePath,
    phoneEvidencePath: browserEvidence.proofSummary?.evidence?.phoneEvidencePath,
    devEnvEvidencePath: browserEvidence.proofSummary?.evidence?.devEnvEvidencePath,
    webReadinessEvidencePath: browserEvidence.proofSummary?.evidence?.webReadinessEvidencePath,
    desktopScreenshotDir: browserEvidence.proofSummary?.evidence?.desktopScreenshotDir,
    windowsChromeScreenshotDir: browserEvidence.proofSummary?.evidence?.windowsChromeScreenshotDir,
    esp32SerialLogPath: plan.outputs.esp32SerialLogPath,
    esp32SerialResultJsonPath: plan.outputs.esp32SerialResultJsonPath,
    esp32SerialRecheckResultJsonPath: plan.outputs.esp32SerialRecheckResultJsonPath,
  }
  validateAllowedKeys(errors, evidence, [...Object.keys(expected), 'browserEvidenceSuccess'], 'proofSummary.evidence')
  if (evidence?.browserEvidenceSuccess !== true) errors.push('proofSummary.evidence.browserEvidenceSuccess must be true.')
  for (const [key, value] of Object.entries(expected)) {
    validatePortableRepoPath(errors, evidence?.[key], `proofSummary.evidence.${key}`)
    compareRepoPaths(errors, evidence?.[key], value, `proofSummary.evidence.${key}`, key)
  }
}

async function validateSerialEvidence(errors, result, liveCapture, savedLogRecheck) {
  validateSerialResult(errors, liveCapture, result.plan, 'esp32Serial.liveCapture', true)
  validateSerialResult(errors, savedLogRecheck, result.plan, 'esp32Serial.savedLogRecheck', false)
  const logText = await readReferencedText(errors, result.plan.outputs.esp32SerialLogPath, 'plan.outputs.esp32SerialLogPath')
  if (logText) {
    for (const marker of SERIAL_LOG_MARKERS) {
      if (!logText.includes(marker)) errors.push(`ESP32 serial log must include marker: ${marker}`)
    }
  }
}

function validateSerialResult(errors, value, plan, label, live) {
  validateAllowedKeys(errors, value, ['port', 'baud', 'source', 'seconds', 'requireInteraction', 'requiredMode', 'failures', 'checks'], label)
  if (!Array.isArray(value?.failures)) errors.push(`${label}.failures must be an array.`)
  if (Array.isArray(value?.failures) && value.failures.length !== 0) errors.push(`${label}.failures must be empty.`)
  if (value?.requireInteraction !== true) errors.push(`${label}.requireInteraction must be true.`)
  if (value?.requiredMode !== true) errors.push(`${label}.requiredMode must be true.`)
  if (live) {
    compareValue(errors, value?.port, plan.hardware?.esp32Serial?.port, `${label}.port`, 'plan.hardware.esp32Serial.port')
    compareValue(errors, value?.baud, plan.hardware?.esp32Serial?.baud, `${label}.baud`, 'plan.hardware.esp32Serial.baud')
    compareValue(errors, value?.seconds, plan.hardware?.esp32Serial?.seconds, `${label}.seconds`, 'plan.hardware.esp32Serial.seconds')
    if (value?.source !== 'serial') errors.push(`${label}.source must be serial.`)
  } else {
    compareRepoPaths(errors, value?.source, plan.outputs?.esp32SerialLogPath, `${label}.source`, 'plan.outputs.esp32SerialLogPath')
  }
  validateSerialChecks(errors, value?.checks, label)
}

function validateSerialChecks(errors, checks, label) {
  if (!Array.isArray(checks)) {
    errors.push(`${label}.checks must be an array.`)
    return
  }
  const byName = new Map(checks.map((check) => [check?.name, check]))
  for (const name of REQUIRED_SERIAL_CHECKS) {
    const check = byName.get(name)
    if (!check) {
      errors.push(`${label}.checks must include ${name}.`)
      continue
    }
    if (check.status !== 'OK') errors.push(`${label}.checks ${name} status must be OK.`)
    if (check.required !== true) errors.push(`${label}.checks ${name} must be required.`)
  }
}

function validateFailedMode(errors, value) {
  if (!value.failure || typeof value.failure !== 'object') {
    errors.push('failure is missing in failed mode.')
    return
  }
  validateAllowedKeys(errors, value.failure, ['stage', 'checkName', 'command', 'exitCode', 'message'], 'failure')
  const allowedStages = {
    'full device loop': value.plan?.commands?.fullLoop?.display,
    'saved browser evidence recheck': value.plan?.commands?.browserEvidence?.display,
    'saved ESP32 serial log recheck': value.plan?.commands?.esp32SerialRecheck?.display,
    'result validation': 'post-process device loop evidence',
  }
  if (!Object.hasOwn(allowedStages, value.failure.stage)) {
    errors.push('failure.stage must identify a device loop stage.')
  } else if (value.failure.command !== allowedStages[value.failure.stage]) {
    errors.push('failure.command must match the command for failure.stage.')
  }
  if (value.failure.checkName !== value.failure.stage) errors.push('failure.checkName must match failure.stage.')
  assertString(errors, value.failure.message, 'failure.message')
  if (value.proofSummary !== null && value.proofSummary !== undefined) {
    errors.push('proofSummary must be null or omitted in failed mode.')
  }
}

function formatProofSummary(proofSummary, sourceState) {
  return `Device loop proof summary: summaryRunId=${proofSummary.summaryRunId} desktop=${formatStatus(
    proofSummary.loops?.desktop?.success,
  )} phone=${formatStatus(proofSummary.loops?.phone?.success)} chrome=${formatStatus(
    proofSummary.loops?.windowsChrome?.success,
  )} parity=${formatStatus(proofSummary.browserParity?.success)} esp32=${formatStatus(
    proofSummary.hardware?.esp32Serial?.success,
  )} frontCamera=${formatStatus(proofSummary.loops?.phone?.frontCameraReady)}/${
    proofSummary.loops?.phone?.frontCameraFacingMode ?? 'unknown'
  } speech=${formatStatus(proofSummary.loops?.phone?.speechInputAvailable)} source=${formatSourceState(
    sourceState,
  )} esp32Log=${proofSummary.evidence?.esp32SerialLogPath} summary=${proofSummary.evidence?.summaryPath}`
}

function formatStatus(value) {
  if (value === true) return 'pass'
  if (value === false) return 'fail'
  return 'unknown'
}

function formatSourceState(sourceState) {
  if (!sourceState) return 'unknown'
  const commit = typeof sourceState.commit === 'string' ? sourceState.commit.slice(0, 7) : 'unknown'
  const dirty = sourceState.dirty === true ? 'dirty' : sourceState.dirty === false ? 'clean' : 'unknown'
  const statusCount = Number.isInteger(sourceState.statusCount) ? sourceState.statusCount : 'unknown'
  const statusSha = typeof sourceState.statusSha256 === 'string' ? sourceState.statusSha256 : 'unknown'
  return `${sourceState.branch ?? 'unknown'}@${commit}/${dirty}#${statusCount}:${statusSha}`
}

async function assertExistingFile(errors, value, label) {
  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) {
    errors.push(`${label} must stay inside the repository root.`)
    return
  }
  try {
    const fileStat = await stat(absolutePath)
    if (!fileStat.isFile()) errors.push(`${label} must point to a file.`)
  } catch (error) {
    errors.push(`${label} cannot be read: ${error?.code ?? error.message ?? error}`)
  }
}

async function readReferencedJson(errors, value, label) {
  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) {
    errors.push(`${label} must stay inside the repository root.`)
    return null
  }
  try {
    const text = await readFile(absolutePath, 'utf8')
    assertAsciiSafeJsonText(text, label)
    return JSON.parse(text)
  } catch (error) {
    errors.push(`${label} JSON cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

async function readReferencedText(errors, value, label) {
  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) {
    errors.push(`${label} must stay inside the repository root.`)
    return null
  }
  try {
    return await readFile(absolutePath, 'utf8')
  } catch (error) {
    errors.push(`${label} text cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

function validateCommandArgPath(errors, args, flag, expected, label) {
  const actual = getCommandArgValue(errors, args, flag, label)
  if (actual === null || expected === undefined || expected === null) return
  compareRepoPaths(errors, actual, expected, label, expected)
}

function validateCommandArgValue(errors, args, flag, expected, label) {
  const actual = getCommandArgValue(errors, args, flag, label)
  if (actual === null || expected === undefined || expected === null) return
  if (String(actual) !== String(expected)) errors.push(`${label} must match ${expected}.`)
}

function validateOptionalPositiveNumberCommandArg(errors, args, flag, expected, label) {
  if (!Array.isArray(args)) return
  const count = args.filter((item) => item === flag).length
  if (expected === null || expected === undefined) {
    if (count !== 0) errors.push(`${label} must be omitted when plan.options.maxAgeMinutes is null.`)
    return
  }
  if (count !== 1) {
    errors.push(`${label} must appear exactly once when plan.options.maxAgeMinutes is set.`)
    return
  }
  const actual = getCommandArgValue(errors, args, flag, label)
  if (actual !== null && Number(actual) !== expected) errors.push(`${label} must match plan.options.maxAgeMinutes.`)
}

function validateCommandFlag(errors, args, flag, expected, label) {
  if (!Array.isArray(args)) return
  const count = args.filter((item) => item === flag).length
  if (expected && count !== 1) errors.push(`${label} must appear exactly once.`)
  if (!expected && count !== 0) errors.push(`${label} must be omitted.`)
}

function getCommandArgValue(errors, args, flag, label) {
  if (!Array.isArray(args)) return null
  const indices = []
  args.forEach((item, index) => {
    if (item === flag) indices.push(index)
  })
  if (indices.length !== 1) {
    errors.push(`${label} must appear exactly once.`)
    return null
  }
  const value = args[indices[0] + 1]
  if (typeof value !== 'string' || value.length === 0 || value.startsWith('-')) {
    errors.push(`${label} must have a value.`)
    return null
  }
  return value
}

function compareStableJson(errors, left, right, leftLabel, rightLabel) {
  if (stableJson(left) !== stableJson(right)) errors.push(`${leftLabel} must match ${rightLabel}.`)
}

function compareValue(errors, left, right, leftLabel, rightLabel) {
  if (left !== right) errors.push(`${leftLabel} must match ${rightLabel}.`)
}

function stableJson(value) {
  return JSON.stringify(sortJsonValue(value))
}

function sortJsonValue(value) {
  if (Array.isArray(value)) return value.map((item) => sortJsonValue(item))
  if (!value || typeof value !== 'object') return value
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sortJsonValue(item)]),
  )
}

function compareRepoPaths(errors, left, right, leftLabel, rightLabel) {
  const leftPath = resolveRepoPath(left)
  const rightPath = resolveRepoPath(right)
  if (!leftPath || !rightPath || leftPath !== rightPath) {
    errors.push(`${leftLabel} must match ${rightLabel}.`)
  }
}

function validateRepoPath(errors, value, label) {
  if (!resolveRepoPath(value)) errors.push(`${label} must stay inside the repository root.`)
}

function validatePortableRepoPath(errors, value, label) {
  if (typeof value === 'string' && path.isAbsolute(value)) errors.push(`${label} must be repo-relative.`)
}

function isInsidePath(child, parent) {
  const childPath = resolveRepoPath(child)
  const parentPath = resolveRepoPath(parent)
  if (!childPath || !parentPath) return false
  const relativePath = path.relative(parentPath, childPath)
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath))
}

function resolveRepoPath(value) {
  if (typeof value !== 'string' || value.length === 0) return null
  const absolutePath = path.isAbsolute(value) ? path.resolve(value) : path.resolve(repoRoot, value)
  const relativePath = path.relative(repoRoot, absolutePath)
  if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) return null
  return absolutePath
}

function validateAllowedKeys(errors, value, allowedKeys, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }
  const allowed = new Set(allowedKeys)
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) errors.push(`${label} must not include unexpected field: ${key}.`)
  }
}

function assertString(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) errors.push(`${label} must be a non-empty string.`)
}

function positiveInteger(value) {
  return Number.isInteger(value) && value > 0
}

function resolveCliPath(value) {
  return path.isAbsolute(value) ? path.resolve(value) : path.resolve(process.cwd(), value)
}
