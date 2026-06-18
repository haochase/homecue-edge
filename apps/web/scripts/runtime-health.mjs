const MAX_TEXT_LENGTH = 700

export function createRuntimeHealthCollector(page) {
  const consoleErrors = []
  const pageErrors = []
  const requestFailures = []
  const httpErrors = []

  page.on('console', (message) => {
    if (message.type() !== 'error') return

    consoleErrors.push({
      text: truncate(message.text()),
      location: formatLocation(message.location()),
    })
  })

  page.on('pageerror', (error) => {
    pageErrors.push({
      message: truncate(error.message),
      stack: truncate(error.stack ?? ''),
    })
  })

  page.on('requestfailed', (request) => {
    requestFailures.push({
      method: request.method(),
      url: sanitizeUrl(request.url()),
      errorText: truncate(request.failure()?.errorText ?? 'unknown'),
    })
  })

  page.on('response', (response) => {
    if (response.status() < 400) return

    httpErrors.push({
      status: response.status(),
      statusText: response.statusText(),
      url: sanitizeUrl(response.url()),
    })
  })

  return {
    snapshot() {
      const counts = {
        consoleErrors: consoleErrors.length,
        pageErrors: pageErrors.length,
        requestFailures: requestFailures.length,
        httpErrors: httpErrors.length,
      }
      const issueCount = Object.values(counts).reduce((total, count) => total + count, 0)

      return {
        success: issueCount === 0,
        issueCount,
        counts,
        consoleErrors,
        pageErrors,
        requestFailures,
        httpErrors,
      }
    },
  }
}

export function assertRuntimeHealth(collector) {
  const result = collector.snapshot()
  if (result.success) {
    return result
  }

  const error = new Error(`Browser runtime health failed: ${formatCounts(result.counts)}`)
  error.details = result
  throw error
}

function formatCounts(counts) {
  return Object.entries(counts)
    .map(([name, count]) => `${name}=${count}`)
    .join(', ')
}

function formatLocation(location) {
  if (!location?.url) return null

  return {
    url: sanitizeUrl(location.url),
    lineNumber: location.lineNumber,
    columnNumber: location.columnNumber,
  }
}

function sanitizeUrl(value) {
  try {
    const url = new URL(value)
    url.search = ''
    url.hash = ''
    return url.toString()
  } catch {
    return truncate(value)
  }
}

function truncate(value) {
  if (typeof value !== 'string') return ''
  return value.length > MAX_TEXT_LENGTH ? `${value.slice(0, MAX_TEXT_LENGTH)}...` : value
}
