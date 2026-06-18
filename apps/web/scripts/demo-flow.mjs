export function buildDemoUrl(appUrl, apiBase) {
  const targetUrl = new URL(appUrl)
  targetUrl.searchParams.set('apiBase', apiBase)
  return targetUrl.toString()
}

export const labels = {
  title: '\u5bb6\u5ead AI \u7ba1\u5bb6',
  runPlan: '\u751f\u6210\u8ba1\u5212',
  resetHome: '\u91cd\u7f6e\u5bb6\u5ead',
  confirmActions: '\u786e\u8ba4\u6267\u884c',
  analyzeScene: '\u5206\u6790\u573a\u666f',
  writeRequest: '\u5199\u5165\u8bf7\u6c42',
  online: '\u5728\u7ebf',
  weak: '\u5f31\u7f51',
  offline: '\u79bb\u7ebf',
  proposeOnly: '\u53ea\u751f\u6210\u5efa\u8bae',
  pendingHardware: '\u7b49\u5f85\u786c\u4ef6\u786e\u8ba4',
  executed: '\u5df2\u672c\u5730\u6267\u884c',
  esp32Serial: 'ESP32 \u4e32\u53e3',
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
  await page.getByRole('button', { name: labels.runPlan }).click()
  await page.waitForSelector('.execution-row.accepted', { timeout: 10000 })
}

export async function runOfflineFallback(page) {
  await page.getByRole('button', { name: labels.resetHome }).first().click()
  await page.waitForSelector('text=结构化动作会先通过本地策略校验。', { timeout: 10000 })
  await page.getByRole('button', { name: labels.offline }).click()
  await page.getByRole('button', { name: labels.runPlan }).click()
  await page.waitForSelector('text=离线兜底', { timeout: 10000 })
}

export async function setProposeOnly(page, enabled = true) {
  await page.locator('.agent-toggle input').nth(1).setChecked(enabled)
}

export function getAcceptedActions(plan) {
  const precheck = Array.isArray(plan.precheck) ? plan.precheck : []
  const actions = Array.isArray(plan.routine?.actions) ? plan.routine.actions : []

  if (!precheck.length) {
    return actions
  }

  return actions.filter((action) =>
    precheck.some(
      (item) =>
        item.accepted &&
        item.device === action.device &&
        item.command === action.command &&
        item.value === action.value,
    ),
  )
}

export async function postJson(url, body) {
  const response = await fetch(url, {
    method: 'POST',
    headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })

  if (!response.ok) {
    throw new Error(`${url} returned HTTP ${response.status}`)
  }

  return response.json()
}

export async function fetchJson(url) {
  const response = await fetch(url)
  if (!response.ok) {
    throw new Error(`${url} returned HTTP ${response.status}`)
  }

  return response.json()
}
