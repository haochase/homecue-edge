import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const validatorScript = path.join(scriptDir, 'validate-full-loop-summary.mjs')
const sourceSummaryFile = path.join(repoRoot, 'assets', 'demo', 'full-loop-report.json')
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'summary-validator-selftest')

await mkdir(outputDir, { recursive: true })

const sourceSummary = JSON.parse(await readFile(sourceSummaryFile, 'utf8'))
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
    name: 'duplicate-json-file',
    expectedError: 'evidence manifest file assets/demo/desktop-loop.json appears 2 times',
    mutate: async (summary) => {
      const desktopEntry = manifestEntry(summary, 'Desktop JSON')
      const chromeEntry = manifestEntry(summary, 'Windows Chrome JSON')
      chromeEntry.file = desktopEntry.file
      chromeEntry.bytes = desktopEntry.bytes
      chromeEntry.sha256 = desktopEntry.sha256
    },
  },
]

const positive = await runValidator(sourceSummaryFile)
if (positive.code !== 0) {
  console.error(positive.output)
  throw new Error(`Expected source summary to pass validation: ${sourceSummaryFile}`)
}
console.log(`PASS source summary: ${path.relative(repoRoot, sourceSummaryFile)}`)

for (const testCase of cases) {
  const summary = structuredClone(sourceSummary)
  await testCase.mutate(summary)

  const testSummaryFile = path.join(outputDir, `${testCase.name}.json`)
  await writeJson(testSummaryFile, summary)

  const result = await runValidator(testSummaryFile)
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

async function runValidator(summaryFile) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [validatorScript, summaryFile, '--require-chrome'], {
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
  const entry = summary.evidence?.files?.find((item) => item?.present && item.label === label)
  if (!entry) throw new Error(`Missing present manifest entry: ${label}`)
  return entry
}

async function writeJson(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}
