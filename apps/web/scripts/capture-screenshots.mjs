import { mkdir } from 'node:fs/promises'
import path from 'node:path'
import { chromium } from 'playwright'
import { openDemo, runOfflineFallback, runOnlinePlan } from './demo-flow.mjs'

const outputDir = process.argv[2]
const appUrl = process.argv[3] ?? 'http://127.0.0.1:5173'
const apiBase = process.argv[4] ?? 'http://127.0.0.1:8723'

if (!outputDir) {
  throw new Error('Output directory argument is required.')
}

await mkdir(outputDir, { recursive: true })

const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 1 })

await openDemo(page, appUrl, apiBase)
await page.screenshot({ path: path.join(outputDir, '01-control-console.png'), fullPage: true })

await runOnlinePlan(page)
await page.screenshot({ path: path.join(outputDir, '02-online-plan.png'), fullPage: true })

await page.locator('.execution-list').screenshot({ path: path.join(outputDir, '03-execution-guard.png') })
await page.locator('.device-grid').screenshot({ path: path.join(outputDir, '04-device-after.png') })

await runOfflineFallback(page)
await page.screenshot({ path: path.join(outputDir, '05-offline-fallback.png'), fullPage: true })

await browser.close()
