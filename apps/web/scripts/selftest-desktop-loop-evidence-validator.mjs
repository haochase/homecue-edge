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
    name: 'desktop-root-unexpected-field',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'evidence root must not include unexpected field: proofSummary',
    mutate: (evidence) => {
      evidence.proofSummary = {}
    },
  },
  {
    name: 'desktop-checks-unexpected-field',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'checks must not include unexpected field: debugTrace',
    mutate: (evidence) => {
      evidence.checks.debugTrace = []
    },
  },
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
    name: 'desktop-screenshot-steps-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'expectedFiles must match the required six-step screenshot set',
    mutate: (evidence) => {
      evidence.checks.screenshotEvidence.expectedFiles[0] = 'wrong-step.png'
    },
  },
  {
    name: 'desktop-text-integrity-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'localizedUi.textIntegrity.mojibakeCount must be 0',
    mutate: (evidence) => {
      evidence.checks.localizedUi.textIntegrity.mojibakeCount = 1
    },
  },
  {
    name: 'desktop-text-integrity-weak-coverage',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'localizedUi.textIntegrity.requiredPhraseCount must be at least 7',
    mutate: (evidence) => {
      evidence.checks.localizedUi.textIntegrity.requiredPhraseCount = 1
    },
  },
  {
    name: 'desktop-localized-title-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'localizedUi.title must be 家庭智能管家',
    mutate: (evidence) => {
      evidence.checks.localizedUi.title = 'HomeCue Edge'
    },
  },
  {
    name: 'desktop-localized-run-button-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'localizedUi.runButton must be 生成计划',
    mutate: (evidence) => {
      evidence.checks.localizedUi.runButton = 'Run plan'
    },
  },
  {
    name: 'desktop-localized-reset-button-missing',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'localizedUi.resetButtonCount must be at least 1',
    mutate: (evidence) => {
      evidence.checks.localizedUi.resetButtonCount = 0
    },
  },
  {
    name: 'desktop-host-environment-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'hostEnvironment.nodeMajorVersion must be at least 20',
    mutate: (evidence) => {
      evidence.checks.hostEnvironment.nodeMajorVersion = 18
    },
  },
  {
    name: 'desktop-first-viewport-visibility-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'firstViewportVisibility.topbar visibleRatio must be between 0.9 and 1',
    mutate: (evidence) => {
      evidence.checks.firstViewportVisibility.panels[0].visibleRatio = 0.5
    },
  },
  {
    name: 'desktop-responsive-overflow-mismatch',
    base: desktopEvidence,
    argsFor: desktopArgs,
    expectedError: 'responsiveLayout.mobile.overflowX must be 0',
    mutate: (evidence) => {
      evidence.checks.responsiveLayout[0].overflowX = 12
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

const defaultFileWithFlags = await runValidator(desktopArgs())
if (defaultFileWithFlags.code !== 0) {
  console.error(defaultFileWithFlags.output)
  throw new Error('Expected default desktop evidence path with flags-only arguments to pass validation.')
}
console.log('PASS default desktop evidence path with flags-only arguments')

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
    ...(file ? [file] : []),
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
