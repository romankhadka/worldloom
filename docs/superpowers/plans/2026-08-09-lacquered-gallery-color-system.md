# Lacquered Gallery Color System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Worldloom's green-black and cyan visual system with the approved Lacquered Gallery palette across Canvas, CSS, metadata, favicon, deterministic browser baselines, and social presentation without changing behavior or layout.

**Architecture:** Put every Canvas material in one immutable JavaScript palette module and every DOM material behind semantic CSS custom properties. Geometry and rendering consume the JavaScript palette; app-wide interface rules consume CSS tokens. Existing deterministic fixtures, contrast checks, visual baselines, metadata tests, and release gates prove that the color-only change preserves structure, behavior, accessibility, and portability.

**Tech Stack:** Phoenix 1.8, LiveView 1.2, HEEx, Tailwind CSS 4 plus custom CSS, Canvas 2D, ECMAScript modules, Node 24 test runner, Playwright 1.62, LazyHTML, ExUnit.

---

## File map

- `assets/js/worldloom/palette.js` — new immutable source and Canvas-interface material contract.
- `assets/js/worldloom/geometry.js` — consumes source materials; no longer owns color literals.
- `assets/js/worldloom/renderer.js` — consumes fallback, target, selection, and viewer materials.
- `assets/css/app.css` — owns the Lacquered Gallery DOM token system and all app-wide surface/state styling.
- `assets/test/palette.test.js` — proves exact Canvas mappings and prevents color literals from leaking back into geometry or rendering.
- `assets/test/color_system.test.js` — proves the semantic CSS foundation, legacy-color removal, and token usage.
- `assets/test/smoke.test.js` — imports the relocated source palette contract.
- `assets/test/geometry.test.js` — imports the relocated source palette contract.
- `assets/test/renderer.test.js` — imports the relocated source palette contract.
- `lib/worldloom_web/components/layouts/root.html.heex` — publishes the lacquer browser color and truthful preview description.
- `priv/static/images/logo.svg` — recolors existing artwork to approved copper without changing geometry.
- `test/worldloom_web/controllers/page_metadata_test.exs` — proves metadata and favicon presentation.
- `e2e/worldloom.spec.js` — proves rendered tokens, composed contrast, states, responsive layouts, and deterministic appearance.
- `e2e/worldloom.spec.js-snapshots/*.png` — accepted Darwin and Linux Lacquered Gallery visual baselines.
- `priv/static/images/worldloom-social-preview.png` — verified 1600-by-900 application capture.

## Task 1: Centralize the Canvas material contract

**Files:**
- Create: `assets/js/worldloom/palette.js`
- Create: `assets/test/palette.test.js`
- Modify: `assets/js/worldloom/geometry.js:1-14`
- Modify: `assets/js/worldloom/renderer.js:1-2, 833-834, 1170, 1185, 1211`
- Modify: `assets/test/smoke.test.js:1-5`
- Modify: `assets/test/geometry.test.js:1-15`
- Modify: `assets/test/renderer.test.js:1-7`

- [ ] **Step 1: Write the failing Canvas palette contract**

Create `assets/test/palette.test.js`:

```javascript
import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

import {canvasPalette, signalPalette} from "../js/worldloom/palette.js"

test("defines the approved Lacquered Gallery signal materials", () => {
  assert.deepEqual(signalPalette, {
    wikimedia: {family: "aged-jade", stroke: "#4db69a", glow: "#9ce6d0"},
    bluesky: {family: "smoky-periwinkle", stroke: "#9a84c7", glow: "#d4c5f1"},
    ripe_ris: {family: "mineral-blue", stroke: "#6c9bad", glow: "#b9dce5"},
    solana: {family: "marigold", stroke: "#e0a43b", glow: "#f5cf7a"},
    drand: {family: "moonstone", stroke: "#c7ddd6", glow: "#f2efe2"},
    usgs: {family: "copper", stroke: "#e07245", glow: "#ffb080"},
    open_meteo: {family: "olive-jade", stroke: "#8da56e", glow: "#c5c77c"},
    visitor: {family: "bright-bone", stroke: "#ffe8c9", glow: "#fff4df"},
  })
})

test("defines the approved Canvas interface materials", () => {
  assert.deepEqual(canvasPalette, {
    fallback: "#ffe8c9",
    targetSeed: "#ffe8c9",
    selectionHalo: "#e3a53a",
    viewerPulse: "#f6e2c5",
  })
})

test("geometry and renderer contain no private color literals", async () => {
  const sources = await Promise.all([
    readFile(new URL("../js/worldloom/geometry.js", import.meta.url), "utf8"),
    readFile(new URL("../js/worldloom/renderer.js", import.meta.url), "utf8"),
  ])

  for (const source of sources) assert.equal(/#[0-9a-f]{3,8}/i.test(source), false)
})
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
rtk node --test assets/test/palette.test.js
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `assets/js/worldloom/palette.js`.

- [ ] **Step 3: Add the immutable palette module**

Create `assets/js/worldloom/palette.js`:

```javascript
function freezePalette(palette) {
  return Object.freeze(
    Object.fromEntries(
      Object.entries(palette).map(([name, material]) => [name, Object.freeze(material)]),
    ),
  )
}

export const signalPalette = freezePalette({
  wikimedia: {family: "aged-jade", stroke: "#4db69a", glow: "#9ce6d0"},
  bluesky: {family: "smoky-periwinkle", stroke: "#9a84c7", glow: "#d4c5f1"},
  ripe_ris: {family: "mineral-blue", stroke: "#6c9bad", glow: "#b9dce5"},
  solana: {family: "marigold", stroke: "#e0a43b", glow: "#f5cf7a"},
  drand: {family: "moonstone", stroke: "#c7ddd6", glow: "#f2efe2"},
  usgs: {family: "copper", stroke: "#e07245", glow: "#ffb080"},
  open_meteo: {family: "olive-jade", stroke: "#8da56e", glow: "#c5c77c"},
  visitor: {family: "bright-bone", stroke: "#ffe8c9", glow: "#fff4df"},
})

export const canvasPalette = Object.freeze({
  fallback: "#ffe8c9",
  targetSeed: "#ffe8c9",
  selectionHalo: "#e3a53a",
  viewerPulse: "#f6e2c5",
})
```

In `geometry.js`, import the contract and delete the local `signalPalette` object:

```javascript
import {signalPalette} from "./palette.js"
import {xorshift32} from "./random.js"
import {buildTopology} from "./topology.js"
```

In `renderer.js`, extend the imports:

```javascript
import {commandsForScene, cubicPrefix, laneToY} from "./geometry.js"
import {canvasPalette} from "./palette.js"
```

Replace the five renderer literals exactly:

```javascript
context.strokeStyle = command.stroke ?? canvasPalette.fallback
context.fillStyle = command.glow ?? command.stroke ?? canvasPalette.fallback
context.fillStyle = canvasPalette.targetSeed
context.strokeStyle = canvasPalette.selectionHalo
context.fillStyle = canvasPalette.viewerPulse
```

Move the three test imports from `geometry.js` to `palette.js`; keep geometry-function imports from `geometry.js`:

```javascript
import {signalPalette} from "../js/worldloom/palette.js"
```

- [ ] **Step 4: Prove GREEN and run affected Canvas tests**

Run:

```bash
rtk node --test assets/test/palette.test.js assets/test/smoke.test.js assets/test/geometry.test.js assets/test/renderer.test.js
```

Expected: PASS with no warnings. Existing topology, geometry, material-layer, and rendering assertions remain unchanged.

- [ ] **Step 5: Commit the Canvas contract**

```bash
rtk git add assets/js/worldloom/palette.js assets/js/worldloom/geometry.js assets/js/worldloom/renderer.js assets/test/palette.test.js assets/test/smoke.test.js assets/test/geometry.test.js assets/test/renderer.test.js
rtk git commit -m "Centralize Lacquered Gallery canvas materials"
```

## Task 2: Apply Lacquered Gallery across the DOM

**Files:**
- Create: `assets/test/color_system.test.js`
- Modify: `assets/css/app.css:13-1389`

- [ ] **Step 1: Write the failing CSS token contract**

Create `assets/test/color_system.test.js`:

```javascript
import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const css = await readFile(new URL("../css/app.css", import.meta.url), "utf8")
const expectedTokens = new Map([
  ["lacquer-deep", "#120708"],
  ["lacquer", "#241013"],
  ["wine", "#35171a"],
  ["wine-raised", "#4b2020"],
  ["bone", "#f6e2c5"],
  ["parchment", "#cbb89f"],
  ["saffron", "#e3a53a"],
  ["jade", "#4db69a"],
  ["periwinkle", "#9a84c7"],
  ["mineral-blue", "#6c9bad"],
  ["marigold", "#e0a43b"],
  ["moonstone", "#c7ddd6"],
  ["copper", "#e07245"],
  ["olive-jade", "#8da56e"],
  ["visitor", "#ffe8c9"],
  ["health-live", "#86d29d"],
  ["health-disconnected", "#f08268"],
  ["health-disabled", "#9f8c82"],
])

test("declares every approved Lacquered Gallery token", () => {
  for (const [name, color] of expectedTokens) {
    assert.match(css.toLowerCase(), new RegExp(`--loom-${name}:\\s*${color}`))
  }
})

test("removes the previous foundation colors", () => {
  for (const legacy of [
    "#07110f", "#030806", "#69ded5", "#f0925e", "#849d68", "#d5bd78",
    "#f5ecd8", "#a3aea7", "#0a1511", "#ba9cf3", "#82dce6", "#efb85e",
    "#e8f5ec",
  ]) {
    assert.equal(css.toLowerCase().includes(legacy), false, legacy)
  }

  for (const legacyChannels of [
    "3 8 6", "5 14 12", "105 222 213", "132 157 104", "213 189 120",
    "240 146 94", "245 236 216", "250 244 228", "255 250 238", "246 207 127",
    "147 226 195", "245 159 121",
  ]) {
    assert.equal(css.includes(legacyChannels), false, legacyChannels)
  }
})

test("routes component colors through semantic tokens", () => {
  const componentRules = css.slice(css.indexOf("@property --cooldown-progress"))
  assert.equal(/#[0-9a-f]{3,8}/i.test(componentRules), false)
  assert.match(css, /\.worldloom-shell\s*\{[\s\S]*var\(--loom-lacquer-deep\)/)
  assert.match(css, /\.gesture-button:hover\s*\{[\s\S]*var\(--loom-wine-raised\)/)
  assert.match(css, /\[data-health-state="live"\][\s\S]*var\(--loom-health-live\)/)
  assert.match(css, /\[data-shape="intervention"\][\s\S]*var\(--loom-visitor\)/)
})
```

- [ ] **Step 2: Run the test and verify RED**

```bash
rtk node --test assets/test/color_system.test.js
```

Expected: FAIL because the Lacquered Gallery token declarations are absent and legacy colors remain.

- [ ] **Step 3: Replace the foundation with semantic tokens**

Replace the current `@theme` color declarations and `:root` block with this exact contract:

```css
@theme {
  --font-display: "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif;
  --font-interface: "Avenir Next", Avenir, "Segoe UI", sans-serif;
  --color-loom-lacquer: #241013;
  --color-loom-bone: #f6e2c5;
  --color-loom-jade: #4db69a;
  --color-loom-copper: #e07245;
  --color-loom-olive-jade: #8da56e;
  --color-loom-saffron: #e3a53a;
}

:root {
  --loom-lacquer-deep: #120708;
  --loom-lacquer-deep-rgb: 18 7 8;
  --loom-lacquer: #241013;
  --loom-lacquer-rgb: 36 16 19;
  --loom-wine: #35171a;
  --loom-wine-rgb: 53 23 26;
  --loom-wine-raised: #4b2020;
  --loom-wine-raised-rgb: 75 32 32;
  --loom-bone: #f6e2c5;
  --loom-bone-rgb: 246 226 197;
  --loom-parchment: #cbb89f;
  --loom-parchment-rgb: 203 184 159;
  --loom-saffron: #e3a53a;
  --loom-saffron-rgb: 227 165 58;
  --loom-jade: #4db69a;
  --loom-jade-rgb: 77 182 154;
  --loom-periwinkle: #9a84c7;
  --loom-mineral-blue: #6c9bad;
  --loom-marigold: #e0a43b;
  --loom-moonstone: #c7ddd6;
  --loom-copper: #e07245;
  --loom-copper-rgb: 224 114 69;
  --loom-olive-jade: #8da56e;
  --loom-olive-jade-rgb: 141 165 110;
  --loom-visitor: #ffe8c9;
  --loom-health-live: #86d29d;
  --loom-health-disconnected: #f08268;
  --loom-health-disabled: #9f8c82;
  --loom-panel: rgb(var(--loom-wine-rgb) / 88%);
  --loom-border: rgb(var(--loom-saffron-rgb) / 24%);
}
```

- [ ] **Step 4: Migrate every component rule through the token system**

Perform these exact semantic replacements throughout `app.css`:

| Previous role or literal family | Replacement |
|---|---|
| `var(--loom-deep)` / `rgb(3 8 6 / A)` | `var(--loom-lacquer-deep)` / `rgb(var(--loom-lacquer-deep-rgb) / A)` |
| `var(--loom-ink)` / `#0a1511` | `var(--loom-lacquer)` / `var(--loom-wine)` |
| `var(--loom-ivory)` / `rgb(245 236 216 / A)` | `var(--loom-bone)` / `rgb(var(--loom-bone-rgb) / A)` |
| `var(--loom-muted)` | `var(--loom-parchment)` |
| `var(--loom-cyan)` / `rgb(105 222 213 / A)` | `var(--loom-jade)` / `rgb(var(--loom-jade-rgb) / A)` |
| `var(--loom-ember)` / `rgb(240 146 94 / A)` | `var(--loom-copper)` / `rgb(var(--loom-copper-rgb) / A)` |
| `var(--loom-moss)` / `rgb(132 157 104 / A)` | `var(--loom-olive-jade)` / `rgb(var(--loom-olive-jade-rgb) / A)` |
| `var(--loom-gold)` / `rgb(213 189 120 / A)` | `var(--loom-saffron)` / `rgb(var(--loom-saffron-rgb) / A)` |
| neutral black shadows `rgb(0 0 0 / A)` | `rgb(var(--loom-lacquer-deep-rgb) / A)` |
| `rgb(250 244 228 / A)`, `rgb(255 250 238 / A)`, or `white` used as text | `rgb(var(--loom-bone-rgb) / A)` or `var(--loom-bone)` |
| `rgb(246 207 127 / A)` | `rgb(var(--loom-saffron-rgb) / A)` |
| `rgb(147 226 195 / A)` | `var(--loom-health-live)` |
| `rgb(245 159 121 / A)` | `var(--loom-health-disconnected)` |
| `#ba9cf3` | `var(--loom-periwinkle)` |
| `#82dce6` | `var(--loom-mineral-blue)` |
| `#efb85e` | `var(--loom-marigold)` |
| `#e8f5ec` | `var(--loom-moonstone)` |

Use these exact high-value component treatments:

```css
.worldloom-shell {
  background:
    radial-gradient(ellipse at 74% 42%, rgb(var(--loom-jade-rgb) / 16%), transparent 34%),
    radial-gradient(ellipse at 20% 76%, rgb(var(--loom-copper-rgb) / 13%), transparent 40%),
    radial-gradient(ellipse at 52% 110%, rgb(var(--loom-saffron-rgb) / 11%), transparent 44%),
    linear-gradient(150deg, var(--loom-lacquer-deep), var(--loom-lacquer) 46%, var(--loom-wine));
}

.worldloom-header {
  border: 0;
  background: linear-gradient(to bottom, rgb(var(--loom-lacquer-rgb) / 86%), transparent);
  box-shadow: inset 0 -1px rgb(var(--loom-saffron-rgb) / 16%);
}

.worldloom-panel,
#mobile-detail-sheet,
.gesture-dock {
  border: 1px solid var(--loom-border);
  background: var(--loom-panel);
  box-shadow: 0 24px 80px rgb(var(--loom-lacquer-deep-rgb) / 48%);
}

.gesture-button:hover {
  background: rgb(var(--loom-wine-raised-rgb) / 78%);
  color: var(--loom-bone);
}

.gesture-button[data-gesture="illuminate"] {
  background: rgb(var(--loom-saffron-rgb) / 7%);
  box-shadow: inset 0 0 0 1px rgb(var(--loom-saffron-rgb) / 18%);
}

.gesture-button[data-gesture="illuminate"]:hover {
  background: rgb(var(--loom-saffron-rgb) / 13%);
}

[data-health-state="live"] .legend-health { color: var(--loom-health-live); }
[data-health-state="disabled"] .legend-health { color: var(--loom-health-disabled); }
[data-health-state="disconnected"] .legend-health { color: var(--loom-health-disconnected); }

[data-shape="strand"] { color: var(--loom-jade); }
[data-shape="fan"] { color: var(--loom-periwinkle); }
[data-shape="fork"] { color: var(--loom-mineral-blue); }
[data-shape="beads"] { color: var(--loom-marigold); }
[data-shape="crystal"] { color: var(--loom-moonstone); }
[data-shape="rupture"] { color: var(--loom-copper); }
[data-shape="atmosphere"] { color: var(--loom-olive-jade); }
[data-shape="intervention"] { color: var(--loom-visitor); }
```

Preserve the complete `@media (forced-colors: active)` block. Preserve all dimensions, positioning, typography, animation timing, pointer behavior, responsive breakpoints, and reduced-motion behavior.

- [ ] **Step 5: Prove GREEN and run the complete JavaScript suite**

```bash
rtk npm test
```

Expected: PASS. The CSS contract reports no legacy foundation colors or component-level hex literals.

- [ ] **Step 6: Commit the app-wide interface**

```bash
rtk git add assets/css/app.css assets/test/color_system.test.js
rtk git commit -m "Apply Lacquered Gallery across the interface"
```

## Task 3: Align browser theme and favicon presentation

**Files:**
- Modify: `test/worldloom_web/controllers/page_metadata_test.exs:54-83`
- Modify: `lib/worldloom_web/components/layouts/root.html.heex:14`
- Modify: `priv/static/images/logo.svg:4`

- [ ] **Step 1: Update metadata tests first**

Change only the expected browser theme color, then add a favicon assertion:

```elixir
assert document
       |> LazyHTML.query("meta[name='theme-color'][content='#120708']")
       |> Enum.count() == 1
```

Add this test:

```elixir
test "serves copper Worldloom favicon artwork", %{conn: conn} do
  response = get(conn, "/images/logo.svg")

  assert response.status == 200
  assert get_resp_header(response, "content-type") == ["image/svg+xml"]
  assert response.resp_body =~ ~s(fill="#E07245")
  refute response.resp_body =~ "#FD4F00"
end
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
rtk mix test test/worldloom_web/controllers/page_metadata_test.exs
```

Expected: FAIL on old `#07110f` and old favicon fill. The existing preview alternative text remains unchanged because it still describes the existing social preview PNG truthfully.

- [ ] **Step 3: Implement the exact browser presentation contract**

In `root.html.heex` use:

```heex
<meta name="theme-color" content="#120708" />
```

In `logo.svg`, preserve the complete path and change only:

```svg
fill="#E07245"
```

- [ ] **Step 4: Prove GREEN**

```bash
rtk mix test test/worldloom_web/controllers/page_metadata_test.exs
```

Expected: all metadata, preview-serving, and favicon tests pass.

- [ ] **Step 5: Commit the public metadata**

```bash
rtk git add test/worldloom_web/controllers/page_metadata_test.exs lib/worldloom_web/components/layouts/root.html.heex priv/static/images/logo.svg
rtk git commit -m "Align Worldloom metadata with Lacquered Gallery"
```

## Task 4: Prove the rendered palette and accept deterministic baselines

**Files:**
- Modify: `assets/css/app.css:685-700`
- Modify: `e2e/worldloom.spec.js:130-225, 767-1011`
- Modify: `e2e/worldloom.spec.js-snapshots/*.png`

- [ ] **Step 1: Add the rendered token and interaction-state contract**

After the existing opening-composition test, add:

```javascript
test("Lacquered Gallery reaches the rendered interface and interaction states", async ({page}) => {
  await openWorldloom(page)

  const palette = await page.evaluate(() => {
    const root = getComputedStyle(document.documentElement)
    return Object.fromEntries([
      "lacquer-deep", "lacquer", "wine", "wine-raised", "bone", "parchment",
      "saffron", "jade", "copper", "health-live", "health-disconnected",
    ].map(name => [name, root.getPropertyValue(`--loom-${name}`).trim().toLowerCase()]))
  })

  expect(palette).toEqual({
    "lacquer-deep": "#120708",
    lacquer: "#241013",
    wine: "#35171a",
    "wine-raised": "#4b2020",
    bone: "#f6e2c5",
    parchment: "#cbb89f",
    saffron: "#e3a53a",
    jade: "#4db69a",
    copper: "#e07245",
    "health-live": "#86d29d",
    "health-disconnected": "#f08268",
  })

  const illuminate = page.getByRole("button", {name: "Illuminate", exact: true})
  await illuminate.hover()
  expect(await contrastForElement(page, "#gesture-illuminate")).toBeGreaterThanOrEqual(4.5)
  await illuminate.focus()
  await expect(illuminate).toBeFocused()
  expect(await page.locator("#gesture-illuminate").evaluate(element =>
    getComputedStyle(element).outlineColor,
  )).toBe("rgb(227, 165, 58)")
})
```

Add this helper beside `localContrastContract`:

```javascript
async function contrastForElement(page, selector) {
  return page.locator(selector).evaluate(element => {
    const root = getComputedStyle(document.documentElement)
    const style = getComputedStyle(element)
    const containerStyle = getComputedStyle(element.closest("#gesture-dock"))
    const worstFoundation = parseColor(
      root.getPropertyValue("--loom-wine-raised"),
    )
    const containerColor = parseColor(containerStyle.backgroundColor)
    const elementColor = parseColor(style.backgroundColor)
    const textColor = parseColor(style.color)
    const containerBackdrop = blend(
      containerColor.rgb,
      worstFoundation.rgb,
      containerColor.alpha,
    )
    const elementBackdrop = blend(
      elementColor.rgb,
      containerBackdrop,
      elementColor.alpha,
    )
    const effectiveText = blend(
      textColor.rgb,
      elementBackdrop,
      textColor.alpha,
    )

    return contrast(effectiveText, elementBackdrop)

    function parseColor(color) {
      const normalized = color.trim()

      if (normalized.startsWith("#")) {
        const hex = normalized.slice(1)
        const channels = hex.length === 3
          ? [...hex].map(channel => Number.parseInt(channel + channel, 16))
          : [0, 2, 4].map(offset => Number.parseInt(hex.slice(offset, offset + 2), 16))
        return {rgb: channels, alpha: 1}
      }

      const channels = normalized.match(/[\d.]+/g)?.map(Number)
      if (!channels || channels.length < 3) throw new Error(`Unsupported color: ${color}`)
      return {rgb: channels.slice(0, 3), alpha: channels[3] ?? 1}
    }

    function blend(foreground, background, alpha) {
      return foreground.map((channel, index) =>
        channel * alpha + background[index] * (1 - alpha),
      )
    }

    function contrast(first, second) {
      const brighter = Math.max(luminance(first), luminance(second))
      const darker = Math.min(luminance(first), luminance(second))
      return (brighter + 0.05) / (darker + 0.05)
    }

    function luminance(color) {
      const [red, green, blue] = color.map(channel => {
        const normalized = channel / 255
        return normalized <= 0.04045
          ? normalized / 12.92
          : ((normalized + 0.055) / 1.055) ** 2.4
      })
      return red * 0.2126 + green * 0.7152 + blue * 0.0722
    }
  })
}
```

Update the existing localized-contrast backing expectation from `[3, 8, 6]` to `[18, 7, 8]`. Replace `worstWeather = [139, 132, 82]` with the approved olive-jade `[141, 165, 110]`.

- [ ] **Step 2: Run focused browser tests and verify the intended RED**

```bash
rtk npm run test:e2e -- --grep "Lacquered Gallery|quiet labels|balanced-world visual release"
```

Expected: the new focus-color assertion fails because Illuminate still inherits the global jade outline, while visual-release cases fail because the accepted screenshots still contain the former palette. Token and composited-contrast assertions pass. Any selector, browser error, layout, or unrelated contrast failure must be fixed before updating baselines.

- [ ] **Step 3: Add the approved Illuminate focus treatment and prove interaction GREEN**

Add the interaction-specific focus treatment without changing the global focus contract:

```css
.gesture-button[data-gesture="illuminate"]:focus-visible {
  outline-color: var(--loom-saffron);
}
```

Re-run the focused command from Step 2. The token, contrast, focus, and quiet-label assertions must pass; only the expected visual-release snapshot mismatches may remain.

- [ ] **Step 4: Update Darwin visual baselines and inspect every image**

```bash
rtk npm run test:e2e -- --grep "balanced-world visual release" --update-snapshots
```

Inspect the updated original-resolution Darwin files in `e2e/worldloom.spec.js-snapshots/`. Accept them only when all of these are true:

- the foundation is oxblood/wine rather than green-black;
- panels are saturated but the weave remains the focal point;
- all eight signal materials remain distinct;
- bone and parchment text remain readable;
- desktop, tablet, mobile, outage, recovery, selection, and reduced-motion states are unclipped;
- no geometry, layout, copy, health semantics, or interaction changed.

- [ ] **Step 5: Produce exact Linux baselines through CI evidence**

Push the task branch after the Darwin review:

```bash
rtk git add assets/css/app.css e2e/worldloom.spec.js e2e/worldloom.spec.js-snapshots
rtk git commit -m "Accept Lacquered Gallery browser presentation"
rtk git push -u origin design-lacquered-gallery
```

Watch the branch CI. The Linux browser job is expected to report only snapshot mismatches against the still-old Linux baselines. Download `browser-failures-1`, map each Playwright `*-actual.png` artifact to its named `*-chromium-linux.png` baseline, inspect each original-resolution image against the checklist above, and replace only the corresponding Linux baselines. Do not accept missing elements, browser failures, unexpected response errors, layout movement, or non-snapshot failures.

Commit the reviewed Linux evidence:

```bash
rtk git add e2e/worldloom.spec.js-snapshots
rtk git commit -m "Record verified Linux Lacquered Gallery baselines"
rtk git push
```

Re-run or watch CI until the complete Linux browser job passes.

- [ ] **Step 6: Re-run the complete local browser suite**

```bash
rtk npm run test:e2e
```

Expected: all Playwright tests pass locally with no console, page, WebSocket, request, response, contrast, or screenshot failures.

## Task 5: Regenerate the truthful social preview

**Files:**
- Modify: `priv/static/images/worldloom-social-preview.png`
- Modify: `lib/worldloom_web/components/layouts/root.html.heex`
- Modify: `test/worldloom_web/controllers/page_metadata_test.exs`

- [ ] **Step 1: Write the failing truthful preview metadata contract**

In `page_metadata_test.exs`, change `expected_image_alt` to this exact approved description:

```elixir
expected_image_alt =
  "An oxblood, jade, copper, and saffron living weave above Worldloom's lacquered gesture dock."
```

Run:

```bash
rtk mix test test/worldloom_web/controllers/page_metadata_test.exs
```

Expected: FAIL because both `og:image:alt` and `twitter:image:alt` still truthfully describe the old cyan, ember, and olive preview.

- [ ] **Step 2: Start the isolated deterministic acceptance server**

Use an isolated managed terminal session:

```bash
rtk env MIX_BUILD_PATH=_build/social MIX_ENV=test WORLDLOOM_E2E=true WORLDLOOM_FEEDS_ENABLED=false mix ecto.reset
rtk env MIX_BUILD_PATH=_build/social MIX_ENV=test WORLDLOOM_E2E=true WORLDLOOM_FEEDS_ENABLED=false mix assets.build
rtk env MIX_BUILD_PATH=_build/social MIX_ENV=test WORLDLOOM_E2E=true WORLDLOOM_FEEDS_ENABLED=false mix phx.server
```

Wait for `http://localhost:4002/healthz` to return HTTP 200. This uses the same
feed-disabled acceptance harness as the verified browser suite, avoiding network
variance without presenting the public sources as disabled.

- [ ] **Step 3: Install the balanced world and capture the verified application**

Install the accepted balanced snapshot through the test-only scene route:

```bash
rtk node --input-type=module -e 'import {balanced} from "./assets/test/fixtures/balanced_snapshots.js"; const response = await fetch("http://localhost:4002/__e2e__/scenes/balanced", {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify({snapshot: balanced})}); if (!response.ok) throw new Error(`${response.status} ${await response.text()}`); console.log(await response.text())'
```

Verify the rendered summary reports all enabled sources live. Then, after
`#loom-canvas[data-ready='true']` is present, run:

```bash
rtk npx playwright screenshot --browser chromium --viewport-size "1600,900" --wait-for-selector "#loom-canvas[data-ready='true']" --wait-for-timeout 4000 http://localhost:4002 priv/static/images/worldloom-social-preview.png
```

Expected: a 1600-by-900 PNG captured from the application, not a concept mockup.

- [ ] **Step 4: Inspect the preview at original resolution**

Reject and recapture if it does not show oxblood/wine foundations, vivid jade/copper/saffron material, readable bone text, the living weave, all enabled sources live, and an unclipped gesture dock. Reject empty, loading, disabled, disconnected, chart-like, or mockup imagery.

- [ ] **Step 5: Align metadata with the accepted preview and prove GREEN**

Only after accepting the captured preview, use this exact content for both `og:image:alt` and `twitter:image:alt` in `root.html.heex`:

```text
An oxblood, jade, copper, and saffron living weave above Worldloom's lacquered gesture dock.
```

Run:

```bash
rtk mix test test/worldloom_web/controllers/page_metadata_test.exs
rtk file priv/static/images/worldloom-social-preview.png
```

Expected: all focused metadata tests pass and `file` reports a 1600-by-900 PNG.

- [ ] **Step 6: Commit the preview and its truthful metadata together**

```bash
rtk git add priv/static/images/worldloom-social-preview.png lib/worldloom_web/components/layouts/root.html.heex test/worldloom_web/controllers/page_metadata_test.exs
rtk git commit -m "Refresh Worldloom's Lacquered Gallery preview"
```

## Task 6: Run the complete release gate and integrate

**Files:**
- Modify only if verification exposes a defect; every code defect begins with a failing regression test.

- [ ] **Step 1: Scan for legacy and stray active colors**

```bash
rtk rg -n "#07110f|#030806|#69ded5|#f0925e|#849d68|#d5bd78|#f5ecd8|#a3aea7|#0a1511|#ba9cf3|#82dce6|#efb85e|#e8f5ec|#63d7d1|#b6fff8|#a991ff|#dcd2ff|#55b9ef|#bdeaff|#e4a746|#ffe0a1|#c4e6eb|#f1fdff|#ec8d55|#ffc08e|#8ba66d|#d3bb70|#f3ead4|#fff9e9" assets lib priv test e2e
```

Expected: no active legacy palette occurrence. Historical design documents and superseded screenshot binaries are outside this scan.

- [ ] **Step 2: Run independent local gates**

Run these suites, in parallel only when their database/build paths do not contend:

```bash
rtk npm test
rtk mix precommit
rtk npm run test:e2e
rtk docker build .
```

Expected: all JavaScript tests, all ExUnit tests, all Playwright tests, warnings-as-errors compilation, formatting, unused dependency checks, and the production container build pass.

- [ ] **Step 3: Review the complete branch diff**

```bash
rtk git status --short
rtk git diff master...HEAD --check
rtk git diff master...HEAD --stat
rtk git log --oneline master..HEAD
```

Expected: clean worktree; only the approved design, plan, color implementation, tests, metadata, favicon, screenshots, and preview differ. Commit messages describe outcomes in imperative language and contain no AI attribution.

- [ ] **Step 4: Obtain final independent reviews**

Dispatch one specification reviewer and one code-quality reviewer against `master...HEAD`. Resolve every substantiated finding with a failing regression test where behavior is involved, then rerun the affected suite and the complete gate.

- [ ] **Step 5: Verify remote CI on the final branch revision**

```bash
rtk git push
rtk gh run list --branch design-lacquered-gallery --limit 5
```

Expected: Elixir, JavaScript, Browser, and Container jobs pass on the final commit.

- [ ] **Step 6: Merge through worktrunk and verify master**

From the task worktree, preserve the reviewed meaningful commits:

```bash
rtk wt merge --no-squash --no-rebase master --yes
```

Then, from the primary Worldloom checkout:

```bash
rtk git status --short
rtk git log -1 --oneline
rtk git push origin master
```

Expected: the worktree branch merges cleanly, local `master` is clean, and `origin/master` contains the verified integrated revision.

- [ ] **Step 7: Restart and inspect localhost**

Restart Worldloom from `/Users/roman/code/worldloom` on port 4000, wait for `/healthz`, then inspect desktop and mobile live pages. Confirm Lacquered Gallery is visible and live signal/gesture behavior still operates. Do not claim the RIPE disconnect issue is fixed by this color-only change.
