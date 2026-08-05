import assert from "node:assert/strict"
import test from "node:test"

import {signalPalette} from "../js/worldloom/geometry.js"
import {laneFromClientY, withinLiveEdgeTarget} from "../js/worldloom/placement.js"

test("the four signal families have fixed accessible palette roles", () => {
  assert.deepEqual(Object.keys(signalPalette), ["wikimedia", "usgs", "open_meteo", "visitor"])
})

test("the live-edge placement surface remains importable without a DOM", () => {
  const bounds = {left: 0, top: 0, width: 800, height: 600}
  assert.equal(withinLiveEdgeTarget(790, bounds), true)
  assert.equal(laneFromClientY(300, bounds), 0.5)
})
