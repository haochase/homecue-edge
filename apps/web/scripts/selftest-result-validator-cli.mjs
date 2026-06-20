import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { parseResultValidatorCliOptions, validateResultFreshness } from './result-validator-cli.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const probeFlag = '--probe-parse'

if (process.argv[2] === probeFlag) {
  parseResultValidatorCliOptions(process.argv.slice(3))
  process.exit(0)
}

const cases = [
  {
    name: 'default options',
    args: [],
    expected: { resultFile: null, maxAgeMinutes: null },
  },
  {
    name: 'result file only',
    args: ['assets/tmp/result.json'],
    expected: { resultFile: 'assets/tmp/result.json', maxAgeMinutes: null },
  },
  {
    name: 'space separated freshness',
    args: ['assets/tmp/result.json', '--max-age-minutes', '30'],
    expected: { resultFile: 'assets/tmp/result.json', maxAgeMinutes: 30 },
  },
  {
    name: 'equals freshness',
    args: ['--max-age-minutes=2.5', 'assets/tmp/result.json'],
    expected: { resultFile: 'assets/tmp/result.json', maxAgeMinutes: 2.5 },
  },
]

for (const testCase of cases) {
  const actual = parseResultValidatorCliOptions(testCase.args)
  assertDeepEqual(actual, testCase.expected, testCase.name)
  console.log(`PASS CLI parse case: ${testCase.name}`)
}

const failureCases = [
  {
    name: 'unknown option',
    args: ['--fresh'],
    expectedOutput: 'Unknown option: --fresh',
  },
  {
    name: 'extra argument',
    args: ['first.json', 'second.json'],
    expectedOutput: 'Unexpected extra argument: second.json',
  },
  {
    name: 'missing max age value',
    args: ['--max-age-minutes'],
    expectedOutput: '--max-age-minutes must be a positive number.',
  },
  {
    name: 'invalid max age value',
    args: ['--max-age-minutes', '0'],
    expectedOutput: '--max-age-minutes must be a positive number.',
  },
  {
    name: 'duplicate max age',
    args: ['--max-age-minutes', '30', '--max-age-minutes=60'],
    expectedOutput: '--max-age-minutes must be provided at most once.',
  },
]

for (const testCase of failureCases) {
  const result = await runParseProbe(testCase.args)
  if (result.code !== 2 || !result.output.includes(testCase.expectedOutput)) {
    throw new Error(
      `${testCase.name}: expected exit 2 with ${JSON.stringify(testCase.expectedOutput)}, got exit ${result.code} and output ${JSON.stringify(result.output)}`,
    )
  }
  console.log(`PASS CLI failure case: ${testCase.name}`)
}

const freshErrors = []
validateResultFreshness(freshErrors, new Date().toISOString(), 60)
assertDeepEqual(freshErrors, [], 'fresh timestamp')
console.log('PASS freshness case: fresh timestamp')

const staleErrors = []
validateResultFreshness(staleErrors, new Date(Date.now() - 120_000).toISOString(), 1)
assertIncludes(staleErrors, 'generatedAt is older than --max-age-minutes=1.', 'stale timestamp')
console.log('PASS freshness case: stale timestamp')

const labeledStaleErrors = []
validateResultFreshness(labeledStaleErrors, new Date(Date.now() - 120_000).toISOString(), 1, 'browserEvidence.generatedAt')
assertIncludes(
  labeledStaleErrors,
  'browserEvidence.generatedAt is older than --max-age-minutes=1.',
  'labeled stale timestamp',
)
console.log('PASS freshness case: labeled stale timestamp')

const futureErrors = []
validateResultFreshness(futureErrors, new Date(Date.now() + 60_000).toISOString(), 1)
assertIncludes(
  futureErrors,
  'generatedAt must not be in the future when --max-age-minutes is set.',
  'future timestamp',
)
console.log('PASS freshness case: future timestamp')

const invalidTimestampErrors = []
validateResultFreshness(invalidTimestampErrors, 'not-a-date', 1)
assertDeepEqual(invalidTimestampErrors, [], 'invalid timestamp')
console.log('PASS freshness case: invalid timestamp defers to caller')

console.log('Result validator CLI self-test passed.')

function assertDeepEqual(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
  }
}

function assertIncludes(actual, expected, label) {
  if (!actual.includes(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(actual)} to include ${JSON.stringify(expected)}`)
  }
}

async function runParseProbe(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [scriptPath, probeFlag, ...args], {
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let output = ''
    child.stdout.on('data', (chunk) => {
      output += chunk
    })
    child.stderr.on('data', (chunk) => {
      output += chunk
    })
    child.on('error', reject)
    child.on('close', (code) => {
      resolve({ code, output })
    })
  })
}
