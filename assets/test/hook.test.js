import assert from "node:assert/strict"
import test from "node:test"

import {
  selectedSequenceFromClick,
  shouldClearSelectionFromClick,
} from "../js/worldloom/hook.js"

test("stops propagation only when a canvas click selects a formation", () => {
  let stopped = false
  const event = {
    clientX: 45,
    clientY: 70,
    stopPropagation() {
      stopped = true
    },
  }
  const element = {
    getBoundingClientRect: () => ({left: 20, top: 30}),
  }
  const renderer = {
    hitTest(x, y) {
      assert.deepEqual([x, y], [25, 40])
      return 17
    },
  }

  assert.equal(selectedSequenceFromClick(event, element, renderer), 17)
  assert.equal(stopped, true)
})

test("lets a canvas click without a formation continue propagating", () => {
  let stopped = false
  const event = {
    clientX: 45,
    clientY: 70,
    stopPropagation() {
      stopped = true
    },
  }
  const element = {
    getBoundingClientRect: () => ({left: 20, top: 30}),
  }
  const renderer = {hitTest: () => null}

  assert.equal(selectedSequenceFromClick(event, element, renderer), null)
  assert.equal(stopped, false)
})

test("classifies only ordinary clicks outside formation detail for dismissal", () => {
  const detailTarget = target("detail")
  const accessibleTarget = target("accessible")
  const outsideTarget = target("outside")
  const detail = {
    contains: candidate => candidate === detailTarget,
  }

  assert.equal(shouldClearSelectionFromClick({target: outsideTarget}, null), false)
  assert.equal(shouldClearSelectionFromClick({target: detailTarget}, detail), false)
  assert.equal(shouldClearSelectionFromClick({target: accessibleTarget}, detail), false)
  assert.equal(shouldClearSelectionFromClick({target: outsideTarget}, detail), true)
})

function target(location) {
  return {
    closest(selector) {
      return selector === "#accessible-formations" && location === "accessible" ? {} : null
    },
  }
}
