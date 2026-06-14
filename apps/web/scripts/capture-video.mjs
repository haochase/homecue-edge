import { mkdir, rename, rm } from 'node:fs/promises'
import path from 'node:path'
import { chromium } from 'playwright'
import { openDemo, pause, runOfflineFallback, runOnlinePlan } from './demo-flow.mjs'

const outputFile = process.argv[2]
const appUrl = process.argv[3] ?? 'http://127.0.0.1:5173'
const apiBase = process.argv[4] ?? 'http://127.0.0.1:8723'
const subtitleMode = process.argv[5] ?? 'subtitled'

if (!outputFile) {
  throw new Error('Output video file argument is required.')
}

const outputDir = path.dirname(outputFile)
const viewport = { width: 1440, height: 810 }

await mkdir(outputDir, { recursive: true })
await rm(outputFile, { force: true })

const browser = await chromium.launch()
const context = await browser.newContext({
  viewport,
  recordVideo: {
    dir: outputDir,
    size: viewport,
  },
})
const page = await context.newPage()
const video = page.video()

try {
  await openDemo(page, appUrl, apiBase)
  await installSubtitleOverlay(page)
  await showSubtitle(page, 'HomeCue Edge turns local home context into a privacy-aware routine.')
  await pause(2200)
  await showSubtitle(page, 'Raw room, schedule, weather, and preference data stay at the edge.')
  await pause(2200)

  await showSubtitle(page, 'Run the agent: planning produces a structured routine, not free-form chat.')
  await runOnlinePlan(page)
  await pause(2200)
  await showSubtitle(page, 'The execution guard checks each proposed action before local device state changes.')
  await page.mouse.wheel(0, 650)
  await pause(2200)
  await page.mouse.wheel(0, -650)
  await pause(1000)

  await showSubtitle(page, 'Offline mode keeps the home responsive with a safe local fallback routine.')
  await runOfflineFallback(page)
  await pause(2200)
  await showSubtitle(page, 'This is the EdgeAgent pattern: sense locally, reason safely, act at home.')
  await page.mouse.wheel(0, 650)
  await pause(2200)
  await hideSubtitle(page)
} finally {
  await context.close()
  await browser.close()
}

if (!video) {
  throw new Error('Playwright did not create a video recording.')
}

const recordedPath = await video.path()
await rename(recordedPath, outputFile)

async function installSubtitleOverlay(page) {
  if (subtitleMode === 'silent') {
    return
  }

  await page.addStyleTag({
    content: `
      #homecue-demo-subtitle {
        position: fixed;
        left: 50%;
        bottom: 26px;
        z-index: 9999;
        max-width: 1120px;
        width: calc(100% - 96px);
        transform: translateX(-50%);
        padding: 18px 24px;
        border: 1px solid rgba(231, 239, 234, 0.34);
        border-radius: 16px;
        background: rgba(25, 39, 35, 0.9);
        color: #f7fbf6;
        box-shadow: 0 18px 44px rgba(20, 31, 28, 0.28);
        font: 800 26px/1.32 Arial, sans-serif;
        letter-spacing: 0;
        text-align: center;
        opacity: 0;
        pointer-events: none;
        transition: opacity 220ms ease;
      }
      #homecue-demo-subtitle.visible {
        opacity: 1;
      }
    `,
  })

  await page.evaluate(() => {
    const subtitle = document.createElement('div')
    subtitle.id = 'homecue-demo-subtitle'
    document.body.appendChild(subtitle)
  })
}

async function showSubtitle(page, text) {
  if (subtitleMode === 'silent') {
    return
  }

  await page.evaluate((subtitleText) => {
    const subtitle = document.querySelector('#homecue-demo-subtitle')
    subtitle.textContent = subtitleText
    subtitle.classList.add('visible')
  }, text)
}

async function hideSubtitle(page) {
  if (subtitleMode === 'silent') {
    return
  }

  await page.evaluate(() => {
    document.querySelector('#homecue-demo-subtitle')?.classList.remove('visible')
  })
}
