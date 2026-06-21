import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { assertAsciiSafeJsonText } from './json-file.mjs'
import { parseResultValidatorCliOptions, validateResultFreshness } from './result-validator-cli.mjs'
import { parityErrorsSignature, recomputeBrowserParity, validateBrowserParityInputs } from './summary-parity.mjs'
import {
  validateRawDevEnvManifest,
  validateRawDevEnvMatchesSummary,
  validateRawWebReadinessManifest,
  validateRawWebReadinessMatchesSummary,
  validateSummaryManifest,
} from './summary-manifest.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const defaultResultFile = path.join(repoRoot, 'assets', 'tmp', 'browser-evidence-check.json')
const cliOptions = parseResultValidatorCliOptions(process.argv.slice(2))
const resultFile = resolveCliPath(cliOptions.resultFile ?? defaultResultFile)
const MIN_LOCALIZED_PHRASE_COUNT = 7
const PROOF_SUMMARY_KEYS = [
  'summaryRunId',
  'appUrl',
  'apiBase',
  'requiredEvidence',
  'browserParity',
  'webReadiness',
  'loops',
  'evidence',
]
const PROOF_SUMMARY_BOOLEAN_GROUP_KEYS = ['desktop', 'phone', 'windowsChrome']
const PROOF_SUMMARY_PARITY_KEYS = ['checked', 'success', 'errorCount']
const PROOF_SUMMARY_WEB_READINESS_KEYS = [
  'run',
  'success',
  'strategy',
  'httpReadyAfter',
  'duplicateStartAvoided',
]
const PROOF_SUMMARY_LOOPS_KEYS = ['desktop', 'phone', 'windowsChrome']
const PROOF_SUMMARY_LOOP_KEYS = [
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
  'externalExecutionSourceMode',
  'acceptedActionCount',
]
const PROOF_SUMMARY_PHONE_LOOP_KEYS = ['run', 'success']
const PROOF_SUMMARY_EVIDENCE_KEYS = [
  'summaryPath',
  'desktopEvidencePath',
  'windowsChromeEvidencePath',
  'phoneEvidencePath',
  'devEnvEvidencePath',
  'webReadinessEvidencePath',
  'desktopScreenshotDir',
  'windowsChromeScreenshotDir',
]
const errors = []
const result = await readResultJson(errors, resultFile)
if (result) {
  errors.push(...(await validateBrowserEvidenceResult(result, resultFile, cliOptions)))
}

if (errors.length) {
  console.error(`Browser evidence result validation failed: ${resultFile}`)
  for (const error of errors) {
    console.error(`- ${error}`)
  }
  process.exit(1)
}

console.log(`Browser evidence result validation passed: ${resultFile}`)
if (result.mode === 'validate') {
  const summary = await readValidatedSummary(result)
  console.log(formatBrowserEvidenceProofSummary(result, summary))
}

async function readResultJson(errors, file) {
  try {
    const text = await readFile(file, 'utf8')
    assertAsciiSafeJsonText(text, 'browser evidence result')
    return JSON.parse(text)
  } catch (error) {
    errors.push(`browser evidence result JSON cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

async function validateBrowserEvidenceResult(value, validatedResultFile, options = {}) {
  const errors = []

  if (!value || typeof value !== 'object') {
    return ['Browser evidence result root must be an object.']
  }

  validateAllowedKeys(
    errors,
    value,
    ['generatedAt', 'success', 'mode', 'sourceState', 'plan', 'checks', 'proofSummary'],
    'result root',
  )
  assertString(errors, value.generatedAt, 'generatedAt')
  if (!Number.isFinite(Date.parse(value.generatedAt))) {
    errors.push('generatedAt must be a valid timestamp.')
  }
  validateResultFreshness(errors, value.generatedAt, options.maxAgeMinutes)
  if (value.success !== true) errors.push('success must be true.')
  if (!['dry-run', 'validate'].includes(value.mode)) errors.push('mode must be dry-run or validate.')

  validatePlan(errors, value.plan, validatedResultFile)
  validateSourceState(errors, value.sourceState)
  validateChecks(errors, value.checks, value.plan)

  if (value.mode === 'validate') {
    await validateValidateMode(errors, value)
  } else if (value.proofSummary !== null && value.proofSummary !== undefined) {
    errors.push('proofSummary must be null or omitted in dry-run mode.')
  }

  return errors
}

function validateSourceState(errors, sourceState) {
  if (!sourceState || typeof sourceState !== 'object') {
    errors.push('sourceState is missing.')
    return
  }

  validateAllowedKeys(errors, sourceState, ['branch', 'commit', 'dirty', 'statusCount', 'statusSha256'], 'sourceState')
  assertString(errors, sourceState.branch, 'sourceState.branch')
  assertString(errors, sourceState.commit, 'sourceState.commit')
  if (typeof sourceState.commit === 'string' && !/^[0-9a-f]{40}$/i.test(sourceState.commit)) {
    errors.push('sourceState.commit must be a 40-character git commit hash.')
  }
  if (typeof sourceState.dirty !== 'boolean') errors.push('sourceState.dirty must be boolean.')
  if (!Number.isInteger(sourceState.statusCount) || sourceState.statusCount < 0) {
    errors.push('sourceState.statusCount must be a non-negative integer.')
  }
  assertString(errors, sourceState.statusSha256, 'sourceState.statusSha256')
  if (typeof sourceState.statusSha256 === 'string' && !/^[0-9a-f]{12}$/i.test(sourceState.statusSha256)) {
    errors.push('sourceState.statusSha256 must be a 12-character SHA-256 prefix.')
  }

  const actual = readCurrentSourceState(errors)
  if (!actual) return

  for (const key of ['branch', 'commit', 'dirty', 'statusCount', 'statusSha256']) {
    if (sourceState[key] !== actual[key]) {
      errors.push(formatSourceStateMismatch('sourceState', key, sourceState[key], actual[key], `current git ${key}`))
    }
  }
}

function formatSourceStateMismatch(label, key, saved, current, expectedLabel) {
  return `${label}.${key} must match ${expectedLabel}. saved=${formatDiagnosticValue(saved)} current=${formatDiagnosticValue(current)}`
}

function formatDiagnosticValue(value) {
  if (typeof value === 'string') return value
  if (typeof value === 'boolean' || typeof value === 'number') return String(value)
  if (value === null) return 'null'
  if (value === undefined) return 'undefined'
  return JSON.stringify(value)
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
    ['summaryPath', 'resultJsonPath', 'inferredFromSummary', 'requiredEvidence', 'options', 'selfTest', 'paths'],
    'plan',
  )
  assertString(errors, plan.summaryPath, 'plan.summaryPath')
  assertString(errors, plan.resultJsonPath, 'plan.resultJsonPath')
  validateRepoPath(errors, plan.summaryPath, 'plan.summaryPath')
  validateRepoPath(errors, plan.resultJsonPath, 'plan.resultJsonPath')
  validatePortableRepoPath(errors, plan.summaryPath, 'plan.summaryPath')
  validatePortableRepoPath(errors, plan.resultJsonPath, 'plan.resultJsonPath')
  compareRepoPaths(errors, plan.resultJsonPath, validatedResultFile, 'plan.resultJsonPath', 'validated result file')

  validateBooleanGroup(errors, plan.inferredFromSummary, 'plan.inferredFromSummary')
  validateBooleanGroup(errors, plan.requiredEvidence, 'plan.requiredEvidence')
  validatePlanOptions(errors, plan.options)
  validateSelfTestPlan(errors, plan.selfTest)
  validateRequiredEvidenceConsistency(errors, plan)
  validatePaths(errors, plan.paths)
  validateRequiredEvidencePaths(errors, plan)
  validateSkippedEvidencePaths(errors, plan)
}

function validatePlanOptions(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('plan.options is missing.')
    return
  }

  validateAllowedKeys(errors, value, ['maxAgeMinutes'], 'plan.options')
  if (value.maxAgeMinutes !== null && value.maxAgeMinutes !== undefined) {
    if (typeof value.maxAgeMinutes !== 'number' || !Number.isFinite(value.maxAgeMinutes) || value.maxAgeMinutes <= 0) {
      errors.push('plan.options.maxAgeMinutes must be null or a positive number.')
    }
  }
}

function validateBooleanGroup(errors, value, label) {
  if (!value || typeof value !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }

  validateAllowedKeys(errors, value, ['desktop', 'phone', 'windowsChrome'], label)
  for (const key of ['desktop', 'phone', 'windowsChrome']) {
    if (typeof value[key] !== 'boolean') errors.push(`${label}.${key} must be boolean.`)
  }
}

function validateSelfTestPlan(errors, value) {
  if (!value || typeof value !== 'object') {
    errors.push('plan.selfTest is missing.')
    return
  }

  validateAllowedKeys(errors, value, ['requested', 'phoneEvidence', 'desktopEvidence', 'summary', 'report'], 'plan.selfTest')
  for (const key of ['requested', 'phoneEvidence', 'desktopEvidence', 'summary', 'report']) {
    if (typeof value[key] !== 'boolean') errors.push(`plan.selfTest.${key} must be boolean.`)
  }

  if (value.requested !== true) {
    for (const key of ['phoneEvidence', 'desktopEvidence', 'summary', 'report']) {
      if (value[key] !== false) errors.push(`plan.selfTest.${key} must be false when plan.selfTest.requested is false.`)
    }
  }
}

function validateRequiredEvidenceConsistency(errors, plan) {
  if (plan.requiredEvidence?.phone !== plan.inferredFromSummary?.phone) {
    errors.push('plan.requiredEvidence.phone must match plan.inferredFromSummary.phone.')
  }
  if (plan.requiredEvidence?.windowsChrome !== plan.inferredFromSummary?.windowsChrome) {
    errors.push('plan.requiredEvidence.windowsChrome must match plan.inferredFromSummary.windowsChrome.')
  }
  if (plan.requiredEvidence?.desktop === true && plan.inferredFromSummary?.desktop !== true) {
    errors.push('plan.requiredEvidence.desktop cannot be true when plan.inferredFromSummary.desktop is false.')
  }

  const desktopAndChromeRequired = plan.requiredEvidence?.desktop === true && plan.requiredEvidence?.windowsChrome === true
  if (plan.selfTest?.requested === true) {
    if (plan.selfTest.phoneEvidence !== (plan.requiredEvidence?.phone === true)) {
      errors.push('plan.selfTest.phoneEvidence must match required phone evidence when self-test is requested.')
    }
    if (plan.selfTest.desktopEvidence !== desktopAndChromeRequired) {
      errors.push('plan.selfTest.desktopEvidence must match required desktop+Chrome evidence when self-test is requested.')
    }
    if (plan.selfTest.summary !== desktopAndChromeRequired) {
      errors.push('plan.selfTest.summary must match required desktop+Chrome evidence when self-test is requested.')
    }
    if (plan.selfTest.report !== (desktopAndChromeRequired && plan.requiredEvidence?.phone === true)) {
      errors.push('plan.selfTest.report must match complete desktop+phone+Chrome evidence when self-test is requested.')
    }
  }
}

function validatePaths(errors, paths) {
  if (!paths || typeof paths !== 'object') {
    errors.push('plan.paths is missing.')
    return
  }

  validateAllowedKeys(
    errors,
    paths,
    [
      'desktopEvidence',
      'desktopScreenshotDir',
      'phoneEvidence',
      'windowsChromeEvidence',
      'windowsChromeScreenshotDir',
    ],
    'plan.paths',
  )
  for (const key of [
    'desktopEvidence',
    'desktopScreenshotDir',
    'phoneEvidence',
    'windowsChromeEvidence',
    'windowsChromeScreenshotDir',
  ]) {
    assertString(errors, paths[key], `plan.paths.${key}`)
    validateRepoPath(errors, paths[key], `plan.paths.${key}`)
    validatePortableRepoPath(errors, paths[key], `plan.paths.${key}`)
  }
}

function validateSkippedEvidencePaths(errors, plan) {
  const skippedPaths = [
    ['desktop', 'desktopEvidence', '__desktop_not_run__.json'],
    ['desktop', 'desktopScreenshotDir', '__desktop_screens_not_run__'],
    ['phone', 'phoneEvidence', '__phone_not_run__.json'],
    ['windowsChrome', 'windowsChromeEvidence', '__chrome_not_run__.json'],
    ['windowsChrome', 'windowsChromeScreenshotDir', '__chrome_screens_not_run__'],
  ]
  for (const [evidenceName, pathKey, sentinel] of skippedPaths) {
    if (plan?.requiredEvidence?.[evidenceName] === false && plan?.paths?.[pathKey] !== sentinel) {
      errors.push(`plan.paths.${pathKey} must be ${sentinel} when ${evidenceName} evidence is not required.`)
    }
  }
}

function validateRequiredEvidencePaths(errors, plan) {
  const requiredPaths = [
    ['desktop', 'desktopEvidence'],
    ['desktop', 'desktopScreenshotDir'],
    ['phone', 'phoneEvidence'],
    ['windowsChrome', 'windowsChromeEvidence'],
    ['windowsChrome', 'windowsChromeScreenshotDir'],
  ]
  for (const [evidenceName, pathKey] of requiredPaths) {
    if (plan?.requiredEvidence?.[evidenceName] === true && isSentinelPath(plan?.paths?.[pathKey])) {
      errors.push(`plan.paths.${pathKey} must be a real evidence path when ${evidenceName} evidence is required.`)
    }
  }
}

function validateChecks(errors, checks, plan) {
  if (!Array.isArray(checks)) {
    errors.push('checks must be an array.')
    return
  }

  const expectedChecks = expectedCheckSpecs(plan)
  validateChecksManifest(errors, checks, expectedChecks)
  validateEvidenceCheck(errors, checks, {
    name: 'desktop raw evidence',
    command: 'npm run desktop:evidence:check',
    expected: plan?.requiredEvidence?.desktop === true,
    path: plan?.paths?.desktopEvidence,
    screenshotDir: plan?.paths?.desktopScreenshotDir,
    allowedKeys: ['name', 'command', 'required', 'path', 'screenshotDir'],
  })
  validateEvidenceCheck(errors, checks, {
    name: 'Windows Chrome raw evidence',
    command: 'npm run desktop:evidence:check -- --require-installed-chrome',
    expected: plan?.requiredEvidence?.windowsChrome === true,
    path: plan?.paths?.windowsChromeEvidence,
    screenshotDir: plan?.paths?.windowsChromeScreenshotDir,
    allowedKeys: ['name', 'command', 'required', 'path', 'screenshotDir'],
  })
  validateEvidenceCheck(errors, checks, {
    name: 'Android Chrome phone evidence',
    command: 'npm run phone:evidence:check',
    expected: plan?.requiredEvidence?.phone === true,
    path: plan?.paths?.phoneEvidence,
    allowedKeys: ['name', 'command', 'required', 'path'],
  })

  validateEvidenceCheck(errors, checks, {
    name: 'full-loop summary evidence',
    command: 'npm run summary:check',
    expected: true,
    path: plan?.summaryPath,
    allowedKeys: ['name', 'command', 'required', 'path'],
  })
  validateSelfTestCheck(errors, checks, 'phone evidence validator self-test', 'npm run phone:evidence:selftest', plan?.selfTest?.phoneEvidence)
  validateSelfTestCheck(errors, checks, 'desktop evidence validator self-test', 'npm run desktop:evidence:selftest', plan?.selfTest?.desktopEvidence)
  validateSelfTestCheck(errors, checks, 'summary validator self-test', `npm run summary:selftest -- ${plan?.summaryPath}`, plan?.selfTest?.summary)
  validateSelfTestCheck(errors, checks, 'full-loop reporter self-test', 'npm run report:selftest', plan?.selfTest?.report)
}

function expectedCheckSpecs(plan) {
  const specs = []
  if (plan?.requiredEvidence?.desktop === true) {
    specs.push({
      name: 'desktop raw evidence',
      command: 'npm run desktop:evidence:check',
    })
  }
  if (plan?.requiredEvidence?.windowsChrome === true) {
    specs.push({
      name: 'Windows Chrome raw evidence',
      command: 'npm run desktop:evidence:check -- --require-installed-chrome',
    })
  }
  if (plan?.requiredEvidence?.phone === true) {
    specs.push({
      name: 'Android Chrome phone evidence',
      command: 'npm run phone:evidence:check',
    })
  }
  specs.push({
    name: 'full-loop summary evidence',
    command: 'npm run summary:check',
  })
  if (plan?.selfTest?.phoneEvidence === true) {
    specs.push({
      name: 'phone evidence validator self-test',
      command: 'npm run phone:evidence:selftest',
    })
  }
  if (plan?.selfTest?.desktopEvidence === true) {
    specs.push({
      name: 'desktop evidence validator self-test',
      command: 'npm run desktop:evidence:selftest',
    })
  }
  if (plan?.selfTest?.summary === true) {
    specs.push({
      name: 'summary validator self-test',
      command: `npm run summary:selftest -- ${plan?.summaryPath}`,
    })
  }
  if (plan?.selfTest?.report === true) {
    specs.push({
      name: 'full-loop reporter self-test',
      command: 'npm run report:selftest',
    })
  }

  return specs
}

function validateChecksManifest(errors, checks, expectedChecks) {
  const expectedNames = expectedChecks.map((check) => check.name)
  const expectedCommands = expectedChecks.map((check) => check.command)
  const actualNames = checks.map((check) => check?.name)
  const actualCommands = checks.map((check) => check?.command)
  if (checks.length !== expectedChecks.length) {
    errors.push(`checks must contain exactly ${expectedChecks.length} entries for this browser evidence plan.`)
  }
  if (stableJson(actualNames) !== stableJson(expectedNames)) {
    errors.push('checks order must match browser evidence plan.')
  }
  if (stableJson(actualCommands) !== stableJson(expectedCommands)) {
    errors.push('checks command order must match browser evidence plan.')
  }

  validateUniqueCheckField(errors, checks, 'name', 'checks entry name')
  validateUniqueCheckField(errors, checks, 'command', 'checks command')

  for (const check of checks) {
    if (typeof check?.name === 'string' && check.name.length > 0 && !expectedNames.includes(check.name)) {
      errors.push(`checks contains unexpected entry: ${check.name}.`)
    }
    if (
      typeof check?.command === 'string' &&
      check.command.length > 0 &&
      !expectedCommands.includes(check.command)
    ) {
      errors.push(`checks command is not allowed for this browser evidence plan: ${check.command}.`)
    }
  }
}

function validateUniqueCheckField(errors, checks, field, label) {
  const seen = new Set()
  for (const check of checks) {
    const value = check?.[field]
    if (typeof value !== 'string' || value.length === 0) continue
    if (seen.has(value)) {
      errors.push(`${label} must be unique: ${value}.`)
      continue
    }
    seen.add(value)
  }
}

function validateAllowedKeys(errors, value, allowedKeys, label) {
  if (!value || typeof value !== 'object') return

  const allowed = new Set(allowedKeys)
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      errors.push(`${label} must not include unexpected field: ${key}.`)
    }
  }
}

function validateEvidenceCheck(
  errors,
  checks,
  { name, command, expected, path: expectedPath, screenshotDir, allowedKeys },
) {
  const entries = checks.filter((check) => check?.name === name)
  if (!expected) {
    if (entries.length) errors.push(`checks must not include ${name} when it is not required.`)
    return
  }
  if (entries.length !== 1) {
    errors.push(`checks must include exactly one ${name} entry.`)
    return
  }

  const [entry] = entries
  validateAllowedKeys(errors, entry, allowedKeys, name)
  if (entry.required !== true) errors.push(`${name} check must be required.`)
  if (entry.command !== command) errors.push(`${name} command must be ${command}.`)
  validatePortableRepoPath(errors, entry.path, `${name} path`)
  compareRepoPaths(errors, entry.path, expectedPath, `${name} path`, `plan path for ${name}`)
  if (screenshotDir) {
    validatePortableRepoPath(errors, entry.screenshotDir, `${name} screenshotDir`)
    compareRepoPaths(
      errors,
      entry.screenshotDir,
      screenshotDir,
      `${name} screenshotDir`,
      `plan screenshotDir for ${name}`,
    )
  }
}

function validateSelfTestCheck(errors, checks, name, command, expected) {
  const entries = checks.filter((check) => check?.name === name)
  if (!expected) {
    if (entries.length) errors.push(`checks must not include ${name} when it is not requested.`)
    return
  }
  if (entries.length !== 1) {
    errors.push(`checks must include exactly one ${name} entry.`)
    return
  }
  validateAllowedKeys(errors, entries[0], ['name', 'command', 'required'], name)
  if (entries[0].required !== true) errors.push(`${name} check must be required.`)
  if (entries[0].command !== command) errors.push(`${name} command must be ${command}.`)
}

async function validateValidateMode(errors, value) {
  const plan = value.plan ?? {}
  await assertExistingFile(errors, plan.summaryPath, 'plan.summaryPath')

  if (plan.requiredEvidence?.desktop === true) {
    await assertExistingFile(errors, plan.paths?.desktopEvidence, 'plan.paths.desktopEvidence')
    await assertExistingDirectory(errors, plan.paths?.desktopScreenshotDir, 'plan.paths.desktopScreenshotDir')
  }
  if (plan.requiredEvidence?.windowsChrome === true) {
    await assertExistingFile(errors, plan.paths?.windowsChromeEvidence, 'plan.paths.windowsChromeEvidence')
    await assertExistingDirectory(errors, plan.paths?.windowsChromeScreenshotDir, 'plan.paths.windowsChromeScreenshotDir')
  }
  if (plan.requiredEvidence?.phone === true) {
    await assertExistingFile(errors, plan.paths?.phoneEvidence, 'plan.paths.phoneEvidence')
  }

  const summary = await readReferencedJson(errors, plan.summaryPath, 'plan.summaryPath')
  await validateSummary(errors, summary, plan)
  validateProofSummary(errors, value.proofSummary, summary, plan)
  validateTimestampNotEarlier(errors, value.generatedAt, summary?.generatedAt, 'generatedAt', 'summary.generatedAt')
  await validateRawEvidence(errors, summary, plan, value.generatedAt)
}

async function readValidatedSummary(value) {
  const summaryPath = value?.plan?.summaryPath
  const absolutePath = resolveRepoPath(summaryPath)
  if (!absolutePath) return null

  const errors = []
  return readJsonFile(errors, absolutePath, 'plan.summaryPath')
}

function formatBrowserEvidenceProofSummary(value, summary) {
  const proofSummary = value?.proofSummary
  return [
    'Browser evidence proof summary:',
    `runId=${proofSummary?.summaryRunId ?? summary?.runId ?? 'unknown'}`,
    `desktop=${formatLoopStatus(proofSummary?.loops?.desktop ?? summary?.loops?.desktop)}`,
    `chrome=${formatLoopStatus(proofSummary?.loops?.windowsChrome ?? summary?.loops?.windowsChrome)}`,
    `phone=${formatLoopStatus(proofSummary?.loops?.phone ?? summary?.loops?.phone)}`,
    `parity=${formatBrowserParity(proofSummary?.browserParity ?? summary?.browserParity)}`,
    `web=${formatWebReadiness(proofSummary?.webReadiness ?? summary?.environment?.webReadiness)}`,
    `source=${formatSourceState(value?.sourceState)}`,
    `screenshots=${formatScreenshotPair(proofSummary ?? summary)}`,
    `text=${formatTextIntegrityPair(proofSummary ?? summary)}`,
    `selftests=${formatSelfTestState(value?.plan?.selfTest)}`,
    `external=${formatExternalSource(proofSummary ?? summary)}`,
    `externalMode=${formatExternalSourceMode(proofSummary ?? summary)}`,
    `devEnvEvidence=${formatDisplayPath(proofSummary?.evidence?.devEnvEvidencePath)}`,
    `webReadinessEvidence=${formatDisplayPath(proofSummary?.evidence?.webReadinessEvidencePath)}`,
    `summary=${formatDisplayPath(proofSummary?.evidence?.summaryPath ?? value?.plan?.summaryPath)}`,
  ].join(' ')
}

function formatSourceState(sourceState) {
  if (!sourceState || typeof sourceState !== 'object') return 'unknown'
  const commit = typeof sourceState.commit === 'string' ? sourceState.commit.slice(0, 7) : 'unknown'
  const dirty = sourceState.dirty === true ? 'dirty' : sourceState.dirty === false ? 'clean' : 'unknown'
  const statusCount = Number.isInteger(sourceState.statusCount) ? sourceState.statusCount : 'unknown'
  const statusSha = typeof sourceState.statusSha256 === 'string' ? sourceState.statusSha256 : 'unknown'
  return `${sourceState.branch ?? 'unknown'}@${commit}/${dirty}#${statusCount}:${statusSha}`
}

function formatLoopStatus(loop) {
  if (!loop || loop.run !== true) return 'not-run'
  if (loop.success === true) return 'pass'
  if (loop.success === false) return 'fail'
  return 'unknown'
}

function formatBrowserParity(browserParity) {
  if (browserParity?.checked !== true) return 'not-checked'
  if (browserParity.success === true) return 'pass'
  if (browserParity.success === false) return 'fail'
  return 'unknown'
}

function formatWebReadiness(value) {
  if (value?.run !== true) return 'not-run'
  if (value.success === true) return value.strategy ?? 'pass'
  if (value.success === false) return 'fail'
  return 'unknown'
}

function formatScreenshotPair(summary) {
  return [
    formatScreenshotCount(summary?.loops?.desktop),
    formatScreenshotCount(summary?.loops?.windowsChrome),
  ].join('+')
}

function formatScreenshotCount(loop) {
  if (!loop || loop.run !== true) return '0'
  return String(loop.screenshotEvidence?.count ?? loop.screenshotCount ?? 'unknown')
}

function formatTextIntegrityPair(summary) {
  return [
    formatTextIntegrity(summary?.loops?.desktop),
    formatTextIntegrity(summary?.loops?.windowsChrome),
  ].join('+')
}

function formatTextIntegrity(loop) {
  if (!loop || loop.run !== true) return '0/0/0'

  const value = loop.textIntegrity ?? {}
  return `${value.requiredPhraseCount ?? loop.textRequiredPhrases ?? 'unknown'}/${
    value.missingPhraseCount ?? loop.textMissingPhrases ?? 'unknown'
  }/${value.mojibakeCount ?? loop.textMojibake ?? 'unknown'}`
}

function formatSelfTestState(selfTest) {
  if (!selfTest || selfTest.requested !== true) return 'not-requested'

  const enabled = []
  if (selfTest.phoneEvidence === true) enabled.push('phone')
  if (selfTest.desktopEvidence === true) enabled.push('desktop')
  if (selfTest.summary === true) enabled.push('summary')
  if (selfTest.report === true) enabled.push('report')
  return enabled.length ? enabled.join('+') : 'requested-none'
}

function formatExternalSource(summary) {
  const sources = [
    summary?.loops?.desktop?.externalExecutionSync?.latestSource,
    summary?.loops?.desktop?.externalExecutionSource,
    summary?.loops?.windowsChrome?.externalExecutionSync?.latestSource,
    summary?.loops?.windowsChrome?.externalExecutionSource,
    summary?.loops?.phone?.externalExecution?.latestSource,
    summary?.loops?.phone?.externalExecutionSource,
  ].filter((source) => typeof source === 'string' && source.length > 0)
  return [...new Set(sources)].join('+') || 'unknown'
}

function formatExternalSourceMode(summary) {
  const modes = [
    summary?.loops?.desktop?.externalExecutionSync?.sourceMode,
    summary?.loops?.desktop?.externalExecutionSourceMode,
    summary?.loops?.windowsChrome?.externalExecutionSync?.sourceMode,
    summary?.loops?.windowsChrome?.externalExecutionSourceMode,
  ].filter((mode) => typeof mode === 'string' && mode.length > 0)
  return [...new Set(modes)].join('+') || 'unknown'
}

function formatDisplayPath(value) {
  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) return String(value ?? 'unknown')

  const relativePath = path.relative(repoRoot, absolutePath).replaceAll(path.sep, '/')
  return relativePath || '.'
}

async function validateSummary(errors, summary, plan) {
  if (!summary || typeof summary !== 'object') return

  validateSummaryManifest(errors, summary, { labelPrefix: 'summary' })
  assertString(errors, summary.generatedAt, 'summary.generatedAt')
  if (!Number.isFinite(timestampMs(summary.generatedAt))) {
    errors.push('summary.generatedAt must be a valid timestamp.')
  }
  if (summary.success !== true) errors.push('summary.success must be true.')
  assertString(errors, summary.runId, 'summary.runId')
  if (summary.loops?.desktop?.run !== plan.inferredFromSummary?.desktop) {
    errors.push('summary.loops.desktop.run must match plan.inferredFromSummary.desktop.')
  }
  if (summary.loops?.phone?.run !== plan.inferredFromSummary?.phone) {
    errors.push('summary.loops.phone.run must match plan.inferredFromSummary.phone.')
  }
  if (summary.loops?.windowsChrome?.run !== plan.inferredFromSummary?.windowsChrome) {
    errors.push('summary.loops.windowsChrome.run must match plan.inferredFromSummary.windowsChrome.')
  }
  if (plan.inferredFromSummary?.desktop === true && summary.loops?.desktop?.success !== true) {
    errors.push('summary.loops.desktop.success must be true when desktop evidence is present.')
  }
  if (plan.inferredFromSummary?.phone === true && summary.loops?.phone?.success !== true) {
    errors.push('summary.loops.phone.success must be true when phone evidence is present.')
  }
  if (plan.inferredFromSummary?.windowsChrome === true && summary.loops?.windowsChrome?.success !== true) {
    errors.push('summary.loops.windowsChrome.success must be true when Windows Chrome evidence is present.')
  }
  if (summary.loops?.desktop?.run === true && summary.loops.desktop.runId !== summary.runId) {
    errors.push('summary.loops.desktop.runId must match summary.runId.')
  }
  if (summary.loops?.windowsChrome?.run === true && summary.loops.windowsChrome.runId !== summary.runId) {
    errors.push('summary.loops.windowsChrome.runId must match summary.runId.')
  }
  validateSummaryLocalizedUi(errors, summary.loops?.desktop, 'summary.loops.desktop')
  validateSummaryLocalizedUi(errors, summary.loops?.windowsChrome, 'summary.loops.windowsChrome')
  if (plan.inferredFromSummary?.desktop === true && plan.inferredFromSummary?.windowsChrome === true) {
    if (summary.browserParity?.checked !== true) {
      errors.push('summary.browserParity.checked must be true when desktop and Windows Chrome evidence are present.')
    }
    if (summary.browserParity?.success !== true) {
      errors.push('summary.browserParity.success must be true when desktop and Windows Chrome evidence are present.')
    }
    validateBrowserParity(errors, summary)
  }
  validateSummaryWebReadiness(errors, summary)

  const manifest = manifestByLabel(summary.evidence?.files)
  if (summary.environment?.preflight?.run === true) {
    await validateRawDevEnvEvidence(
      errors,
      summary.environment.preflight,
      manifest.get('Dev Environment JSON'),
      'summary.environment.preflight',
    )
  }
  if (manifest.get('Web Readiness JSON')?.present !== true) {
    errors.push('summary.evidence Web Readiness JSON must be present.')
  } else {
    await validateRawWebReadinessEvidence(
      errors,
      summary.environment?.webReadiness,
      manifest.get('Web Readiness JSON'),
      'summary.environment.webReadiness',
    )
  }
  if (plan.inferredFromSummary?.desktop) {
    compareRepoPaths(
      errors,
      manifest.get('Desktop JSON')?.file,
      plan.paths?.desktopEvidence,
      'summary.evidence Desktop JSON',
      'plan.paths.desktopEvidence',
    )
    await validateManifestScreenshots(errors, summary.evidence?.files, plan.paths?.desktopScreenshotDir, 'desktop')
  }
  if (plan.inferredFromSummary?.windowsChrome) {
    compareRepoPaths(
      errors,
      manifest.get('Windows Chrome JSON')?.file,
      plan.paths?.windowsChromeEvidence,
      'summary.evidence Windows Chrome JSON',
      'plan.paths.windowsChromeEvidence',
    )
    await validateManifestScreenshots(errors, summary.evidence?.files, plan.paths?.windowsChromeScreenshotDir, 'Windows Chrome')
  }
  if (plan.inferredFromSummary?.phone) {
    compareRepoPaths(
      errors,
      manifest.get('Phone JSON')?.file,
      plan.paths?.phoneEvidence,
      'summary.evidence Phone JSON',
      'plan.paths.phoneEvidence',
    )
  }
}

async function validateRawDevEnvEvidence(errors, preflight, manifestEntry, label) {
  if (!manifestEntry?.present) {
    errors.push(`${label} manifest entry is missing.`)
    return
  }
  if (!preflight?.run) return

  const raw = await readReferencedJson(errors, manifestEntry.file, `${label} raw evidence`)
  if (!raw) return

  validateRawDevEnvManifest(errors, raw, label)
  validateRawDevEnvMatchesSummary(errors, raw, preflight, label, compareValue)
}

async function validateRawWebReadinessEvidence(errors, webReadiness, manifestEntry, label) {
  if (!webReadiness?.run || !manifestEntry?.present) return

  const raw = await readReferencedJson(errors, manifestEntry.file, `${label} raw evidence`)
  if (!raw) return

  validateRawWebReadinessManifest(errors, raw, label)
  validateRawWebReadinessMatchesSummary(errors, raw, webReadiness, label, compareValue)
}

function validateProofSummary(errors, proofSummary, summary, plan) {
  if (!proofSummary || typeof proofSummary !== 'object') {
    errors.push('proofSummary is missing in validate mode.')
    return
  }
  validateProofSummaryManifest(errors, proofSummary, 'proofSummary')
  if (!summary || typeof summary !== 'object') return

  compareValue(errors, proofSummary.summaryRunId, summary.runId, 'proofSummary.summaryRunId', 'summary.runId')
  compareValue(errors, proofSummary.appUrl, summary.appUrl, 'proofSummary.appUrl', 'summary.appUrl')
  compareValue(errors, proofSummary.apiBase, summary.apiBase, 'proofSummary.apiBase', 'summary.apiBase')
  compareValue(
    errors,
    stableJson(proofSummary.requiredEvidence ?? {}),
    stableJson(plan?.requiredEvidence ?? {}),
    'proofSummary.requiredEvidence',
    'plan.requiredEvidence',
  )
  validateProofSummaryParity(errors, proofSummary.browserParity, summary.browserParity)
  validateProofSummaryWebReadiness(errors, proofSummary.webReadiness, summary.environment?.webReadiness)
  validateProofSummaryWebReadinessEvidence(errors, proofSummary.evidence, summary)
  validateProofSummaryLoop(errors, proofSummary.loops?.desktop, summary.loops?.desktop, 'proofSummary.loops.desktop')
  validateProofSummaryLoop(errors, proofSummary.loops?.windowsChrome, summary.loops?.windowsChrome, 'proofSummary.loops.windowsChrome')
  compareValue(errors, proofSummary.loops?.phone?.run, summary.loops?.phone?.run, 'proofSummary.loops.phone.run', 'summary.loops.phone.run')
  compareValue(
    errors,
    proofSummary.loops?.phone?.success ?? null,
    summary.loops?.phone?.success ?? null,
    'proofSummary.loops.phone.success',
    'summary.loops.phone.success',
  )
  validateProofSummaryEvidence(errors, proofSummary.evidence, plan)
}

function validateProofSummaryManifest(errors, proofSummary, label) {
  validateAllowedKeys(errors, proofSummary, PROOF_SUMMARY_KEYS, label)
  validateAllowedKeys(errors, proofSummary?.requiredEvidence, PROOF_SUMMARY_BOOLEAN_GROUP_KEYS, `${label}.requiredEvidence`)
  validateAllowedKeys(errors, proofSummary?.browserParity, PROOF_SUMMARY_PARITY_KEYS, `${label}.browserParity`)
  validateAllowedKeys(errors, proofSummary?.webReadiness, PROOF_SUMMARY_WEB_READINESS_KEYS, `${label}.webReadiness`)
  validateAllowedKeys(errors, proofSummary?.loops, PROOF_SUMMARY_LOOPS_KEYS, `${label}.loops`)
  validateAllowedKeys(errors, proofSummary?.loops?.desktop, PROOF_SUMMARY_LOOP_KEYS, `${label}.loops.desktop`)
  validateAllowedKeys(
    errors,
    proofSummary?.loops?.windowsChrome,
    PROOF_SUMMARY_LOOP_KEYS,
    `${label}.loops.windowsChrome`,
  )
  validateAllowedKeys(errors, proofSummary?.loops?.phone, PROOF_SUMMARY_PHONE_LOOP_KEYS, `${label}.loops.phone`)
  validateAllowedKeys(errors, proofSummary?.evidence, PROOF_SUMMARY_EVIDENCE_KEYS, `${label}.evidence`)
}

function validateProofSummaryParity(errors, proof, summary) {
  if (!proof || typeof proof !== 'object') {
    errors.push('proofSummary.browserParity is missing.')
    return
  }

  compareValue(errors, proof.checked, summary?.checked, 'proofSummary.browserParity.checked', 'summary.browserParity.checked')
  compareValue(errors, proof.success, summary?.success, 'proofSummary.browserParity.success', 'summary.browserParity.success')
  compareValue(
    errors,
    proof.errorCount,
    Array.isArray(summary?.errors) ? summary.errors.length : null,
    'proofSummary.browserParity.errorCount',
    'summary.browserParity.errors.length',
  )
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

function validateProofSummaryLoop(errors, proof, summary, label) {
  if (!proof || typeof proof !== 'object') {
    errors.push(`${label} is missing.`)
    return
  }
  if (!summary || typeof summary !== 'object') return

  compareValue(errors, proof.run, summary.run, `${label}.run`, 'summary loop run')
  compareValue(errors, proof.success, summary.success, `${label}.success`, 'summary loop success')
  compareValue(errors, proof.title ?? null, summary.title ?? null, `${label}.title`, 'summary loop title')
  compareValue(errors, proof.runButton ?? null, summary.localizedUi?.runButton ?? null, `${label}.runButton`, 'summary loop run button')
  compareValue(
    errors,
    proof.textRequiredPhrases ?? null,
    summary.textIntegrity?.requiredPhraseCount ?? null,
    `${label}.textRequiredPhrases`,
    'summary loop required phrase count',
  )
  compareValue(
    errors,
    proof.textMissingPhrases ?? null,
    summary.textIntegrity?.missingPhraseCount ?? null,
    `${label}.textMissingPhrases`,
    'summary loop missing phrase count',
  )
  compareValue(errors, proof.textMojibake ?? null, summary.textIntegrity?.mojibakeCount ?? null, `${label}.textMojibake`, 'summary loop mojibake count')
  compareValue(
    errors,
    proof.firstViewportMinVisibleRatio ?? null,
    summary.firstViewportVisibility?.minVisibleRatio ?? null,
    `${label}.firstViewportMinVisibleRatio`,
    'summary loop first viewport ratio',
  )
  compareValue(errors, proof.runtimeIssueCount ?? null, summary.runtimeHealth?.issueCount ?? null, `${label}.runtimeIssueCount`, 'summary loop issue count')
  compareValue(errors, proof.screenshotCount ?? null, summary.screenshotEvidence?.count ?? null, `${label}.screenshotCount`, 'summary loop screenshot count')
  compareValue(
    errors,
    proof.uniqueScreenshotDigestCount ?? null,
    summary.screenshotEvidence?.uniqueDigestCount ?? null,
    `${label}.uniqueScreenshotDigestCount`,
    'summary loop unique screenshot digest count',
  )
  compareValue(
    errors,
    proof.externalExecutionSource ?? null,
    summary.externalExecutionSync?.latestSource ?? null,
    `${label}.externalExecutionSource`,
    'summary loop external execution source',
  )
  compareValue(
    errors,
    proof.externalExecutionSourceMode ?? null,
    summary.externalExecutionSync?.sourceMode ?? null,
    `${label}.externalExecutionSourceMode`,
    'summary loop external execution source mode',
  )
  compareValue(
    errors,
    proof.acceptedActionCount ?? null,
    summary.externalExecutionSync?.acceptedActionCount ?? null,
    `${label}.acceptedActionCount`,
    'summary loop accepted action count',
  )
}

function validateProofSummaryEvidence(errors, evidence, plan) {
  if (!evidence || typeof evidence !== 'object') {
    errors.push('proofSummary.evidence is missing.')
    return
  }

  const pairs = [
    ['summaryPath', plan?.summaryPath],
    ['desktopEvidencePath', plan?.paths?.desktopEvidence],
    ['windowsChromeEvidencePath', plan?.paths?.windowsChromeEvidence],
    ['phoneEvidencePath', plan?.paths?.phoneEvidence],
    ['desktopScreenshotDir', plan?.paths?.desktopScreenshotDir],
    ['windowsChromeScreenshotDir', plan?.paths?.windowsChromeScreenshotDir],
  ]
  for (const [key, expected] of pairs) {
    validatePortableRepoPath(errors, evidence[key], `proofSummary.evidence.${key}`)
    compareRepoPaths(errors, evidence[key], expected, `proofSummary.evidence.${key}`, `plan ${key}`)
  }
}

function validateProofSummaryWebReadinessEvidence(errors, evidence, summary) {
  if (!evidence || typeof evidence !== 'object') return

  const manifest = manifestByLabel(summary?.evidence?.files)
  validatePortableRepoPath(errors, evidence.devEnvEvidencePath, 'proofSummary.evidence.devEnvEvidencePath')
  compareRepoPaths(
    errors,
    evidence.devEnvEvidencePath,
    manifest.get('Dev Environment JSON')?.file,
    'proofSummary.evidence.devEnvEvidencePath',
    'summary.evidence Dev Environment JSON',
  )
  validatePortableRepoPath(errors, evidence.webReadinessEvidencePath, 'proofSummary.evidence.webReadinessEvidencePath')
  compareRepoPaths(
    errors,
    evidence.webReadinessEvidencePath,
    manifest.get('Web Readiness JSON')?.file,
    'proofSummary.evidence.webReadinessEvidencePath',
    'summary.evidence Web Readiness JSON',
  )
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

async function validateRawEvidence(errors, summary, plan, resultGeneratedAt) {
  if (!summary || typeof summary !== 'object') return

  if (plan.requiredEvidence?.desktop === true) {
    const desktopEvidence = await readReferencedJson(errors, plan.paths?.desktopEvidence, 'plan.paths.desktopEvidence')
    validateRawEvidenceRun(errors, desktopEvidence, {
      label: 'desktop raw evidence',
      summaryLoop: summary.loops?.desktop,
      summary,
      summaryScreenshots: summaryScreenshotEntries(summary.evidence?.files, plan.paths?.desktopScreenshotDir),
      expectedRunId: summary.runId,
      expectedBrowserName: 'playwright-chromium',
      resultGeneratedAt,
    })
  }

  if (plan.requiredEvidence?.windowsChrome === true) {
    const chromeEvidence = await readReferencedJson(errors, plan.paths?.windowsChromeEvidence, 'plan.paths.windowsChromeEvidence')
    validateRawEvidenceRun(errors, chromeEvidence, {
      label: 'Windows Chrome raw evidence',
      summaryLoop: summary.loops?.windowsChrome,
      summary,
      summaryScreenshots: summaryScreenshotEntries(summary.evidence?.files, plan.paths?.windowsChromeScreenshotDir),
      expectedRunId: summary.runId,
      expectedBrowserName: 'windows-chrome',
      resultGeneratedAt,
    })
  }
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

async function validateManifestScreenshots(errors, files, screenshotDir, label) {
  if (!Array.isArray(files)) return

  const screenshotEntries = files.filter(
    (entry) => entry?.present === true && entry.label === 'Screenshot' && isInsidePath(entry.file, screenshotDir),
  )
  if (screenshotEntries.length !== 6) errors.push(`summary.evidence must include 6 ${label} screenshot entries.`)

  for (const entry of screenshotEntries) {
    await validateManifestFile(errors, entry, `summary.evidence ${label} screenshot ${entry.file ?? 'unknown'}`)
  }
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

async function assertExistingDirectory(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) return

  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) {
    errors.push(`${label} must stay inside the repository root.`)
    return
  }

  try {
    const fileStat = await stat(absolutePath)
    if (!fileStat.isDirectory()) errors.push(`${label} must point to a directory.`)
  } catch (error) {
    errors.push(`${label} cannot be read: ${error?.code ?? error.message ?? error}`)
  }
}

async function readReferencedJson(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) return null

  const absolutePath = resolveRepoPath(value)
  if (!absolutePath) return null

  return readJsonFile(errors, absolutePath, label)
}

async function readJsonFile(errors, absolutePath, label) {
  try {
    const text = await readFile(absolutePath, 'utf8')
    assertAsciiSafeJsonText(text, label)
    return JSON.parse(text)
  } catch (error) {
    errors.push(`${label} JSON cannot be read: ${error?.code ?? error.message ?? error}`)
    return null
  }
}

function compareRepoPaths(errors, left, right, leftLabel, rightLabel) {
  if (isSentinelPath(left) || isSentinelPath(right)) {
    if (left !== right) {
      errors.push(`${leftLabel} must match ${rightLabel}.`)
    }
    return
  }

  const leftPath = resolveRepoPath(left)
  const rightPath = resolveRepoPath(right)
  if (!leftPath || !rightPath || leftPath !== rightPath) {
    errors.push(`${leftLabel} must match ${rightLabel}.`)
  }
}

function compareValue(errors, left, right, leftLabel, rightLabel) {
  if (left !== right) {
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

function validateRepoPath(errors, value, label) {
  if (isSentinelPath(value)) return
  if (!resolveRepoPath(value)) errors.push(`${label} must stay inside the repository root.`)
}

function validatePortableRepoPath(errors, value, label) {
  if (typeof value === 'string' && path.isAbsolute(value)) {
    errors.push(`${label} must be repo-relative.`)
  }
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
  if (isSentinelPath(value)) return null

  const absolutePath = path.isAbsolute(value) ? path.resolve(value) : path.resolve(repoRoot, value)
  const relativePath = path.relative(repoRoot, absolutePath)
  if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    return null
  }

  return absolutePath
}

function isSentinelPath(value) {
  return typeof value === 'string' && value.startsWith('__')
}

function assertString(errors, value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    errors.push(`${label} must be a non-empty string.`)
  }
}

function resolveCliPath(value) {
  return path.isAbsolute(value) ? path.resolve(value) : path.resolve(process.cwd(), value)
}
