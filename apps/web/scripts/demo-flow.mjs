export function buildDemoUrl(appUrl, apiBase) {
  const targetUrl = new URL(appUrl)
  targetUrl.searchParams.set('apiBase', apiBase)
  return targetUrl.toString()
}

export function pause(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds)
  })
}

export async function openDemo(page, appUrl, apiBase) {
  await page.goto(buildDemoUrl(appUrl, apiBase), { waitUntil: 'networkidle' })
  await page.waitForSelector('.context-grid', { timeout: 10000 })
}

export async function runOnlinePlan(page) {
  await page.getByRole('button', { name: 'Run agent' }).click()
  await page.waitForSelector('.execution-row.accepted', { timeout: 10000 })
}

export async function runOfflineFallback(page) {
  await page.getByRole('button', { name: 'Reset home' }).click()
  await page.waitForSelector('text=Structured actions will be checked before local execution.', { timeout: 10000 })
  await page.getByRole('button', { name: 'offline' }).click()
  await page.getByRole('button', { name: 'Run agent' }).click()
  await page.waitForSelector('text=offline fallback', { timeout: 10000 })
}
