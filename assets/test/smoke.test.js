import assert from "node:assert/strict"
import test from "node:test"

import {signalPalette} from "../js/worldloom/geometry.js"

test("the four signal families have fixed accessible palette roles", () => {
  assert.deepEqual(Object.keys(signalPalette), ["wikimedia", "usgs", "open_meteo", "visitor"])
})
