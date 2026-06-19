import { createHash } from 'node:crypto'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parityErrorsSignature, recomputeBrowserParity, validateBrowserParityInputs } from './summary-parity.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const defaultResultFile = path.join(repoRoot, 'assets', 'tmp', 'computer-loop-check.json')
const resultFile = resolveCliPath(process.argv[2] ?? defaultResultFile)
const MIN_LOCALIZED_PHRASE_COUNT = 7
const result = JSON.parse(await readFile(resultFile, 'utf8'))
const errors = await validateComputerLoopResult(result, resultFile)

if (errors.length) {
  console.error(`Computer loop result validation failed: ${resultFile}`)
  for (const error of errors) {
    console.error(`- ${error}`)
  }
  process.exit(1)
}

console.log(`Computer loop result validation passed: ${resultFile}`)
if (result.mode === 'validate') {
  console.log(formatProofSummary(result.proofSummary))
}

async function validateComputerLoopResult(value, validatedResultFile) {
  const errors = []

  if (!value || typeof value !== 'object') {
    return ['Computer loop result root must be an object.']
  }

  assertString(errors, value.generatedAt, 'generatedAt')
  if (!Number.isFinite(Date.parse(value.generatedAt))) {
    errors.push('generatedAt must be a valid timestamp.')
  }
  if (!['dry-run', 'validate', 'failed'].includes(value.mode)) errors.push('mode must be dry-run, validate, or failed.')
  if (value.mode === 'failed') {
    if (value.success !== false) errors.push('success must be false in failed mode.')
  } else if (value.success !== true) {
    errors.push('success must be true.')
  }
  assertString(errors, value.runId, 'runId')
  if (value.plan?.runId && value.runId !== value.plan.runId) {
    errors.push('runId must match plan.runId.')
  }

  validatePlan(errors, value.plan, validatedResultFile)
  validateChecks(errors, value.checks, value.plan)

  if (value.mode === 'validate') {
    await validateValidateMode(errors, value)
  } else if (value.mode === 'failed') {
    validateFailedMode(errors, value)
  } else {
    if (value.proofSummary !== null && value.proofSummary !== undefined) {
      errors.push('proofSummary must be null or omitted in dry-run mode.')
    }
    if (value.browserEvidence !== null && value.browserEvidence !== undefined) {
      errors.push('browserEvidence must be null or omitted in dry-run mode.')
    }
  }

  return errors
}

function validatePlan(errors, plan, validatedResultFile) {
  if (!plan || typeof plan !== 'object') {
    errors.push('plan is missing.')
    return
  }

  assertString(errors, plan.runId, 'plan.runId')
  if (plan.requestedLoops?.desktop !== true) errors.push('plan.requestedLoops.desktop must be true.')
  if (plan.requestedLoops?.phone !== false) errors.push('plan.requestedLoops.phone must be false.')
  if (plan.requestedLoops?.windowsChrome !== true) errors.push('plan.requestedLoops.windowsChrome must be true.')

  if (!positiveInteger(plan.options?.startupTimeoutSeconds)) {
    errors.push('plan.options.startupTimeoutSeconds must be a positive integer.')
  }
  if (!positiveInteger(plan.options?.stepTimeoutSeconds)) {
    errors.push('plan.options.stepTimeoutSeconds must be a positive integer.')
  }
  if (!positiveInteger(plan.options?.browserWrapperSharedStateLockTimeoutSeconds)) {
    errors.push('plan.options.browserWrapperSharedStateLockTimeoutSeconds must be a positive integer.')
  }
  if (typeof plan.options?.skipPreflight !== 'boolean') errors.push('plan.options.skipPreflight must be boolean.')
  if (typeof plan.options?.selfTest !== 'boolean') errors.push('plan.options.selfTest must be boolean.')

  validateOutputs(errors, plan.outputs)
  validateGates(errors, plan.gates)
  validateCommands(errors, plan.commands)
  validatePlanConsistency(errors, plan, validatedResultFile)
}

function validateOutputs(errors, outputs) {
  if (!outputs || typeof outputs !== 'object') {
    errors.push('plan.outputs is missing.')
    return
  }

  for (const label of ['outputDir', 'reportPath', 'summaryPath', 'resultJsonPath', 'browserEvidenceResultJsonPath']) {
    assertString(errors, outputs[label], `plan.outputs.${label}`)
    if (typeof outputs[label] === 'string') validateRepoPath(errors, outputs[label], `plan.outputs.${label}`)
  }

  const outputDir = resolveRepoPath(outputs.outputDir)
  if (!outputDir) return

  for (const label of ['reportPath', 'summaryPath', 'browserEvidenceResultJsonPath']) {
    if (!isInsidePath(outputs[label], outputs.outputDir)) {
      errors.push(`plan.outputs.${label} must be inside plan.outputs.outputDir.`)
    }
  }
}

function validateGates(errors, gates) {
  if (!gates || typeof gates !== 'object') {
    errors.push('plan.gates is missing.')
    return
  }

  if (gates.fullLoopIncludeChrome !== true) errors.push('plan.gates.fullLoopIncludeChrome must be true.')
  if (gates.fullLoopIncludePhone !== false) errors.push('plan.gates.fullLoopIncludePhone must be false.')
  if (gates.browserEvidenceRequireDesktop !== true) {
    errors.push('plan.gates.browserEvidenceRequireDesktop must be true.')
  }
  if (gates.browserEvidenceRequireChrome !== true) errors.push('plan.gates.browserEvidenceRequireChrome must be true.')
  if (gates.browserEvidenceRequirePhone !== false) errors.push('plan.gates.browserEvidenceRequirePhone must be false.')
  if (typeof gates.browserEvidenceSelfTest !== 'boolean') {
    errors.push('plan.gates.browserEvidenceSelfTest must be boolean.')
  }
  validateBrowserWrapperLock(errors, gates.browserWrapperSharedStateLock)
  validateFullLoopWebReadiness(errors, gates.fullLoopWebReadiness)
}

function validateCommands(errors, commands) {
  if (!commands || typeof commands !== 'object') {
    errors.push('plan.commands is missing.')
    return
  }

  validateCommand(errors, commands.fullLoop, 'plan.commands.fullLoop', [
    'check-full-loop.ps1',
    '-IncludeChrome',
    '-BrowserWrapperSharedStateLockTimeoutSeconds',
    '-PartialEvidenceDir',
    '-ReportPath',
    '-SummaryPath',
  ])
  validateCommand(errors, commands.browserEvidence, 'plan.commands.browserEvidence', [
    'check-browser-evidence.ps1',
    '-RequireDesktop',
    '-RequireChrome',
    '-ResultJsonPath',
  ])

  if (arrayContains(commands.fullLoop?.args, '-IncludePhone')) {
    errors.push('plan.commands.fullLoop.args must not include -IncludePhone for computer-only checks.')
  }
  if (arrayContains(commands.browserEvidence?.args, '-RequirePhone')) {
    errors.push('plan.commands.browserEvidence.args must not include -RequirePhone for computer-only checks.')
  }
}

function validatePlanConsistency(errors, plan, validatedResultFile) {
  const outputs = plan.outputs ?? {}
  const options = plan.options ?? {}
  const gates = plan.gates ?? {}
  const commands = plan.commands ?? {}

  compareRepoPaths(
    errors,
    outputs.resultJsonPath,
    validatedResultFile,
    'plan.outputs.resultJsonPath',
    'validated result file',
  )

  if (gates.browserEvidenceSelfTest !== options.selfTest) {
    errors.push('plan.gates.browserEvidenceSelfTest must match plan.options.selfTest.')
  }
  if (gates.browserWrapperSharedStateLock?.timeoutSeconds !== options.browserWrapperSharedStateLockTimeoutSeconds) {
    errors.push(
      'plan.gates.browserWrapperSharedStateLock.timeoutSeconds must match plan.options.browserWrapperSharedStateLockTimeoutSeconds.',
    )
  }

  validateCommandFlag(
    errors,
    commands.fullLoop?.args,
    '-IncludeChrome',
    gates.fullLoopIncludeChrome === true,
    'plan.commands.fullLoop -IncludeChrome',
    'plan.gates.fullLoopIncludeChrome',
  )
  validateCommandFlag(
    errors,
    commands.fullLoop?.args,
    '-IncludePhone',
    gates.fullLoopIncludePhone === true,
    'plan.commands.fullLoop -IncludePhone',
    'plan.gates.fullLoopIncludePhone',
  )
  validateCommandFlag(
    errors,
    commands.fullLoop?.args,
    '-SkipPreflight',
    options.skipPreflight === true,
    'plan.commands.fullLoop -SkipPreflight',
    'plan.options.skipPreflight',
  )
  validateCommandArgValue(
    errors,
    commands.fullLoop?.args,
    '-StartupTimeoutSeconds',
    options.startupTimeoutSeconds,
    'plan.commands.fullLoop -StartupTimeoutSeconds',
    'plan.options.startupTimeoutSeconds',
  )
  validateCommandArgValue(
    errors,
    commands.fullLoop?.args,
    '-StepTimeoutSeconds',
    options.stepTimeoutSeconds,
    'plan.commands.fullLoop -StepTimeoutSeconds',
    'plan.options.stepTimeoutSeconds',
  )
  validateCommandArgValue(
    errors,
    commands.fullLoop?.args,
    '-BrowserWrapperSharedStateLockTimeoutSeconds',
    options.browserWrapperSharedStateLockTimeoutSeconds,
    'plan.commands.fullLoop -BrowserWrapperSharedStateLockTimeoutSeconds',
    'plan.options.browserWrapperSharedStateLockTimeoutSeconds',
  )
  validateCommandArgPath(
    errors,
    commands.fullLoop?.args,
    '-PartialEvidenceDir',
    outputs.outputDir,
    'plan.commands.fullLoop -PartialEvidenceDir',
    'plan.outputs.outputDir',
  )
  validateCommandArgPath(
    errors,
    commands.fullLoop?.args,
    '-ReportPath',
    outputs.reportPath,
    'plan.commands.fullLoop -ReportPath',
    'plan.outputs.reportPath',
  )
  validateCommandArgPath(
    errors,
    commands.fullLoop?.args,
    '-SummaryPath',
    outputs.summaryPath,
    'plan.commands.fullLoop -SummaryPath',
    'plan.outputs.summaryPath',
  )

  validateCommandFlag(
    errors,
    commands.browserEvidence?.args,
    '-RequireDesktop',
    gates.browserEvidenceRequireDesktop === true,
    'plan.commands.browserEvidence -RequireDesktop',
    'plan.gates.browserEvidenceRequireDesktop',
  )
  validateCommandFlag(
    errors,
    commands.browserEvidence?.args,
    '-RequireChrome',
    gates.browserEvidenceRequireChrome === true,
    'plan.commands.browserEvidence -RequireChrome',
    'plan.gates.browserEvidenceRequireChrome',
  )
  validateCommandFlag(
    errors,
    commands.browserEvidence?.args,
    '-RequirePhone',
    gates.browserEvidenceRequirePhone === true,
    'plan.commands.browserEvidence -RequirePhone',
    'plan.gates.browserEvidenceRequirePhone',
  )
  validateCommandFlag(
    errors,
    commands.browserEvidence?.args,
    '-SelfTest',
    gates.browserEvidenceSelfTest === true,
    'plan.commands.browserEvidence -SelfTest',
    'plan.gates.browserEvidenceSelfTest',
  )
  validateCommandArgPath(
    errors,
    commands.browserEvidence?.args,
    '-SummaryPath',
    outputs.summaryPath,
    'plan.commands.browserEvidence -SummaryPath',
    'plan.outputs.summaryPath',
  )
  validateCommandArgPath(
    errors,
    commands.browserEvidence?.args,
    '-ResultJsonPath',
    outputs.browserEvidenceResultJsonPath,
    'plan.commands.browserEvidence -ResultJsonPath',
    'plan.outputs.browserEvidenceResultJsonPath',
  )
}

function validateCommand(errors, command, label, requiredTokens) {
  if (!command || typeof command !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  if (command.executable !== 'powershell') errors.push(`${label}.executable must be powershell.`)
  if (!Array.isArray(command.args)) errors.push(`${label}.args must be an array.`)
  assertString(errors, command.display, `${label}.display`)

  const display = typeof command.display === 'string' ? command.display : ''
  for (const token of requiredTokens) {
    if (!arrayContains(command.args, token) && !display.includes(token)) {
      errors.push(`${label} must include ${token}.`)
    }
  }

  if (Array.isArray(command.args)) {
    for (const argument of command.args) {
      if (typeof argument === 'string' && !display.includes(argument)) {
        errors.push(`${label}.display must include args entry: ${argument}.`)
      }
    }
  }
}

function validateBrowserWrapperLock(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('plan.gates.browserWrapperSharedStateLock is missing.')
    return
  }

  if (value.name !== 'Global\\HCEdgeBrowserLoopGate') {
    errors.push('plan.gates.browserWrapperSharedStateLock.name must be Global\\HCEdgeBrowserLoopGate.')
  }
  if (!positiveInteger(value.timeoutSeconds)) {
    errors.push('plan.gates.browserWrapperSharedStateLock.timeoutSeconds must be a positive integer.')
  }
}

function validateFullLoopWebReadiness(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('plan.gates.fullLoopWebReadiness is missing.')
    return
  }

  if (value.httpProbeBeforePortReuse !== true) {
    errors.push('plan.gates.fullLoopWebReadiness.httpProbeBeforePortReuse must be true.')
  }
  if (value.stalePortBlocksDuplicateStart !== true) {
    errors.push('plan.gates.fullLoopWebReadiness.stalePortBlocksDuplicateStart must be true.')
  }
}

function validateChecks(errors, checks, plan) {
  if (!Array.isArray(checks) || checks.length !== 2) {
    errors.push('checks must contain exactly two entries.')
    return
  }

  const fullLoop = checks.find((check) => check?.name === 'computer full loop')
  const browserEvidence = checks.find((check) => check?.name === 'saved browser evidence recheck')
  if (!fullLoop) errors.push('checks missing computer full loop entry.')
  if (!browserEvidence) errors.push('checks missing saved browser evidence recheck entry.')
  if (fullLoop?.required !== true) errors.push('computer full loop check must be required.')
  if (browserEvidence?.required !== true) errors.push('saved browser evidence recheck must be required.')
  if (plan?.outputs?.summaryPath && fullLoop?.summaryPath !== plan.outputs.summaryPath) {
    errors.push('computer full loop summaryPath must match plan.outputs.summaryPath.')
  }
  if (plan?.outputs?.reportPath && fullLoop?.reportPath !== plan.outputs.reportPath) {
    errors.push('computer full loop reportPath must match plan.outputs.reportPath.')
  }
  if (plan?.commands?.fullLoop?.display && fullLoop?.command !== plan.commands.fullLoop.display) {
    errors.push('computer full loop command must match plan.commands.fullLoop.display.')
  }
  if (plan?.outputs?.browserEvidenceResultJsonPath && browserEvidence?.resultJsonPath !== plan.outputs.browserEvidenceResultJsonPath) {
    errors.push('saved browser evidence resultJsonPath must match plan.outputs.browserEvidenceResultJsonPath.')
  }
  if (plan?.commands?.browserEvidence?.display && browserEvidence?.command !== plan.commands.browserEvidence.display) {
    errors.push('saved browser evidence command must match plan.commands.browserEvidence.display.')
  }
}

async function validateValidateMode(errors, value) {
  const outputs = value.plan?.outputs ?? {}

  await assertExistingFile(errors, outputs.reportPath, 'plan.outputs.reportPath')
  await assertExistingFile(errors, outputs.summaryPath, 'plan.outputs.summaryPath')
  await assertExistingFile(errors, outputs.browserEvidenceResultJsonPath, 'plan.outputs.browserEvidenceResultJsonPath')
  const report = await readReferencedText(errors, outputs.reportPath, 'plan.outputs.reportPath')
  const summary = await readReferencedJson(errors, outputs.summaryPath, 'plan.outputs.summaryPath')
  const browserEvidenceFile = await readReferencedJson(errors, outputs.browserEvidenceResultJsonPath, 'plan.outputs.browserEvidenceResultJsonPath')

  const browserEvidence = value.browserEvidence
  if (!browserEvidence || typeof browserEvidence !== 'object') {
    errors.push('browserEvidence is missing in validate mode.')
    return
  }
  assertString(errors, browserEvidence.generatedAt, 'browserEvidence.generatedAt')
  if (!Number.isFinite(timestampMs(browserEvidence.generatedAt))) {
    errors.push('browserEvidence.generatedAt must be a valid timestamp.')
  }
  if (browserEvidenceFile && stableJson(browserEvidenceFile) !== stableJson(browserEvidence)) {
    errors.push('browserEvidence must exactly match plan.outputs.browserEvidenceResultJsonPath content.')
  }
  if (browserEvidence.success !== true) errors.push('browserEvidence.success must be true.')
  if (browserEvidence.mode !== 'validate') errors.push('browserEvidence.mode must be validate.')
  if (browserEvidence.plan?.inferredFromSummary?.desktop !== true) {
    errors.push('browserEvidence.plan.inferredFromSummary.desktop must be true.')
  }
  if (browserEvidence.plan?.inferredFromSummary?.windowsChrome !== true) {
    errors.push('browserEvidence.plan.inferredFromSummary.windowsChrome must be true.')
  }
  if (browserEvidence.plan?.inferredFromSummary?.phone !== false) {
    errors.push('browserEvidence.plan.inferredFromSummary.phone must be false.')
  }
  if (browserEvidence.plan?.requiredEvidence?.desktop !== true) {
    errors.push('browserEvidence.plan.requiredEvidence.desktop must be true.')
  }
  if (browserEvidence.plan?.requiredEvidence?.windowsChrome !== true) {
    errors.push('browserEvidence.plan.requiredEvidence.windowsChrome must be true.')
  }
  if (browserEvidence.plan?.requiredEvidence?.phone !== false) {
    errors.push('browserEvidence.plan.requiredEvidence.phone must be false.')
  }
  if (stableJson(browserEvidence.plan?.requiredEvidence) !== stableJson(browserEvidence.plan?.inferredFromSummary)) {
    errors.push('browserEvidence.plan.requiredEvidence must match inferredFromSummary for computer-only result.')
  }
  validateBrowserEvidenceSelfTest(errors, browserEvidence.plan?.selfTest, value.plan?.options?.selfTest === true)

  compareRepoPaths(
    errors,
    browserEvidence.plan?.summaryPath,
    outputs.summaryPath,
    'browserEvidence.plan.summaryPath',
    'plan.outputs.summaryPath',
  )
  compareRepoPaths(
    errors,
    browserEvidence.plan?.resultJsonPath,
    outputs.browserEvidenceResultJsonPath,
    'browserEvidence.plan.resultJsonPath',
    'plan.outputs.browserEvidenceResultJsonPath',
  )
  validateTimestampNotEarlier(errors, value.generatedAt, browserEvidence.generatedAt, 'generatedAt', 'browserEvidence.generatedAt')
  validateTimestampNotEarlier(errors, value.generatedAt, summary?.generatedAt, 'generatedAt', 'summary.generatedAt')
  validateTimestampNotEarlier(
    errors,
    browserEvidence.generatedAt,
    summary?.generatedAt,
    'browserEvidence.generatedAt',
    'summary.generatedAt',
  )
  validateNestedBrowserEvidencePaths(errors, browserEvidence.plan, outputs)
  validateBrowserEvidenceProofSummary(errors, browserEvidence.proofSummary, summary, browserEvidence.plan)
  await validateSummaryEvidence(errors, summary, browserEvidence.plan, value.plan)
  validateProofSummary(errors, value.proofSummary, summary, browserEvidence, value.plan)
  validateReportEvidence(errors, report, summary)
  await validateRawLoopEvidence(errors, summary, browserEvidence.plan, value.generatedAt)

  const browserEvidenceChecks = Array.isArray(browserEvidence.checks) ? browserEvidence.checks : []
  const commandEntries = new Map(browserEvidenceChecks.map((check) => [check?.command, check]))
  validateBrowserEvidenceCheck(errors, commandEntries, {
    command: 'npm run desktop:evidence:check',
    path: browserEvidence.plan?.paths?.desktopEvidence,
    screenshotDir: browserEvidence.plan?.paths?.desktopScreenshotDir,
  })
  validateBrowserEvidenceCheck(errors, commandEntries, {
    command: 'npm run desktop:evidence:check -- --require-installed-chrome',
    path: browserEvidence.plan?.paths?.windowsChromeEvidence,
    screenshotDir: browserEvidence.plan?.paths?.windowsChromeScreenshotDir,
  })
  validateBrowserEvidenceCheck(errors, commandEntries, {
    command: 'npm run summary:check',
    path: browserEvidence.plan?.summaryPath,
  })
  if (commandEntries.has('npm run phone:evidence:check')) {
    errors.push('browserEvidence.checks must not include phone evidence check for computer-only result.')
  }
  validateBrowserEvidenceSelfTestCommands(errors, commandEntries, browserEvidence.plan)
}

function validateFailedMode(errors, value) {
  if (value.proofSummary !== null && value.proofSummary !== undefined) {
    errors.push('proofSummary must be null or omitted in failed mode.')
  }
  if (value.browserEvidence !== null && value.browserEvidence !== undefined) {
    errors.push('browserEvidence must be null or omitted in failed mode.')
  }

  const failure = value.failure
  if (!failure || typeof failure !== 'object') {
    errors.push('failure is missing in failed mode.')
    return
  }

  if (!['computer full loop', 'saved browser evidence recheck', 'result validation'].includes(failure.stage)) {
    errors.push('failure.stage must identify a computer loop stage.')
  }
  if (failure.checkName !== failure.stage) {
    errors.push('failure.checkName must match failure.stage.')
  }
  assertString(errors, failure.message, 'failure.message')
  if (failure.exitCode !== null && failure.exitCode !== undefined && !Number.isInteger(failure.exitCode)) {
    errors.push('failure.exitCode must be an integer, null, or omitted.')
  }
  if (failure.command !== null && failure.command !== undefined) {
    assertString(errors, failure.command, 'failure.command')
  }

  validateFailureCommand(errors, failure, value.plan)
}

function validateFailureCommand(errors, failure, plan) {
  if (typeof failure?.command !== 'string' || failure.command.length === 0) return

  const expectedCommands = {
    'computer full loop': plan?.commands?.fullLoop?.display,
    'saved browser evidence recheck': plan?.commands?.browserEvidence?.display,
    'result validation': [
      `npm run computer:result:check -- ${resolveRepoPath(plan?.outputs?.resultJsonPath) ?? plan?.outputs?.resultJsonPath}`,
      'post-process computer loop evidence',
    ],
  }
  const expected = expectedCommands[failure.stage]

  if (Array.isArray(expected) && !expected.includes(failure.command)) {
    errors.push('failure.command must match the command for failure.stage.')
  } else if (typeof expected === 'string' && expected.length > 0 && failure.command !== expected) {
    errors.push('failure.command must match the command for failure.stage.')
  }
}

function validateProofSummary(errors, proofSummary, summary, browserEvidence, plan) {
  if (!proofSummary || typeof proofSummary !== 'object') {
    errors.push('proofSummary is missing in validate mode.')
    return
  }
  if (!summary || typeof summary !== 'object') return

  compareValue(errors, proofSummary.summaryRunId, summary.runId, 'proofSummary.summaryRunId', 'summary.runId')
  compareValue(errors, proofSummary.appUrl, summary.appUrl, 'proofSummary.appUrl', 'summary.appUrl')
  compareValue(errors, proofSummary.apiBase, summary.apiBase, 'proofSummary.apiBase', 'summary.apiBase')
  compareValue(
    errors,
    stableJson(proofSummary.requestedLoops ?? {}),
    stableJson(plan?.requestedLoops ?? {}),
    'proofSummary.requestedLoops',
    'plan.requestedLoops',
  )
  validateProofSummaryParity(errors, proofSummary.browserParity, summary.browserParity)
  validateProofSummaryWebReadiness(errors, proofSummary.webReadiness, summary.environment?.webReadiness)
  validateProofSummaryLoop(errors, proofSummary.loops?.desktop, summary.loops?.desktop, 'proofSummary.loops.desktop')
  validateProofSummaryLoop(
    errors,
    proofSummary.loops?.windowsChrome,
    summary.loops?.windowsChrome,
    'proofSummary.loops.windowsChrome',
  )
  compareValue(errors, proofSummary.loops?.phone?.run, false, 'proofSummary.loops.phone.run', 'computer-only false')
  compareValue(
    errors,
    proofSummary.loops?.phone?.success ?? null,
    summary.loops?.phone?.success ?? null,
    'proofSummary.loops.phone.success',
    'summary.loops.phone.success',
  )
  compareValue(
    errors,
    proofSummary.evidence?.reportPath,
    plan?.outputs?.reportPath,
    'proofSummary.evidence.reportPath',
    'plan.outputs.reportPath',
  )
  compareValue(
    errors,
    proofSummary.evidence?.summaryPath,
    plan?.outputs?.summaryPath,
    'proofSummary.evidence.summaryPath',
    'plan.outputs.summaryPath',
  )
  compareValue(
    errors,
    proofSummary.evidence?.browserEvidenceResultJsonPath,
    plan?.outputs?.browserEvidenceResultJsonPath,
    'proofSummary.evidence.browserEvidenceResultJsonPath',
    'plan.outputs.browserEvidenceResultJsonPath',
  )
  compareValue(
    errors,
    proofSummary.evidence?.browserEvidenceSuccess,
    browserEvidence?.success,
    'proofSummary.evidence.browserEvidenceSuccess',
    'browserEvidence.success',
  )
  validateProofSummaryRawEvidencePaths(errors, proofSummary.evidence, browserEvidence?.proofSummary?.evidence)
}

function validateProofSummaryRawEvidencePaths(errors, evidence, browserEvidence) {
  if (!evidence || typeof evidence !== 'object') return

  for (const key of ['desktopEvidencePath', 'windowsChromeEvidencePath', 'webReadinessEvidencePath']) {
    compareRepoPaths(
      errors,
      evidence[key],
      browserEvidence?.[key],
      `proofSummary.evidence.${key}`,
      `browserEvidence.proofSummary.evidence.${key}`,
    )
  }
}

function validateProofSummaryWebReadiness(errors, proof, summary, label = 'proofSummary.webReadiness') {
  if (!proof || typeof proof !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  compareValue(errors, proof.run, summary?.run, `${label}.run`, 'summary.environment.webReadiness.run')
  compareValue(errors, proof.success, summary?.success, `${label}.success`, 'summary.environment.webReadiness.success')
  compareValue(errors, proof.strategy, summary?.strategy, `${label}.strategy`, 'summary.environment.webReadiness.strategy')
  compareValue(
    errors,
    proof.httpReadyAfter,
    summary?.httpReadyAfter,
    `${label}.httpReadyAfter`,
    'summary.environment.webReadiness.httpReadyAfter',
  )
  compareValue(
    errors,
    proof.duplicateStartAvoided,
    summary?.duplicateStartAvoided,
    `${label}.duplicateStartAvoided`,
    'summary.environment.webReadiness.duplicateStartAvoided',
  )
}

function validateProofSummaryParity(errors, proof, summary, label = 'proofSummary.browserParity') {
  if (!proof || typeof proof !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  compareValue(errors, proof.checked, summary?.checked, `${label}.checked`, 'summary.browserParity.checked')
  compareValue(errors, proof.success, summary?.success, `${label}.success`, 'summary.browserParity.success')
  compareValue(
    errors,
    proof.errorCount,
    Array.isArray(summary?.errors) ? summary.errors.length : null,
    `${label}.errorCount`,
    'summary.browserParity.errors.length',
  )
}

function validateProofSummaryLoop(errors, proof, summary, label) {
  if (!proof || typeof proof !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }
  if (!summary || typeof summary !== 'object') return

  compareValue(errors, proof.run, summary.run, `${label}.run`, 'summary loop run')
  compareValue(errors, proof.success, summary.success, `${label}.success`, 'summary loop success')
  compareValue(errors, proof.title, summary.title, `${label}.title`, 'summary loop title')
  compareValue(errors, proof.runButton, summary.localizedUi?.runButton, `${label}.runButton`, 'summary loop run button')
  compareValue(
    errors,
    proof.textRequiredPhrases,
    summary.textIntegrity?.requiredPhraseCount,
    `${label}.textRequiredPhrases`,
    'summary loop required phrase count',
  )
  compareValue(
    errors,
    proof.textMissingPhrases,
    summary.textIntegrity?.missingPhraseCount,
    `${label}.textMissingPhrases`,
    'summary loop missing phrase count',
  )
  compareValue(errors, proof.textMojibake, summary.textIntegrity?.mojibakeCount, `${label}.textMojibake`, 'summary loop mojibake count')
  compareValue(
    errors,
    proof.firstViewportMinVisibleRatio,
    summary.firstViewportVisibility?.minVisibleRatio,
    `${label}.firstViewportMinVisibleRatio`,
    'summary loop first viewport ratio',
  )
  compareValue(errors, proof.runtimeIssueCount, summary.runtimeHealth?.issueCount, `${label}.runtimeIssueCount`, 'summary loop issue count')
  compareValue(errors, proof.screenshotCount, summary.screenshotEvidence?.count, `${label}.screenshotCount`, 'summary loop screenshot count')
  compareValue(
    errors,
    proof.uniqueScreenshotDigestCount,
    summary.screenshotEvidence?.uniqueDigestCount,
    `${label}.uniqueScreenshotDigestCount`,
    'summary loop unique screenshot digest count',
  )
  compareValue(
    errors,
    proof.externalExecutionSource,
    summary.externalExecutionSync?.latestSource,
    `${label}.externalExecutionSource`,
    'summary loop external execution source',
  )
  compareValue(
    errors,
    proof.acceptedActionCount,
    summary.externalExecutionSync?.acceptedActionCount,
    `${label}.acceptedActionCount`,
    'summary loop accepted action count',
  )
}

function validateBrowserEvidenceProofSummary(errors, proofSummary, summary, browserEvidencePlan) {
  if (!proofSummary || typeof proofSummary !== 'object') {
    errors.push('browserEvidence.proofSummary is missing in validate mode.')
    return
  }
  if (!summary || typeof summary !== 'object') return

  compareValue(errors, proofSummary.summaryRunId, summary.runId, 'browserEvidence.proofSummary.summaryRunId', 'summary.runId')
  compareValue(errors, proofSummary.appUrl, summary.appUrl, 'browserEvidence.proofSummary.appUrl', 'summary.appUrl')
  compareValue(errors, proofSummary.apiBase, summary.apiBase, 'browserEvidence.proofSummary.apiBase', 'summary.apiBase')
  compareValue(
    errors,
    stableJson(proofSummary.requiredEvidence ?? {}),
    stableJson(browserEvidencePlan?.requiredEvidence ?? {}),
    'browserEvidence.proofSummary.requiredEvidence',
    'browserEvidence.plan.requiredEvidence',
  )
  validateProofSummaryParity(errors, proofSummary.browserParity, summary.browserParity, 'browserEvidence.proofSummary.browserParity')
  validateProofSummaryWebReadiness(
    errors,
    proofSummary.webReadiness,
    summary.environment?.webReadiness,
    'browserEvidence.proofSummary.webReadiness',
  )
  validateProofSummaryLoop(
    errors,
    proofSummary.loops?.desktop,
    summary.loops?.desktop,
    'browserEvidence.proofSummary.loops.desktop',
  )
  validateProofSummaryLoop(
    errors,
    proofSummary.loops?.windowsChrome,
    summary.loops?.windowsChrome,
    'browserEvidence.proofSummary.loops.windowsChrome',
  )
  compareValue(
    errors,
    proofSummary.loops?.phone?.run,
    summary.loops?.phone?.run,
    'browserEvidence.proofSummary.loops.phone.run',
    'summary.loops.phone.run',
  )
  compareValue(
    errors,
    proofSummary.loops?.phone?.success ?? null,
    summary.loops?.phone?.success ?? null,
    'browserEvidence.proofSummary.loops.phone.success',
    'summary.loops.phone.success',
  )
  validateBrowserEvidenceProofSummaryPaths(errors, proofSummary.evidence, browserEvidencePlan)
  validateBrowserEvidenceProofSummaryWebReadinessPath(errors, proofSummary.evidence, summary)
}

function validateBrowserEvidenceProofSummaryPaths(errors, evidence, browserEvidencePlan) {
  if (!evidence || typeof evidence !== 'object') {
    errors.push('browserEvidence.proofSummary.evidence is missing.')
    return
  }

  const pairs = [
    ['summaryPath', browserEvidencePlan?.summaryPath],
    ['desktopEvidencePath', browserEvidencePlan?.paths?.desktopEvidence],
    ['windowsChromeEvidencePath', browserEvidencePlan?.paths?.windowsChromeEvidence],
    ['phoneEvidencePath', browserEvidencePlan?.paths?.phoneEvidence],
    ['desktopScreenshotDir', browserEvidencePlan?.paths?.desktopScreenshotDir],
    ['windowsChromeScreenshotDir', browserEvidencePlan?.paths?.windowsChromeScreenshotDir],
  ]
  for (const [key, expected] of pairs) {
    compareRepoPaths(errors, evidence[key], expected, `browserEvidence.proofSummary.evidence.${key}`, `browserEvidence.plan ${key}`)
  }
}

function validateBrowserEvidenceProofSummaryWebReadinessPath(errors, evidence, summary) {
  if (!evidence || typeof evidence !== 'object') return

  const manifest = manifestByLabel(summary?.evidence?.files)
  compareRepoPaths(
    errors,
    evidence.webReadinessEvidencePath,
    manifest.get('Web Readiness JSON')?.file,
    'browserEvidence.proofSummary.evidence.webReadinessEvidencePath',
    'summary.evidence Web Readiness JSON',
  )
}

function formatProofSummary(proofSummary) {
  if (!proofSummary || typeof proofSummary !== 'object') {
    return 'Computer loop proof summary: unavailable'
  }

  return [
    'Computer loop proof summary:',
    `summaryRunId=${proofSummary.summaryRunId ?? 'unknown'}`,
    `desktop=${formatProofBoolean(proofSummary.loops?.desktop?.success)}`,
    `chrome=${formatProofBoolean(proofSummary.loops?.windowsChrome?.success)}`,
    `parity=${formatProofBoolean(proofSummary.browserParity?.success)}`,
    `web=${proofSummary.webReadiness?.strategy ?? 'unknown'}`,
    `screenshots=${proofSummary.loops?.desktop?.screenshotCount ?? 'unknown'}+${
      proofSummary.loops?.windowsChrome?.screenshotCount ?? 'unknown'
    }`,
    `text=${formatProofText(proofSummary.loops?.desktop)}+${formatProofText(proofSummary.loops?.windowsChrome)}`,
    `external=${proofSummary.loops?.desktop?.externalExecutionSource ?? 'unknown'}`,
    `summary=${proofSummary.evidence?.summaryPath ?? 'unknown'}`,
  ].join(' ')
}

function formatProofText(loop) {
  if (!loop || loop.run !== true) return '0/0/0'

  return `${loop.textRequiredPhrases ?? 'unknown'}/${loop.textMissingPhrases ?? 'unknown'}/${
    loop.textMojibake ?? 'unknown'
  }`
}

function formatProofBoolean(value) {
  if (value === true) return 'pass'
  if (value === false) return 'fail'
  return 'unknown'
}

function formatWebReadiness(value) {
  if (!value?.run) return 'not run'
  const status = value.success === true ? 'pass' : 'fail'
  return `${status} (${value.strategy ?? 'unknown'}, port before:${formatBoolean(
    value.portListeningBefore,
  )}, http before:${formatBoolean(value.httpReadyBefore)})`
}

function formatBoolean(value) {
  if (value === true) return 'yes'
  if (value === false) return 'no'
  return 'unknown'
}

function validateBrowserEvidenceSelfTest(errors, value, requested) {
  if (!value || typeof value !== 'object') {
    errors.push('browserEvidence.plan.selfTest is missing.')
    return
  }

  const expected = {
    requested,
    phoneEvidence: false,
    desktopEvidence: requested,
    summary: requested,
    report: false,
  }

  for (const [key, expectedValue] of Object.entries(expected)) {
    if (value[key] !== expectedValue) {
      errors.push(`browserEvidence.plan.selfTest.${key} must match plan.options.selfTest for computer-only result.`)
    }
  }
}

function validateBrowserEvidenceSelfTestCommands(errors, commandEntries, plan) {
  const checks = [
    ['phoneEvidence', 'npm run phone:evidence:selftest'],
    ['desktopEvidence', 'npm run desktop:evidence:selftest'],
    ['summary', `npm run summary:selftest -- ${plan?.summaryPath}`],
    ['report', 'npm run report:selftest'],
  ]

  for (const [key, command] of checks) {
    const expected = plan?.selfTest?.[key] === true
    const check = commandEntries.get(command)
    const present = Boolean(check)
    if (expected && !present) {
      errors.push(`browserEvidence.checks missing self-test command: ${command}`)
    }
    if (expected && check?.required !== true) {
      errors.push(`browserEvidence.checks self-test command must be required: ${command}`)
    }
    if (!expected && present) {
      errors.push(`browserEvidence.checks must not include self-test command: ${command}`)
    }
  }
}

function validateBrowserEvidenceCheck(errors, commandEntries, { command, path: expectedPath, screenshotDir }) {
  const check = commandEntries.get(command)
  if (!check) {
    errors.push(`browserEvidence.checks missing command: ${command}`)
    return
  }

  if (check.required !== true) {
    errors.push(`browserEvidence.checks ${command} must be required.`)
  }
  compareRepoPaths(errors, check.path, expectedPath, `browserEvidence.checks ${command} path`, `browserEvidence.plan ${command} path`)

  if (screenshotDir) {
    compareRepoPaths(
      errors,
      check.screenshotDir,
      screenshotDir,
      `browserEvidence.checks ${command} screenshotDir`,
      `browserEvidence.plan ${command} screenshotDir`,
    )
  } else if (check.screenshotDir !== undefined) {
    errors.push(`browserEvidence.checks ${command} must not include screenshotDir.`)
  }
}

function validateReportEvidence(errors, report, summary) {
  if (typeof report !== 'string' || !summary || typeof summary !== 'object') return

  for (const [label, expected] of [
    ['Desktop loop', 'pass'],
    ['Windows Chrome loop', 'pass'],
    ['Phone loop', 'not run'],
    ['Run ID', summary.runId],
    ['Web readiness', formatWebReadiness(summary.environment?.webReadiness)],
    ['App URL', summary.appUrl],
    ['API base', summary.apiBase],
  ]) {
    if (typeof expected !== 'string' || expected.length === 0) continue
    const line = `- ${label}: ${expected}`
    if (!report.includes(line)) {
      errors.push(`report must include "${line}".`)
    }
  }
}

async function validateSummaryEvidence(errors, summary, browserEvidencePlan, resultPlan) {
  if (!summary || typeof summary !== 'object') return

  assertString(errors, summary.generatedAt, 'summary.generatedAt')
  if (!Number.isFinite(timestampMs(summary.generatedAt))) {
    errors.push('summary.generatedAt must be a valid timestamp.')
  }
  if (summary.success !== true) errors.push('summary.success must be true.')
  assertString(errors, summary.runId, 'summary.runId')
  if (summary.loops?.desktop?.run === true && summary.loops.desktop.runId !== summary.runId) {
    errors.push('summary.loops.desktop.runId must match summary.runId.')
  }
  if (summary.loops?.windowsChrome?.run === true && summary.loops.windowsChrome.runId !== summary.runId) {
    errors.push('summary.loops.windowsChrome.runId must match summary.runId.')
  }
  if (summary.loops?.desktop?.run !== true) errors.push('summary.loops.desktop.run must be true.')
  if (summary.loops?.desktop?.success !== true) errors.push('summary.loops.desktop.success must be true.')
  if (summary.loops?.windowsChrome?.run !== true) errors.push('summary.loops.windowsChrome.run must be true.')
  if (summary.loops?.windowsChrome?.success !== true) errors.push('summary.loops.windowsChrome.success must be true.')
  if (summary.loops?.phone?.run !== false) errors.push('summary.loops.phone.run must be false for computer-only result.')
  validateSummaryLocalizedUi(errors, summary.loops?.desktop, 'summary.loops.desktop')
  validateSummaryLocalizedUi(errors, summary.loops?.windowsChrome, 'summary.loops.windowsChrome')
  if (summary.browserParity?.checked !== true) errors.push('summary.browserParity.checked must be true.')
  if (summary.browserParity?.success !== true) errors.push('summary.browserParity.success must be true.')
  validateBrowserParity(errors, summary)
  validateSummaryWebReadiness(errors, summary)

  const manifest = manifestByLabel(summary.evidence?.files)
  compareRepoPaths(
    errors,
    manifest.get('Desktop JSON')?.file,
    browserEvidencePlan?.paths?.desktopEvidence,
    'summary.evidence Desktop JSON',
    'browserEvidence.plan.paths.desktopEvidence',
  )
  compareRepoPaths(
    errors,
    manifest.get('Windows Chrome JSON')?.file,
    browserEvidencePlan?.paths?.windowsChromeEvidence,
    'summary.evidence Windows Chrome JSON',
    'browserEvidence.plan.paths.windowsChromeEvidence',
  )
  if (manifest.get('Phone JSON')?.present === true) {
    errors.push('summary.evidence Phone JSON must not be present for computer-only result.')
  }
  if (manifest.get('Web Readiness JSON')?.present !== true) {
    errors.push('summary.evidence Web Readiness JSON must be present for computer-only result.')
  }

  await validateSummaryScreenshots(errors, summary.evidence?.files, browserEvidencePlan?.paths, resultPlan?.outputs)
}

function validateSummaryWebReadiness(errors, summary) {
  const value = summary?.environment?.webReadiness
  if (!value || typeof value !== 'object') {
    errors.push('summary.environment.webReadiness is missing.')
    return
  }
  if (value.run !== true) errors.push('summary.environment.webReadiness.run must be true.')
  if (value.success !== true) errors.push('summary.environment.webReadiness.success must be true.')
  compareValue(errors, value.runId, summary.runId, 'summary.environment.webReadiness.runId', 'summary.runId')
  compareValue(errors, value.appUrl, summary.appUrl, 'summary.environment.webReadiness.appUrl', 'summary.appUrl')
  if (!['already-ready', 'waited-on-stale-port', 'started-new-server'].includes(value.strategy)) {
    errors.push('summary.environment.webReadiness.strategy must be a known Ensure-Web strategy.')
  }
  if (value.httpReadyAfter !== true) errors.push('summary.environment.webReadiness.httpReadyAfter must be true.')
  if (value.gates?.httpProbeBeforePortReuse !== true) {
    errors.push('summary.environment.webReadiness.gates.httpProbeBeforePortReuse must be true.')
  }
  if (value.gates?.stalePortBlocksDuplicateStart !== true) {
    errors.push('summary.environment.webReadiness.gates.stalePortBlocksDuplicateStart must be true.')
  }
}

function validateSummaryLocalizedUi(errors, loop, label) {
  if (!loop?.run) return
  const localizedUi = loop.localizedUi
  if (!localizedUi || typeof localizedUi !== 'object') {
    errors.push(`${label}.localizedUi is missing.`)
    return
  }

  if (localizedUi.title !== loop.title) errors.push(`${label}.localizedUi.title must match ${label}.title.`)
  if (localizedUi.runButton !== '\u751f\u6210\u8ba1\u5212') {
    errors.push(`${label}.localizedUi.runButton must be \u751f\u6210\u8ba1\u5212.`)
  }
  if (!Number.isInteger(localizedUi.resetButtonCount) || localizedUi.resetButtonCount < 1) {
    errors.push(`${label}.localizedUi.resetButtonCount must be at least 1.`)
  }
  validateSummaryTextIntegrity(errors, loop.textIntegrity, `${label}.textIntegrity`)
  validateRawTextIntegrity(errors, localizedUi.textIntegrity, loop.textIntegrity, `${label}.localizedUi.textIntegrity`)
}

function validateBrowserParity(errors, summary) {
  errors.push(...validateBrowserParityInputs(summary.loops?.desktop, 'summary.loops.desktop'))
  errors.push(...validateBrowserParityInputs(summary.loops?.windowsChrome, 'summary.loops.windowsChrome'))
  const expected = recomputeBrowserParity(summary.loops?.desktop, summary.loops?.windowsChrome)
  const actual = summary.browserParity ?? {}
  if (actual.checked !== expected.checked) {
    errors.push('summary.browserParity.checked must match recomputed browser parity.')
  }
  if (actual.success !== expected.success) {
    errors.push('summary.browserParity.success must match recomputed browser parity.')
  }
  if (parityErrorsSignature(actual.errors) !== parityErrorsSignature(expected.errors)) {
    errors.push('summary.browserParity.errors must match recomputed browser parity.')
  }
}

async function validateRawLoopEvidence(errors, summary, browserEvidencePlan, resultGeneratedAt) {
  if (!summary || typeof summary !== 'object' || !browserEvidencePlan?.paths) return

  const desktopEvidence = await readReferencedJson(
    errors,
    browserEvidencePlan.paths.desktopEvidence,
    'browserEvidence.plan.paths.desktopEvidence',
  )
  const chromeEvidence = await readReferencedJson(
    errors,
    browserEvidencePlan.paths.windowsChromeEvidence,
    'browserEvidence.plan.paths.windowsChromeEvidence',
  )

  validateRawEvidenceRun(errors, desktopEvidence, {
    label: 'desktop raw evidence',
    summaryLoop: summary.loops?.desktop,
    summary,
    summaryScreenshots: summaryScreenshotEntries(summary.evidence?.files, browserEvidencePlan.paths.desktopScreenshotDir),
    expectedRunId: summary.runId,
    expectedBrowserName: 'playwright-chromium',
    resultGeneratedAt,
  })
  validateRawEvidenceRun(errors, chromeEvidence, {
    label: 'Windows Chrome raw evidence',
    summaryLoop: summary.loops?.windowsChrome,
    summary,
    summaryScreenshots: summaryScreenshotEntries(summary.evidence?.files, browserEvidencePlan.paths.windowsChromeScreenshotDir),
    expectedRunId: summary.runId,
    expectedBrowserName: 'windows-chrome',
    resultGeneratedAt,
  })
}

function validateRawEvidenceRun(
  errors,
  evidence,
  { label, summaryLoop, summary, summaryScreenshots, expectedRunId, expectedBrowserName, resultGeneratedAt },
) {
  if (!evidence || typeof evidence !== 'object') return

  if (evidence.success !== true) errors.push(`${label}.success must be true.`)
  if (expectedRunId && evidence.runId !== expectedRunId) {
    errors.push(`${label}.runId must match summary.runId.`)
  }
  if (expectedBrowserName && evidence.browserName !== expectedBrowserName) {
    errors.push(`${label}.browserName must be ${expectedBrowserName}.`)
  }
  if (summary?.appUrl && evidence.appUrl !== summary.appUrl) {
    errors.push(`${label}.appUrl must match summary.appUrl.`)
  }
  if (summary?.apiBase && evidence.apiBase !== summary.apiBase) {
    errors.push(`${label}.apiBase must match summary.apiBase.`)
  }
  if (summaryLoop?.pageUrl && evidence.pageUrl !== summaryLoop.pageUrl) {
    errors.push(`${label}.pageUrl must match summary loop pageUrl.`)
  }
  validateRawLoopTiming(errors, evidence, summaryLoop, label)
  validateRawTextIntegrity(
    errors,
    evidence.checks?.localizedUi?.textIntegrity,
    summaryLoop?.textIntegrity,
    `${label}.textIntegrity`,
  )
  validateRawLocalizedUi(errors, evidence.checks?.localizedUi, summaryLoop?.localizedUi, `${label}.localizedUi`)
  validateRawRuntimeHealth(errors, evidence.checks?.runtimeHealth, summaryLoop?.runtimeHealth, `${label}.runtimeHealth`)
  validateRawScreenshotEvidence(
    errors,
    evidence,
    evidence.checks?.screenshotEvidence,
    summaryLoop?.screenshotEvidence,
    summaryScreenshots,
    `${label}.screenshotEvidence`,
  )
  assertString(errors, evidence.finishedAt, `${label}.finishedAt`)
  if (!Number.isFinite(timestampMs(evidence.finishedAt))) {
    errors.push(`${label}.finishedAt must be a valid timestamp.`)
  }
  validateTimestampNotEarlier(errors, resultGeneratedAt, evidence.finishedAt, 'generatedAt', `${label}.finishedAt`)
}

function validateRawLocalizedUi(errors, raw, summary, label) {
  if (!raw || !summary) {
    errors.push(`${label} is missing.`)
    return
  }

  for (const key of ['title', 'runButton', 'resetButtonCount']) {
    if (raw[key] !== summary[key]) {
      errors.push(`${label}.${key} must match summary loop.`)
    }
  }
  validateRawTextIntegrity(errors, raw.textIntegrity, summary.textIntegrity, `${label}.textIntegrity`)
}

function summaryScreenshotEntries(files, screenshotDir) {
  if (!Array.isArray(files)) return []
  return files.filter(
    (entry) => entry?.present === true && entry.label === 'Screenshot' && isInsidePath(entry.file, screenshotDir),
  )
}

function validateRawLoopTiming(errors, evidence, summaryLoop, label) {
  if (!summaryLoop) return

  if (evidence.startedAt !== summaryLoop.startedAt) {
    errors.push(`${label}.startedAt must match summary loop.`)
  }
  if (evidence.finishedAt !== summaryLoop.finishedAt) {
    errors.push(`${label}.finishedAt must match summary loop.`)
  }
}

function validateRawTextIntegrity(errors, raw, summary, label) {
  if (!summary) return
  if (!raw || typeof raw !== 'object') {
    errors.push(`${label} raw evidence is missing.`)
    return
  }

  validateSummaryTextIntegrity(errors, raw, label)
  validateSummaryTextIntegrity(errors, summary, label)
  for (const key of ['requiredPhraseCount', 'missingPhraseCount', 'mojibakeCount']) {
    if (raw[key] !== summary[key]) {
      errors.push(`${label}.${key} must match summary loop.`)
    }
  }
}

function validateSummaryTextIntegrity(errors, value, label) {
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

function validateRawRuntimeHealth(errors, raw, summary, label) {
  if (!summary) return
  if (!raw || typeof raw !== 'object') {
    errors.push(`${label} raw evidence is missing.`)
    return
  }

  if (raw.success !== summary.success) errors.push(`${label}.success must match summary loop.`)
  if (raw.issueCount !== summary.issueCount) errors.push(`${label}.issueCount must match summary loop.`)
  if (stableJson(raw.counts ?? {}) !== stableJson(summary.counts ?? {})) {
    errors.push(`${label}.counts must match summary loop.`)
  }
}

function validateRawScreenshotEvidence(errors, evidence, raw, summary, summaryScreenshots, label) {
  if (!summary) return
  if (!raw || typeof raw !== 'object') {
    errors.push(`${label} raw evidence is missing.`)
    return
  }

  const rawSuccess = raw.success !== false
  if (rawSuccess !== summary.success) {
    errors.push(`${label}.success must match summary loop.`)
  }

  for (const key of ['count', 'uniqueDigestCount', 'minWidth', 'minHeight', 'minBytes', 'minImageDataBytes']) {
    if (raw[key] !== summary[key]) {
      errors.push(`${label}.${key} must match summary loop.`)
    }
  }

  if (stableJson(raw.expectedFiles ?? []) !== stableJson(summary.expectedFiles ?? [])) {
    errors.push(`${label}.expectedFiles must match summary loop.`)
  }

  if (Array.isArray(evidence.screenshots) && evidence.screenshots.length !== summary.count) {
    errors.push(`${label}.screenshots length must match summary loop.`)
  }

  if (!Array.isArray(raw.files)) {
    errors.push(`${label}.files raw evidence must be an array.`)
    return
  }
  if (raw.files.length !== summaryScreenshots.length) {
    errors.push(`${label}.files length must match summary evidence manifest.`)
  }
  validateRawScreenshotPaths(errors, evidence.screenshots, raw.files, `${label}.files`)

  const summaryByFile = new Map(summaryScreenshots.map((entry) => [entry.file, entry]))
  for (const rawFile of raw.files) {
    if (!rawFile || typeof rawFile.path !== 'string') continue
    const summaryFile = summaryByFile.get(rawFile.path)
    if (!summaryFile) {
      errors.push(`${label}.files missing from summary evidence manifest: ${rawFile.path}.`)
      continue
    }
    if (rawFile.bytes !== summaryFile.bytes) {
      errors.push(`${label}.files ${rawFile.path} bytes must match summary evidence manifest.`)
    }
    if (rawFile.sha256 !== summaryFile.sha256) {
      errors.push(`${label}.files ${rawFile.path} sha256 must match summary evidence manifest.`)
    }
  }
}

function validateRawScreenshotPaths(errors, screenshots, rawFiles, label) {
  if (!Array.isArray(screenshots)) return

  const filePaths = rawFiles.map((entry) => entry?.path)
  if (stableJson(screenshots) !== stableJson(filePaths)) {
    errors.push(`${label} paths must match raw screenshots.`)
  }
}

async function validateSummaryScreenshots(errors, files, paths, outputs) {
  if (!Array.isArray(files)) {
    errors.push('summary.evidence.files must be an array.')
    return
  }

  const screenshotFiles = files.filter((entry) => entry?.present === true && entry.label === 'Screenshot')
  if (screenshotFiles.length !== 12) {
    errors.push('summary.evidence must include 12 present screenshot entries for desktop and Windows Chrome.')
  }

  const desktopDir = resolveRepoPath(paths?.desktopScreenshotDir)
  const chromeDir = resolveRepoPath(paths?.windowsChromeScreenshotDir)
  const outputDir = resolveRepoPath(outputs?.outputDir)
  let desktopCount = 0
  let chromeCount = 0

  for (const entry of screenshotFiles) {
    if (!entry.file) {
      errors.push('summary.evidence screenshot file must be present.')
      continue
    }

    const filePath = resolveRepoPath(entry.file)
    if (!filePath) {
      errors.push('summary.evidence screenshot file must stay inside the repository root.')
      continue
    }
    if (outputDir && !isInsidePath(entry.file, outputs.outputDir)) {
      errors.push('summary.evidence screenshot file must be inside plan.outputs.outputDir.')
    }
    await validateManifestFile(errors, entry, `summary.evidence screenshot ${entry.file}`)
    if (desktopDir && isInsidePath(entry.file, paths.desktopScreenshotDir)) desktopCount += 1
    if (chromeDir && isInsidePath(entry.file, paths.windowsChromeScreenshotDir)) chromeCount += 1
  }

  if (desktopCount !== 6) errors.push('summary.evidence must include 6 desktop screenshot entries.')
  if (chromeCount !== 6) errors.push('summary.evidence must include 6 Windows Chrome screenshot entries.')
}

async function validateManifestFile(errors, entry, label) {
  const absolutePath = resolveRepoPath(entry?.file)
  if (!absolutePath) {
    errors.push(`${label} must stay inside the repository root.`)
    return
  }

  let fileStat
  let buffer
  try {
    fileStat = await stat(absolutePath)
    buffer = await readFile(absolutePath)
  } catch (error) {
    errors.push(`${label} cannot be read: ${error?.code ?? error.message ?? error}`)
    return
  }

  if (!fileStat.isFile()) {
    errors.push(`${label} must point to a file.`)
    return
  }

  if (entry.bytes !== fileStat.size) {
    errors.push(`${label} bytes mismatch (${fileStat.size} != ${entry.bytes ?? 'missing'}).`)
  }

  const digest = createHash('sha256').update(buffer).digest('hex').slice(0, 12)
  if (entry.sha256 !== digest) {
    errors.push(`${label} sha256 mismatch (${digest} != ${entry.sha256 ?? 'missing'}).`)
  }
}

function manifestByLabel(files) {
  const manifest = new Map()
  if (!Array.isArray(files)) return manifest

  for (const entry of files) {
    if (entry?.label && !manifest.has(entry.label)) {
      manifest.set(entry.label, entry)
    }
  }

  return manifest
}

function validateNestedBrowserEvidencePaths(errors, browserEvidencePlan, outputs) {
  const paths = browserEvidencePlan?.paths
  if (!paths || typeof paths !== 'object') {
    errors.push('browserEvidence.plan.paths is missing.')
    return
  }

  const requiredInsideOutputDir = [
    ['desktopEvidence', paths.desktopEvidence],
    ['desktopScreenshotDir', paths.desktopScreenshotDir],
    ['windowsChromeEvidence', paths.windowsChromeEvidence],
    ['windowsChromeScreenshotDir', paths.windowsChromeScreenshotDir],
  ]

  for (const [label, value] of requiredInsideOutputDir) {
    assertString(errors, value, `browserEvidence.plan.paths.${label}`)
    if (typeof value === 'string') {
      validateRepoPath(errors, value, `browserEvidence.plan.paths.${label}`)
      if (!isInsidePath(value, outputs.outputDir)) {
        errors.push(`browserEvidence.plan.paths.${label} must be inside plan.outputs.outputDir.`)
      }
    }
  }

  if (paths.phoneEvidence && isInsidePath(paths.phoneEvidence, outputs.outputDir)) {
    errors.push('browserEvidence.plan.paths.phoneEvidence must not point to run-local phone evidence for computer-only result.')
  }
}

async function assertExistingFile(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) return

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
  if (typeof value !== 'string' || value.length === 0) return null

  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) return null

  try {
    return JSON.parse(await readFile(absolutePath, 'utf8'))
  } catch (error) {
    errors.push(`${label} JSON cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

async function readReferencedText(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) return null

  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) return null

  try {
    return await readFile(absolutePath, 'utf8')
  } catch (error) {
    errors.push(`${label} text cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

function stableJson(value) {
  return JSON.stringify(sortJsonValue(value))
}

function compareValue(errors, left, right, leftLabel, rightLabel) {
  if (left !== right) {
    errors.push(`${leftLabel} must match ${rightLabel}.`)
  }
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

function validateTimestampNotEarlier(errors, later, earlier, laterLabel, earlierLabel) {
  const laterMs = timestampMs(later)
  const earlierMs = timestampMs(earlier)
  if (Number.isFinite(laterMs) && Number.isFinite(earlierMs) && laterMs < earlierMs) {
    errors.push(`${laterLabel} must not be earlier than ${earlierLabel}.`)
  }
}

function timestampMs(value) {
  if (typeof value !== 'string' || value.length === 0) return Number.NaN
  const time = Date.parse(value)
  return Number.isFinite(time) ? time : Number.NaN
}

function validateCommandArgPath(errors, args, flag, expected, argLabel, expectedLabel) {
  const actual = getCommandArgValue(errors, args, flag, argLabel)
  if (actual === null || expected === undefined || expected === null) return

  compareRepoPaths(errors, actual, expected, argLabel, expectedLabel)
}

function validateCommandArgValue(errors, args, flag, expected, argLabel, expectedLabel) {
  const actual = getCommandArgValue(errors, args, flag, argLabel)
  if (actual === null || expected === undefined || expected === null) return

  if (String(actual) !== String(expected)) {
    errors.push(`${argLabel} must match ${expectedLabel}.`)
  }
}

function validateCommandFlag(errors, args, flag, expected, argLabel, expectedLabel) {
  if (!Array.isArray(args)) return

  const count = args.filter((item) => item === flag).length
  if (expected && count !== 1) {
    errors.push(`${argLabel} must appear exactly once when ${expectedLabel} is true.`)
  }
  if (!expected && count !== 0) {
    errors.push(`${argLabel} must be omitted when ${expectedLabel} is false.`)
  }
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

function validateRepoPath(errors, value, label) {
  if (!resolveRepoPath(value)) errors.push(`${label} must stay inside the repository root.`)
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
  if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    return null
  }

  return absolutePath
}

function assertString(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    errors.push(`${label} must be a non-empty string.`)
  }
}

function resolveCliPath(value) {
  return path.isAbsolute(value) ? path.resolve(value) : path.resolve(process.cwd(), value)
}

function positiveInteger(value) {
  return Number.isInteger(value) && value > 0
}

function arrayContains(value, expected) {
  return Array.isArray(value) && value.includes(expected)
}
