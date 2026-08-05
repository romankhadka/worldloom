import assert from "node:assert/strict"
import test from "node:test"

import {viewerHoldMsFor} from "../../load/viewer_profile.js"

test("holds local-100 viewers for the complete capacity run", () => {
  assert.equal(viewerHoldMsFor("local-100"), 3 * 60 * 1_000)
})

test("preserves existing long-running profile hold durations", () => {
  assert.equal(viewerHoldMsFor("launch"), 35 * 60 * 1_000)
  assert.equal(viewerHoldMsFor("local"), 6 * 60 * 1_000)
})

test("uses the short hold for smoke and unspecified profiles", () => {
  assert.equal(viewerHoldMsFor("smoke"), 2_000)
  assert.equal(viewerHoldMsFor("future-profile"), 2_000)
})
