import assert from "node:assert/strict"
import test from "node:test"

import {
  clientYForLane,
  laneFromClientY,
  withinLiveEdgeTarget,
} from "../js/worldloom/placement.js"

const bounds = {left: 20, top: 100, width: 1000, height: 600}

test("maps pointer height to the padded normalized lane", () => {
  const rawOneEighthLaneY = bounds.top + 40 + (bounds.height - 80) * 0.125

  assert.equal(laneFromClientY(140, bounds), 0)
  assert.equal(laneFromClientY(400, bounds), 0.5)
  assert.equal(laneFromClientY(660, bounds), 1)
  assert.equal(laneFromClientY(-100, bounds), 0)
  assert.equal(laneFromClientY(900, bounds), 1)
  assert.equal(laneFromClientY(rawOneEighthLaneY, bounds), 0.15)
})

test("reverses a lane into the same live-edge height", () => {
  for (let laneIndex = 0; laneIndex <= 20; laneIndex++) {
    const lane = laneIndex / 20
    const clientY = clientYForLane(lane, bounds)
    assert.equal(laneFromClientY(clientY, bounds), lane)
  }
})

test("limits direct placement to the live-edge target", () => {
  assert.equal(withinLiveEdgeTarget(990, bounds), true)
  assert.equal(withinLiveEdgeTarget(930, bounds), false)
  assert.equal(withinLiveEdgeTarget(956, bounds), true)
  assert.equal(withinLiveEdgeTarget(1020, bounds), true)
  assert.equal(withinLiveEdgeTarget(955, bounds), false)
  assert.equal(withinLiveEdgeTarget(1021, bounds), false)
})
