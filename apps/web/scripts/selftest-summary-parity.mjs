import { parityErrorsSignature, recomputeBrowserParity, validateBrowserParityInputs } from './summary-parity.mjs'

const baseDesktop = createLoopSummary()
const baseChrome = createLoopSummary()

assertParity('positive parity', recomputeBrowserParity(baseDesktop, baseChrome), {
  checked: true,
  success: true,
  errors: [],
})

const cases = [
  {
    name: 'localized run button mismatch',
    expectedError: 'run button mismatch',
    mutate: (chrome) => {
      chrome.localizedUi.runButton = 'Run plan'
    },
  },
  {
    name: 'first viewport mismatch',
    expectedError: 'first viewport panel count mismatch',
    mutate: (chrome) => {
      chrome.firstViewportVisibility.panelCount = 4
    },
  },
  {
    name: 'scene handoff mismatch',
    expectedError: 'scene raw image retained mismatch',
    mutate: (chrome) => {
      chrome.scenePromptHandoff.rawImageRetained = true
    },
  },
  {
    name: 'execution sync mismatch',
    expectedError: 'external sync source mismatch',
    mutate: (chrome) => {
      chrome.externalExecutionSync.latestSource = 'web'
    },
  },
  {
    name: 'execution source mode mismatch',
    expectedError: 'external sync mode mismatch',
    mutate: (chrome) => {
      chrome.externalExecutionSync.sourceMode = 'serial-hardware'
    },
  },
  {
    name: 'runtime and screenshot mismatch',
    expectedError: 'screenshot unique digest count mismatch',
    mutate: (chrome) => {
      chrome.runtimeHealth.issueCount = 1
      chrome.screenshotEvidence.uniqueDigestCount = 5
    },
  },
  {
    name: 'responsive layout mismatch',
    expectedError: 'responsive layout mismatch',
    mutate: (chrome) => {
      chrome.responsiveLayout[0].overflowX = 8
    },
  },
]

for (const testCase of cases) {
  const desktop = structuredClone(baseDesktop)
  const chrome = structuredClone(baseChrome)
  testCase.mutate(chrome)
  const result = recomputeBrowserParity(desktop, chrome)

  if (result.checked !== true) throw new Error(`${testCase.name}: expected checked parity.`)
  if (result.success !== false) throw new Error(`${testCase.name}: expected failed parity.`)
  if (!result.errors.some((error) => error.includes(testCase.expectedError))) {
    throw new Error(`${testCase.name}: expected error containing "${testCase.expectedError}", got ${result.errors.join('; ')}`)
  }
  console.log(`PASS summary parity negative case: ${testCase.name}`)
}

const signature = parityErrorsSignature(['a mismatch', 'b mismatch'])
if (signature !== 'a mismatch|b mismatch') {
  throw new Error(`Expected parityErrorsSignature to join errors, got ${signature}`)
}
if (parityErrorsSignature(null) !== null) {
  throw new Error('Expected parityErrorsSignature(null) to return null.')
}

const missingSceneInput = structuredClone(baseDesktop)
delete missingSceneInput.scenePromptHandoff.scene
assertInputError(
  'missing scene parity input',
  missingSceneInput,
  'summary.loops.desktop',
  'summary.loops.desktop.scenePromptHandoff.scene is required for browser parity.',
)

const missingLayoutInput = structuredClone(baseDesktop)
missingLayoutInput.responsiveLayout = []
assertInputError(
  'missing responsive layout parity input',
  missingLayoutInput,
  'summary.loops.desktop',
  'summary.loops.desktop.responsiveLayout is required for browser parity.',
)

console.log('Summary parity self-test passed.')

function assertParity(name, actual, expected) {
  if (actual.checked !== expected.checked) throw new Error(`${name}: checked mismatch.`)
  if (actual.success !== expected.success) throw new Error(`${name}: success mismatch.`)
  if (parityErrorsSignature(actual.errors) !== parityErrorsSignature(expected.errors)) {
    throw new Error(`${name}: errors mismatch.`)
  }
  console.log(`PASS summary parity case: ${name}`)
}

function assertInputError(name, loop, label, expectedError) {
  const errors = validateBrowserParityInputs(loop, label)
  if (!errors.includes(expectedError)) {
    throw new Error(`${name}: expected "${expectedError}", got ${errors.join('; ')}`)
  }
  console.log(`PASS summary parity input case: ${name}`)
}

function createLoopSummary() {
  return {
    run: true,
    title: '\u5bb6\u5ead\u667a\u80fd\u7ba1\u5bb6',
    localizedUi: {
      runButton: '\u751f\u6210\u8ba1\u5212',
      resetButtonCount: 1,
    },
    textIntegrity: {
      mojibakeCount: 0,
      missingPhraseCount: 0,
    },
    firstViewportVisibility: {
      panelCount: 5,
      minVisibleRatio: 1,
    },
    scenePromptHandoff: {
      scene: 'low-energy evening arrival',
      rawImageRetained: false,
      rawImageEchoed: false,
    },
    webConfirmExecute: {
      latestSource: 'web',
    },
    offlineFallback: {
      latestSource: 'plan',
    },
    externalExecutionSync: {
      acceptedActionCount: 5,
      latestSource: 'esp32-serial',
      sourceMode: 'api-simulated-room-terminal',
    },
    runtimeHealth: {
      issueCount: 0,
    },
    screenshotEvidence: {
      count: 6,
      uniqueDigestCount: 6,
    },
    responsiveLayout: [
      {
        label: 'mobile',
        overflowX: 0,
        overflowingButtonCount: 0,
        overlappingPanelPairCount: 0,
        panelCount: 7,
      },
      {
        label: 'desktop',
        overflowX: 0,
        overflowingButtonCount: 0,
        overlappingPanelPairCount: 0,
        panelCount: 7,
      },
    ],
  }
}
