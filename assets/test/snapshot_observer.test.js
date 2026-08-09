import assert from "node:assert/strict"
import test from "node:test"

import {
  balancedSnapshotComplete,
  mergeBalancedSnapshotObservation,
  mergeSnapshotObservations,
} from "../../load/snapshot_observer.js"

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

test("records increasing snapshot watermarks and every public source role", () => {
  const initialObservation = {watermarks: [], sources: []}

  const firstObservation = mergeBalancedSnapshotObservation(
    initialObservation,
    {
      commit_watermark: 20,
      display_events: [
        {source: "wikimedia"},
        {source: "drand"},
        {source: "wikimedia"},
      ],
      memory_events: [{source: "usgs"}],
      ambient: {source: "open_meteo"},
    },
  )
  const completeObservation = mergeBalancedSnapshotObservation(
    firstObservation,
    {
      commit_watermark: 24,
      display_events: [{source: "bluesky"}, {source: "ripe_ris"}],
    },
  )

  assert.deepEqual(initialObservation, {watermarks: [], sources: []})
  assert.deepEqual(completeObservation, {
    watermarks: [20, 24],
    sources: [
      "wikimedia",
      "drand",
      "usgs",
      "open_meteo",
      "bluesky",
      "ripe_ris",
    ],
  })
  assert.equal(
    balancedSnapshotComplete(completeObservation, [
      "wikimedia",
      "drand",
      "usgs",
      "open_meteo",
      "bluesky",
      "ripe_ris",
    ]),
    true,
  )
})

test("rejects duplicate and decreasing watermarks without inventing source coverage", () => {
  let observation = {watermarks: [30], sources: ["wikimedia"]}

  for (const envelope of [
    {commit_watermark: 30, display_events: [{source: "drand"}]},
    {commit_watermark: 29, display_events: [{source: "bluesky"}]},
    {commit_watermark: 0, display_events: [{source: "ripe_ris"}]},
    {commit_watermark: "31", display_events: [{source: "solana"}]},
    {commit_watermark: 31, display_events: null},
  ]) {
    observation = mergeBalancedSnapshotObservation(observation, envelope)
  }

  assert.deepEqual(observation, {
    watermarks: [30, 31],
    sources: ["wikimedia"],
  })
  assert.equal(
    balancedSnapshotComplete(observation, ["wikimedia", "drand"]),
    false,
  )
  assert.equal(
    balancedSnapshotComplete(observation, ["wikimedia", "open_meteo"]),
    false,
  )

  observation = mergeBalancedSnapshotObservation(observation, {
    commit_watermark: 32,
    memory_events: [{source: "drand"}],
  })

  assert.equal(
    balancedSnapshotComplete(observation, ["wikimedia", "drand"]),
    true,
  )
})

test("handles malformed balanced snapshot observations safely", () => {
  let observation = null

  for (const envelope of [
    null,
    [],
    {},
    {commit_watermark: Number.MAX_SAFE_INTEGER + 1},
    {commit_watermark: Number.NaN, display_events: [null, {}, {source: ""}]},
  ]) {
    assert.doesNotThrow(() => {
      observation = mergeBalancedSnapshotObservation(observation, envelope)
    })
  }

  assert.deepEqual(observation, {watermarks: [], sources: []})
  assert.equal(balancedSnapshotComplete(observation, []), false)
  assert.equal(balancedSnapshotComplete(observation, "wikimedia"), false)
})
