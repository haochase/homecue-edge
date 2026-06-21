import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeJsonFile } from './json-file.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const validatorScript = path.join(scriptDir, 'validate-device-loop-result.mjs')
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'device-loop-result-validator-selftest')
const sourceSummary = formatSourceState(currentSourceState())

await mkdir(outputDir, { recursive: true })

const positive = createResult()
await writeFixtureFiles(positive)
const positiveFile = path.join(outputDir, 'positive.json')
setResultJsonPath(positive, positiveFile)
await writeJson(positiveFile, positive)
const positiveResult = await runValidator(positiveFile)
if (positiveResult.code !== 0) {
  console.error(positiveResult.output)
  throw new Error('Expected positive device loop result to pass validation.')
}
assertOutputIncludes(
  positiveResult.output,
  `Device loop proof summary: summaryRunId=full-loop-selftest desktop=pass phone=pass chrome=pass parity=pass esp32=pass frontCamera=pass/user speech=pass source=${sourceSummary} esp32Log=assets/tmp/device-loop-result-validator-selftest/esp32-serial-level4.log summary=assets/tmp/device-loop-result-validator-selftest/device-loop-report.json`,
  'positive proof summary output',
)
console.log('PASS positive device loop result')

const fresh = createResult({ maxAgeMinutes: 60 })
fresh.generatedAt = new Date().toISOString()
fresh.browserEvidence.generatedAt = fresh.generatedAt
await writeFixtureFiles(fresh)
const freshFile = path.join(outputDir, 'fresh.json')
setResultJsonPath(fresh, freshFile)
await writeJson(freshFile, fresh)
const freshResult = await runValidator(freshFile, ['--max-age-minutes', '60'])
if (freshResult.code !== 0) {
  console.error(freshResult.output)
  throw new Error('Expected fresh device loop result to pass freshness validation.')
}
console.log('PASS fresh device loop result')

const staleResult = await runValidator(positiveFile, ['--max-age-minutes', '1'])
if (staleResult.code === 0 || !staleResult.output.includes('generatedAt is older than --max-age-minutes=1.')) {
  console.error(staleResult.output)
  throw new Error('Expected stale device loop result to fail freshness validation.')
}
console.log('PASS stale device loop result')

const dryRun = createResult({ mode: 'dry-run' })
dryRun.proofSummary = null
dryRun.browserEvidence = null
dryRun.esp32Serial = {
  liveCapture: null,
  savedLogRecheck: null,
}
const dryRunFile = path.join(outputDir, 'dry-run.json')
setResultJsonPath(dryRun, dryRunFile)
await writeJson(dryRunFile, dryRun)
const dryRunResult = await runValidator(dryRunFile)
if (dryRunResult.code !== 0) {
  console.error(dryRunResult.output)
  throw new Error('Expected dry-run device loop result to pass validation.')
}
assertOutputExcludes(dryRunResult.output, 'Device loop proof summary:', 'dry-run proof summary output')
console.log('PASS dry-run device loop result')

const failed = createResult({ mode: 'failed' })
failed.success = false
failed.proofSummary = null
failed.browserEvidence = null
failed.esp32Serial = {
  liveCapture: null,
  savedLogRecheck: null,
}
failed.failure = {
  stage: 'full device loop',
  checkName: 'full device loop',
  command: failed.plan.commands.fullLoop.display,
  exitCode: 1,
  message: 'simulated full device loop failure',
}
const failedFile = path.join(outputDir, 'failed.json')
setResultJsonPath(failed, failedFile)
await writeJson(failedFile, failed)
const failedResult = await runValidator(failedFile)
if (failedResult.code !== 0) {
  console.error(failedResult.output)
  throw new Error('Expected failed device loop result to pass validation.')
}
assertOutputExcludes(failedResult.output, 'Device loop proof summary:', 'failed result proof summary output')
console.log('PASS failed device loop result')

const negativeCases = [
  {
    name: 'source-state-dirty-mismatch',
    expectedError: 'sourceState.dirty must match current git dirty.',
    mutate: (result) => {
      result.sourceState.dirty = !result.sourceState.dirty
    },
  },
  {
    name: 'missing-isolate-evidence-flag',
    expectedError: 'plan.commands.fullLoop -IsolateEvidence must appear exactly once.',
    mutate: (result) => {
      removeArg(result.plan.commands.fullLoop.args, '-IsolateEvidence')
      refreshCommand(result, 'fullLoop')
    },
  },
  {
    name: 'browser-evidence-phone-not-required',
    expectedError: 'browserEvidence.plan.requiredEvidence.phone must be true.',
    mutate: (result) => {
      result.browserEvidence.plan.requiredEvidence.phone = false
    },
  },
  {
    name: 'esp32-live-failure',
    expectedError: 'esp32Serial.liveCapture.failures must be empty.',
    mutate: (result) => {
      result.esp32Serial.liveCapture.failures = ['gateway health']
    },
  },
  {
    name: 'serial-log-missing-plan-marker',
    expectedError: 'ESP32 serial log must include marker: > serial homecue:plan',
    serialLogText: '[HomeCue Edge]\n[/health] HTTP 200\n',
  },
]

for (const testCase of negativeCases) {
  const result = createResult()
  testCase.mutate?.(result)
  await writeFixtureFiles(result, { serialLogText: testCase.serialLogText })
  const file = path.join(outputDir, `${testCase.name}.json`)
  setResultJsonPath(result, file)
  await writeJson(file, result)
  const validation = await runValidator(file)
  if (validation.code === 0 || !validation.output.includes(testCase.expectedError)) {
    console.error(validation.output)
    throw new Error(`Expected negative case ${testCase.name} to fail with ${testCase.expectedError}.`)
  }
  console.log(`PASS negative case: ${testCase.name}`)
}

console.log('Device loop result validator self-test passed.')

function createResult({ mode = 'validate', maxAgeMinutes = null } = {}) {
  const summaryPath = 'assets/tmp/device-loop-result-validator-selftest/device-loop-report.json'
  const reportPath = 'assets/tmp/device-loop-result-validator-selftest/device-loop-report.md'
  const browserEvidencePath = 'assets/tmp/device-loop-result-validator-selftest/browser-evidence-check.json'
  const esp32LogPath = 'assets/tmp/device-loop-result-validator-selftest/esp32-serial-level4.log'
  const esp32ResultPath = 'assets/tmp/device-loop-result-validator-selftest/esp32-serial-level4.json'
  const esp32RecheckPath = 'assets/tmp/device-loop-result-validator-selftest/esp32-serial-saved-log-check.json'
  const outputPath = 'assets/tmp/device-loop-result-validator-selftest'
  const fullLoopArgs = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    'scripts/check-full-loop.ps1',
    '-AppUrl',
    'http://127.0.0.1:5173',
    '-ApiBase',
    'http://127.0.0.1:8723',
    '-IncludePhone',
    '-IncludeChrome',
    '-IncludeEsp32Serial',
    '-IsolateEvidence',
    '-StartupTimeoutSeconds',
    '60',
    '-StepTimeoutSeconds',
    '240',
    '-BrowserWrapperSharedStateLockTimeoutSeconds',
    '1200',
    '-PartialEvidenceDir',
    outputPath,
    '-ReportPath',
    reportPath,
    '-SummaryPath',
    summaryPath,
    '-Esp32Port',
    'COM7',
    '-Esp32Baud',
    '115200',
    '-Esp32SerialSeconds',
    '45',
    '-Esp32SerialCommandIndex',
    '0',
  ]
  const browserEvidenceArgs = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    'scripts/check-browser-evidence.ps1',
    '-SummaryPath',
    summaryPath,
    '-RequireDesktop',
    '-RequirePhone',
    '-RequireChrome',
    '-ResultJsonPath',
    browserEvidencePath,
    ...(maxAgeMinutes === null ? [] : ['-MaxAgeMinutes', String(maxAgeMinutes)]),
  ]
  const serialRecheckArgs = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    'scripts/check-esp32-serial-log.ps1',
    '-LogPath',
    esp32LogPath,
    '-RequireInteraction',
    '-Required',
    '-ResultJsonPath',
    esp32RecheckPath,
  ]
  const plan = {
    runId: 'device-loop-selftest',
    requestedLoops: {
      desktop: true,
      phone: true,
      windowsChrome: true,
      esp32Serial: true,
    },
    options: {
      skipPreflight: false,
      selfTest: false,
      adbPathProvided: false,
      startupTimeoutSeconds: 60,
      stepTimeoutSeconds: 240,
      browserWrapperSharedStateLockTimeoutSeconds: 1200,
      maxAgeMinutes,
    },
    outputs: {
      outputDir: outputPath,
      reportPath,
      summaryPath,
      resultJsonPath: 'assets/tmp/device-loop-result-validator-selftest/device-loop-check.json',
      browserEvidenceResultJsonPath: browserEvidencePath,
      esp32SerialLogPath: esp32LogPath,
      esp32SerialResultJsonPath: esp32ResultPath,
      esp32SerialRecheckResultJsonPath: esp32RecheckPath,
    },
    expectedEvidence: {
      desktopEvidence: 'required-from-summary',
      phoneEvidence: 'required-from-summary',
      windowsChromeEvidence: 'required-from-summary',
      esp32SerialLog: esp32LogPath,
      esp32SerialResult: esp32ResultPath,
    },
    gates: {
      fullLoopIncludePhone: true,
      fullLoopIncludeChrome: true,
      fullLoopIncludeEsp32Serial: true,
      fullLoopIsolateEvidence: true,
      browserEvidenceRequireDesktop: true,
      browserEvidenceRequirePhone: true,
      browserEvidenceRequireChrome: true,
      browserEvidenceSelfTest: false,
      browserWrapperSharedStateLock: {
        name: 'Global\\HCEdgeBrowserLoopGate',
        timeoutSeconds: 1200,
      },
      fullLoopWebReadiness: {
        httpProbeBeforePortReuse: true,
        stalePortBlocksDuplicateStart: true,
        lanReachabilityForEsp32: true,
      },
      esp32Serial: {
        run: true,
        firmwareFlowRequired: true,
        autoSerialLevel4: true,
        requireInteraction: true,
        savedLogRecheck: true,
      },
    },
    hardware: {
      esp32Serial: {
        run: true,
        port: 'COM7',
        baud: 115200,
        seconds: 45,
        serialCommandIndex: 0,
        skipReset: false,
      },
    },
    commands: {
      fullLoop: {
        executable: 'powershell',
        args: fullLoopArgs,
        display: displayCommand('powershell', fullLoopArgs),
      },
      browserEvidence: {
        executable: 'powershell',
        args: browserEvidenceArgs,
        display: displayCommand('powershell', browserEvidenceArgs),
      },
      esp32SerialRecheck: {
        executable: 'powershell',
        args: serialRecheckArgs,
        display: displayCommand('powershell', serialRecheckArgs),
      },
    },
  }
  const browserEvidence = createBrowserEvidence(plan)
  const liveCapture = createSerialResult({ source: 'serial', port: 'COM7', baud: 115200, seconds: 45 })
  const savedLogRecheck = createSerialResult({
    source: path.join(repoRoot, esp32LogPath),
    port: '',
    baud: '',
    seconds: '',
  })

  return {
    generatedAt: '2026-06-19T00:00:02.000Z',
    success: mode === 'failed' ? false : true,
    mode,
    runId: plan.runId,
    sourceState: currentSourceState(),
    plan,
    checks: [
      {
        name: 'full device loop',
        command: plan.commands.fullLoop.display,
        required: true,
        summaryPath,
        reportPath,
        esp32SerialLogPath: esp32LogPath,
        esp32SerialResultJsonPath: esp32ResultPath,
      },
      {
        name: 'saved browser evidence recheck',
        command: plan.commands.browserEvidence.display,
        required: true,
        resultJsonPath: browserEvidencePath,
      },
      {
        name: 'saved ESP32 serial log recheck',
        command: plan.commands.esp32SerialRecheck.display,
        required: true,
        logPath: esp32LogPath,
        resultJsonPath: esp32RecheckPath,
      },
    ],
    proofSummary: mode === 'dry-run' ? null : proofSummary(plan),
    browserEvidence: mode === 'dry-run' ? null : browserEvidence,
    esp32Serial:
      mode === 'dry-run'
        ? {
            liveCapture: null,
            savedLogRecheck: null,
          }
        : {
            liveCapture,
            savedLogRecheck,
          },
    failure: null,
  }
}

function createBrowserEvidence(plan) {
  const paths = {
    desktopEvidence: 'assets/tmp/device-loop-result-validator-selftest/desktop-loop.json',
    desktopScreenshotDir: 'assets/tmp/device-loop-result-validator-selftest/playwright-chromium-screens',
    phoneEvidence: 'assets/tmp/device-loop-result-validator-selftest/phone-loop.json',
    windowsChromeEvidence: 'assets/tmp/device-loop-result-validator-selftest/chrome-loop.json',
    windowsChromeScreenshotDir: 'assets/tmp/device-loop-result-validator-selftest/windows-chrome-screens',
  }

  return {
    generatedAt: '2026-06-19T00:00:01.000Z',
    success: true,
    mode: 'validate',
    sourceState: currentSourceState(),
    plan: {
      summaryPath: plan.outputs.summaryPath,
      resultJsonPath: plan.outputs.browserEvidenceResultJsonPath,
      inferredFromSummary: {
        desktop: true,
        phone: true,
        windowsChrome: true,
      },
      requiredEvidence: {
        desktop: true,
        phone: true,
        windowsChrome: true,
      },
      options: {
        maxAgeMinutes: plan.options.maxAgeMinutes,
      },
      selfTest: {
        requested: false,
        phoneEvidence: false,
        desktopEvidence: false,
        summary: false,
        report: false,
      },
      paths,
    },
    checks: [],
    proofSummary: browserEvidenceProofSummary(plan, paths),
  }
}

function createSerialResult({ source, port, baud, seconds }) {
  return {
    port,
    baud,
    source,
    seconds,
    requireInteraction: true,
    requiredMode: true,
    failures: [],
    checks: [
      serialCheck('boot banner', true),
      serialCheck('button-route mode', true),
      serialCheck('TCA9555 key expander', false),
      serialCheck('BOOT fallback', true),
      serialCheck('WiFi connected', true),
      serialCheck('gateway health', true),
      serialCheck('plan trigger', true),
      serialCheck('plan proposal', true),
      serialCheck('confirm trigger', true),
      serialCheck('execute confirmation', true),
    ],
  }
}

function serialCheck(name, required) {
  return {
    name,
    status: 'OK',
    required,
    detail: 'self-test marker',
  }
}

function browserEvidenceProofSummary(plan, paths) {
  return {
    summaryRunId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    requiredEvidence: {
      desktop: true,
      phone: true,
      windowsChrome: true,
    },
    browserParity: {
      checked: true,
      success: true,
      errorCount: 0,
    },
    webReadiness: webReadinessProof(),
    loops: {
      desktop: loopProofSummary(),
      phone: {
        run: true,
        success: true,
      },
      windowsChrome: loopProofSummary(),
    },
    evidence: {
      summaryPath: plan.outputs.summaryPath,
      desktopEvidencePath: paths.desktopEvidence,
      windowsChromeEvidencePath: paths.windowsChromeEvidence,
      phoneEvidencePath: paths.phoneEvidence,
      devEnvEvidencePath: 'assets/tmp/device-loop-result-validator-selftest/dev-env-check.json',
      webReadinessEvidencePath: 'assets/tmp/device-loop-result-validator-selftest/web-readiness.json',
      desktopScreenshotDir: paths.desktopScreenshotDir,
      windowsChromeScreenshotDir: paths.windowsChromeScreenshotDir,
    },
  }
}

function proofSummary(plan) {
  return {
    summaryRunId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    requestedLoops: plan.requestedLoops,
    browserParity: {
      checked: true,
      success: true,
      errorCount: 0,
    },
    webReadiness: webReadinessProof(),
    loops: {
      desktop: loopProofSummary(),
      phone: phoneProofSummary(),
      windowsChrome: loopProofSummary(),
    },
    hardware: {
      esp32Serial: {
        run: true,
        success: true,
        port: 'COM7',
        baud: 115200,
        seconds: 45,
        serialCommandIndex: 0,
        skipReset: false,
        requireInteraction: true,
        requiredMode: true,
        liveFailureCount: 0,
        recheckFailureCount: 0,
        liveCheckCount: 10,
        recheckCheckCount: 10,
        liveResultJsonPath: plan.outputs.esp32SerialResultJsonPath,
        savedLogPath: plan.outputs.esp32SerialLogPath,
        savedLogRecheckResultJsonPath: plan.outputs.esp32SerialRecheckResultJsonPath,
      },
    },
    evidence: {
      reportPath: plan.outputs.reportPath,
      summaryPath: plan.outputs.summaryPath,
      browserEvidenceResultJsonPath: plan.outputs.browserEvidenceResultJsonPath,
      browserEvidenceSuccess: true,
      desktopEvidencePath: 'assets/tmp/device-loop-result-validator-selftest/desktop-loop.json',
      windowsChromeEvidencePath: 'assets/tmp/device-loop-result-validator-selftest/chrome-loop.json',
      phoneEvidencePath: 'assets/tmp/device-loop-result-validator-selftest/phone-loop.json',
      devEnvEvidencePath: 'assets/tmp/device-loop-result-validator-selftest/dev-env-check.json',
      webReadinessEvidencePath: 'assets/tmp/device-loop-result-validator-selftest/web-readiness.json',
      desktopScreenshotDir: 'assets/tmp/device-loop-result-validator-selftest/playwright-chromium-screens',
      windowsChromeScreenshotDir: 'assets/tmp/device-loop-result-validator-selftest/windows-chrome-screens',
      esp32SerialLogPath: plan.outputs.esp32SerialLogPath,
      esp32SerialResultJsonPath: plan.outputs.esp32SerialResultJsonPath,
      esp32SerialRecheckResultJsonPath: plan.outputs.esp32SerialRecheckResultJsonPath,
    },
  }
}

function webReadinessProof() {
  return {
    run: true,
    success: true,
    strategy: 'already-ready',
    httpReadyAfter: true,
    duplicateStartAvoided: true,
  }
}

function loopProofSummary() {
  return {
    run: true,
    success: true,
    title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
    runButton: '\u751f\u6210\u8ba1\u5212',
    textRequiredPhrases: 7,
    textMissingPhrases: 0,
    textMojibake: 0,
    firstViewportMinVisibleRatio: 1,
    runtimeIssueCount: 0,
    screenshotCount: 6,
    uniqueScreenshotDigestCount: 6,
    externalExecutionSource: 'esp32-serial',
    externalExecutionSourceMode: 'api-simulated-room-terminal',
    acceptedActionCount: 5,
  }
}

function phoneProofSummary() {
  return {
    run: true,
    success: true,
    title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
    textRequiredPhrases: 7,
    textMissingPhrases: 0,
    textMojibake: 0,
    frontCameraReady: true,
    frontCameraFacingMode: 'user',
    speechInputAvailable: true,
    speechInputSkipped: false,
    rawImageNotRetained: true,
    runtimeIssueCount: 0,
    externalExecutionSource: 'esp32-serial',
    acceptedActionCount: 5,
  }
}

function createSummary() {
  return {
    generatedAt: '2026-06-19T00:00:00.000Z',
    success: true,
    runId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    environment: {
      webReadiness: {
        run: true,
        success: true,
        strategy: 'already-ready',
        httpReadyAfter: true,
        duplicateStartAvoided: true,
      },
    },
    browserParity: {
      checked: true,
      success: true,
      errors: [],
    },
    loops: {
      desktop: summaryLoop('playwright-chromium'),
      phone: summaryPhoneLoop(),
      windowsChrome: summaryLoop('windows-chrome'),
    },
  }
}

function summaryLoop(browserName) {
  return {
    run: true,
    success: true,
    browserName,
    title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
    textIntegrity: {
      requiredPhraseCount: 7,
      missingPhraseCount: 0,
      mojibakeCount: 0,
    },
    localizedUi: {
      runButton: '\u751f\u6210\u8ba1\u5212',
    },
    firstViewportVisibility: {
      minVisibleRatio: 1,
    },
    runtimeHealth: {
      issueCount: 0,
    },
    screenshotEvidence: {
      count: 6,
      uniqueDigestCount: 6,
    },
    externalExecutionSync: {
      latestSource: 'esp32-serial',
      sourceMode: 'api-simulated-room-terminal',
      acceptedActionCount: 5,
    },
  }
}

function summaryPhoneLoop() {
  return {
    run: true,
    success: true,
    title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
    textIntegrity: {
      requiredPhraseCount: 7,
      missingPhraseCount: 0,
      mojibakeCount: 0,
    },
    frontCamera: {
      ready: true,
      facingMode: 'user',
    },
    speechInput: {
      available: true,
      skipped: false,
    },
    scene: {
      rawImageNotRetained: true,
    },
    runtimeHealth: {
      issueCount: 0,
    },
    externalExecution: {
      latestSource: 'esp32-serial',
      acceptedActionCount: 5,
    },
  }
}

async function writeFixtureFiles(result, { serialLogText = serialLog() } = {}) {
  await writeJson(resolveRepoPath(result.plan.outputs.summaryPath), createSummary())
  await writeText(resolveRepoPath(result.plan.outputs.reportPath), '# Device loop report self-test\n')
  if (result.browserEvidence) {
    await writeJson(resolveRepoPath(result.plan.outputs.browserEvidenceResultJsonPath), result.browserEvidence)
  }
  if (result.esp32Serial?.liveCapture) {
    await writeJson(resolveRepoPath(result.plan.outputs.esp32SerialResultJsonPath), result.esp32Serial.liveCapture)
  }
  if (result.esp32Serial?.savedLogRecheck) {
    await writeJson(resolveRepoPath(result.plan.outputs.esp32SerialRecheckResultJsonPath), result.esp32Serial.savedLogRecheck)
  }
  await writeText(resolveRepoPath(result.plan.outputs.esp32SerialLogPath), serialLogText)
}

function serialLog() {
  return [
    '[HomeCue Edge] ESP32-S3-AUDIO-Board firmware booting...',
    '[/health] HTTP 200',
    '> serial homecue:plan 0',
    '[/plan] proposed 5 action(s) - awaiting confirmation',
    '> serial homecue:execute',
    '  exec light.set_scene -> accepted',
  ].join('\n')
}

function setResultJsonPath(result, file) {
  result.plan.outputs.resultJsonPath = toRepoPath(file)
}

function refreshCommand(result, commandName) {
  result.plan.commands[commandName].display = displayCommand('powershell', result.plan.commands[commandName].args)
  const check = result.checks.find((entry) => entry.command.startsWith('powershell') && entry.name.includes(commandName === 'fullLoop' ? 'device' : commandName))
  if (check) check.command = result.plan.commands[commandName].display
}

function removeArg(args, flag) {
  const index = args.indexOf(flag)
  if (index !== -1) args.splice(index, 1)
}

function currentSourceState() {
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
}

function formatSourceState(sourceState) {
  const commit = typeof sourceState.commit === 'string' ? sourceState.commit.slice(0, 7) : 'unknown'
  const dirty = sourceState.dirty === true ? 'dirty' : sourceState.dirty === false ? 'clean' : 'unknown'
  const statusCount = Number.isInteger(sourceState.statusCount) ? sourceState.statusCount : 'unknown'
  const statusSha = typeof sourceState.statusSha256 === 'string' ? sourceState.statusSha256 : 'unknown'
  return `${sourceState.branch ?? 'unknown'}@${commit}/${dirty}#${statusCount}:${statusSha}`
}

function gitOutput(args) {
  return execFileSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim()
}

function displayCommand(executable, args) {
  return [executable, ...args].join(' ')
}

async function runValidator(file, args = []) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [validatorScript, file, ...args], {
      cwd: path.join(repoRoot, 'apps', 'web'),
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let output = ''

    child.stdout.on('data', (chunk) => {
      output += chunk.toString()
    })
    child.stderr.on('data', (chunk) => {
      output += chunk.toString()
    })
    child.on('error', reject)
    child.on('close', (code) => {
      resolve({ code, output })
    })
  })
}

async function writeJson(file, value) {
  await writeJsonFile(file, value)
}

async function writeText(file, value) {
  await mkdir(path.dirname(file), { recursive: true })
  await writeFile(file, value, 'utf8')
}

function resolveRepoPath(file) {
  return path.isAbsolute(file) ? file : path.resolve(repoRoot, file)
}

function toRepoPath(file) {
  return path.relative(repoRoot, file).replaceAll(path.sep, '/')
}

function assertOutputIncludes(actual, expected, label) {
  if (!actual.includes(expected)) {
    throw new Error(`${label}: expected output to include ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
  }
}

function assertOutputExcludes(actual, expected, label) {
  if (actual.includes(expected)) {
    throw new Error(`${label}: expected output not to include ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
  }
}
