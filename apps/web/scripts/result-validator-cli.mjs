export function parseResultValidatorCliOptions(args) {
  const options = { resultFile: null, maxAgeMinutes: null }

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (arg === '--max-age-minutes') {
      setMaxAgeMinutes(options, args[index + 1])
      index += 1
      continue
    }
    if (arg?.startsWith('--max-age-minutes=')) {
      setMaxAgeMinutes(options, arg.slice('--max-age-minutes='.length))
      continue
    }
    if (arg?.startsWith('--')) {
      exitWithUsageError(`Unknown option: ${arg}`)
    }
    if (options.resultFile) {
      exitWithUsageError(`Unexpected extra argument: ${arg}`)
    }
    options.resultFile = arg
  }

  return options
}

export function validateResultFreshness(errors, generatedAt, maxAgeMinutes, label = 'generatedAt') {
  if (!maxAgeMinutes) return

  const generatedAtMs = Date.parse(generatedAt)
  if (!Number.isFinite(generatedAtMs)) return

  const ageMs = Date.now() - generatedAtMs
  if (ageMs < 0) {
    errors.push(`${label} must not be in the future when --max-age-minutes is set.`)
    return
  }
  if (ageMs > maxAgeMinutes * 60 * 1000) {
    errors.push(`${label} is older than --max-age-minutes=${maxAgeMinutes}.`)
  }
}

function setMaxAgeMinutes(options, value) {
  if (options.maxAgeMinutes !== null) {
    exitWithUsageError('--max-age-minutes must be provided at most once.')
  }

  options.maxAgeMinutes = parseMaxAgeMinutes(value)
}

function parseMaxAgeMinutes(value) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    exitWithUsageError('--max-age-minutes must be a positive number.')
  }

  return parsed
}

function exitWithUsageError(message) {
  console.error(message)
  process.exit(2)
}
