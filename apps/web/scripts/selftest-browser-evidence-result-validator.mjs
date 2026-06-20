import { execFileSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const validatorScript = path.join(scriptDir, 'validate-browser-evidence-result.mjs')
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'browser-evidence-result-validator-selftest')
const sourceSummary = formatSourceState(currentSourceState())

await mkdir(outputDir, { recursive: true })
await mkdir(path.join(outputDir, 'playwright-chromium-screens'), { recursive: true })
await mkdir(path.join(outputDir, 'windows-chrome-screens'), { recursive: true })
for (const directory of ['playwright-chromium-screens', 'windows-chrome-screens']) {
  for (const file of screenshotFiles()) {
    await writeText(path.join(outputDir, directory, file), 'fake screenshot\n')
  }
}
const positive = createResult()
await writeRawLoopEvidence(positive.plan.paths)
await writeJson(path.join(outputDir, 'phone-loop.json'), { success: true })

await writeJson(resolveRepoPath(positive.plan.summaryPath), await createSummary(positive.plan))

const positiveFile = path.join(outputDir, 'positive.json')
setResultJsonPath(positive, positiveFile)
await writeJson(positiveFile, positive)
const positiveResult = await runValidator(positiveFile)
if (positiveResult.code !== 0) {
  console.error(positiveResult.output)
  throw new Error('Expected positive browser evidence result to pass validation.')
}
if (
  !positiveResult.output.includes(
    `Browser evidence proof summary: runId=full-loop-selftest desktop=pass chrome=pass phone=not-run parity=pass web=already-ready source=${sourceSummary} screenshots=6+6 text=7/0/0+7/0/0 selftests=not-requested external=esp32-serial devEnvEvidence=assets/tmp/browser-evidence-result-validator-selftest/dev-env-check.json webReadinessEvidence=assets/tmp/browser-evidence-result-validator-selftest/web-readiness.json summary=assets/tmp/browser-evidence-result-validator-selftest/full-loop-report.json`,
  )
) {
  console.error(positiveResult.output)
  throw new Error('Expected positive browser evidence result to print compact proof summary.')
}
console.log('PASS positive browser evidence result')

const fresh = structuredClone(positive)
fresh.generatedAt = new Date().toISOString()
const freshFile = path.join(outputDir, 'fresh.json')
setResultJsonPath(fresh, freshFile)
await writeJson(freshFile, fresh)
const freshResult = await runValidator(freshFile, ['--max-age-minutes', '60'])
if (freshResult.code !== 0) {
  console.error(freshResult.output)
  throw new Error('Expected fresh browser evidence result to pass freshness validation.')
}
console.log('PASS fresh browser evidence result')

const staleResult = await runValidator(positiveFile, ['--max-age-minutes', '1'])
if (staleResult.code === 0 || !staleResult.output.includes('generatedAt is older than --max-age-minutes=1.')) {
  console.error(staleResult.output)
  throw new Error('Expected stale browser evidence result to fail freshness validation.')
}
console.log('PASS stale browser evidence result')

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
  throw new Error('Expected future browser evidence result to fail freshness validation.')
}
console.log('PASS future browser evidence result')

const invalidFreshnessResult = await runValidator(positiveFile, ['--max-age-minutes', '0'])
if (invalidFreshnessResult.code === 0 || !invalidFreshnessResult.output.includes('--max-age-minutes must be a positive number.')) {
  console.error(invalidFreshnessResult.output)
  throw new Error('Expected invalid browser evidence freshness option to fail.')
}
console.log('PASS invalid browser evidence freshness option')

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
  throw new Error('Expected duplicate browser evidence freshness option to fail.')
}
console.log('PASS duplicate browser evidence freshness option')

const dryRun = createResult({ mode: 'dry-run' })
const dryRunFile = path.join(outputDir, 'dry-run.json')
setResultJsonPath(dryRun, dryRunFile)
await writeJson(dryRunFile, dryRun)
const dryRunResult = await runValidator(dryRunFile)
if (dryRunResult.code !== 0) {
  console.error(dryRunResult.output)
  throw new Error('Expected dry-run browser evidence result to pass validation.')
}
if (dryRunResult.output.includes('Browser evidence proof summary:')) {
  console.error(dryRunResult.output)
  throw new Error('Expected dry-run browser evidence result to skip compact proof summary.')
}
console.log('PASS dry-run browser evidence result')

const cases = [
  {
    name: 'result-root-unexpected-field',
    expectedError: 'result root must not include unexpected field: failure.',
    mutate: (result) => {
      result.failure = null
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
    name: 'plan-unexpected-field',
    expectedError: 'plan must not include unexpected field: artifacts.',
    mutate: (result) => {
      result.plan.artifacts = []
    },
  },
  {
    name: 'plan-paths-unexpected-field',
    expectedError: 'plan.paths must not include unexpected field: reportPath.',
    mutate: (result) => {
      result.plan.paths.reportPath = result.plan.summaryPath
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
    name: 'plan-selftest-unexpected-field',
    expectedError: 'plan.selfTest must not include unexpected field: traces.',
    mutate: (result) => {
      result.plan.selfTest.traces = false
    },
  },
  {
    name: 'result-path-mismatch',
    expectedError: 'plan.resultJsonPath must match validated result file.',
    mutate: (result) => {
      result.plan.resultJsonPath = 'assets/tmp/browser-evidence-result-validator-selftest/other-result.json'
    },
  },
  {
    name: 'absolute-plan-summary-path',
    expectedError: 'plan.summaryPath must be repo-relative.',
    mutate: (result) => {
      const absoluteSummaryPath = path.join(repoRoot, result.plan.summaryPath)
      result.plan.summaryPath = absoluteSummaryPath
      result.checks.find((check) => check.name === 'full-loop summary evidence').path = absoluteSummaryPath
      result.proofSummary.evidence.summaryPath = absoluteSummaryPath
    },
  },
  {
    name: 'absolute-plan-desktop-path',
    expectedError: 'plan.paths.desktopEvidence must be repo-relative.',
    mutate: (result) => {
      const absoluteDesktopPath = path.join(repoRoot, result.plan.paths.desktopEvidence)
      result.plan.paths.desktopEvidence = absoluteDesktopPath
      result.checks.find((check) => check.name === 'desktop raw evidence').path = absoluteDesktopPath
      result.proofSummary.evidence.desktopEvidencePath = absoluteDesktopPath
    },
  },
  {
    name: 'absolute-proof-summary-path',
    expectedError: 'proofSummary.evidence.windowsChromeEvidencePath must be repo-relative.',
    mutate: (result) => {
      result.proofSummary.evidence.windowsChromeEvidencePath = path.join(
        repoRoot,
        result.proofSummary.evidence.windowsChromeEvidencePath,
      )
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
    expectedError: 'proofSummary.evidence must not include unexpected field: reportPath.',
    mutate: (result) => {
      result.proofSummary.evidence.reportPath = 'assets/tmp/browser-evidence-result-validator-selftest/report.md'
    },
  },
  {
    name: 'proof-summary-run-id-mismatch',
    expectedError: 'proofSummary.summaryRunId must match summary.runId.',
    mutate: (result) => {
      result.proofSummary.summaryRunId = 'different-full-loop'
    },
  },
  {
    name: 'proof-summary-required-evidence-mismatch',
    expectedError: 'proofSummary.requiredEvidence must match plan.requiredEvidence.',
    mutate: (result) => {
      result.proofSummary.requiredEvidence.windowsChrome = false
    },
  },
  {
    name: 'proof-summary-web-readiness-mismatch',
    expectedError: 'proofSummary.webReadiness.strategy must match summary.environment.webReadiness.strategy.',
    mutate: (result) => {
      result.proofSummary.webReadiness.strategy = 'started-new-server'
    },
  },
  {
    name: 'proof-summary-screenshot-count-mismatch',
    expectedError: 'proofSummary.loops.desktop.screenshotCount must match summary loop screenshot count.',
    mutate: (result) => {
      result.proofSummary.loops.desktop.screenshotCount = 5
    },
  },
  {
    name: 'proof-summary-external-source-mismatch',
    expectedError: 'proofSummary.loops.windowsChrome.externalExecutionSource must match summary loop external execution source.',
    mutate: (result) => {
      result.proofSummary.loops.windowsChrome.externalExecutionSource = 'web'
    },
  },
  {
    name: 'proof-summary-evidence-path-mismatch',
    expectedError: 'proofSummary.evidence.windowsChromeEvidencePath must match plan windowsChromeEvidencePath.',
    mutate: (result) => {
      result.proofSummary.evidence.windowsChromeEvidencePath =
        'assets/tmp/browser-evidence-result-validator-selftest/other-chrome-loop.json'
    },
  },
  {
    name: 'proof-summary-web-readiness-path-mismatch',
    expectedError:
      'proofSummary.evidence.webReadinessEvidencePath must match summary.evidence Web Readiness JSON.',
    mutate: (result) => {
      result.proofSummary.evidence.webReadinessEvidencePath =
        'assets/tmp/browser-evidence-result-validator-selftest/other-web-readiness.json'
    },
  },
  {
    name: 'proof-summary-dev-env-path-mismatch',
    expectedError: 'proofSummary.evidence.devEnvEvidencePath must match summary.evidence Dev Environment JSON.',
    mutate: (result) => {
      result.proofSummary.evidence.devEnvEvidencePath =
        'assets/tmp/browser-evidence-result-validator-selftest/other-dev-env.json'
    },
  },
  {
    name: 'summary-phone-run-mismatch',
    expectedError: 'summary.loops.phone.run must match plan.inferredFromSummary.phone.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.phone.run = true
      })
    },
  },
  {
    name: 'skipped-phone-path-uses-demo-evidence',
    expectedError: 'plan.paths.phoneEvidence must be __phone_not_run__.json when phone evidence is not required.',
    mutate: (result) => {
      result.plan.paths.phoneEvidence = 'assets/demo/phone-loop.json'
      result.proofSummary.evidence.phoneEvidencePath = result.plan.paths.phoneEvidence
    },
  },
  {
    name: 'required-phone-path-uses-sentinel',
    expectedError: 'plan.paths.phoneEvidence must be a real evidence path when phone evidence is required.',
    mutate: (result) => {
      result.plan.inferredFromSummary.phone = true
      result.plan.requiredEvidence.phone = true
      result.plan.paths.phoneEvidence = '__phone_not_run__.json'
      result.proofSummary.requiredEvidence.phone = true
      result.proofSummary.loops.phone.run = true
      result.proofSummary.loops.phone.success = true
      result.proofSummary.evidence.phoneEvidencePath = result.plan.paths.phoneEvidence
      result.checks.push({
        name: 'Android Chrome phone evidence',
        command: 'npm run phone:evidence:check',
        required: true,
        path: result.plan.paths.phoneEvidence,
      })
    },
  },
  {
    name: 'skipped-desktop-path-uses-demo-evidence',
    expectedError: 'plan.paths.desktopEvidence must be __desktop_not_run__.json when desktop evidence is not required.',
    mutate: (result) => {
      result.plan.inferredFromSummary.desktop = false
      result.plan.requiredEvidence.desktop = false
      result.plan.paths.desktopEvidence = 'assets/demo/desktop-loop.json'
      result.checks = result.checks.filter((check) => check.name !== 'desktop raw evidence')
      result.proofSummary.requiredEvidence.desktop = false
      result.proofSummary.loops.desktop.run = false
      result.proofSummary.loops.desktop.success = null
      result.proofSummary.evidence.desktopEvidencePath = result.plan.paths.desktopEvidence
    },
  },
  {
    name: 'required-desktop-path-uses-sentinel',
    expectedError: 'plan.paths.desktopEvidence must be a real evidence path when desktop evidence is required.',
    mutate: (result) => {
      result.plan.paths.desktopEvidence = '__desktop_not_run__.json'
      result.checks.find((check) => check.name === 'desktop raw evidence').path = result.plan.paths.desktopEvidence
      result.proofSummary.evidence.desktopEvidencePath = result.plan.paths.desktopEvidence
    },
  },
  {
    name: 'skipped-desktop-screenshot-dir-uses-demo-evidence',
    expectedError: 'plan.paths.desktopScreenshotDir must be __desktop_screens_not_run__ when desktop evidence is not required.',
    mutate: (result) => {
      result.plan.inferredFromSummary.desktop = false
      result.plan.requiredEvidence.desktop = false
      result.plan.paths.desktopEvidence = '__desktop_not_run__.json'
      result.plan.paths.desktopScreenshotDir = 'assets/demo/playwright-chromium-screens'
      result.checks = result.checks.filter((check) => check.name !== 'desktop raw evidence')
      result.proofSummary.requiredEvidence.desktop = false
      result.proofSummary.loops.desktop.run = false
      result.proofSummary.loops.desktop.success = null
      result.proofSummary.evidence.desktopEvidencePath = result.plan.paths.desktopEvidence
      result.proofSummary.evidence.desktopScreenshotDir = result.plan.paths.desktopScreenshotDir
    },
  },
  {
    name: 'skipped-chrome-path-uses-demo-evidence',
    expectedError: 'plan.paths.windowsChromeEvidence must be __chrome_not_run__.json when windowsChrome evidence is not required.',
    mutate: (result) => {
      result.plan.inferredFromSummary.windowsChrome = false
      result.plan.requiredEvidence.windowsChrome = false
      result.plan.paths.windowsChromeEvidence = 'assets/demo/chrome-loop.json'
      result.checks = result.checks.filter((check) => check.name !== 'Windows Chrome raw evidence')
      result.proofSummary.requiredEvidence.windowsChrome = false
      result.proofSummary.loops.windowsChrome.run = false
      result.proofSummary.loops.windowsChrome.success = null
      result.proofSummary.evidence.windowsChromeEvidencePath = result.plan.paths.windowsChromeEvidence
    },
  },
  {
    name: 'required-chrome-screenshot-dir-uses-sentinel',
    expectedError: 'plan.paths.windowsChromeScreenshotDir must be a real evidence path when windowsChrome evidence is required.',
    prepare: async (result, name) => {
      await attachSummary(result, name, () => {})
      result.plan.paths.windowsChromeScreenshotDir = '__chrome_screens_not_run__'
      result.checks.find((check) => check.name === 'Windows Chrome raw evidence').screenshotDir =
        result.plan.paths.windowsChromeScreenshotDir
      result.proofSummary.evidence.windowsChromeScreenshotDir = result.plan.paths.windowsChromeScreenshotDir
    },
  },
  {
    name: 'skipped-chrome-screenshot-dir-uses-demo-evidence',
    expectedError: 'plan.paths.windowsChromeScreenshotDir must be __chrome_screens_not_run__ when windowsChrome evidence is not required.',
    mutate: (result) => {
      result.plan.inferredFromSummary.windowsChrome = false
      result.plan.requiredEvidence.windowsChrome = false
      result.plan.paths.windowsChromeEvidence = '__chrome_not_run__.json'
      result.plan.paths.windowsChromeScreenshotDir = 'assets/demo/windows-chrome-screens'
      result.checks = result.checks.filter((check) => check.name !== 'Windows Chrome raw evidence')
      result.proofSummary.requiredEvidence.windowsChrome = false
      result.proofSummary.loops.windowsChrome.run = false
      result.proofSummary.loops.windowsChrome.success = null
      result.proofSummary.evidence.windowsChromeEvidencePath = result.plan.paths.windowsChromeEvidence
      result.proofSummary.evidence.windowsChromeScreenshotDir = result.plan.paths.windowsChromeScreenshotDir
    },
  },
  {
    name: 'desktop-check-path-mismatch',
    expectedError: 'desktop raw evidence path must match plan path for desktop raw evidence.',
    mutate: (result) => {
      result.checks.find((check) => check.name === 'desktop raw evidence').path =
        'assets/tmp/browser-evidence-result-validator-selftest/other-desktop-loop.json'
    },
  },
  {
    name: 'checks-order-mismatch',
    expectedError: 'checks order must match browser evidence plan.',
    mutate: (result) => {
      const [desktopCheck, chromeCheck, ...rest] = result.checks
      result.checks = [chromeCheck, desktopCheck, ...rest]
    },
  },
  {
    name: 'checks-command-order-mismatch',
    expectedError: 'checks command order must match browser evidence plan.',
    mutate: (result) => {
      const [desktopCheck, chromeCheck, ...rest] = result.checks
      result.checks = [
        { ...desktopCheck, command: chromeCheck.command },
        { ...chromeCheck, command: desktopCheck.command },
        ...rest,
      ]
    },
  },
  {
    name: 'checks-duplicate-name',
    expectedError: 'checks entry name must be unique: desktop raw evidence.',
    mutate: (result) => {
      result.checks[1].name = 'desktop raw evidence'
    },
  },
  {
    name: 'checks-duplicate-command',
    expectedError: 'checks command must be unique: npm run desktop:evidence:check.',
    mutate: (result) => {
      result.checks[1].command = 'npm run desktop:evidence:check'
    },
  },
  {
    name: 'checks-unexpected-entry',
    expectedError: 'checks contains unexpected entry: other raw evidence.',
    mutate: (result) => {
      result.checks.push({
        name: 'other raw evidence',
        command: 'npm run other:evidence:check',
        required: true,
      })
    },
  },
  {
    name: 'checks-unknown-command',
    expectedError: 'checks command is not allowed for this browser evidence plan: npm run other:evidence:check.',
    mutate: (result) => {
      result.checks.push({
        name: 'full-loop summary evidence',
        command: 'npm run other:evidence:check',
        required: true,
      })
    },
  },
  {
    name: 'desktop-check-unexpected-field',
    expectedError: 'desktop raw evidence must not include unexpected field: resultJsonPath.',
    mutate: (result) => {
      result.checks.find((check) => check.name === 'desktop raw evidence').resultJsonPath =
        result.plan.resultJsonPath
    },
  },
  {
    name: 'chrome-screenshot-dir-mismatch',
    expectedError: 'Windows Chrome raw evidence screenshotDir must match plan screenshotDir for Windows Chrome raw evidence.',
    mutate: (result) => {
      result.checks.find((check) => check.name === 'Windows Chrome raw evidence').screenshotDir =
        'assets/tmp/browser-evidence-result-validator-selftest/other-chrome-screens'
    },
  },
  {
    name: 'phone-check-unexpected',
    expectedError: 'checks must not include Android Chrome phone evidence when it is not required.',
    mutate: (result) => {
      result.checks.push({
        name: 'Android Chrome phone evidence',
        command: 'npm run phone:evidence:check',
        required: true,
        path: result.plan.paths.phoneEvidence,
      })
    },
  },
  {
    name: 'summary-manifest-mismatch',
    expectedError: 'summary.evidence Windows Chrome JSON must match plan.paths.windowsChromeEvidence.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.evidence.files.find((entry) => entry.label === 'Windows Chrome JSON').file =
          'assets/tmp/browser-evidence-result-validator-selftest/other-chrome-loop.json'
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
          result.plan.paths.desktopEvidence
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
    name: 'screenshot-digest-mismatch',
    expectedError: 'summary.evidence desktop screenshot',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        const screenshot = summary.evidence.files.find(
          (entry) =>
            entry.label === 'Screenshot' &&
            entry.file.startsWith(result.plan.paths.desktopScreenshotDir),
        )
        screenshot.sha256 = '000000000000'
      })
    },
  },
  {
    name: 'summary-desktop-success-mismatch',
    expectedError: 'summary.loops.desktop.success must be true when desktop evidence is present.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.desktop.success = false
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
    name: 'summary-web-readiness-manifest-missing',
    expectedError: 'summary.evidence Web Readiness JSON must be present.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.evidence.files = summary.evidence.files.filter((entry) => entry.label !== 'Web Readiness JSON')
      })
    },
  },
  {
    name: 'summary-browser-parity-mismatch',
    expectedError: 'summary.browserParity.success must be true when desktop and Windows Chrome evidence are present.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.browserParity.success = false
      })
    },
  },
  {
    name: 'summary-localized-title-legacy-mismatch',
    expectedError: 'summary.loops.desktop.localizedUi.title must match summary.loops.desktop.title.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.desktop.localizedUi.title = 'HomeCue Edge'
      })
    },
  },
  {
    name: 'summary-browser-parity-recomputed-mismatch',
    expectedError: 'summary.browserParity.success must match recomputed browser parity.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.windowsChrome.localizedUi.runButton = 'Run plan'
      })
    },
  },
  {
    name: 'summary-browser-parity-input-missing',
    expectedError: 'summary.loops.desktop.scenePromptHandoff.scene is required for browser parity.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        delete summary.loops.desktop.scenePromptHandoff.scene
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
    name: 'summary-browser-parity-execution-source-mismatch',
    expectedError: 'summary.browserParity.success must match recomputed browser parity.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.loops.windowsChrome.externalExecutionSync.latestSource = 'web'
      })
    },
  },
  {
    name: 'summary-generated-after-result',
    expectedError: 'generatedAt must not be earlier than summary.generatedAt.',
    prepare: async (result, name) => {
      await attachSummary(result, name, (summary) => {
        summary.generatedAt = '2026-06-19T00:00:01.000Z'
      })
    },
  },
  {
    name: 'required-chrome-mismatch',
    expectedError: 'plan.requiredEvidence.windowsChrome must match plan.inferredFromSummary.windowsChrome.',
    mutate: (result) => {
      result.plan.requiredEvidence.windowsChrome = false
    },
  },
  {
    name: 'selftest-summary-mismatch',
    expectedError: 'checks must include exactly one summary validator self-test entry.',
    mutate: (result) => {
      result.plan.selfTest.requested = true
      result.plan.selfTest.desktopEvidence = true
      result.plan.selfTest.summary = true
    },
  },
  {
    name: 'selftest-summary-unexpected-field',
    expectedError: 'summary validator self-test must not include unexpected field: path.',
    mutate: (result) => {
      result.plan.selfTest.requested = true
      result.plan.selfTest.desktopEvidence = true
      result.plan.selfTest.summary = true
      result.checks.push(
        { name: 'desktop evidence validator self-test', command: 'npm run desktop:evidence:selftest', required: true },
        {
          name: 'summary validator self-test',
          command: `npm run summary:selftest -- ${result.plan.summaryPath}`,
          required: true,
          path: result.plan.summaryPath,
        },
      )
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
    name: 'raw-desktop-app-url-mismatch',
    expectedError: 'desktop raw evidence.appUrl must match summary.appUrl.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { appUrl: 'http://127.0.0.1:9999' },
      })
    },
  },
  {
    name: 'raw-desktop-started-at-mismatch',
    expectedError: 'desktop raw evidence.startedAt must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { startedAt: '2026-06-18T23:59:57.000Z' },
      })
    },
  },
  {
    name: 'raw-desktop-text-integrity-mismatch',
    expectedError: 'desktop raw evidence.textIntegrity.mojibakeCount must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: rawChecks({ textIntegrity: { mojibakeCount: 1 } }) },
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
    name: 'raw-desktop-localized-run-button-mismatch',
    expectedError: 'desktop raw evidence.localizedUi.runButton must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: rawChecks({ localizedUi: { runButton: 'Run plan' } }) },
      })
    },
  },
  {
    name: 'raw-desktop-runtime-health-mismatch',
    expectedError: 'desktop raw evidence.runtimeHealth.issueCount must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: rawChecks({ runtimeHealth: { issueCount: 1, counts: { consoleErrors: 1 } } }) },
      })
    },
  },
  {
    name: 'raw-desktop-screenshot-count-mismatch',
    expectedError: 'desktop raw evidence.screenshotEvidence.count must match summary loop.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { checks: await rawChecksForDirectory(result.plan.paths.desktopScreenshotDir, { count: 5 }) },
      })
    },
  },
  {
    name: 'raw-desktop-screenshot-digest-mismatch',
    expectedError: 'desktop raw evidence.screenshotEvidence.files',
    prepare: async (result, name) => {
      const checks = await rawChecksForDirectory(result.plan.paths.desktopScreenshotDir)
      checks.screenshotEvidence.files[0].sha256 = '000000000000'
      await attachRunLocalEvidence(result, name, {
        desktop: { checks },
      })
    },
  },
  {
    name: 'raw-desktop-screenshot-path-list-mismatch',
    expectedError: 'desktop raw evidence.screenshotEvidence.files paths must match raw screenshots.',
    prepare: async (result, name) => {
      const screenshots = screenshotFiles().map((file) => `${result.plan.paths.desktopScreenshotDir}/${file}`)
      await attachRunLocalEvidence(result, name, {
        desktop: { screenshots: [...screenshots.slice(1), screenshots[0]] },
      })
    },
  },
  {
    name: 'raw-desktop-finished-after-result',
    expectedError: 'generatedAt must not be earlier than desktop raw evidence.finishedAt.',
    prepare: async (result, name) => {
      await attachRunLocalEvidence(result, name, {
        desktop: { finishedAt: '2026-06-19T00:00:01.000Z' },
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
  await writeRawLoopEvidence(result.plan.paths)
  testCase.mutate?.(result)
  await testCase.prepare?.(result, testCase.name)
  if (!testCase.prepare) {
    await writeJson(resolveRepoPath(result.plan.summaryPath), await createSummary(result.plan))
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

console.log('Browser evidence result validator self-test passed.')

async function attachSummary(result, name, mutate) {
  const summaryPath = `assets/tmp/browser-evidence-result-validator-selftest/${name}-summary.json`
  result.plan.summaryPath = summaryPath
  result.proofSummary.evidence.summaryPath = summaryPath
  const summary = await createSummary(result.plan)
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
  const baseDir = `assets/tmp/browser-evidence-result-validator-selftest/${name}`
  result.plan.summaryPath = `${baseDir}/full-loop-report.json`
  result.plan.paths.desktopEvidence = `${baseDir}/desktop-loop.json`
  result.plan.paths.desktopScreenshotDir = `${baseDir}/playwright-chromium-screens`
  result.plan.paths.windowsChromeEvidence = `${baseDir}/chrome-loop.json`
  result.plan.paths.windowsChromeScreenshotDir = `${baseDir}/windows-chrome-screens`
  result.checks.find((check) => check.name === 'desktop raw evidence').path = result.plan.paths.desktopEvidence
  result.checks.find((check) => check.name === 'desktop raw evidence').screenshotDir =
    result.plan.paths.desktopScreenshotDir
  result.checks.find((check) => check.name === 'Windows Chrome raw evidence').path =
    result.plan.paths.windowsChromeEvidence
  result.checks.find((check) => check.name === 'Windows Chrome raw evidence').screenshotDir =
    result.plan.paths.windowsChromeScreenshotDir
  result.checks.find((check) => check.name === 'full-loop summary evidence').path = result.plan.summaryPath
  result.proofSummary.evidence.summaryPath = result.plan.summaryPath
  result.proofSummary.evidence.desktopEvidencePath = result.plan.paths.desktopEvidence
  result.proofSummary.evidence.desktopScreenshotDir = result.plan.paths.desktopScreenshotDir
  result.proofSummary.evidence.windowsChromeEvidencePath = result.plan.paths.windowsChromeEvidence
  result.proofSummary.evidence.windowsChromeScreenshotDir = result.plan.paths.windowsChromeScreenshotDir

  await mkdir(resolveRepoPath(result.plan.paths.desktopScreenshotDir), { recursive: true })
  await mkdir(resolveRepoPath(result.plan.paths.windowsChromeScreenshotDir), { recursive: true })
  for (const directory of [result.plan.paths.desktopScreenshotDir, result.plan.paths.windowsChromeScreenshotDir]) {
    for (const file of screenshotFiles()) {
      await writeText(resolveRepoPath(`${directory}/${file}`), 'fake screenshot\n')
    }
  }
  await writeJson(resolveRepoPath(result.plan.summaryPath), await createSummary(result.plan))
  await writeRawLoopEvidence(result.plan.paths, { desktop, chrome })
}

async function createSummary(plan) {
  return {
    generatedAt: '2026-06-18T23:59:59.000Z',
    success: true,
    runId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    loops: {
      desktop: {
        run: plan.inferredFromSummary.desktop,
        success: plan.inferredFromSummary.desktop ? true : null,
        runId: plan.inferredFromSummary.desktop ? 'full-loop-selftest' : null,
        startedAt: plan.inferredFromSummary.desktop ? '2026-06-18T23:59:50.000Z' : null,
        finishedAt: plan.inferredFromSummary.desktop ? '2026-06-18T23:59:58.000Z' : null,
        pageUrl: plan.inferredFromSummary.desktop
          ? 'http://127.0.0.1:5173/?apiBase=http%3A%2F%2F127.0.0.1%3A8723'
          : null,
        title: plan.inferredFromSummary.desktop ? '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6' : null,
        textIntegrity: plan.inferredFromSummary.desktop ? summaryTextIntegrity() : null,
        localizedUi: plan.inferredFromSummary.desktop ? summaryLocalizedUi() : null,
        firstViewportVisibility: plan.inferredFromSummary.desktop ? summaryFirstViewportVisibility() : null,
        responsiveLayout: plan.inferredFromSummary.desktop ? summaryResponsiveLayout() : null,
        runtimeHealth: plan.inferredFromSummary.desktop ? summaryRuntimeHealth() : null,
        screenshotEvidence: plan.inferredFromSummary.desktop ? summaryScreenshotEvidence() : null,
        scenePromptHandoff: plan.inferredFromSummary.desktop ? summaryScenePromptHandoff() : null,
        webConfirmExecute: plan.inferredFromSummary.desktop ? summaryWebConfirmExecute() : null,
        offlineFallback: plan.inferredFromSummary.desktop ? summaryOfflineFallback() : null,
        externalExecutionSync: plan.inferredFromSummary.desktop ? summaryExternalExecutionSync() : null,
      },
      phone: {
        run: plan.inferredFromSummary.phone,
        success: plan.inferredFromSummary.phone ? true : null,
      },
      windowsChrome: {
        run: plan.inferredFromSummary.windowsChrome,
        success: plan.inferredFromSummary.windowsChrome ? true : null,
        runId: plan.inferredFromSummary.windowsChrome ? 'full-loop-selftest' : null,
        startedAt: plan.inferredFromSummary.windowsChrome ? '2026-06-18T23:59:50.000Z' : null,
        finishedAt: plan.inferredFromSummary.windowsChrome ? '2026-06-18T23:59:58.000Z' : null,
        pageUrl: plan.inferredFromSummary.windowsChrome
          ? 'http://127.0.0.1:5173/?apiBase=http%3A%2F%2F127.0.0.1%3A8723'
          : null,
        title: plan.inferredFromSummary.windowsChrome ? '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6' : null,
        textIntegrity: plan.inferredFromSummary.windowsChrome ? summaryTextIntegrity() : null,
        localizedUi: plan.inferredFromSummary.windowsChrome ? summaryLocalizedUi() : null,
        firstViewportVisibility: plan.inferredFromSummary.windowsChrome ? summaryFirstViewportVisibility() : null,
        responsiveLayout: plan.inferredFromSummary.windowsChrome ? summaryResponsiveLayout() : null,
        runtimeHealth: plan.inferredFromSummary.windowsChrome ? summaryRuntimeHealth() : null,
        screenshotEvidence: plan.inferredFromSummary.windowsChrome ? summaryScreenshotEvidence() : null,
        scenePromptHandoff: plan.inferredFromSummary.windowsChrome ? summaryScenePromptHandoff() : null,
        webConfirmExecute: plan.inferredFromSummary.windowsChrome ? summaryWebConfirmExecute() : null,
        offlineFallback: plan.inferredFromSummary.windowsChrome ? summaryOfflineFallback() : null,
        externalExecutionSync: plan.inferredFromSummary.windowsChrome ? summaryExternalExecutionSync() : null,
      },
    },
    browserParity: {
      checked: plan.inferredFromSummary.desktop && plan.inferredFromSummary.windowsChrome,
      success: plan.inferredFromSummary.desktop && plan.inferredFromSummary.windowsChrome,
      errors: [],
    },
    environment: {
      preflight: summaryDevEnv(),
      webReadiness: summaryWebReadiness(),
    },
    evidence: {
      files: [
        { label: 'Desktop JSON', file: plan.paths.desktopEvidence, present: true },
        { label: 'Windows Chrome JSON', file: plan.paths.windowsChromeEvidence, present: true },
        { label: 'Phone JSON', file: null, present: false },
        {
          label: 'Dev Environment JSON',
          file: 'assets/tmp/browser-evidence-result-validator-selftest/dev-env-check.json',
          present: true,
          ...(await writeDevEnvEvidence()),
        },
        {
          label: 'Web Readiness JSON',
          file: 'assets/tmp/browser-evidence-result-validator-selftest/web-readiness.json',
          present: true,
          ...(await writeWebReadinessEvidence()),
        },
        ...(await screenshotEntries(plan.paths.desktopScreenshotDir)),
        ...(await screenshotEntries(plan.paths.windowsChromeScreenshotDir)),
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
  const file = resolveRepoPath('assets/tmp/browser-evidence-result-validator-selftest/dev-env-check.json')
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
    portListeningBefore: false,
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
  const file = resolveRepoPath('assets/tmp/browser-evidence-result-validator-selftest/web-readiness.json')
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

function createResult({ mode = 'validate' } = {}) {
  const summaryPath = 'assets/tmp/browser-evidence-result-validator-selftest/full-loop-report.json'
  const plan = {
    summaryPath,
    resultJsonPath: 'assets/tmp/browser-evidence-result-validator-selftest/browser-evidence-check.json',
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
      maxAgeMinutes: null,
    },
    selfTest: {
      requested: false,
      phoneEvidence: false,
      desktopEvidence: false,
      summary: false,
      report: false,
    },
    paths: {
      desktopEvidence: 'assets/tmp/browser-evidence-result-validator-selftest/desktop-loop.json',
      desktopScreenshotDir: 'assets/tmp/browser-evidence-result-validator-selftest/playwright-chromium-screens',
      phoneEvidence: '__phone_not_run__.json',
      windowsChromeEvidence: 'assets/tmp/browser-evidence-result-validator-selftest/chrome-loop.json',
      windowsChromeScreenshotDir: 'assets/tmp/browser-evidence-result-validator-selftest/windows-chrome-screens',
    },
  }

  return {
    generatedAt: '2026-06-19T00:00:00.000Z',
    success: true,
    mode,
    sourceState: currentSourceState(),
    plan,
    checks: [
      {
        name: 'desktop raw evidence',
        command: 'npm run desktop:evidence:check',
        required: true,
        path: plan.paths.desktopEvidence,
        screenshotDir: plan.paths.desktopScreenshotDir,
      },
      {
        name: 'Windows Chrome raw evidence',
        command: 'npm run desktop:evidence:check -- --require-installed-chrome',
        required: true,
        path: plan.paths.windowsChromeEvidence,
        screenshotDir: plan.paths.windowsChromeScreenshotDir,
      },
      {
        name: 'full-loop summary evidence',
        command: 'npm run summary:check',
        required: true,
        path: plan.summaryPath,
      },
    ],
    proofSummary: mode === 'dry-run' ? null : proofSummary(plan),
  }
}

function proofSummary(plan) {
  return {
    summaryRunId: 'full-loop-selftest',
    appUrl: 'http://127.0.0.1:5173',
    apiBase: 'http://127.0.0.1:8723',
    requiredEvidence: { ...plan.requiredEvidence },
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
      summaryPath: plan.summaryPath,
      desktopEvidencePath: plan.paths.desktopEvidence,
      windowsChromeEvidencePath: plan.paths.windowsChromeEvidence,
      phoneEvidencePath: plan.paths.phoneEvidence,
      devEnvEvidencePath: 'assets/tmp/browser-evidence-result-validator-selftest/dev-env-check.json',
      webReadinessEvidencePath: 'assets/tmp/browser-evidence-result-validator-selftest/web-readiness.json',
      desktopScreenshotDir: plan.paths.desktopScreenshotDir,
      windowsChromeScreenshotDir: plan.paths.windowsChromeScreenshotDir,
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
    acceptedActionCount: 5,
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

function setResultJsonPath(result, file) {
  result.plan.resultJsonPath = toRepoPath(file)
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
  await mkdir(path.dirname(file), { recursive: true })
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
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
