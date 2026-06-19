import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const reporterScript = path.join(scriptDir, 'summarize-full-loop.mjs')
const desktopEvidenceFile = path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const phoneEvidenceFile = path.join(repoRoot, 'assets', 'demo', 'phone-loop.json')
const chromeEvidenceFile = path.join(repoRoot, 'assets', 'demo', 'chrome-loop.json')
const legacyScreensArg = '__legacy_desktop_screens_unused__'
const devEnvEvidenceFile = path.join(repoRoot, 'assets', 'tmp', 'dev-env-check.json')
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'full-loop-reporter-selftest')

await mkdir(outputDir, { recursive: true })

const positive = await runReporter('positive', phoneEvidenceFile)
if (positive.code !== 0) {
  console.error(positive.output)
  throw new Error(`Expected source full-loop report evidence to pass: ${phoneEvidenceFile}`)
}
console.log('PASS source report evidence')

const phoneEvidence = JSON.parse(await readFile(phoneEvidenceFile, 'utf8'))
const negativeCases = [
  {
    name: 'phone-front-camera-facing-mode-mismatch',
    expectedError: 'Phone front camera facingMode must be user',
    mutate: (evidence) => {
      evidence.checks.frontCamera.facingMode = 'environment'
    },
  },
  {
    name: 'phone-front-camera-track-state-mismatch',
    expectedError: 'Phone front camera trackState must be live',
    mutate: (evidence) => {
      evidence.checks.frontCamera.trackState = 'ended'
    },
  },
]

for (const testCase of negativeCases) {
  const evidence = structuredClone(phoneEvidence)
  testCase.mutate(evidence)

  const badPhoneFile = path.join(outputDir, `${testCase.name}.json`)
  await writeJson(badPhoneFile, evidence)

  const result = await runReporter(testCase.name, badPhoneFile)
  if (result.code === 0) {
    throw new Error(`Expected ${testCase.name} to fail report generation.`)
  }
  if (!result.output.includes(testCase.expectedError)) {
    console.error(result.output)
    throw new Error(`Expected ${testCase.name} failure to include: ${testCase.expectedError}`)
  }

  console.log(`PASS negative case: ${testCase.name}`)
}

console.log('Full loop reporter self-test passed.')

async function runReporter(name, phoneFile) {
  const reportFile = path.join(outputDir, `${name}.md`)
  const summaryFile = path.join(outputDir, `${name}.json`)

  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [
        reporterScript,
        reportFile,
        desktopEvidenceFile,
        phoneFile,
        legacyScreensArg,
        chromeEvidenceFile,
        summaryFile,
        devEnvEvidenceFile,
      ],
      {
        cwd: path.join(repoRoot, 'apps', 'web'),
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    )
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
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}
