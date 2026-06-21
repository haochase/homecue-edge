import { execFileSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeJsonFile } from './json-file.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const validatorScript = path.join(scriptDir, 'validate-computer-loop-result.mjs')
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'computer-loop-result-validator-selftest')
const desktopEvidenceCommand = 'npm run desktop:evidence:check'
const windowsChromeEvidenceCommand = 'npm run desktop:evidence:check -- --require-installed-chrome'
const sourceSummary = formatSourceState(currentSourceState())

await mkdir(outputDir, { recursive: true })
await writeScreenshotFiles({
  desktopScreenshotDir: path.join(outputDir, 'playwright-chromium-screens'),
  windowsChromeScreenshotDir: path.join(outputDir, 'windows-chrome-screens'),
})

const positive = createResult()
await writeRawLoopEvidence(positive.browserEvidence.plan.paths)
const positiveSummary = await createSummary(positive.browserEvidence.plan.paths)
await writeReport(path.join(outputDir, 'computer-loop-report.md'), positiveSummary)
await writeJson(path.join(outputDir, 'computer-loop-report.json'), positiveSummary)
await writeJson(path.join(outputDir, 'browser-evidence-check.json'), positive.browserEvidence)

const positiveFile = path.join(outputDir, 'positive.json')
setResultJsonPath(positive, positiveFile)
await writeJson(positiveFile, positive)
const positiveResult = await runValidator(positiveFile)
if (positiveResult.code !== 0) {
  console.error(positiveResult.output)
  throw new Error('Expected positive computer loop result to pass validation.')
}
assertOutputIncludes(
  positiveResult.output,
  `Computer loop proof summary: summaryRunId=full-loop-selftest desktop=pass chrome=pass phone=not-run parity=pass web=already-ready source=${sourceSummary} screenshots=6+6 text=7/0/0+7/0/0 external=esp32-serial externalMode=api-simulated-room-terminal phoneEvidence=__phone_not_run__.json devEnvEvidence=assets/tmp/computer-loop-result-validator-selftest/dev-env-check.json webReadinessEvidence=assets/tmp/computer-loop-result-validator-selftest/web-readiness.json summary=assets/tmp/computer-loop-result-validator-selftest/computer-loop-report.json`,
  'positive proof summary output',
)
console.log('PASS positive computer loop result')

const fresh = createResult({
  maxAgeMinutes: 60,
  browserEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/fresh-browser-evidence-check.json',
})
fresh.generatedAt = new Date().toISOString()
fresh.browserEvidence.generatedAt = fresh.generatedAt
const freshFile = path.join(outputDir, 'fresh.json')
setResultJsonPath(fresh, freshFile)
await writeJson(resolveRepoPath(fresh.plan.outputs.browserEvidenceResultJsonPath), fresh.browserEvidence)
await writeJson(freshFile, fresh)
const freshResult = await runValidator(freshFile, ['--max-age-minutes', '60'])
if (freshResult.code !== 0) {
  console.error(freshResult.output)
  throw new Error('Expected fresh computer loop result to pass freshness validation.')
}
console.log('PASS fresh computer loop result')

const staleResult = await runValidator(positiveFile, ['--max-age-minutes', '1'])
if (staleResult.code === 0 || !staleResult.output.includes('generatedAt is older than --max-age-minutes=1.')) {
  console.error(staleResult.output)
  throw new Error('Expected stale computer loop result to fail freshness validation.')
}
console.log('PASS stale computer loop result')

const staleBrowserEvidence = createResult({
  maxAgeMinutes: 1,
  browserEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/stale-browser-evidence-check.json',
})
staleBrowserEvidence.generatedAt = new Date().toISOString()
const staleBrowserEvidenceFile = path.join(outputDir, 'stale-browser-evidence.json')
setResultJsonPath(staleBrowserEvidence, staleBrowserEvidenceFile)
await writeJson(resolveRepoPath(staleBrowserEvidence.plan.outputs.browserEvidenceResultJsonPath), staleBrowserEvidence.browserEvidence)
await writeJson(staleBrowserEvidenceFile, staleBrowserEvidence)
const staleBrowserEvidenceResult = await runValidator(staleBrowserEvidenceFile, ['--max-age-minutes', '1'])
if (
  staleBrowserEvidenceResult.code === 0 ||
  !staleBrowserEvidenceResult.output.includes('browserEvidence.generatedAt is older than --max-age-minutes=1.')
) {
  console.error(staleBrowserEvidenceResult.output)
  throw new Error('Expected stale nested browser evidence to fail freshness validation.')
}
console.log('PASS stale nested browser evidence result')

const future = structuredClone(positive)
future.generatedAt = new Date(Date.now() + 60_000).toISOString()
const futureFile = path.join(outputDir, 'future.json')
setResultJsonPath(future, futureFile)
await writeJson(futureFile, future)
const futureResult = await runValidator(futureFile, ['--max-age-minutes', '60'])
if (
  futureResult.code === 0 ||
  !futureResult.output.includes('generatedAt must not be in the future when --max-age-minutes is set.')
) {
  console.error(futureResult.output)
  throw new Error('Expected future computer loop result to fail freshness validation.')
}
console.log('PASS future computer loop result')

const invalidFreshnessResult = await runValidator(positiveFile, ['--max-age-minutes', '0'])
if (invalidFreshnessResult.code === 0 || !invalidFreshnessResult.output.includes('--max-age-minutes must be a positive number.')) {
  console.error(invalidFreshnessResult.output)
  throw new Error('Expected invalid computer loop freshness option to fail.')
}
console.log('PASS invalid computer loop freshness option')

const duplicateFreshnessResult = await runValidator(positiveFile, [
  '--max-age-minutes',
  '30',
  '--max-age-minutes=60',
])
if (
  duplicateFreshnessResult.code === 0 ||
  !duplicateFreshnessResult.output.includes('--max-age-minutes must be provided at most once.')
) {
  console.error(duplicateFreshnessResult.output)
  throw new Error('Expected duplicate computer loop freshness option to fail.')
}
console.log('PASS duplicate computer loop freshness option')

const dryRun = createResult({ mode: 'dry-run', browserEvidence: null })
const dryRunFile = path.join(outputDir, 'dry-run.json')
setResultJsonPath(dryRun, dryRunFile)
await writeJson(dryRunFile, dryRun)
const dryRunResult = await runValidator(dryRunFile)
if (dryRunResult.code !== 0) {
  console.error(dryRunResult.output)
  throw new Error('Expected dry-run computer loop result to pass validation.')
}
assertOutputExcludes(dryRunResult.output, 'Computer loop proof summary:', 'dry-run proof summary output')
console.log('PASS dry-run computer loop result')

await assertAsciiSafeJsonIsRequired()

const failed = createResult({ mode: 'failed', browserEvidence: null })
failed.success = false
failed.proofSummary = null
failed.failure = {
  stage: 'computer full loop',
  checkName: 'computer full loop',
  command: failed.plan.commands.fullLoop.display,
  exitCode: 1,
  message: 'simulated computer full loop failure',
}
const failedFile = path.join(outputDir, 'failed.json')
setResultJsonPath(failed, failedFile)
await writeJson(failedFile, failed)
const failedResult = await runValidator(failedFile)
if (failedResult.code !== 0) {
  console.error(failedResult.output)
  throw new Error('Expected failed computer loop result to pass validation.')
}
assertOutputExcludes(failedResult.output, 'Computer loop proof summary:', 'failed result proof summary output')
console.log('PASS failed computer loop result')

const selfTestPositive = createResult({ selfTest: true })
await writeRawLoopEvidence(selfTestPositive.browserEvidence.plan.paths)
const selfTestPositiveSummary = await createSummary(selfTestPositive.browserEvidence.plan.paths)
await writeReport(path.join(outputDir, 'selftest-computer-loop-report.md'), selfTestPositiveSummary)
await writeJson(path.join(outputDir, 'selftest-computer-loop-report.json'), selfTestPositiveSummary)
await writeJson(path.join(outputDir, 'selftest-browser-evidence-check.json'), selfTestPositive.browserEvidence)

const selfTestPositiveFile = path.join(outputDir, 'selftest-positive.json')
setResultJsonPath(selfTestPositive, selfTestPositiveFile)
await writeJson(selfTestPositiveFile, selfTestPositive)
const selfTestPositiveResult = await runValidator(selfTestPositiveFile)
if (selfTestPositiveResult.code !== 0) {
  console.error(selfTestPositiveResult.output)
  throw new Error('Expected self-test computer loop result to pass validation.')
}
assertOutputIncludes(
  selfTestPositiveResult.output,
  `Computer loop proof summary: summaryRunId=full-loop-selftest desktop=pass chrome=pass phone=not-run parity=pass web=already-ready source=${sourceSummary} screenshots=6+6 text=7/0/0+7/0/0 external=esp32-serial externalMode=api-simulated-room-terminal phoneEvidence=__phone_not_run__.json devEnvEvidence=assets/tmp/computer-loop-result-validator-selftest/dev-env-check.json webReadinessEvidence=assets/tmp/computer-loop-result-validator-selftest/web-readiness.json summary=assets/tmp/computer-loop-result-validator-selftest/selftest-computer-loop-report.json`,
  'self-test proof summary output',
)
console.log('PASS self-test computer loop result')

const cases = [
  {
    name: 'result-root-unexpected-field',
    expectedError: 'result root must not include unexpected field: artifacts.',
    mutate: (result) => {
      result.artifacts = []
    },
  },
  {
    name: 'plan-unexpected-field',
    expectedError: 'plan must not include unexpected field: artifacts.',
    mutate: (result) => {
      result.plan.artifacts = []
    },
  },
  {
    name: 'source-state-missing',
    expectedError: 'sourceState is missing.',
    mutate: (result) => {
      delete result.sourceState
    },
  },
  {
    name: 'source-state-unexpected-field',
    expectedError: 'sourceState must not include unexpected field: remote.',
    mutate: (result) => {
      result.sourceState.remote = 'origin'
    },
  },
  {
    name: 'source-state-commit-mismatch',
    expectedError: 'sourceState.commit must match current git commit.',
    mutate: (result) => {
      result.sourceState.commit = '0'.repeat(40)
    },
  },
  {
    name: 'source-state-status-invalid',
    expectedError: 'sourceState.statusSha256 must be a 12-character SHA-256 prefix.',
    mutate: (result) => {
      result.sourceState.statusSha256 = 'not-a-hash'
    },
  },
  {
    name: 'source-state-dirty-mismatch',
    expectedError: 'sourceState.dirty must match current git dirty.',
    mutate: (result) => {
      result.sourceState.dirty = !result.sourceState.dirty
    },
  },
  {
    name: 'source-state-status-sha-mismatch',
    expectedError: 'sourceState.statusSha256 must match current git statusSha256.',
    mutate: (result) => {
      result.sourceState.statusSha256 = '0'.repeat(12)
    },
  },
  {
    name: 'plan-options-unexpected-field',
    expectedError: 'plan.options must not include unexpected field: debug.',
    mutate: (result) => {
      result.plan.options.debug = true
    },
  },
  {
    name: 'plan-options-max-age-invalid',
    expectedError: 'plan.options.maxAgeMinutes must be null or a positive number.',
    mutate: (result) => {
      result.plan.options.maxAgeMinutes = 0
    },
  },
  {
    name: 'browser-evidence-max-age-arg-missing',
    expectedError: 'plan.commands.browserEvidence -MaxAgeMinutes must appear exactly once when plan.options.maxAgeMinutes is set.',
    mutate: (result) => {
      result.plan.options.maxAgeMinutes = 30
      result.browserEvidence.plan.options.maxAgeMinutes = 30
    },
  },
  {
    name: 'browser-evidence-max-age-arg-mismatch',
    expectedError: 'plan.commands.browserEvidence -MaxAgeMinutes must match plan.options.maxAgeMinutes.',
    mutate: (result) => {
      result.plan.options.maxAgeMinutes = 30
      result.browserEvidence.plan.options.maxAgeMinutes = 30
      result.plan.commands.browserEvidence.args.push('-MaxAgeMinutes', '60')
      result.plan.commands.browserEvidence.display = displayCommand('powershell', result.plan.commands.browserEvidence.args)
      result.checks.find((check) => check.name === 'saved browser evidence recheck').command =
        result.plan.commands.browserEvidence.display
    },
  },
  {
    name: 'browser-evidence-max-age-arg-unexpected',
    expectedError: 'plan.commands.browserEvidence -MaxAgeMinutes must be omitted when plan.options.maxAgeMinutes is null.',
    mutate: (result) => {
      result.plan.commands.browserEvidence.args.push('-MaxAgeMinutes', '30')
      result.plan.commands.browserEvidence.display = displayCommand('powershell', result.plan.commands.browserEvidence.args)
      result.checks.find((check) => check.name === 'saved browser evidence recheck').command =
        result.plan.commands.browserEvidence.display
    },
  },
  {
    name: 'plan-command-unexpected-field',
    expectedError: 'plan.commands.fullLoop must not include unexpected field: cwd.',
    mutate: (result) => {
      result.plan.commands.fullLoop.cwd = '.'
    },
  },
  {
    name: 'result-path-mismatch',
    expectedError: 'plan.outputs.resultJsonPath must match validated result file.',
    mutate: (result) => {
      result.plan.outputs.resultJsonPath = 'assets/tmp/computer-loop-result-validator-selftest/other-result.json'
    },
  },
  {
    name: 'absolute-output-summary-path',
    expectedError: 'plan.outputs.summaryPath must be repo-relative.',
    mutate: (result) => {
      const absoluteSummaryPath = path.join(repoRoot, result.plan.outputs.summaryPath)
      result.plan.outputs.summaryPath = absoluteSummaryPath
      result.checks[0].summaryPath = absoluteSummaryPath
      result.browserEvidence.plan.summaryPath = absoluteSummaryPath
      result.browserEvidence.proofSummary.evidence.summaryPath = absoluteSummaryPath
      result.proofSummary.evidence.summaryPath = absoluteSummaryPath
    },
  },
  {
    name: 'absolute-full-loop-script-path',
    expectedError: 'plan.commands.fullLoop -File must be repo-relative.',
    mutate: (result) => {
      const fileIndex = result.plan.commands.fullLoop.args.indexOf('-File') + 1
      result.plan.commands.fullLoop.args[fileIndex] = path.join(repoRoot, result.plan.commands.fullLoop.args[fileIndex])
      result.plan.commands.fullLoop.display = displayCommand('powershell', result.plan.commands.fullLoop.args)
      result.checks[0].command = result.plan.commands.fullLoop.display
    },
  },
  {
    name: 'full-loop-script-path-mismatch',
    expectedError: 'plan.commands.fullLoop -File must match scripts/check-full-loop.ps1.',
    mutate: (result) => {
      const fileIndex = result.plan.commands.fullLoop.args.indexOf('-File') + 1
      result.plan.commands.fullLoop.args[fileIndex] = 'scripts/check-browser-evidence.ps1'
      result.plan.commands.fullLoop.display = displayCommand('powershell', result.plan.commands.fullLoop.args)
      result.checks[0].command = result.plan.commands.fullLoop.display
    },
  },
  {
    name: 'browser-evidence-script-path-mismatch',
    expectedError: 'plan.commands.browserEvidence -File must match scripts/check-browser-evidence.ps1.',
    mutate: (result) => {
      const fileIndex = result.plan.commands.browserEvidence.args.indexOf('-File') + 1
      result.plan.commands.browserEvidence.args[fileIndex] = 'scripts/check-full-loop.ps1'
      result.plan.commands.browserEvidence.display = displayCommand('powershell', result.plan.commands.browserEvidence.args)
      result.checks[1].command = result.plan.commands.browserEvidence.display
    },
  },
  {
    name: 'absolute-browser-evidence-proof-summary-path',
    expectedError: 'browserEvidence.proofSummary.evidence.desktopEvidencePath must be repo-relative.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.evidence.desktopEvidencePath = path.join(
        repoRoot,
        result.browserEvidence.proofSummary.evidence.desktopEvidencePath,
      )
      result.proofSummary.evidence.desktopEvidencePath = result.browserEvidence.proofSummary.evidence.desktopEvidencePath
    },
  },
  {
    name: 'failed-success-true',
    expectedError: 'success must be false in failed mode.',
    mutate: (result) => {
      result.mode = 'failed'
      result.failure = {
        stage: 'computer full loop',
        checkName: 'computer full loop',
        command: result.plan.commands.fullLoop.display,
        exitCode: 1,
        message: 'simulated failure',
      }
      result.proofSummary = null
      result.browserEvidence = null
    },
  },
  {
    name: 'failed-missing-failure',
    expectedError: 'failure is missing in failed mode.',
    mutate: (result) => {
      result.mode = 'failed'
      result.success = false
      result.proofSummary = null
      result.browserEvidence = null
    },
  },
  {
    name: 'failed-invalid-stage',
    expectedError: 'failure.stage must identify a computer loop stage.',
    mutate: (result) => {
      result.mode = 'failed'
      result.success = false
      result.proofSummary = null
      result.browserEvidence = null
      result.failure = {
        stage: 'other stage',
        checkName: 'other stage',
        command: result.plan.commands.fullLoop.display,
        exitCode: 1,
        message: 'simulated failure',
      }
    },
  },
  {
    name: 'failed-unexpected-field',
    expectedError: 'failure must not include unexpected field: proofSummary.',
    mutate: (result) => {
      result.mode = 'failed'
      result.success = false
      result.proofSummary = null
      result.browserEvidence = null
      result.failure = {
        stage: 'computer full loop',
        checkName: 'computer full loop',
        command: result.plan.commands.fullLoop.display,
        exitCode: 1,
        message: 'simulated failure',
        proofSummary: {},
      }
    },
  },
  {
    name: 'failed-check-name-mismatch',
    expectedError: 'failure.checkName must match failure.stage.',
    mutate: (result) => {
      result.mode = 'failed'
      result.success = false
      result.proofSummary = null
      result.browserEvidence = null
      result.failure = {
        stage: 'computer full loop',
        checkName: 'saved browser evidence recheck',
        command: result.plan.commands.fullLoop.display,
        exitCode: 1,
        message: 'simulated failure',
      }
    },
  },
  {
    name: 'failed-command-mismatch',
    expectedError: 'failure.command must match the command for failure.stage.',
    mutate: (result) => {
      result.mode = 'failed'
      result.success = false
      result.proofSummary = null
      result.browserEvidence = null
      result.failure = {
        stage: 'saved browser evidence recheck',
        checkName: 'saved browser evidence recheck',
        command: result.plan.commands.fullLoop.display,
        exitCode: 1,
        message: 'simulated failure',
      }
    },
  },
  {
    name: 'full-loop-report-arg-mismatch',
    expectedError: 'plan.commands.fullLoop -ReportPath must match plan.outputs.reportPath.',
    mutate: (result) => {
      const reportPathIndex = result.plan.commands.fullLoop.args.indexOf('-ReportPath') + 1
      result.plan.commands.fullLoop.args[reportPathIndex] =
        'assets/tmp/computer-loop-result-validator-selftest/other-report.md'
    },
  },
  {
    name: 'browser-evidence-result-arg-mismatch',
    expectedError: 'plan.commands.browserEvidence -ResultJsonPath must match plan.outputs.browserEvidenceResultJsonPath.',
    mutate: (result) => {
      const resultPathIndex = result.plan.commands.browserEvidence.args.indexOf('-ResultJsonPath') + 1
      result.plan.commands.browserEvidence.args[resultPathIndex] =
        'assets/tmp/computer-loop-result-validator-selftest/other-browser-evidence.json'
    },
  },
  {
    name: 'full-loop-browser-wrapper-lock-timeout-arg-mismatch',
    expectedError:
      'plan.commands.fullLoop -BrowserWrapperSharedStateLockTimeoutSeconds must match plan.options.browserWrapperSharedStateLockTimeoutSeconds.',
    mutate: (result) => {
      const lockTimeoutIndex = result.plan.commands.fullLoop.args.indexOf('-BrowserWrapperSharedStateLockTimeoutSeconds') + 1
      result.plan.commands.fullLoop.args[lockTimeoutIndex] = '99'
    },
  },
  {
    name: 'full-loop-display-mismatch',
    expectedError: 'computer full loop command must match plan.commands.fullLoop.display.',
    mutate: (result) => {
      result.checks[0].command = 'powershell -File scripts/check-full-loop.ps1'
    },
  },
  {
    name: 'top-level-check-order-mismatch',
    expectedError: 'checks order must be computer full loop then saved browser evidence recheck.',
    mutate: (result) => {
      result.checks = [result.checks[1], result.checks[0]]
    },
  },
  {
    name: 'top-level-check-duplicate-name',
    expectedError: 'checks entry name must be unique: computer full loop.',
    mutate: (result) => {
      result.checks[1].name = 'computer full loop'
    },
  },
  {
    name: 'top-level-check-unexpected-name',
    expectedError: 'checks contains unexpected entry: other check.',
    mutate: (result) => {
      result.checks[1].name = 'other check'
    },
  },
  {
    name: 'top-level-full-loop-unexpected-field',
    expectedError: 'computer full loop check must not include unexpected field: resultJsonPath.',
    mutate: (result) => {
      result.checks[0].resultJsonPath = result.plan.outputs.browserEvidenceResultJsonPath
    },
  },
  {
    name: 'top-level-browser-evidence-unexpected-field',
    expectedError: 'saved browser evidence recheck must not include unexpected field: reportPath.',
    mutate: (result) => {
      result.checks[1].reportPath = result.plan.outputs.reportPath
    },
  },
  {
    name: 'phone-loop-requested',
    expectedError: 'plan.requestedLoops.phone must be false.',
    mutate: (result) => {
      result.plan.requestedLoops.phone = true
    },
  },
  {
    name: 'phone-expected-evidence-missing',
    expectedError: 'plan.expectedEvidence.phoneEvidence must be __phone_not_run__.json for computer-only checks.',
    mutate: (result) => {
      result.plan.expectedEvidence.phoneEvidence = 'assets/demo/phone-loop.json'
    },
  },
  {
    name: 'full-loop-includes-phone',
    expectedError: 'plan.commands.fullLoop.args must not include -IncludePhone',
    mutate: (result) => {
      result.plan.commands.fullLoop.args.push('-IncludePhone')
    },
  },
  {
    name: 'full-loop-skip-phone-missing',
    expectedError: 'plan.commands.fullLoop.args must include -SkipPhone for computer-only checks.',
    mutate: (result) => {
      result.plan.commands.fullLoop.args = result.plan.commands.fullLoop.args.filter((arg) => arg !== '-SkipPhone')
    },
  },
  {
    name: 'full-loop-skip-phone-gate-missing',
    expectedError: 'plan.gates.fullLoopSkipPhone must be true for computer-only checks.',
    mutate: (result) => {
      result.plan.gates.fullLoopSkipPhone = false
    },
  },
  {
    name: 'browser-evidence-phone-required',
    expectedError: 'browserEvidence.plan.requiredEvidence.phone must be false.',
    mutate: (result) => {
      result.browserEvidence.plan.requiredEvidence.phone = true
    },
  },
  {
    name: 'browser-evidence-root-unexpected-field',
    expectedError: 'browserEvidence must not include unexpected field: failure.',
    mutate: (result) => {
      result.browserEvidence.failure = null
    },
  },
  {
    name: 'browser-evidence-source-state-missing',
    expectedError: 'browserEvidence.sourceState is missing.',
    mutate: (result) => {
      delete result.browserEvidence.sourceState
    },
  },
  {
    name: 'browser-evidence-source-state-commit-mismatch',
    expectedError: 'browserEvidence.sourceState.commit must match current git commit.',
    mutate: (result) => {
      result.browserEvidence.sourceState.commit = '0'.repeat(40)
    },
  },
  {
    name: 'browser-evidence-source-state-dirty-mismatch',
    expectedError: 'browserEvidence.sourceState.dirty must match current git dirty.',
    mutate: (result) => {
      result.browserEvidence.sourceState.dirty = !result.browserEvidence.sourceState.dirty
    },
  },
  {
    name: 'browser-evidence-source-state-status-sha-mismatch',
    expectedError: 'browserEvidence.sourceState.statusSha256 must match current git statusSha256.',
    mutate: (result) => {
      result.browserEvidence.sourceState.statusSha256 = '0'.repeat(12)
    },
  },
  {
    name: 'browser-evidence-source-state-top-level-mismatch',
    expectedError: 'browserEvidence.sourceState must match top-level sourceState.',
    mutate: (result) => {
      result.browserEvidence.sourceState.statusCount += 1
    },
  },
  {
    name: 'browser-evidence-plan-unexpected-field',
    expectedError: 'browserEvidence.plan must not include unexpected field: artifacts.',
    mutate: (result) => {
      result.browserEvidence.plan.artifacts = []
    },
  },
  {
    name: 'browser-evidence-plan-paths-unexpected-field',
    expectedError: 'browserEvidence.plan.paths must not include unexpected field: reportPath.',
    mutate: (result) => {
      result.browserEvidence.plan.paths.reportPath = result.plan.outputs.reportPath
    },
  },
  {
    name: 'browser-evidence-plan-options-unexpected-field',
    expectedError: 'browserEvidence.plan.options must not include unexpected field: debug.',
    mutate: (result) => {
      result.browserEvidence.plan.options.debug = true
    },
  },
  {
    name: 'browser-evidence-plan-options-invalid',
    expectedError: 'browserEvidence.plan.options.maxAgeMinutes must be null or a positive number.',
    mutate: (result) => {
      result.browserEvidence.plan.options.maxAgeMinutes = 0
    },
  },
  {
    name: 'browser-evidence-plan-options-max-age-mismatch',
    expectedError: 'browserEvidence.plan.options.maxAgeMinutes must match plan.options.maxAgeMinutes.',
    mutate: (result) => {
      result.plan.options.maxAgeMinutes = 30
      result.browserEvidence.plan.options.maxAgeMinutes = 60
    },
  },
  {
    name: 'browser-evidence-phone-inferred',
    expectedError: 'browserEvidence.plan.inferredFromSummary.phone must be false.',
    mutate: (result) => {
      result.browserEvidence.plan.inferredFromSummary.phone = true
    },
  },
  {
    name: 'browser-evidence-skipped-phone-path-uses-demo-evidence',
    expectedError: 'browserEvidence.plan.paths.phoneEvidence must be __phone_not_run__.json when phone evidence is not required.',
    mutate: (result) => {
      result.browserEvidence.plan.paths.phoneEvidence = 'assets/demo/phone-loop.json'
      result.browserEvidence.proofSummary.evidence.phoneEvidencePath = result.browserEvidence.plan.paths.phoneEvidence
      result.proofSummary.evidence.phoneEvidencePath = result.browserEvidence.plan.paths.phoneEvidence
    },
  },
  {
    name: 'expected-phone-evidence-browser-path-mismatch',
    expectedError: 'plan.expectedEvidence.phoneEvidence must match browserEvidence.plan.paths.phoneEvidence.',
    mutate: (result) => {
      result.browserEvidence.plan.paths.phoneEvidence = 'assets/tmp/computer-loop-result-validator-selftest/phone-loop.json'
    },
  },
  {
    name: 'browser-evidence-required-desktop-path-uses-sentinel',
    expectedError: 'browserEvidence.plan.paths.desktopEvidence must be a real evidence path when desktop evidence is required.',
    mutate: (result) => {
      result.browserEvidence.plan.paths.desktopEvidence = '__desktop_not_run__.json'
      findBrowserEvidenceCheck(result, desktopEvidenceCommand).path = result.browserEvidence.plan.paths.desktopEvidence
      result.browserEvidence.proofSummary.evidence.desktopEvidencePath = result.browserEvidence.plan.paths.desktopEvidence
      result.proofSummary.evidence.desktopEvidencePath = result.browserEvidence.plan.paths.desktopEvidence
    },
  },
  {
    name: 'browser-evidence-required-chrome-screenshot-dir-uses-sentinel',
    expectedError:
      'browserEvidence.plan.paths.windowsChromeScreenshotDir must be a real evidence path when windowsChrome evidence is required.',
    mutate: (result) => {
      result.browserEvidence.plan.paths.windowsChromeScreenshotDir = '__chrome_screens_not_run__'
      findBrowserEvidenceCheck(result, windowsChromeEvidenceCommand).screenshotDir =
        result.browserEvidence.plan.paths.windowsChromeScreenshotDir
      result.browserEvidence.proofSummary.evidence.windowsChromeScreenshotDir =
        result.browserEvidence.plan.paths.windowsChromeScreenshotDir
      result.proofSummary.evidence.windowsChromeScreenshotDir = result.browserEvidence.plan.paths.windowsChromeScreenshotDir
    },
  },
  {
    name: 'browser-evidence-selftest-requested',
    expectedError: 'browserEvidence.plan.selfTest.requested must match plan.options.selfTest for computer-only result.',
    mutate: (result) => {
      result.browserEvidence.plan.selfTest.requested = true
    },
  },
  {
    name: 'browser-wrapper-lock-name-mismatch',
    expectedError: 'plan.gates.browserWrapperSharedStateLock.name must be Global\\HCEdgeBrowserLoopGate.',
    mutate: (result) => {
      result.plan.gates.browserWrapperSharedStateLock.name = 'Global\\OtherLock'
    },
  },
  {
    name: 'browser-wrapper-lock-timeout-mismatch',
    expectedError:
      'plan.gates.browserWrapperSharedStateLock.timeoutSeconds must match plan.options.browserWrapperSharedStateLockTimeoutSeconds.',
    mutate: (result) => {
      result.plan.gates.browserWrapperSharedStateLock.timeoutSeconds = 99
    },
  },
  {
    name: 'web-readiness-http-probe-missing',
    expectedError: 'plan.gates.fullLoopWebReadiness.httpProbeBeforePortReuse must be true.',
    mutate: (result) => {
      result.plan.gates.fullLoopWebReadiness.httpProbeBeforePortReuse = false
    },
  },
  {
    name: 'web-readiness-stale-port-missing',
    expectedError: 'plan.gates.fullLoopWebReadiness.stalePortBlocksDuplicateStart must be true.',
    mutate: (result) => {
      result.plan.gates.fullLoopWebReadiness.stalePortBlocksDuplicateStart = false
    },
  },
  {
    name: 'browser-evidence-selftest-summary-mismatch',
    expectedError: 'browserEvidence.plan.selfTest.summary must match plan.options.selfTest for computer-only result.',
    mutate: (result) => {
      applySelfTestMode(result)
      result.browserEvidence.plan.selfTest.summary = false
    },
  },
  {
    name: 'browser-evidence-selftest-command-missing',
    expectedError: 'browserEvidence.checks missing self-test command: npm run summary:selftest',
    mutate: (result) => {
      applySelfTestMode(result)
      result.browserEvidence.checks = result.browserEvidence.checks.filter(
        (check) => !check.command.startsWith('npm run summary:selftest'),
      )
    },
  },
  {
    name: 'browser-evidence-selftest-check-count-missing',
    expectedError: 'browserEvidence.checks must contain exactly 5 entries for this computer-only result.',
    mutate: (result) => {
      applySelfTestMode(result)
      result.browserEvidence.checks = result.browserEvidence.checks.filter(
        (check) => !check.command.startsWith('npm run summary:selftest'),
      )
    },
  },
  {
    name: 'browser-evidence-desktop-check-not-required',
    expectedError: 'browserEvidence.checks npm run desktop:evidence:check must be required.',
    mutate: (result) => {
      findBrowserEvidenceCheck(result, desktopEvidenceCommand).required = false
    },
  },
  {
    name: 'browser-evidence-desktop-check-name-mismatch',
    expectedError: 'browserEvidence.checks npm run desktop:evidence:check name must be desktop raw evidence.',
    mutate: (result) => {
      findBrowserEvidenceCheck(result, desktopEvidenceCommand).name = 'desktop loop check'
    },
  },
  {
    name: 'browser-evidence-desktop-check-unexpected-field',
    expectedError: 'browserEvidence.checks npm run desktop:evidence:check must not include unexpected field: resultJsonPath.',
    mutate: (result) => {
      findBrowserEvidenceCheck(result, desktopEvidenceCommand).resultJsonPath = result.browserEvidence.plan.resultJsonPath
    },
  },
  {
    name: 'browser-evidence-duplicate-desktop-check',
    expectedError: 'browserEvidence.checks command must be unique: npm run desktop:evidence:check.',
    mutate: (result) => {
      const check = findBrowserEvidenceCheck(result, desktopEvidenceCommand)
      result.browserEvidence.checks.push({ ...check })
    },
  },
  {
    name: 'browser-evidence-unknown-command',
    expectedError: 'browserEvidence.checks command is not allowed for computer-only result: npm run other:evidence:check.',
    mutate: (result) => {
      result.browserEvidence.checks.push({ command: 'npm run other:evidence:check', required: true })
    },
  },
  {
    name: 'browser-evidence-extra-check-count',
    expectedError: 'browserEvidence.checks must contain exactly 3 entries for this computer-only result.',
    mutate: (result) => {
      result.browserEvidence.checks.push({ command: 'npm run desktop:evidence:selftest', required: true })
    },
  },
  {
    name: 'browser-evidence-check-order-mismatch',
    expectedError: 'browserEvidence.checks command order must match the computer-only evidence plan.',
    mutate: (result) => {
      const [desktopCheck, chromeCheck, ...rest] = result.browserEvidence.checks
      result.browserEvidence.checks = [chromeCheck, desktopCheck, ...rest]
    },
  },
  {
    name: 'browser-evidence-desktop-check-path-mismatch',
    expectedError:
      'browserEvidence.checks npm run desktop:evidence:check path must match browserEvidence.plan npm run desktop:evidence:check path.',
    mutate: (result) => {
      findBrowserEvidenceCheck(result, desktopEvidenceCommand).path =
        'assets/tmp/computer-loop-result-validator-selftest/other-desktop-loop.json'
    },
  },
  {
    name: 'browser-evidence-chrome-check-screenshot-dir-mismatch',
    expectedError:
      'browserEvidence.checks npm run desktop:evidence:check -- --require-installed-chrome screenshotDir must match browserEvidence.plan npm run desktop:evidence:check -- --require-installed-chrome screenshotDir.',
    mutate: (result) => {
      findBrowserEvidenceCheck(result, windowsChromeEvidenceCommand).screenshotDir =
        'assets/tmp/computer-loop-result-validator-selftest/other-windows-chrome-screens'
    },
  },
  {
    name: 'browser-evidence-summary-check-path-mismatch',
    expectedError:
      'browserEvidence.checks npm run summary:check path must match browserEvidence.plan npm run summary:check path.',
    mutate: (result) => {
      findBrowserEvidenceCheck(result, 'npm run summary:check').path =
        'assets/tmp/computer-loop-result-validator-selftest/other-summary.json'
    },
  },
  {
    name: 'browser-evidence-selftest-command-not-required',
    expectedError: 'browserEvidence.checks self-test command must be required: npm run summary:selftest',
    mutate: (result) => {
      applySelfTestMode(result)
      findBrowserEvidenceCheck(result, 'npm run summary:selftest', { prefix: true }).required = false
    },
  },
  {
    name: 'browser-evidence-selftest-name-mismatch',
    expectedError: 'browserEvidence.checks self-test command name must be summary validator self-test: npm run summary:selftest',
    mutate: (result) => {
      applySelfTestMode(result)
      findBrowserEvidenceCheck(result, 'npm run summary:selftest', { prefix: true }).name = 'summary check'
    },
  },
  {
    name: 'browser-evidence-selftest-unexpected-field',
    expectedError: 'must not include unexpected field: path.',
    mutate: (result) => {
      applySelfTestMode(result)
      findBrowserEvidenceCheck(result, 'npm run summary:selftest', { prefix: true }).path =
        result.browserEvidence.plan.summaryPath
    },
  },
  {
    name: 'browser-evidence-duplicate-selftest-command',
    expectedError: 'browserEvidence.checks command must be unique: npm run summary:selftest',
    mutate: (result) => {
      applySelfTestMode(result)
      const check = findBrowserEvidenceCheck(result, 'npm run summary:selftest', { prefix: true })
      result.browserEvidence.checks.push({ ...check })
    },
  },
  {
    name: 'browser-evidence-unknown-selftest-command',
    expectedError: 'browserEvidence.checks command is not allowed for computer-only result: npm run unknown:selftest.',
    mutate: (result) => {
      applySelfTestMode(result)
      result.browserEvidence.checks.push({ command: 'npm run unknown:selftest', required: true })
    },
  },
  {
    name: 'browser-evidence-selftest-command-unexpected',
    expectedError: 'browserEvidence.checks must not include self-test command: npm run report:selftest',
    mutate: (result) => {
      result.browserEvidence.checks.push({ command: 'npm run report:selftest', required: true })
    },
  },
  {
    name: 'browser-evidence-summary-mismatch',
    expectedError: 'browserEvidence.plan.summaryPath must match plan.outputs.summaryPath.',
    mutate: (result) => {
      result.browserEvidence.plan.summaryPath = 'assets/tmp/computer-loop-result-validator-selftest/other-summary.json'
    },
  },
  {
    name: 'browser-evidence-result-path-mismatch',
    expectedError: 'browserEvidence.plan.resultJsonPath must match plan.outputs.browserEvidenceResultJsonPath.',
    mutate: (result) => {
      result.browserEvidence.plan.resultJsonPath =
        'assets/tmp/computer-loop-result-validator-selftest/other-browser-evidence.json'
    },
  },
  {
    name: 'referenced-browser-evidence-ascii-safe-json-required',
    expectedError:
      'plan.outputs.browserEvidenceResultJsonPath JSON cannot be read: plan.outputs.browserEvidenceResultJsonPath must be ASCII-safe JSON',
    prepare: async (result, name) => {
      const file = `assets/tmp/computer-loop-result-validator-selftest/${name}/browser-evidence-check.json`
      result.plan.outputs.browserEvidenceResultJsonPath = file
      result.checks[1].resultJsonPath = file
      await writeNonAsciiJson(resolveRepoPath(file), result.browserEvidence)
    },
    skipBrowserEvidenceRewrite: true,
  },
  {
    name: 'missing-browser-evidence',
    expectedError: 'browserEvidence is missing in validate mode.',
    mutate: (result) => {
      result.browserEvidence = null
    },
  },
  {
    name: 'missing-browser-evidence-proof-summary',
    expectedError: 'browserEvidence.proofSummary is missing in validate mode.',
    mutate: (result) => {
      result.browserEvidence.proofSummary = null
    },
  },
  {
    name: 'browser-evidence-proof-summary-unexpected-field',
    expectedError: 'browserEvidence.proofSummary must not include unexpected field: artifacts.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.artifacts = []
    },
  },
  {
    name: 'browser-evidence-proof-summary-loop-unexpected-field',
    expectedError: 'browserEvidence.proofSummary.loops.windowsChrome must not include unexpected field: trace.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.loops.windowsChrome.trace = {}
    },
  },
  {
    name: 'browser-evidence-proof-summary-evidence-unexpected-field',
    expectedError: 'browserEvidence.proofSummary.evidence must not include unexpected field: reportPath.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.evidence.reportPath = result.plan.outputs.reportPath
    },
  },
  {
    name: 'browser-evidence-proof-summary-run-id-mismatch',
    expectedError: 'browserEvidence.proofSummary.summaryRunId must match summary.runId.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.summaryRunId = 'different-full-loop'
    },
  },
  {
    name: 'browser-evidence-proof-summary-path-mismatch',
    expectedError: 'browserEvidence.proofSummary.evidence.desktopEvidencePath must match browserEvidence.plan desktopEvidencePath.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.evidence.desktopEvidencePath =
        'assets/tmp/computer-loop-result-validator-selftest/other-desktop-loop.json'
    },
  },
  {
    name: 'browser-evidence-proof-summary-web-readiness-path-mismatch',
    expectedError:
      'browserEvidence.proofSummary.evidence.webReadinessEvidencePath must match summary.evidence Web Readiness JSON.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.evidence.webReadinessEvidencePath =
        'assets/tmp/computer-loop-result-validator-selftest/other-web-readiness.json'
    },
  },
  {
    name: 'browser-evidence-proof-summary-dev-env-path-mismatch',
    expectedError:
      'browserEvidence.proofSummary.evidence.devEnvEvidencePath must match summary.evidence Dev Environment JSON.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.evidence.devEnvEvidencePath =
        'assets/tmp/computer-loop-result-validator-selftest/other-dev-env.json'
    },
  },
  {
    name: 'browser-evidence-proof-summary-web-readiness-mismatch',
    expectedError:
      'browserEvidence.proofSummary.webReadiness.strategy must match summary.environment.webReadiness.strategy.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.webReadiness.strategy = 'started-new-server'
    },
  },
  {
    name: 'missing-proof-summary',
    expectedError: 'proofSummary is missing in validate mode.',
    mutate: (result) => {
      result.proofSummary = null
    },
  },
  {
    name: 'proof-summary-unexpected-field',
    expectedError: 'proofSummary must not include unexpected field: artifacts.',
    mutate: (result) => {
      result.proofSummary.artifacts = []
    },
  },
  {
    name: 'proof-summary-loop-unexpected-field',
    expectedError: 'proofSummary.loops.desktop must not include unexpected field: trace.',
    mutate: (result) => {
      result.proofSummary.loops.desktop.trace = {}
    },
  },
  {
    name: 'proof-summary-evidence-unexpected-field',
    expectedError: 'proofSummary.evidence must not include unexpected field: browserEvidenceReportPath.',
    mutate: (result) => {
      result.proofSummary.evidence.browserEvidenceReportPath = result.plan.outputs.reportPath
    },
  },
  {
    name: 'proof-summary-screenshot-count-mismatch',
    expectedError: 'proofSummary.loops.windowsChrome.screenshotCount must match summary loop screenshot count.',
    mutate: (result) => {
      result.proofSummary.loops.windowsChrome.screenshotCount = 5
    },
  },
  {
    name: 'proof-summary-text-required-count-mismatch',
    expectedError: 'proofSummary.loops.desktop.textRequiredPhrases must match summary loop required phrase count.',
    mutate: (result) => {
      result.proofSummary.loops.desktop.textRequiredPhrases = 1
    },
  },
  {
    name: 'proof-summary-raw-evidence-path-mismatch',
    expectedError:
      'proofSummary.evidence.windowsChromeScreenshotDir must match browserEvidence.proofSummary.evidence.windowsChromeScreenshotDir.',
    mutate: (result) => {
      result.proofSummary.evidence.windowsChromeScreenshotDir =
        'assets/tmp/computer-loop-result-validator-selftest/other-windows-chrome-screens'
    },
  },
  {
    name: 'proof-summary-dev-env-path-mismatch',
    expectedError:
      'proofSummary.evidence.devEnvEvidencePath must match browserEvidence.proofSummary.evidence.devEnvEvidencePath.',
    mutate: (result) => {
      result.proofSummary.evidence.devEnvEvidencePath =
        'assets/tmp/computer-loop-result-validator-selftest/other-dev-env.json'
    },
  },
  {
    name: 'proof-summary-phone-evidence-path-mismatch',
    expectedError: 'proofSummary.evidence.phoneEvidencePath must match plan.expectedEvidence.phoneEvidence.',
    mutate: (result) => {
      result.proofSummary.evidence.phoneEvidencePath = 'assets/demo/phone-loop.json'
    },
  },
  {
    name: 'proof-summary-phone-evidence-browser-path-mismatch',
    expectedError: 'proofSummary.evidence.phoneEvidencePath must match browserEvidence.proofSummary.evidence.phoneEvidencePath.',
    mutate: (result) => {
      result.browserEvidence.proofSummary.evidence.phoneEvidencePath = 'assets/demo/phone-loop.json'
      result.proofSummary.evidence.phoneEvidencePath = result.plan.expectedEvidence.phoneEvidence
    },
  },
  {
    name: 'summary-outside-output-dir',
    expectedError: 'plan.outputs.summaryPath must be inside plan.outputs.outputDir.',
    mutate: (result) => {
      result.plan.outputs.summaryPath = 'assets/demo/full-loop-report.json'
      result.checks[0].summaryPath = result.plan.outputs.summaryPath
      result.browserEvidence.plan.summaryPath = result.plan.outputs.summaryPath
    },
  },
  {
    name: 'referenced-summary-ascii-safe-json-required',
    expectedError: 'plan.outputs.summaryPath JSON cannot be read: plan.outputs.summaryPath must be ASCII-safe JSON',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name)
      const summary = await createSummary(result.browserEvidence.plan.paths)
      await writeNonAsciiJson(resolveRepoPath(result.plan.outputs.summaryPath), summary)
    },
  },
  {
    name: 'desktop-evidence-outside-output-dir',
    expectedError: 'browserEvidence.plan.paths.desktopEvidence must be inside plan.outputs.outputDir.',
    mutate: (result) => {
      result.browserEvidence.plan.paths.desktopEvidence = 'assets/demo/desktop-loop.json'
    },
  },
  {
    name: 'chrome-screenshots-outside-output-dir',
    expectedError: 'browserEvidence.plan.paths.windowsChromeScreenshotDir must be inside plan.outputs.outputDir.',
    mutate: (result) => {
      result.browserEvidence.plan.paths.windowsChromeScreenshotDir = 'assets/demo/windows-chrome-screens'
    },
  },
  {
    name: 'embedded-browser-evidence-mismatch',
    expectedError: 'browserEvidence must exactly match plan.outputs.browserEvidenceResultJsonPath content.',
    mutate: (result) => {
      result.browserEvidence.plan.requiredEvidence.windowsChrome = false
    },
    skipBrowserEvidenceRewrite: true,
  },
  {
    name: 'browser-evidence-generated-after-result',
    expectedError: 'generatedAt must not be earlier than browserEvidence.generatedAt.',
    mutate: (result) => {
      result.browserEvidence.generatedAt = '2026-06-19T00:00:03.000Z'
    },
  },
  {
    name: 'summary-phone-run-mismatch',
    expectedError: 'summary.loops.phone.run must be false for computer-only result.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.phone.run = true
        summary.loops.phone.success = true
      })
    },
  },
  {
    name: 'summary-web-readiness-missing',
    expectedError: 'summary.environment.webReadiness is missing.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        delete summary.environment.webReadiness
      })
    },
  },
  {
    name: 'summary-web-readiness-gate-mismatch',
    expectedError: 'summary.environment.webReadiness.gates.httpProbeBeforePortReuse must be true.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.environment.webReadiness.gates.httpProbeBeforePortReuse = false
      })
    },
  },
  {
    name: 'summary-root-unexpected-field',
    expectedError: 'summary root must not include unexpected field: proofSummary.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.proofSummary = {}
      })
    },
  },
  {
    name: 'summary-loop-unexpected-field',
    expectedError: 'summary.loops.desktop must not include unexpected field: trace.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.desktop.trace = {}
      })
    },
  },
  {
    name: 'summary-evidence-file-unexpected-field',
    expectedError: 'summary.evidence.files Desktop JSON must not include unexpected field: absolutePath.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.evidence.files.find((entry) => entry.label === 'Desktop JSON').absolutePath =
          result.browserEvidence.plan.paths.desktopEvidence
      })
    },
  },
  {
    name: 'summary-web-readiness-raw-unexpected-field',
    expectedError: 'summary.environment.webReadiness raw evidence must not include unexpected field: artifacts.',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await attachWebReadiness(summary, { artifacts: [] })
      })
    },
  },
  {
    name: 'summary-dev-env-raw-unexpected-field',
    expectedError: 'summary.environment.preflight raw evidence must not include unexpected field: artifacts.',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await attachDevEnv(summary, { artifacts: [] })
      })
    },
  },
  {
    name: 'summary-generated-after-result',
    expectedError: 'generatedAt must not be earlier than summary.generatedAt.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.generatedAt = '2026-06-19T00:00:03.000Z'
      })
    },
  },
  {
    name: 'summary-generated-after-browser-evidence',
    expectedError: 'browserEvidence.generatedAt must not be earlier than summary.generatedAt.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.generatedAt = '2026-06-19T00:00:01.500Z'
      })
    },
  },
  {
    name: 'summary-localized-run-button-mismatch',
    expectedError: 'summary.loops.desktop.localizedUi.runButton must be 生成计划.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.desktop.localizedUi.runButton = 'Run plan'
      })
    },
  },
  {
    name: 'summary-browser-parity-recomputed-mismatch',
    expectedError: 'summary.browserParity.success must match recomputed browser parity.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.windowsChrome.localizedUi.resetButtonCount = 2
      })
    },
  },
  {
    name: 'summary-browser-parity-input-missing',
    expectedError: 'summary.loops.windowsChrome.responsiveLayout is required for browser parity.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.windowsChrome.responsiveLayout = []
      })
    },
  },
  {
    name: 'summary-text-integrity-weak-coverage',
    expectedError: 'summary.loops.desktop.textIntegrity.requiredPhraseCount must be at least 7',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.desktop.textIntegrity.requiredPhraseCount = 1
        summary.loops.desktop.localizedUi.textIntegrity.requiredPhraseCount = 1
      })
    },
  },
  {
    name: 'summary-browser-parity-screenshot-mismatch',
    expectedError: 'summary.browserParity.success must match recomputed browser parity.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.windowsChrome.screenshotEvidence.uniqueDigestCount = 5
      })
    },
  },
  {
    name: 'summary-desktop-manifest-mismatch',
    expectedError: 'summary.evidence Desktop JSON must match browserEvidence.plan.paths.desktopEvidence.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.evidence.files.find((entry) => entry.label === 'Desktop JSON').file = 'assets/demo/desktop-loop.json'
      })
    },
  },
  {
    name: 'screenshot-digest-mismatch',
    expectedError: 'summary.evidence screenshot',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        const screenshot = summary.evidence.files.find(
          (entry) =>
            entry.label === 'Screenshot' &&
            entry.file.startsWith(result.browserEvidence.plan.paths.desktopScreenshotDir),
        )
        screenshot.sha256 = '000000000000'
      })
    },
  },
  {
    name: 'report-run-id-mismatch',
    expectedError: 'report must include "- Run ID: full-loop-selftest".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), {
          ...summary,
          runId: 'different-full-loop',
        })
      })
    },
  },
  {
    name: 'report-dev-env-preflight-mismatch',
    expectedError: 'report must include "- Dev environment preflight: pass (1 ok, 0 warn, 0 fail, phone optional)".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), {
          ...summary,
          environment: {
            ...summary.environment,
            preflight: summaryDevEnv({ okCount: 2 }),
          },
        })
      })
    },
  },
  {
    name: 'report-browser-parity-mismatch',
    expectedError: 'report must include "- Browser parity: pass".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), {
          ...summary,
          browserParity: {
            ...summary.browserParity,
            success: false,
            errors: ['desktop and chrome mismatch'],
          },
        })
      })
    },
  },
  {
    name: 'report-app-url-mismatch',
    expectedError: 'report must include "- App URL: http://127.0.0.1:5173".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), {
          ...summary,
          appUrl: 'http://127.0.0.1:9999',
        })
      })
    },
  },
  {
    name: 'report-api-base-mismatch',
    expectedError: 'report must include "- API base: http://127.0.0.1:8723".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), {
          ...summary,
          apiBase: 'http://127.0.0.1:9998',
        })
      })
    },
  },
  {
    name: 'report-evidence-desktop-json-mismatch',
    expectedError:
      'report must include "- Desktop JSON: assets/tmp/computer-loop-result-validator-selftest/desktop-loop.json',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        const reportSummary = structuredClone(summary)
        reportSummary.evidence.files.find((entry) => entry.label === 'Desktop JSON').file =
          'assets/demo/desktop-loop.json'
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), reportSummary)
      })
    },
  },
  {
    name: 'report-evidence-phone-not-run-mismatch',
    expectedError: 'report must include "- Phone JSON: not run".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        const reportSummary = structuredClone(summary)
        Object.assign(reportSummary.evidence.files.find((entry) => entry.label === 'Phone JSON'), {
          present: true,
          file: 'assets/demo/phone-loop.json',
          bytes: 1,
          sha256: '000000000000',
        })
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), reportSummary)
      })
    },
  },
  {
    name: 'report-desktop-title-mismatch',
    expectedError: 'report Desktop Browser section must include "- Title: \u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        const reportSummary = structuredClone(summary)
        reportSummary.loops.desktop.title = 'Wrong desktop title'
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), reportSummary)
      })
    },
  },
  {
    name: 'report-chrome-external-sync-mismatch',
    expectedError: 'report Windows Chrome section must include "- External sync source: esp32-serial".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        const reportSummary = structuredClone(summary)
        reportSummary.loops.windowsChrome.externalExecutionSync.latestSource = 'web'
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), reportSummary)
      })
    },
  },
  {
    name: 'report-external-sync-boundary-missing',
    expectedError:
      'report Demo Talking Points section must include "- The desktop external sync proof uses an API-simulated room-terminal event; real ESP32 serial proof is captured only by the device loop gate.".',
    prepare: async (result, name) => {
      await attachSummary(result, name, async (summary) => {
        await writeReport(resolveRepoPath(result.plan.outputs.reportPath), summary, { omitExternalSyncBoundary: true })
      })
    },
  },
  {
    name: 'raw-desktop-run-id-mismatch',
    expectedError: 'desktop raw evidence.runId must match summary.runId.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { runId: 'different-full-loop' },
      })
    },
  },
  {
    name: 'referenced-raw-desktop-ascii-safe-json-required',
    expectedError:
      'browserEvidence.plan.paths.desktopEvidence JSON cannot be read: browserEvidence.plan.paths.desktopEvidence must be ASCII-safe JSON',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name)
      const raw = JSON.parse(await readFile(resolveRepoPath(result.browserEvidence.plan.paths.desktopEvidence), 'utf8'))
      await writeNonAsciiJson(resolveRepoPath(result.browserEvidence.plan.paths.desktopEvidence), raw)
    },
  },
  {
    name: 'referenced-raw-chrome-ascii-safe-json-required',
    expectedError:
      'browserEvidence.plan.paths.windowsChromeEvidence JSON cannot be read: browserEvidence.plan.paths.windowsChromeEvidence must be ASCII-safe JSON',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name)
      const raw = JSON.parse(
        await readFile(resolveRepoPath(result.browserEvidence.plan.paths.windowsChromeEvidence), 'utf8'),
      )
      await writeNonAsciiJson(resolveRepoPath(result.browserEvidence.plan.paths.windowsChromeEvidence), raw)
    },
  },
  {
    name: 'raw-desktop-app-url-mismatch',
    expectedError: 'desktop raw evidence.appUrl must match summary.appUrl.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { appUrl: 'http://127.0.0.1:9999' },
      })
    },
  },
  {
    name: 'raw-desktop-finished-at-summary-mismatch',
    expectedError: 'desktop raw evidence.finishedAt must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { finishedAt: '2026-06-18T23:59:57.000Z' },
      })
    },
  },
  {
    name: 'raw-desktop-text-integrity-mismatch',
    expectedError: 'desktop raw evidence.textIntegrity.missingPhraseCount must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: rawChecks({ textIntegrity: { missingPhraseCount: 1 } }) },
      })
    },
  },
  {
    name: 'raw-desktop-text-integrity-weak-coverage',
    expectedError: 'desktop raw evidence.textIntegrity.requiredPhraseCount must be at least 7',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: rawChecks({ textIntegrity: { requiredPhraseCount: 1 } }) },
      })
    },
  },
  {
    name: 'raw-desktop-localized-reset-count-mismatch',
    expectedError: 'desktop raw evidence.localizedUi.resetButtonCount must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: rawChecks({ localizedUi: { resetButtonCount: 2 } }) },
      })
    },
  },
  {
    name: 'raw-desktop-runtime-health-mismatch',
    expectedError: 'desktop raw evidence.runtimeHealth.counts must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: rawChecks({ runtimeHealth: { counts: { failedRequests: 1 } } }) },
      })
    },
  },
  {
    name: 'raw-desktop-screenshot-expected-files-mismatch',
    expectedError: 'desktop raw evidence.screenshotEvidence.expectedFiles must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: {
          checks: await rawChecksForDirectory(result.browserEvidence.plan.paths.desktopScreenshotDir, {
            expectedFiles: [...screenshotFiles().slice(1), screenshotFiles()[0]],
          }),
        },
      })
    },
  },
  {
    name: 'raw-desktop-screenshot-manifest-mismatch',
    expectedError: 'desktop raw evidence.screenshotEvidence.files',
    prepare: async (result, name) => {
      const checks = await rawChecksForDirectory(result.browserEvidence.plan.paths.desktopScreenshotDir)
      checks.screenshotEvidence.files[0].bytes += 1
      await attachRunLocalEvidence(result, name, {
        desktop: { checks },
      })
    },
  },
  {
    name: 'raw-desktop-screenshot-path-list-mismatch',
    expectedError: 'desktop raw evidence.screenshotEvidence.files paths must match raw screenshots.',
    prepare: async (result, name) => {
      const checks = await rawChecksForDirectory(result.browserEvidence.plan.paths.desktopScreenshotDir)
      checks.screenshotEvidence.files[0].path = `${result.browserEvidence.plan.paths.desktopScreenshotDir}/unexpected.png`
      await attachRunLocalEvidence(result, name, {
        desktop: { checks },
      })
    },
  },
  {
    name: 'raw-desktop-finished-after-result',
    expectedError: 'generatedAt must not be earlier than desktop raw evidence.finishedAt.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { finishedAt: '2026-06-19T00:00:03.000Z' },
      })
    },
  },
  {
    name: 'raw-chrome-browser-name-mismatch',
    expectedError: 'Windows Chrome raw evidence.browserName must be windows-chrome.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        chrome: { browserName: 'playwright-chromium' },
      })
    },
  },
]

for (const testCase of cases) {
  const result = createResult()
  const file = path.join(outputDir, `${testCase.name}.json`)
  setResultJsonPath(result, file)
  await writeJson(resolveRepoPath(result.plan.outputs.browserEvidenceResultJsonPath), result.browserEvidence)
  await writeRawLoopEvidence(result.browserEvidence.plan.paths)
  testCase.mutate?.(result)
  await testCase.prepare?.(result, testCase.name)
  if (!testCase.skipBrowserEvidenceRewrite && result.browserEvidence) {
    await writeJson(resolveRepoPath(result.plan.outputs.browserEvidenceResultJsonPath), result.browserEvidence)
  }

  await writeJson(file, result)

  const validation = await runValidator(file)
  if (validation.code === 0) {
    throw new Error(`Expected ${testCase.name} to fail validation.`)
  }
  if (!validation.output.includes(testCase.expectedError)) {
    console.error(validation.output)
    throw new Error(`Expected ${testCase.name} failure to include: ${testCase.expectedError}`)
  }

  console.log(`PASS negative case: ${testCase.name}`)
}

console.log('Computer loop result validator self-test passed.')

function assertOutputIncludes(output, expected, label) {
  if (!output.includes(expected)) {
    console.error(output)
    throw new Error(`Expected ${label} to include: ${expected}`)
  }
}

function assertOutputExcludes(output, unexpected, label) {
  if (output.includes(unexpected)) {
    console.error(output)
    throw new Error(`Expected ${label} to exclude: ${unexpected}`)
  }
}

async function attachSummary(result, name, mutate) {
  const summaryPath = `assets/tmp/computer-loop-result-validator-selftest/${name}-summary.json`
  result.plan.outputs.summaryPath = summaryPath
  result.checks[0].summaryPath = summaryPath
  result.browserEvidence.plan.summaryPath = summaryPath
  result.proofSummary.evidence.summaryPath = summaryPath

  const summary = await createSummary(result.browserEvidence.plan.paths)
  await mutate(summary)
  await writeJson(resolveRepoPath(summaryPath), summary)
}

async function attachWebReadiness(summary, overrides = {}) {
  const entry = summary.evidence.files.find((item) => item.label === 'Web Readiness JSON')
  Object.assign(entry, await writeWebReadinessEvidence(overrides))
}

async function attachDevEnv(summary, overrides = {}) {
  const entry = summary.evidence.files.find((item) => item.label === 'Dev Environment JSON')
  Object.assign(entry, await writeDevEnvEvidence(overrides))
}

async function attachRunLocalEvidence(result, name, { desktop = {}, chrome = {} } = {}) {
  const baseDir = `assets/tmp/computer-loop-result-validator-selftest/${name}`
  result.plan.outputs.outputDir = baseDir
  result.plan.outputs.reportPath = `${baseDir}/computer-loop-report.md`
  result.plan.outputs.summaryPath = `${baseDir}/computer-loop-report.json`
  result.plan.outputs.browserEvidenceResultJsonPath = `${baseDir}/browser-evidence-check.json`
  result.checks[0].reportPath = result.plan.outputs.reportPath
  result.checks[0].summaryPath = result.plan.outputs.summaryPath
  result.checks[1].resultJsonPath = result.plan.outputs.browserEvidenceResultJsonPath
  result.browserEvidence.plan.summaryPath = result.plan.outputs.summaryPath
  result.browserEvidence.plan.paths.desktopEvidence = `${baseDir}/desktop-loop.json`
  result.browserEvidence.plan.paths.desktopScreenshotDir = `${baseDir}/playwright-chromium-screens`
  result.browserEvidence.plan.paths.windowsChromeEvidence = `${baseDir}/chrome-loop.json`
  result.browserEvidence.plan.paths.windowsChromeScreenshotDir = `${baseDir}/windows-chrome-screens`
  result.browserEvidence.proofSummary.evidence.summaryPath = result.plan.outputs.summaryPath
  result.browserEvidence.proofSummary.evidence.desktopEvidencePath = result.browserEvidence.plan.paths.desktopEvidence
  result.browserEvidence.proofSummary.evidence.desktopScreenshotDir = result.browserEvidence.plan.paths.desktopScreenshotDir
  result.browserEvidence.proofSummary.evidence.windowsChromeEvidencePath = result.browserEvidence.plan.paths.windowsChromeEvidence
  result.browserEvidence.proofSummary.evidence.windowsChromeScreenshotDir = result.browserEvidence.plan.paths.windowsChromeScreenshotDir
  result.proofSummary.evidence.reportPath = result.plan.outputs.reportPath
  result.proofSummary.evidence.summaryPath = result.plan.outputs.summaryPath
  result.proofSummary.evidence.browserEvidenceResultJsonPath = result.plan.outputs.browserEvidenceResultJsonPath
  result.proofSummary.evidence.desktopEvidencePath = result.browserEvidence.proofSummary.evidence.desktopEvidencePath
  result.proofSummary.evidence.windowsChromeEvidencePath =
    result.browserEvidence.proofSummary.evidence.windowsChromeEvidencePath
  result.proofSummary.evidence.phoneEvidencePath = result.browserEvidence.proofSummary.evidence.phoneEvidencePath
  result.proofSummary.evidence.devEnvEvidencePath = result.browserEvidence.proofSummary.evidence.devEnvEvidencePath
  result.proofSummary.evidence.webReadinessEvidencePath =
    result.browserEvidence.proofSummary.evidence.webReadinessEvidencePath
  result.proofSummary.evidence.desktopScreenshotDir = result.browserEvidence.proofSummary.evidence.desktopScreenshotDir
  result.proofSummary.evidence.windowsChromeScreenshotDir =
    result.browserEvidence.proofSummary.evidence.windowsChromeScreenshotDir

  await writeScreenshotFiles(result.browserEvidence.plan.paths)
  await writeRawLoopEvidence(result.browserEvidence.plan.paths, { desktop, chrome })
  const summary = await createSummary(result.browserEvidence.plan.paths)
  await writeReport(resolveRepoPath(result.plan.outputs.reportPath), summary)
  await writeJson(resolveRepoPath(result.plan.outputs.summaryPath), summary)
}

function setResultJsonPath(result, file) {
  result.plan.outputs.resultJsonPath = toRepoPath(file)
}

async function createSummary(paths) {
  return {
    generatedAt: '2026-06-18T23:59:59.000Z',
    success: true,
    runId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    loops: {
      desktop: {
        run: true,
        success: true,
        runId: 'full-loop-selftest',
        startedAt: '2026-06-18T23:59:50.000Z',
        finishedAt: '2026-06-18T23:59:58.000Z',
        pageUrl: 'http://127.0.0.1:5173/?apiBase=http%3A%2F%2F127.0.0.1%3A8723',
        title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
        textIntegrity: summaryTextIntegrity(),
        localizedUi: summaryLocalizedUi(),
        firstViewportVisibility: summaryFirstViewportVisibility(),
        responsiveLayout: summaryResponsiveLayout(),
        runtimeHealth: summaryRuntimeHealth(),
        screenshotEvidence: summaryScreenshotEvidence(),
        scenePromptHandoff: summaryScenePromptHandoff(),
        webConfirmExecute: summaryWebConfirmExecute(),
        offlineFallback: summaryOfflineFallback(),
        externalExecutionSync: summaryExternalExecutionSync(),
      },
      phone: {
        run: false,
        success: null,
      },
      windowsChrome: {
        run: true,
        success: true,
        runId: 'full-loop-selftest',
        startedAt: '2026-06-18T23:59:50.000Z',
        finishedAt: '2026-06-18T23:59:58.000Z',
        pageUrl: 'http://127.0.0.1:5173/?apiBase=http%3A%2F%2F127.0.0.1%3A8723',
        title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
        textIntegrity: summaryTextIntegrity(),
        localizedUi: summaryLocalizedUi(),
        firstViewportVisibility: summaryFirstViewportVisibility(),
        responsiveLayout: summaryResponsiveLayout(),
        runtimeHealth: summaryRuntimeHealth(),
        screenshotEvidence: summaryScreenshotEvidence(),
        scenePromptHandoff: summaryScenePromptHandoff(),
        webConfirmExecute: summaryWebConfirmExecute(),
        offlineFallback: summaryOfflineFallback(),
        externalExecutionSync: summaryExternalExecutionSync(),
      },
    },
    browserParity: {
      checked: true,
      success: true,
      errors: [],
    },
    environment: {
      preflight: summaryDevEnv(),
      webReadiness: summaryWebReadiness(),
    },
    evidence: {
      files: [
        {
          label: 'Desktop JSON',
          file: paths.desktopEvidence,
          present: true,
          ...(await fileDigest(resolveRepoPath(paths.desktopEvidence))),
        },
        {
          label: 'Windows Chrome JSON',
          file: paths.windowsChromeEvidence,
          present: true,
          ...(await fileDigest(resolveRepoPath(paths.windowsChromeEvidence))),
        },
        { label: 'Phone JSON', file: null, present: false },
        {
          label: 'Dev Environment JSON',
          file: 'assets/tmp/computer-loop-result-validator-selftest/dev-env-check.json',
          present: true,
          ...(await writeDevEnvEvidence()),
        },
        {
          label: 'Web Readiness JSON',
          file: 'assets/tmp/computer-loop-result-validator-selftest/web-readiness.json',
          present: true,
          ...(await writeWebReadinessEvidence()),
        },
        ...(await screenshotEntries(paths.desktopScreenshotDir)),
        ...(await screenshotEntries(paths.windowsChromeScreenshotDir)),
      ],
    },
  }
}

function summaryDevEnv(overrides = {}) {
  return {
    run: true,
    success: true,
    generatedAt: '2026-06-18T23:59:48.000Z',
    required: true,
    requirePhone: false,
    okCount: 1,
    warnCount: 0,
    failCount: 0,
    checks: [
      {
        name: 'node',
        category: 'host',
        ok: true,
        required: true,
        status: 'OK',
        detail: 'v24.14.0',
      },
    ],
    ...overrides,
  }
}

async function writeDevEnvEvidence(overrides = {}) {
  const file = resolveRepoPath('assets/tmp/computer-loop-result-validator-selftest/dev-env-check.json')
  const raw = summaryDevEnv(overrides)
  delete raw.run
  delete raw.okCount
  delete raw.warnCount
  delete raw.failCount
  await writeJson(file, raw)
  return fileDigest(file)
}

function summaryWebReadiness(overrides = {}) {
  return {
    run: true,
    success: true,
    generatedAt: '2026-06-18T23:59:49.000Z',
    runId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    webPort: 5173,
    strategy: 'already-ready',
    portListeningBefore: true,
    httpReadyBefore: true,
    httpReadyAfter: true,
    duplicateStartAvoided: true,
    gates: {
      httpProbeBeforePortReuse: true,
      stalePortBlocksDuplicateStart: true,
    },
    ...overrides,
  }
}

async function writeWebReadinessEvidence(overrides = {}) {
  const file = resolveRepoPath('assets/tmp/computer-loop-result-validator-selftest/web-readiness.json')
  const raw = summaryWebReadiness(overrides)
  delete raw.run
  delete raw.success
  await writeJson(file, raw)
  return fileDigest(file)
}

async function writeRawLoopEvidence(paths, { desktop = {}, chrome = {} } = {}) {
  const desktopScreenshots = screenshotFiles().map((file) => `${paths.desktopScreenshotDir}/${file}`)
  const chromeScreenshots = screenshotFiles().map((file) => `${paths.windowsChromeScreenshotDir}/${file}`)
  await writeJson(resolveRepoPath(paths.desktopEvidence), {
    success: true,
    runId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    pageUrl: 'http://127.0.0.1:5173/?apiBase=http%3A%2F%2F127.0.0.1%3A8723',
    browserName: 'playwright-chromium',
    startedAt: '2026-06-18T23:59:50.000Z',
    finishedAt: '2026-06-18T23:59:58.000Z',
    screenshots: desktopScreenshots,
    checks: await rawChecksForDirectory(paths.desktopScreenshotDir),
    ...desktop,
  })
  await writeJson(resolveRepoPath(paths.windowsChromeEvidence), {
    success: true,
    runId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    pageUrl: 'http://127.0.0.1:5173/?apiBase=http%3A%2F%2F127.0.0.1%3A8723',
    browserName: 'windows-chrome',
    startedAt: '2026-06-18T23:59:50.000Z',
    finishedAt: '2026-06-18T23:59:58.000Z',
    screenshots: chromeScreenshots,
    checks: await rawChecksForDirectory(paths.windowsChromeScreenshotDir),
    ...chrome,
  })
}

function summaryTextIntegrity(overrides = {}) {
  return {
    requiredPhraseCount: 7,
    missingPhraseCount: 0,
    mojibakeCount: 0,
    ...overrides,
  }
}

function summaryLocalizedUi(overrides = {}) {
  const textIntegrity = overrides.textIntegrity ?? {}
  return {
    title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
    runButton: '\u751f\u6210\u8ba1\u5212',
    resetButtonCount: 1,
    ...overrides,
    textIntegrity: summaryTextIntegrity(textIntegrity),
  }
}

function summaryFirstViewportVisibility(overrides = {}) {
  return {
    minVisibleRatio: 1,
    panelCount: 5,
    hiddenPanelCount: 0,
    ...overrides,
  }
}

function summaryRuntimeHealth(overrides = {}) {
  return {
    success: true,
    issueCount: 0,
    counts: {},
    ...overrides,
  }
}

function summaryResponsiveLayout(overrides = []) {
  return [
    {
      label: 'mobile',
      overflowX: 0,
      overflowingButtonCount: 0,
      overlappingPanelPairCount: 0,
      panelCount: 7,
    },
    ...overrides,
  ]
}

function summaryScreenshotEvidence(overrides = {}) {
  return {
    success: true,
    count: 6,
    expectedFiles: screenshotFiles(),
    uniqueDigestCount: 6,
    minWidth: null,
    minHeight: null,
    minBytes: null,
    minImageDataBytes: null,
    ...overrides,
  }
}

function summaryScenePromptHandoff(overrides = {}) {
  return {
    ready: true,
    proposeOnly: true,
    promptPresent: true,
    scene: 'low-energy evening arrival',
    rawImageRetained: false,
    rawImageEchoed: false,
    ...overrides,
  }
}

function summaryWebConfirmExecute(overrides = {}) {
  return {
    latestSource: 'web',
    latestSequence: 10,
    acceptedRows: 5,
    ...overrides,
  }
}

function summaryOfflineFallback(overrides = {}) {
  return {
    latestSource: 'plan',
    latestSequence: 11,
    executionCount: 3,
    ...overrides,
  }
}

function summaryExternalExecutionSync(overrides = {}) {
  return {
    latestSource: 'esp32-serial',
    sourceMode: 'api-simulated-room-terminal',
    latestSequence: 12,
    acceptedActionCount: 5,
    ...overrides,
  }
}

async function rawChecksForDirectory(directory, screenshotEvidence = {}) {
  return {
    localizedUi: summaryLocalizedUi(),
    runtimeHealth: summaryRuntimeHealth(),
    screenshotEvidence: {
      ...summaryScreenshotEvidence(),
      files: await screenshotFileEntries(directory),
      ...screenshotEvidence,
    },
  }
}

function rawChecks({ localizedUi = {}, textIntegrity = {}, runtimeHealth = {}, screenshotEvidence = {} } = {}) {
  return {
    localizedUi: summaryLocalizedUi({ ...localizedUi, textIntegrity }),
    runtimeHealth: summaryRuntimeHealth(runtimeHealth),
    screenshotEvidence: {
      ...summaryScreenshotEvidence(),
      files: [],
      ...screenshotEvidence,
    },
  }
}

async function screenshotFileEntries(directory) {
  const entries = []
  for (const file of screenshotFiles()) {
    const entryPath = `${directory}/${file}`
    entries.push({
      path: entryPath,
      ...(await fileDigest(resolveRepoPath(entryPath))),
    })
  }
  return entries
}

async function screenshotEntries(directory) {
  const entries = []
  for (const file of screenshotFiles()) {
    const entryPath = `${directory}/${file}`
    entries.push({
      label: 'Screenshot',
      file: entryPath,
      present: true,
      ...(await fileDigest(resolveRepoPath(entryPath))),
    })
  }
  return entries
}

function screenshotFiles() {
  return [
    '01-control-console.png',
    '02-scene-prompt-handoff.png',
    '03-propose-only.png',
    '04-web-confirmation.png',
    '05-offline-fallback.png',
    '06-external-sync.png',
  ]
}

function createResult({
  mode = 'validate',
  browserEvidence = undefined,
  selfTest = false,
  maxAgeMinutes = null,
  browserEvidencePath = undefined,
} = {}) {
  const prefix = selfTest ? 'selftest-' : ''
  const summaryPath = `assets/tmp/computer-loop-result-validator-selftest/${prefix}computer-loop-report.json`
  const reportPath = `assets/tmp/computer-loop-result-validator-selftest/${prefix}computer-loop-report.md`
  const resolvedBrowserEvidencePath =
    browserEvidencePath ?? `assets/tmp/computer-loop-result-validator-selftest/${prefix}browser-evidence-check.json`
  const fullLoopArgs = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    'scripts/check-full-loop.ps1',
    '-SkipPhone',
    '-IncludeChrome',
    '-StartupTimeoutSeconds',
    '60',
    '-StepTimeoutSeconds',
    '180',
    '-BrowserWrapperSharedStateLockTimeoutSeconds',
    '1200',
    '-PartialEvidenceDir',
    'assets/tmp/computer-loop-result-validator-selftest',
    '-ReportPath',
    reportPath,
    '-SummaryPath',
    summaryPath,
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
    '-RequireChrome',
    '-ResultJsonPath',
    resolvedBrowserEvidencePath,
    ...(selfTest ? ['-SelfTest'] : []),
    ...(maxAgeMinutes === null ? [] : ['-MaxAgeMinutes', String(maxAgeMinutes)]),
  ]

  const plan = {
    runId: 'computer-loop-selftest',
    requestedLoops: {
      desktop: true,
      phone: false,
      windowsChrome: true,
    },
    options: {
      skipPreflight: false,
      selfTest,
      startupTimeoutSeconds: 60,
      stepTimeoutSeconds: 180,
      browserWrapperSharedStateLockTimeoutSeconds: 1200,
      maxAgeMinutes,
    },
    outputs: {
      outputDir: 'assets/tmp/computer-loop-result-validator-selftest',
      reportPath,
      summaryPath,
      resultJsonPath: 'assets/tmp/computer-loop-result-validator-selftest/computer-loop-check.json',
      browserEvidenceResultJsonPath: resolvedBrowserEvidencePath,
    },
    expectedEvidence: {
      phoneEvidence: '__phone_not_run__.json',
    },
    gates: {
      fullLoopIncludeChrome: true,
      fullLoopIncludePhone: false,
      fullLoopSkipPhone: true,
      browserEvidenceRequireDesktop: true,
      browserEvidenceRequireChrome: true,
      browserEvidenceRequirePhone: false,
      browserEvidenceSelfTest: selfTest,
      browserWrapperSharedStateLock: {
        name: 'Global\\HCEdgeBrowserLoopGate',
        timeoutSeconds: 1200,
      },
      fullLoopWebReadiness: {
        httpProbeBeforePortReuse: true,
        stalePortBlocksDuplicateStart: true,
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
    },
  }

  return {
    generatedAt: '2026-06-19T00:00:02.000Z',
    success: true,
    mode,
    runId: plan.runId,
    sourceState: currentSourceState(),
    plan,
    checks: [
      {
        name: 'computer full loop',
        command: plan.commands.fullLoop.display,
        required: true,
        summaryPath,
        reportPath,
      },
      {
        name: 'saved browser evidence recheck',
        command: plan.commands.browserEvidence.display,
        required: true,
        resultJsonPath: resolvedBrowserEvidencePath,
      },
    ],
    proofSummary: mode === 'dry-run' ? null : proofSummary(plan),
    browserEvidence:
      browserEvidence === undefined
        ? {
            generatedAt: '2026-06-19T00:00:01.000Z',
            success: true,
            mode: 'validate',
            sourceState: currentSourceState(),
            plan: {
              summaryPath,
              resultJsonPath: resolvedBrowserEvidencePath,
              inferredFromSummary: {
                desktop: true,
                phone: false,
                windowsChrome: true,
              },
              requiredEvidence: {
                desktop: true,
                phone: false,
                windowsChrome: true,
              },
              options: {
                maxAgeMinutes,
              },
              selfTest: {
                requested: selfTest,
                phoneEvidence: false,
                desktopEvidence: selfTest,
                summary: selfTest,
                report: false,
              },
              paths: {
                desktopEvidence: 'assets/tmp/computer-loop-result-validator-selftest/desktop-loop.json',
                desktopScreenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/playwright-chromium-screens',
                phoneEvidence: '__phone_not_run__.json',
                windowsChromeEvidence: 'assets/tmp/computer-loop-result-validator-selftest/chrome-loop.json',
                windowsChromeScreenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/windows-chrome-screens',
              },
            },
            checks: [
              {
                name: 'desktop raw evidence',
                command: 'npm run desktop:evidence:check',
                required: true,
                path: 'assets/tmp/computer-loop-result-validator-selftest/desktop-loop.json',
                screenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/playwright-chromium-screens',
              },
              {
                name: 'Windows Chrome raw evidence',
                command: 'npm run desktop:evidence:check -- --require-installed-chrome',
                required: true,
                path: 'assets/tmp/computer-loop-result-validator-selftest/chrome-loop.json',
                screenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/windows-chrome-screens',
              },
              {
                name: 'full-loop summary evidence',
                command: 'npm run summary:check',
                required: true,
                path: summaryPath,
              },
              ...(selfTest
                ? [
                    {
                      name: 'desktop evidence validator self-test',
                      command: 'npm run desktop:evidence:selftest',
                      required: true,
                    },
                    {
                      name: 'summary validator self-test',
                      command: `npm run summary:selftest -- ${summaryPath}`,
                      required: true,
                    },
                  ]
                : []),
            ],
            proofSummary: browserEvidenceProofSummary({
              summaryPath,
              paths: {
                desktopEvidence: 'assets/tmp/computer-loop-result-validator-selftest/desktop-loop.json',
                desktopScreenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/playwright-chromium-screens',
                phoneEvidence: '__phone_not_run__.json',
                windowsChromeEvidence: 'assets/tmp/computer-loop-result-validator-selftest/chrome-loop.json',
                windowsChromeScreenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/windows-chrome-screens',
              },
            }),
          }
        : browserEvidence,
  }
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

function browserEvidenceProofSummary(browserEvidencePlan) {
  return {
    summaryRunId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    requiredEvidence: {
      desktop: true,
      phone: false,
      windowsChrome: true,
    },
    browserParity: {
      checked: true,
      success: true,
      errorCount: 0,
    },
    webReadiness: {
      run: true,
      success: true,
      strategy: 'already-ready',
      httpReadyAfter: true,
      duplicateStartAvoided: true,
    },
    loops: {
      desktop: loopProofSummary(),
      windowsChrome: loopProofSummary(),
      phone: {
        run: false,
        success: null,
      },
    },
    evidence: {
      summaryPath: browserEvidencePlan.summaryPath,
      desktopEvidencePath: browserEvidencePlan.paths.desktopEvidence,
      windowsChromeEvidencePath: browserEvidencePlan.paths.windowsChromeEvidence,
      phoneEvidencePath: browserEvidencePlan.paths.phoneEvidence,
      devEnvEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/dev-env-check.json',
      webReadinessEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/web-readiness.json',
      desktopScreenshotDir: browserEvidencePlan.paths.desktopScreenshotDir,
      windowsChromeScreenshotDir: browserEvidencePlan.paths.windowsChromeScreenshotDir,
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
    webReadiness: {
      run: true,
      success: true,
      strategy: 'already-ready',
      httpReadyAfter: true,
      duplicateStartAvoided: true,
    },
    loops: {
      desktop: loopProofSummary(),
      windowsChrome: loopProofSummary(),
      phone: {
        run: false,
        success: null,
      },
    },
    evidence: {
      reportPath: plan.outputs.reportPath,
      summaryPath: plan.outputs.summaryPath,
      browserEvidenceResultJsonPath: plan.outputs.browserEvidenceResultJsonPath,
      browserEvidenceSuccess: true,
      desktopEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/desktop-loop.json',
      windowsChromeEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/chrome-loop.json',
      phoneEvidencePath: '__phone_not_run__.json',
      devEnvEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/dev-env-check.json',
      webReadinessEvidencePath: 'assets/tmp/computer-loop-result-validator-selftest/web-readiness.json',
      desktopScreenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/playwright-chromium-screens',
      windowsChromeScreenshotDir: 'assets/tmp/computer-loop-result-validator-selftest/windows-chrome-screens',
    },
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

function applySelfTestMode(result) {
  result.plan.options.selfTest = true
  result.plan.gates.browserEvidenceSelfTest = true
  if (!result.plan.commands.browserEvidence.args.includes('-SelfTest')) {
    result.plan.commands.browserEvidence.args.push('-SelfTest')
  }
  result.browserEvidence.plan.selfTest.requested = true
  result.browserEvidence.plan.selfTest.desktopEvidence = true
  result.browserEvidence.plan.selfTest.summary = true
  result.browserEvidence.checks.push(
    {
      name: 'desktop evidence validator self-test',
      command: 'npm run desktop:evidence:selftest',
      required: true,
    },
    {
      name: 'summary validator self-test',
      command: `npm run summary:selftest -- ${result.browserEvidence.plan.summaryPath}`,
      required: true,
    },
  )
}

function findBrowserEvidenceCheck(result, command, { prefix = false } = {}) {
  return result.browserEvidence.checks.find((check) =>
    prefix ? check.command.startsWith(command) : check.command === command,
  )
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

async function writeNonAsciiJson(file, value) {
  await mkdir(path.dirname(file), { recursive: true })
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

async function assertAsciiSafeJsonIsRequired() {
  const file = path.join(outputDir, 'computer-result-ascii-safe-json-required.json')
  await writeFile(file, `${JSON.stringify(positive, null, 2)}\n`, 'utf8')

  const result = await runValidator(file)
  if (result.code === 0) {
    throw new Error('Expected computer-result-ascii-safe-json-required to fail validation.')
  }
  if (!result.output.includes('computer loop result must be ASCII-safe JSON')) {
    console.error(result.output)
    throw new Error('Expected computer-result-ascii-safe-json-required failure to include ASCII-safe JSON error.')
  }

  console.log('PASS negative case: computer-result-ascii-safe-json-required')
}

async function writeReport(file, summary, { omitExternalSyncBoundary = false } = {}) {
  await writeText(
    file,
    [
      '# Home AI Companion Loop Report',
      '',
      `Generated: ${summary.generatedAt}`,
      '',
      '## Summary',
      '',
      '- Desktop loop: pass',
      '- Windows Chrome loop: pass',
      '- Phone loop: not run',
      `- Run ID: ${summary.runId}`,
      `- Dev environment preflight: ${formatDevEnvPreflight(summary.environment?.preflight)}`,
      `- Web readiness: ${formatWebReadiness(summary.environment?.webReadiness)}`,
      `- Browser parity: ${formatBrowserParity(summary.browserParity)}`,
      `- App URL: ${summary.appUrl}`,
      `- API base: ${summary.apiBase}`,
      '',
      '## Desktop Browser',
      '',
      ...formatLoop(summary.loops?.desktop),
      '',
      '## Windows Chrome',
      '',
      ...formatLoop(summary.loops?.windowsChrome),
      '',
      '## Android Chrome Phone',
      '',
      '- Not run.',
      '',
      '## Evidence Files',
      '',
      ...formatManifest(summary.evidence?.files),
      '',
      '## Demo Talking Points',
      '',
      ...formatDemoTalkingPoints(summary, { omitExternalSyncBoundary }),
      '',
    ].join('\n'),
  )
}

function formatDemoTalkingPoints(summary, { omitExternalSyncBoundary = false } = {}) {
  const points = [
    '- The loop verifies the HomeCue assistant path across desktop web, Windows Chrome, the edge API, and simulated room-terminal execution.',
    '- Phone proof was not run in this report; run the full loop with phone enabled for Android camera and speech coverage.',
    '- The desktop proof covers propose-only planning, web confirmation, offline fallback, and ESP32-style external confirmation sync.',
    '- Browser parity is pass between the desktop browser targets.',
  ]
  if (!omitExternalSyncBoundary) {
    points.splice(
      3,
      0,
      '- The desktop external sync proof uses an API-simulated room-terminal event; real ESP32 serial proof is captured only by the device loop gate.',
    )
  }
  if (summary?.environment?.preflight?.run === true) {
    points.push('- The environment preflight records host, browser, port, ADB, and authorized-phone readiness before browser automation starts.')
  }
  if (summary?.environment?.webReadiness?.run === true) {
    points.push('- The web readiness proof records whether the loop reused a ready Vite server or waited on a stale web port before browser automation.')
  }
  return points
}

function formatLoop(loop) {
  return [
    `- Title: ${loop?.title ?? 'unknown'}`,
    `- Chinese text integrity: ${formatTextIntegrity(loop?.textIntegrity)}`,
    `- Runtime health: ${formatRuntimeHealth(loop?.runtimeHealth)}`,
    `- Screenshot evidence: ${formatScreenshotEvidence(loop?.screenshotEvidence)}`,
    `- External sync source: ${loop?.externalExecutionSync?.latestSource ?? 'unknown'}`,
    `- External sync mode: ${loop?.externalExecutionSync?.sourceMode ?? 'unknown'}`,
    `- External accepted actions: ${loop?.externalExecutionSync?.acceptedActionCount ?? 'unknown'}`,
  ]
}

function formatTextIntegrity(value) {
  if (!value) return 'not checked'
  return `${value.requiredPhraseCount ?? 0} phrases, missing:${value.missingPhraseCount ?? '?'} mojibake:${
    value.mojibakeCount ?? '?'
  }`
}

function formatRuntimeHealth(value) {
  if (!value) return 'not checked'
  const counts = value.counts ?? {}
  const issueCount =
    value.issueCount ?? Object.values(counts).reduce((total, count) => total + (typeof count === 'number' ? count : 0), 0)
  const summary = [
    `console:${counts.consoleErrors ?? 0}`,
    `page:${counts.pageErrors ?? 0}`,
    `request:${counts.requestFailures ?? 0}`,
    `http:${counts.httpErrors ?? 0}`,
  ].join(', ')
  return value.success === false || issueCount > 0 ? `fail (${summary})` : `clean (${summary})`
}

function formatScreenshotEvidence(value) {
  if (!value) return 'not checked'
  if (value.success === false) return `fail (${value.error ?? 'unknown error'})`
  return `${value.count ?? 0} PNGs, unique:${value.uniqueDigestCount ?? '?'}, min ${value.minWidth ?? '?'}x${
    value.minHeight ?? '?'
  }, ${value.minBytes ?? '?'} bytes`
}

function formatDevEnvPreflight(value) {
  if (!value?.run) return 'not run'
  const status = value.success === true ? 'pass' : 'fail'
  const phone = value.requirePhone ? 'phone required' : 'phone optional'
  return `${status} (${value.okCount ?? 'unknown'} ok, ${value.warnCount ?? 'unknown'} warn, ${
    value.failCount ?? 'unknown'
  } fail, ${phone})`
}

function formatWebReadiness(value) {
  if (!value?.run) return 'not run'
  const status = value.success === true ? 'pass' : 'fail'
  return `${status} (${value.strategy ?? 'unknown'}, port before:${formatBoolean(
    value.portListeningBefore,
  )}, http before:${formatBoolean(value.httpReadyBefore)})`
}

function formatBrowserParity(value) {
  if (!value?.checked) return 'not checked'
  if (value.success) return 'pass'
  return `fail (${Array.isArray(value.errors) ? value.errors.join('; ') : 'unknown'})`
}

function formatManifest(entries) {
  if (!Array.isArray(entries)) return []
  return entries.map((entry) => {
    if (!entry.present) return `- ${entry.label}: not run`
    return `- ${entry.label}: ${entry.file} (${entry.bytes} bytes, sha256:${entry.sha256})`
  })
}

function formatBoolean(value) {
  if (value === true) return 'yes'
  if (value === false) return 'no'
  return 'unknown'
}

async function writeScreenshotFiles(paths) {
  for (const directory of [paths.desktopScreenshotDir, paths.windowsChromeScreenshotDir]) {
    await mkdir(resolveRepoPath(directory), { recursive: true })
    for (const file of screenshotFiles()) {
      await writeText(resolveRepoPath(`${directory}/${file}`), `fake screenshot ${directory}/${file}\n`)
    }
  }
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

async function fileDigest(file) {
  const buffer = await readFile(file)
  return {
    bytes: buffer.length,
    sha256: createHash('sha256').update(buffer).digest('hex').slice(0, 12),
  }
}
