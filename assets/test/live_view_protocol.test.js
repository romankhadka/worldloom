import assert from "node:assert/strict"
import test from "node:test"

import {liveViewEventValue, socketCloseError} from "../../load/live_view_protocol.js"

test("encodes LiveView form values like a browser form submission", () => {
  assert.equal(
    liveViewEventValue({gesture: "tug", lane: "0.5"}, "form"),
    "gesture=tug&lane=0.5",
  )
  assert.equal(
    liveViewEventValue({note: "warm light", lane: 0.75}, "form"),
    "note=warm%20light&lane=0.75",
  )
})

test("preserves click values and already encoded form text", () => {
  const click = {sequence: 42}
  assert.equal(liveViewEventValue(click, "click"), click)
  assert.equal(liveViewEventValue("gesture=knot&lane=0.25", "form"), "gesture=knot&lane=0.25")
})

test("classifies only a close before client leave as unexpected", () => {
  assert.equal(socketCloseError(true), null)
  assert.equal(socketCloseError(false), "websocket closed before the LiveView client left")
})
