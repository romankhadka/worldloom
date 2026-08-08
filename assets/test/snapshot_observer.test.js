import assert from "node:assert/strict"
import test from "node:test"

import {mergeSnapshotObservations} from "../../load/snapshot_observer.js"

test("records committed display and memory sequences without inferring gaps", () => {
  const initialObservations = {}

  const observedAt = mergeSnapshotObservations(initialObservations, {
    display_events: [{sequence: 10}, {sequence: 12}],
    memory_events: [{sequence: 7}],
    ambient: {sequence: 13},
    scaffold: [{sequence: 8}],
  }, 1_000)

  assert.deepEqual(initialObservations, {})
  assert.deepEqual(observedAt, {7: 1_000, 10: 1_000, 12: 1_000})
  assert.equal(observedAt[11], undefined)
  assert.equal(observedAt[13], undefined)
})

test("ignores malformed snapshot roles and entries safely", () => {
  let observedAt = {}

  for (const envelope of [
    null,
    {},
    {display_events: null, memory_events: {}},
    {
      display_events: [null, {}, {sequence: 0}, {sequence: -1}, {sequence: "4"}],
      memory_events: [{sequence: Number.MAX_SAFE_INTEGER + 1}, {sequence: Number.NaN}],
    },
  ]) {
    assert.doesNotThrow(() => {
      observedAt = mergeSnapshotObservations(observedAt, envelope, 2_000)
    })
  }

  assert.deepEqual(observedAt, {})
})

test("keeps the first observation time when a sequence appears again", () => {
  let observedAt = {}
  observedAt = mergeSnapshotObservations(observedAt, {
    display_events: [{sequence: 41}, {sequence: 41}],
    memory_events: [{sequence: 41}],
  }, 3_000)

  observedAt = mergeSnapshotObservations(observedAt, {
    display_events: [],
    memory_events: [{sequence: 41}],
  }, 9_000)

  assert.deepEqual(observedAt, {41: 3_000})
})
