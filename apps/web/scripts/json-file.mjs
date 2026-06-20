import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

const nonAsciiPattern = /[^\x00-\x7F]/gu

export async function writeJsonFile(file, value) {
  await mkdir(path.dirname(file), { recursive: true })
  await writeFile(file, `${toAsciiJson(value)}\n`, 'utf8')
}

export function toAsciiJson(value) {
  return JSON.stringify(value, null, 2).replace(nonAsciiPattern, escapeJsonCodePoint)
}

export function assertAsciiSafeJsonText(text, label) {
  nonAsciiPattern.lastIndex = 0
  const hasNonAscii = nonAsciiPattern.test(text)
  nonAsciiPattern.lastIndex = 0
  if (hasNonAscii) {
    throw new Error(`${label} must be ASCII-safe JSON`)
  }
}

function escapeJsonCodePoint(char) {
  const codePoint = char.codePointAt(0)
  if (codePoint <= 0xffff) {
    return `\\u${codePoint.toString(16).padStart(4, '0')}`
  }

  const shifted = codePoint - 0x10000
  const high = 0xd800 + (shifted >> 10)
  const low = 0xdc00 + (shifted & 0x3ff)
  return `\\u${high.toString(16).padStart(4, '0')}\\u${low.toString(16).padStart(4, '0')}`
}
