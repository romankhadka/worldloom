import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const css = await readFile(new URL("../css/app.css", import.meta.url), "utf8")
const expectedTokens = new Map([
  ["lacquer-deep", "#120708"], ["lacquer", "#241013"], ["wine", "#35171a"],
  ["wine-raised", "#4b2020"], ["bone", "#f6e2c5"], ["parchment", "#cbb89f"],
  ["saffron", "#e3a53a"], ["jade", "#4db69a"], ["periwinkle", "#9a84c7"],
  ["mineral-blue", "#6c9bad"], ["marigold", "#e0a43b"], ["moonstone", "#c7ddd6"],
  ["copper", "#e07245"], ["olive-jade", "#8da56e"], ["visitor", "#ffe8c9"],
  ["health-live", "#86d29d"], ["health-disconnected", "#f08268"],
  ["health-disabled", "#9f8c82"],
])
const expectedRgbCompanions = new Map([
  ["lacquer-deep-rgb", "18 7 8"], ["lacquer-rgb", "36 16 19"],
  ["wine-rgb", "53 23 26"], ["wine-raised-rgb", "75 32 32"],
  ["bone-rgb", "246 226 197"], ["parchment-rgb", "203 184 159"],
  ["saffron-rgb", "227 165 58"], ["jade-rgb", "77 182 154"],
  ["copper-rgb", "224 114 69"], ["olive-jade-rgb", "141 165 110"],
])
const expectedThemeMirrors = new Map([
  ["lacquer", "#241013"], ["bone", "#f6e2c5"], ["jade", "#4db69a"],
  ["copper", "#e07245"], ["olive-jade", "#8da56e"], ["saffron", "#e3a53a"],
])

function declarationBlock(selector) {
  const escapedSelector = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const match = css.match(new RegExp(`${escapedSelector}\\s*\\{([^}]*)\\}`))
  assert.ok(match, `missing CSS declaration block for ${selector}`)
  return match[1]
}

test("declares every approved Lacquered Gallery token", () => {
  for (const [name, color] of expectedTokens) {
    assert.match(css.toLowerCase(), new RegExp(`--loom-${name}:\\s*${color}`))
  }
})

test("declares every approved RGB companion", () => {
  for (const [name, channels] of expectedRgbCompanions) {
    const channelPattern = channels.split(" ").join("\\s+")
    assert.match(css, new RegExp(`--loom-${name}:\\s*${channelPattern}\\s*;`))
  }
})

test("mirrors the approved foundation colors into the Tailwind theme", () => {
  const theme = declarationBlock("@theme")
  for (const [name, color] of expectedThemeMirrors) {
    assert.match(theme.toLowerCase(), new RegExp(`--color-loom-${name}:\\s*${color}\\s*;`))
  }
})

test("removes the previous foundation colors", () => {
  for (const legacy of [
    "#07110f", "#030806", "#69ded5", "#f0925e", "#849d68", "#d5bd78",
    "#f5ecd8", "#a3aea7", "#0a1511", "#ba9cf3", "#82dce6", "#efb85e", "#e8f5ec",
  ]) assert.equal(css.toLowerCase().includes(legacy), false, legacy)

  for (const legacyChannels of [
    "3 8 6", "5 14 12", "105 222 213", "132 157 104", "213 189 120",
    "240 146 94", "245 236 216", "250 244 228", "255 250 238", "246 207 127",
    "147 226 195", "245 159 121",
  ]) assert.equal(css.includes(legacyChannels), false, legacyChannels)
})

test("routes component colors through semantic tokens", () => {
  const componentStart = css.indexOf("@property --cooldown-progress")
  assert.ok(componentStart >= 0, "missing @property --cooldown-progress sentinel")
  const componentRules = css.slice(componentStart)
  assert.equal(/#[0-9a-f]{3,8}/i.test(componentRules), false)
  assert.match(declarationBlock(".worldloom-shell"), /var\(--loom-lacquer-deep\)/)
  assert.match(declarationBlock(".gesture-button:hover"), /var\(--loom-wine-raised\)/)
  assert.match(declarationBlock('[data-health-state="live"] .legend-health'), /var\(--loom-health-live\)/)
  assert.match(declarationBlock('[data-shape="intervention"]'), /var\(--loom-visitor\)/)
})
