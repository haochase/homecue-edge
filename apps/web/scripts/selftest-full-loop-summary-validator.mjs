import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const validatorScript = path.join(scriptDir, 'validate-full-loop-summary.mjs')
const defaultSourceSummaryFile = path.join(repoRoot, 'assets', 'demo', 'full-loop-report.json')
const sourceSummaryFile = process.argv[2] ?? defaultSourceSummaryFile
const usesDefaultSourceSummary = !process.argv[2]
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'summary-validator-selftest')

await mkdir(outputDir, { recursive: true })

const sourceSummaryInput = JSON.parse(await readFile(sourceSummaryFile, 'utf8'))
const sourceSummary = await writeSelfContainedSourceSummary(sourceSummaryInput)
const selfContainedSourceSummaryFile = path.join(outputDir, 'source-summary.json')
await writeJson(selfContainedSourceSummaryFile, sourceSummary)
const sourceDesktopEntry = manifestEntry(sourceSummary, 'Desktop JSON')
const validatorArgs = [
  ...(sourceSummary.loops?.windowsChrome?.run ? ['--require-chrome'] : []),
  ...(sourceSummary.loops?.phone?.run ? ['--require-phone'] : []),
]
const cases = [
  {
    name: 'chrome-product-mismatch',
    expectedError: 'executableProductName must identify Google Chrome',
    mutate: async (summary) => {
      summary.loops.windowsChrome.browserEnvironment.executableProductName = 'Not Chrome'
    },
  },
  {
    name: 'chrome-version-mismatch',
    expectedError: 'runtimeMajorVersion must match executableMajorVersion',
    mutate: async (summary) => {
      summary.loops.windowsChrome.browserEnvironment.executableMajorVersion =
        summary.loops.windowsChrome.browserEnvironment.runtimeMajorVersion + 1
    },
  },
  {
    name: 'browser-origin-mismatch',
    expectedError: 'locationOrigin raw evidence must match appUrl origin',
    mutate: async (summary) => {
      const raw = await readManifestJson(summary, 'Windows Chrome JSON')
      raw.checks.browserEnvironment.locationOrigin = 'http://127.0.0.1:9999'
      await replaceManifestJson(summary, 'Windows Chrome JSON', raw, 'bad-origin-chrome-loop.json')
    },
  },
  {
    name: 'desktop-host-environment-mismatch',
    expectedError: 'loops.desktop.hostEnvironment.nodeMajorVersion must be at least 20',
    mutate: async (summary) => {
      summary.loops.desktop.hostEnvironment.nodeMajorVersion = 18
    },
  },
  {
    name: 'desktop-localized-run-button-mismatch',
    expectedError: 'loops.desktop.localizedUi.runButton must be 生成计划',
    mutate: async (summary) => {
      summary.loops.desktop.localizedUi.runButton = 'Run plan'
    },
  },
  {
    name: 'desktop-text-integrity-weak-coverage',
    expectedError: 'loops.desktop.textIntegrity.requiredPhraseCount must be at least 7',
    mutate: async (summary) => {
      summary.loops.desktop.textIntegrity.requiredPhraseCount = 1
      summary.loops.desktop.localizedUi.textIntegrity.requiredPhraseCount = 1
    },
  },
  {
    name: 'desktop-localized-raw-reset-count-mismatch',
    expectedError: 'loops.desktop.localizedUi.resetButtonCount raw evidence mismatch',
    mutate: async (summary) => {
      summary.loops.desktop.localizedUi.resetButtonCount = 2
    },
  },
  {
    name: 'duplicate-json-file',
    expectedError: `evidence manifest file ${sourceDesktopEntry.file} appears 2 times`,
    mutate: async (summary) => {
      const desktopEntry = manifestEntry(summary, 'Desktop JSON')
      const chromeEntry = manifestEntry(summary, 'Windows Chrome JSON')
      chromeEntry.file = desktopEntry.file
      chromeEntry.bytes = desktopEntry.bytes
      chromeEntry.sha256 = desktopEntry.sha256
    },
  },
  {
    name: 'dev-env-required-mismatch',
    expectedError: 'environment.preflight.required must be true',
    mutate: async (summary) => {
      summary.environment.preflight.required = false
    },
  },
  {
    name: 'dev-env-raw-check-mismatch',
    expectedError: 'environment.preflight.checks raw evidence mismatch',
    mutate: async (summary) => {
      const raw = await readManifestJson(summary, 'Dev Environment JSON')
      raw.checks[0].ok = false
      await replaceManifestJson(summary, 'Dev Environment JSON', raw, 'bad-dev-env-check.json')
    },
  },
  {
    name: 'dev-env-after-loop-start',
    expectedError: 'environment.preflight.generatedAt must not be later than loops.desktop.startedAt',
    mutate: async (summary) => {
      summary.environment.preflight.generatedAt = new Date(
        Date.parse(summary.loops.desktop.startedAt) + 1000,
      ).toISOString()
      const raw = await readManifestJson(summary, 'Dev Environment JSON')
      raw.generatedAt = summary.environment.preflight.generatedAt
      await replaceManifestJson(summary, 'Dev Environment JSON', raw, 'bad-dev-env-timing.json')
    },
  },
  {
    name: 'dev-env-not-run-with-present-manifest',
    expectedError: 'evidence manifest must not include present Dev Environment JSON when preflight did not run',
    mutate: async (summary) => {
      summary.loops.phone.run = false
      summary.loops.phone.success = null
      summary.environment.preflight = { run: false, success: null }
    },
    args: ['--require-chrome'],
  },
  {
    name: 'web-readiness-gate-mismatch',
    expectedError: 'environment.webReadiness.gates.httpProbeBeforePortReuse must be true.',
    mutate: async (summary) => {
      await attachWebReadiness(summary)
      summary.environment.webReadiness.gates.httpProbeBeforePortReuse = false
    },
  },
  {
    name: 'web-readiness-raw-app-url-mismatch',
    expectedError: 'environment.webReadiness.appUrl raw evidence mismatch',
    mutate: async (summary) => {
      await attachWebReadiness(summary, { appUrl: 'http://127.0.0.1:9999' })
    },
  },
]

if (sourceSummary.loops?.phone?.run) {
  cases.push({
    name: 'dev-env-phone-required-mismatch',
    expectedError: 'environment.preflight.requirePhone must be true when phone loop is required or present',
    mutate: async (summary) => {
      summary.environment.preflight.requirePhone = false
      const raw = await readManifestJson(summary, 'Dev Environment JSON')
      raw.requirePhone = false
      await replaceManifestJson(summary, 'Dev Environment JSON', raw, 'bad-dev-env-require-phone.json')
    },
  })
  cases.push({
    name: 'phone-text-integrity-mismatch',
    expectedError: 'loops.phone.textIntegrity.mojibakeCount must be 0.',
    mutate: async (summary) => {
      summary.loops.phone.textIntegrity.mojibakeCount = 1
    },
  })
  cases.push({
    name: 'phone-text-integrity-weak-coverage',
    expectedError: 'loops.phone.textIntegrity.requiredPhraseCount must be at least 7',
    mutate: async (summary) => {
      summary.loops.phone.textIntegrity.requiredPhraseCount = 1
    },
  })
  cases.push({
    name: 'phone-front-camera-mirror-mismatch',
    expectedError: 'loops.phone.frontCamera.mirrored must be true.',
    mutate: async (summary) => {
      summary.loops.phone.frontCamera.mirrored = false
    },
  })
}

const positive = await runValidator(selfContainedSourceSummaryFile)
if (positive.code !== 0) {
  console.error(positive.output)
  throw new Error(`Expected self-contained source summary to pass validation: ${selfContainedSourceSummaryFile}`)
}
console.log(`PASS source summary: ${path.relative(repoRoot, selfContainedSourceSummaryFile)}`)

if (usesDefaultSourceSummary) {
  const defaultFileWithFlags = await runValidatorWithDefaultFile(validatorArgs)
  if (defaultFileWithFlags.code !== 0) {
    console.log('SKIP default summary path with flags-only arguments because default demo raw evidence is mutable.')
  } else {
    console.log('PASS default summary path with flags-only arguments')
  }
} else {
  console.log('SKIP default summary path with flags-only arguments for custom source summary')
}

if (sourceSummary.loops?.windowsChrome?.run) {
  const chromeOnlySummaryFile = await writeChromeOnlySkipPreflightSummary(sourceSummary)
  const chromeOnly = await runValidator(chromeOnlySummaryFile, ['--allow-skip-desktop', '--require-chrome'])
  if (chromeOnly.code !== 0) {
    console.error(chromeOnly.output)
    throw new Error(`Expected generated Chrome-only skip-preflight summary to pass validation: ${chromeOnlySummaryFile}`)
  }
  console.log(`PASS generated Chrome-only skip-preflight summary: ${path.relative(repoRoot, chromeOnlySummaryFile)}`)
}

for (const testCase of cases) {
  const summary = structuredClone(sourceSummary)
  await testCase.mutate(summary)

  const testSummaryFile = path.join(outputDir, `${testCase.name}.json`)
  await writeJson(testSummaryFile, summary)

  const result = await runValidator(testSummaryFile, testCase.args)
  if (result.code === 0) {
    throw new Error(`Expected ${testCase.name} to fail validation.`)
  }
  if (!result.output.includes(testCase.expectedError)) {
    console.error(result.output)
    throw new Error(`Expected ${testCase.name} failure to include: ${testCase.expectedError}`)
  }

  console.log(`PASS negative case: ${testCase.name}`)
}

console.log('Full loop summary validator self-test passed.')

async function runValidator(summaryFile, args = validatorArgs) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [validatorScript, summaryFile, ...args], {
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

async function runValidatorWithDefaultFile(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [validatorScript, ...args], {
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

async function readManifestJson(summary, label) {
  const entry = manifestEntry(summary, label)
  return JSON.parse(await readFile(path.join(repoRoot, entry.file), 'utf8'))
}

async function writeSelfContainedSourceSummary(summary) {
  const result = structuredClone(summary)

  if (result.environment?.preflight?.run === true) {
    await replaceManifestJson(result, 'Dev Environment JSON', {
      generatedAt: result.environment.preflight.generatedAt,
      success: result.environment.preflight.success,
      required: result.environment.preflight.required,
      requirePhone: result.environment.preflight.requirePhone,
      checks: result.environment.preflight.checks,
    }, 'source-dev-env-check.json')
  }

  return result
}

async function attachWebReadiness(summary, overrides = {}) {
  const webReadiness = {
    generatedAt: new Date(Date.parse(summary.loops.desktop.startedAt) - 1000).toISOString(),
    runId: summary.runId,
    appUrl: summary.appUrl,
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

  summary.environment.webReadiness = {
    run: true,
    success: webReadiness.httpReadyAfter === true,
    generatedAt: webReadiness.generatedAt,
    runId: summary.runId,
    appUrl: summary.appUrl,
    webPort: webReadiness.webPort,
    strategy: webReadiness.strategy,
    portListeningBefore: webReadiness.portListeningBefore,
    httpReadyBefore: webReadiness.httpReadyBefore,
    httpReadyAfter: webReadiness.httpReadyAfter,
    duplicateStartAvoided: webReadiness.duplicateStartAvoided,
    gates: webReadiness.gates,
  }
  if (!summary.evidence.files.some((entry) => entry?.label === 'Web Readiness JSON')) {
    summary.evidence.files.push({ label: 'Web Readiness JSON', present: true })
  }
  await replaceManifestJson(summary, 'Web Readiness JSON', webReadiness, 'web-readiness.json')
}

async function replaceManifestJson(summary, label, value, fileName) {
  const file = path.join(outputDir, fileName)
  await writeJson(file, value)

  const buffer = await readFile(file)
  const entry = manifestEntry(summary, label)
  entry.file = path.relative(repoRoot, file).replaceAll(path.sep, '/')
  entry.bytes = buffer.length
  entry.sha256 = createHash('sha256').update(buffer).digest('hex').slice(0, 12)
}

function manifestEntry(summary, label) {
  const existing = summary.evidence?.files?.find((item) => item?.label === label)
  if (existing && !existing.present) {
    existing.present = true
    return existing
  }

  const entry = summary.evidence?.files?.find((item) => item?.present && item.label === label)
  if (!entry) throw new Error(`Missing present manifest entry: ${label}`)
  return entry
}

async function writeJson(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

async function copyChromeOnlyScreenshots(chromeRaw) {
  const sourceScreenshots = Array.isArray(chromeRaw.screenshots) ? chromeRaw.screenshots : []
  const sourceEvidenceFiles = Array.isArray(chromeRaw.checks?.screenshotEvidence?.files)
    ? chromeRaw.checks.screenshotEvidence.files
    : []
  const evidenceByPath = new Map(sourceEvidenceFiles.map((entry) => [entry?.path, entry]))
  const screenshotDir = path.join(outputDir, 'chrome-only', 'windows-chrome-screens')
  await mkdir(screenshotDir, { recursive: true })

  const copied = []
  for (const sourceScreenshot of sourceScreenshots) {
    const destination = path.join(screenshotDir, path.basename(sourceScreenshot))
    await copyFile(path.join(repoRoot, sourceScreenshot), destination)

    const buffer = await readFile(destination)
    const relativePath = path.relative(repoRoot, destination).replaceAll(path.sep, '/')
    const sourceEvidence = evidenceByPath.get(sourceScreenshot) ?? {}
    copied.push({
      ...sourceEvidence,
      path: relativePath,
      bytes: buffer.length,
      sha256: createHash('sha256').update(buffer).digest('hex').slice(0, 12),
    })
  }

  chromeRaw.screenshots = copied.map((entry) => entry.path)
  if (chromeRaw.checks?.screenshotEvidence) {
    chromeRaw.checks.screenshotEvidence.files = copied
  }

  return copied.map(({ path: file, bytes, sha256 }) => ({
    label: 'Screenshot',
    file,
    present: true,
    bytes,
    sha256,
  }))
}

async function writeChromeOnlySkipPreflightSummary(source) {
  const summary = structuredClone(source)
  const chromeEntry = manifestEntry(summary, 'Windows Chrome JSON')
  const chromeRaw = JSON.parse(await readFile(path.join(repoRoot, chromeEntry.file), 'utf8'))
  const screenshotEntries = await copyChromeOnlyScreenshots(chromeRaw)
  await replaceManifestJson(summary, 'Windows Chrome JSON', chromeRaw, 'chrome-only-raw.json')
  if (summary.environment?.webReadiness?.run === true) {
    await replaceManifestJson(
      summary,
      'Web Readiness JSON',
      {
        generatedAt: summary.environment.webReadiness.generatedAt,
        runId: summary.environment.webReadiness.runId,
        appUrl: summary.environment.webReadiness.appUrl,
        webPort: summary.environment.webReadiness.webPort,
        strategy: summary.environment.webReadiness.strategy,
        portListeningBefore: summary.environment.webReadiness.portListeningBefore,
        httpReadyBefore: summary.environment.webReadiness.httpReadyBefore,
        httpReadyAfter: summary.environment.webReadiness.httpReadyAfter,
        duplicateStartAvoided: summary.environment.webReadiness.duplicateStartAvoided,
        gates: summary.environment.webReadiness.gates,
      },
      'chrome-only-web-readiness.json',
    )
  }

  summary.loops.desktop = { run: false, success: null }
  summary.loops.phone = { run: false, success: null }
  summary.environment.preflight = { run: false, success: null }
  summary.browserParity = { checked: false, success: null, errors: [] }
  summary.evidence.files = [
    manifestEntry(summary, 'Windows Chrome JSON'),
    ...(summary.environment?.webReadiness?.run === true ? [manifestEntry(summary, 'Web Readiness JSON')] : []),
    ...screenshotEntries,
  ]

  const summaryFile = path.join(outputDir, 'chrome-only-skip-preflight-positive.json')
  await writeJson(summaryFile, summary)
  return summaryFile
}
