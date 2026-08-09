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
