import { mkdir } from 'node:fs/promises'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'

const sourceSvg = process.argv[2]
const outputPng = process.argv[3]

if (!sourceSvg || !outputPng) {
  throw new Error('Usage: node scripts/export-cover.mjs <source-svg> <output-png>')
}

await mkdir(path.dirname(outputPng), { recursive: true })

const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1 })

await page.goto(pathToFileURL(path.resolve(sourceSvg)).toString(), { waitUntil: 'networkidle' })
await page.screenshot({ path: outputPng, fullPage: false, omitBackground: false, timeout: 60000 })
await browser.close()
