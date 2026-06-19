import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..', '..', '..')
const validatorScript = path.join(scriptDir, 'validate-desktop-loop-evidence.mjs')
const desktopEvidenceFile = path.join(repoRoot, 'assets', 'demo', 'desktop-loop.json')
const chromeEvidenceFile = path.join(repoRoot, 'assets', 'demo', 'chrome-loop.json')
const outputDir = path.join(repoRoot, 'assets', 'tmp', 'desktop-evidence-validator-selftest')

await mkdir(outputDir, { recursive: true })

const desktopEvidence = JSON.parse(await readFile(desktopEvidenceFile, 'utf8'))
const chromeEvidence = JSON.parse(await readFile(chromeEvidenceFile, 'utf8'))
const positiveCases = [
  {
    name: 'desktop',
    file: desktopEvidenceFile,
    args: desktopArgs(desktopEvidenceFile),
  },
  {
    name: 'windows-chrome',
    file: chromeEvidenceFile,
    args: chromeArgs(chromeEvidenceFile),
  },
]
const negativeCases = [
  {
    name: 'chrome-product-mismatch',
    base: chromeEvidence,
    argsFor: chromeArgs,
    expectedError: 'executableProductName must identify Google Chrome',
    mutate: (evidence) => {
      evidence.checks.browserEnvironment.executableProductName = 'Not Chrome'
    },
  },
  {
    name: 'chrome-screenshot-digest-mismatch',
    base: chromeEvidence,
    argsFor: chromeArgs,
    expectedError: 'screenshot sha256 mismatch',
    mutate: (evidence) => {
      evidence.checks.screenshotEvidence.files[0].sha256 = '000000000000'
    },
  },
  {
    name: 'chrome-screenshot-directory-mismatch',
    base: chromeEvidence,
    argsFor: chromeArgs,
    expectedError: 'screenshots must use assets/demo/windows-chrome-screens/',
    mutate: (evidence) => {
      evidence.screenshots[0] = 'assets/demo/playwright-chromium-screens/01-control-console.png'
      evidence.checks.screenshotEvidence.files[0].path = evidence.screenshots[0]
    },
  },
  {
    name: 'desktop-external-source-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'externalExecutionSync.latestSource must be esp32-serial',
    mutate: (evidence) => {
      evidence.checks.externalExecutionSync.latestSource = 'web'
    },
  },
]

for (const testCase of positiveCases) {
  const result = await runValidator(testCase.args)
  if (result.code !== 0) {
    console.error(result.output)
    throw new Error(`Expected ${testCase.name} raw evidence to pass validation: ${testCase.file}`)
  }

  console.log(`PASS source evidence: ${testCase.name}`)
}

for (const testCase of negativeCases) {
  const evidence = structuredClone(testCase.base)
  testCase.mutate(evidence)

  const file = path.join(outputDir, `${testCase.name}.json`)
  await writeJson(file, evidence)

  const result = await runValidator(testCase.argsFor(file))
  if (result.code === 0) {
    throw new Error(`Expected ${testCase.name} to fail validation.`)
  }
  if (!result.output.includes(testCase.expectedError)) {
    console.error(result.output)
    throw new Error(`Expected ${testCase.name} failure to include: ${testCase.expectedError}`)
  }

  console.log(`PASS negative case: ${testCase.name}`)
}

console.log('Desktop loop evidence validator self-test passed.')

function desktopArgs(file) {
  return [
    validatorScript,
    file,
    '--browser-name',
    'playwright-chromium',
    '--executable-path',
    'bundled',
    '--screenshot-dir',
    'assets/demo/playwright-chromium-screens/',
  ]
}

function chromeArgs(file) {
  return [
    validatorScript,
    file,
    '--browser-name',
    'windows-chrome',
    '--executable-path',
    'custom',
    '--screenshot-dir',
    'assets/demo/windows-chrome-screens/',
    '--require-installed-chrome',
  ]
}

async function runValidator(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, {
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
