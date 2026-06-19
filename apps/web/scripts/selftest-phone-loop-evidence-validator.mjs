import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const validatorScript = path.join(scriptDir, 'validate-phone-loop-evidence.mjs')
const sourceEvidenceFile = path.join(repoRoot, 'assets', 'demo', 'phone-loop.json')
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'phone-evidence-validator-selftest')

await mkdir(outputDir, { recursive: true })

const sourceEvidence = JSON.parse(await readFile(sourceEvidenceFile, 'utf8'))
sourceEvidence.checks.frontCamera.classList ??= ['camera-preview', 'mirror']
sourceEvidence.checks.frontCamera.mirrored ??= true
sourceEvidence.checks.frontCamera.objectFit ??= 'cover'
const cases = [
  {
    name: 'front-camera-facing-mode-mismatch',
    expectedError: 'checks.frontCamera.facingMode must be user.',
    mutate: (evidence) => {
      evidence.checks.frontCamera.facingMode = 'environment'
    },
  },
  {
    name: 'front-camera-preview-not-mirrored',
    expectedError: 'checks.frontCamera.mirrored must be true.',
    mutate: (evidence) => {
      evidence.checks.frontCamera.mirrored = false
      evidence.checks.frontCamera.classList = ['camera-preview']
    },
  },
  {
    name: 'localized-text-integrity-mismatch',
    expectedError: 'checks.localizedUi.textIntegrity.mojibakeCount must be 0.',
    mutate: (evidence) => {
      evidence.checks.localizedUi.textIntegrity.mojibakeCount = 1
    },
  },
  {
    name: 'localized-text-integrity-weak-coverage',
    expectedError: 'checks.localizedUi.textIntegrity.requiredPhraseCount must be at least 7.',
    mutate: (evidence) => {
      evidence.checks.localizedUi.textIntegrity.requiredPhraseCount = 1
    },
  },
  {
    name: 'external-source-mismatch',
    expectedError: 'checks.externalExecution.latestSource must be esp32-serial.',
    mutate: (evidence) => {
      evidence.checks.externalExecution.latestSource = 'web'
    },
  },
]

const normalizedSourceEvidenceFile = path.join(outputDir, 'normalized-source-phone-loop.json')
await writeJson(normalizedSourceEvidenceFile, sourceEvidence)

const positive = await runValidator(normalizedSourceEvidenceFile)
if (positive.code !== 0) {
  console.error(positive.output)
  throw new Error(`Expected normalized source phone evidence to pass validation: ${normalizedSourceEvidenceFile}`)
}
console.log(`PASS normalized source phone evidence: ${path.relative(repoRoot, normalizedSourceEvidenceFile)}`)

for (const testCase of cases) {
  const evidence = structuredClone(sourceEvidence)
  testCase.mutate(evidence)

  const testEvidenceFile = path.join(outputDir, `${testCase.name}.json`)
  await writeJson(testEvidenceFile, evidence)

  const result = await runValidator(testEvidenceFile)
  if (result.code === 0) {
    throw new Error(`Expected ${testCase.name} to fail validation.`)
  }
  if (!result.output.includes(testCase.expectedError)) {
    console.error(result.output)
    throw new Error(`Expected ${testCase.name} failure to include: ${testCase.expectedError}`)
  }

  console.log(`PASS negative case: ${testCase.name}`)
}

console.log('Phone loop evidence validator self-test passed.')

async function runValidator(file) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [validatorScript, file], {
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
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}
