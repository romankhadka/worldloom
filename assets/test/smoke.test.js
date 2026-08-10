import assert from "node:assert/strict"
import test from "node:test"

import {signalPalette} from "../js/worldloom/palette.js"
import {laneFromClientY, withinLiveEdgeTarget} from "../js/worldloom/placement.js"

const fixtureModuleUrl = new URL("./fixtures/balanced_snapshots.js", import.meta.url)
const fixtureModule = await import(fixtureModuleUrl).catch(error => {
  if (error.code === "ERR_MODULE_NOT_FOUND" && error.url === fixtureModuleUrl.href) return {}
  throw error
})

test("exports every named balanced-world acceptance fixture", () => {
  assert.deepEqual(Object.keys(fixtureModule).sort(), [
    "balanced",
    "balancedQuarterHour",
    "balancedQuarterHourPriorEvents",
    "delayedRecovery",
    "memoryExpiry",
    "totalOutage",
    "wikimediaSurge",
  ])
})

const namedFixtures = Object.entries(fixtureModule).filter(([_name, fixture]) =>
  !Array.isArray(fixture)
)
const scheduledSources = ["bluesky", "drand", "ripe_ris", "solana", "wikimedia"]
const scheduledSourceSet = new Set(scheduledSources)

function eventsIn(snapshot) {
  return [
    ...(snapshot.display_events ?? []),
    ...(snapshot.memory_events ?? []),
    ...(snapshot.ambient ? [snapshot.ambient] : []),
  ]
}

function rollingBalancedIntervals(snapshot) {
  const windowStart = Date.parse(snapshot.window_end) - 60_000

  return Array.from({length: 51}, (_entry, offsetSeconds) => {
    const intervalStart = windowStart + offsetSeconds * 1_000
    const intervalEnd = intervalStart + 10_000

    return (snapshot.display_events ?? []).filter(event => {
      const occurredAt = Date.parse(event.occurred_at)
      return scheduledSourceSet.has(event.source) &&
        occurredAt >= intervalStart && occurredAt < intervalEnd
    })
  })
}

test("every named fixture is a complete snapshot envelope", () => {
  for (const [name, snapshot] of namedFixtures) {
    assert.equal(snapshot.snapshot_version, 1, `${name} snapshot_version`)
    assert.equal(typeof snapshot.window_end, "string", `${name} window_end`)
    assert.equal(Number.isSafeInteger(snapshot.commit_watermark), true, `${name} watermark`)
    assert.equal(Array.isArray(snapshot.display_events), true, `${name} display_events`)
    assert.equal(Array.isArray(snapshot.memory_events), true, `${name} memory_events`)
    assert.equal(
      snapshot.ambient === null || typeof snapshot.ambient === "object",
      true,
      `${name} ambient`,
    )
  }
})

test("every fixture sequence is positive and unique within its snapshot", () => {
  for (const [name, snapshot] of namedFixtures) {
    const sequences = eventsIn(snapshot).map(event => event.sequence)

    assert.ok(sequences.length > 0, `${name} has fixture events`)
    assert.equal(
      sequences.every(sequence => Number.isSafeInteger(sequence) && sequence > 0),
      true,
      `${name} has positive safe sequences`,
    )
    assert.equal(new Set(sequences).size, sequences.length, `${name} sequences are unique`)
    assert.equal(Math.max(...sequences), snapshot.commit_watermark, `${name} watermark is final`)
  }
})

test("every fixture timestamp is an explicit UTC instant", () => {
  const utcTimestamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/

  for (const [name, snapshot] of namedFixtures) {
    const timestamps = [snapshot.window_end, ...eventsIn(snapshot).map(event => event.occurred_at)]

    assert.ok(timestamps.length > 1, `${name} has event timestamps`)
    for (const timestamp of timestamps) {
      assert.equal(utcTimestamp.test(timestamp), true, `${name} UTC timestamp: ${timestamp}`)
      assert.equal(Number.isFinite(Date.parse(timestamp)), true, `${name} valid timestamp`)
    }
  }
})

test("quarter-hour prior events are bounded, unique, and end before the live minute", () => {
  const priorEvents = fixtureModule.balancedQuarterHourPriorEvents
  const liveStart = Date.parse(fixtureModule.balancedQuarterHour.window_end) - 60_000

  assert.ok(priorEvents.length <= 1_200)
  assert.ok(priorEvents.length > 1_000)
  assert.equal(new Set(priorEvents.map(event => event.sequence)).size, priorEvents.length)
  assert.ok(priorEvents.every(event => event.sequence < 10_000))
  assert.ok(priorEvents.every(event => Date.parse(event.occurred_at) < liveStart))
  assert.equal(priorEvents[0].occurred_at, "2026-08-08T11:46:00.000Z")
})

test("every rolling ten-second balanced interval contains all five scheduled families", () => {
  const intervals = rollingBalancedIntervals(fixtureModule.balanced)

  assert.equal(intervals.length, 51)
  for (const [index, events] of intervals.entries()) {
    assert.deepEqual(
      [...new Set(events.map(event => event.source))].sort(),
      scheduledSources,
      `rolling interval ${index}`,
    )
  }
})

test("no scheduled family exceeds forty percent of durable balanced anchors", () => {
  for (const [index, events] of rollingBalancedIntervals(fixtureModule.balanced).entries()) {
    assert.ok(events.length >= 10, `rolling interval ${index} has ten durable anchors`)

    for (const source of scheduledSources) {
      const sourceCount = events.filter(event => event.source === source).length
      assert.ok(sourceCount / events.length <= 0.4, `${source} share in interval ${index}`)
    }
  }
})

test("balanced earthquake, weather, and visitor context stays outside the source quota", () => {
  const contextualSources = new Set([
    ...(fixtureModule.balanced.memory_events ?? []).map(event => event.source),
    fixtureModule.balanced.ambient?.source,
  ])

  assert.equal(contextualSources.has("usgs"), true)
  assert.equal(contextualSources.has("open_meteo"), true)
  assert.equal(contextualSources.has("visitor"), true)
  assert.equal(
    (fixtureModule.balanced.display_events ?? []).every(event => scheduledSourceSet.has(event.source)),
    true,
  )
  assert.deepEqual(
    fixtureModule.balanced.memory_events.map(event => [event.source, event.occurred_at]),
    [
      ["usgs", "2026-08-08T11:42:00.000Z"],
      ["visitor", "2026-08-08T11:57:00.000Z"],
      ["visitor", "2026-08-08T11:54:00.000Z"],
      ["visitor", "2026-08-08T11:51:00.000Z"],
    ],
  )
  const visitorSequences = fixtureModule.balanced.memory_events
    .filter(event => event.source === "visitor")
    .map(event => event.sequence)
  assert.deepEqual(visitorSequences, [...visitorSequences].sort((left, right) => right - left))
})

test("balanced uses uninterrupted genuine source cadences", () => {
  const minuteStart = Date.parse(fixtureModule.balanced.window_end) - 60_000
  const quicknetGenesisUnixSecond = 1_692_803_367
  const offsetsBySource = new Map(scheduledSources.map(source => [source, []]))

  for (const event of fixtureModule.balanced.display_events) {
    offsetsBySource.get(event.source).push((Date.parse(event.occurred_at) - minuteStart) / 1_000)
  }

  assert.deepEqual(offsetsBySource.get("wikimedia"), offsetsThrough(0, 60, 4))
  assert.deepEqual(offsetsBySource.get("bluesky"), offsetsThrough(1, 60, 4))
  assert.deepEqual(offsetsBySource.get("ripe_ris"), offsetsThrough(2, 60, 4))
  assert.deepEqual(offsetsBySource.get("solana"), offsetsThrough(3, 60, 4))
  assert.deepEqual(offsetsBySource.get("drand"), offsetsThrough(0, 60, 3))

  const rounds = fixtureModule.balanced.display_events
    .filter(event => event.source === "drand")
  const roundNumbers = rounds.map(event => event.metrics.round)
  assert.equal(roundNumbers.length, 21)
  assert.equal(
    roundNumbers.every((round, index) => index === 0 || round === roundNumbers[index - 1] + 1),
    true,
  )
  for (const event of rounds) {
    const expectedUnixSecond = quicknetGenesisUnixSecond + (event.metrics.round - 1) * 3
    assert.equal(Date.parse(event.occurred_at) / 1_000, expectedUnixSecond)
  }
})

test("named scenarios encode surge, recovery, outage, and memory expiry", () => {
  const balancedWikimedia = fixtureModule.balanced.display_events
    .filter(event => event.source === "wikimedia")
  const surgeWikimedia = fixtureModule.wikimediaSurge.display_events
    .filter(event => event.source === "wikimedia")
  const ripeRecoveryEvents = fixtureModule.delayedRecovery.display_events
    .filter(event => event.source === "ripe_ris")
  const recoveryStart = Date.parse(fixtureModule.delayedRecovery.window_end) - 30_000

  assert.deepEqual(
    surgeWikimedia.map(event => event.occurred_at),
    balancedWikimedia.map(event => event.occurred_at),
  )
  assert.equal(surgeWikimedia.every(event => event.intensity > 0.8), true)
  assert.equal(balancedWikimedia.every(event => event.intensity < 0.8), true)
  assert.ok(ripeRecoveryEvents.length > 0)
  assert.equal(
    ripeRecoveryEvents.every(event => Date.parse(event.occurred_at) >= recoveryStart),
    true,
  )
  assert.deepEqual(
    fixtureModule.totalOutage.display_events.map(event => [event.source, event.occurred_at]),
    fixtureModule.balanced.display_events.map(event => [event.source, event.occurred_at]),
  )
  assert.ok(fixtureModule.totalOutage.memory_events.length > 0)
  assert.ok(fixtureModule.totalOutage.ambient)
  assert.ok(fixtureModule.balanced.memory_events.length > 0)
  assert.equal(fixtureModule.memoryExpiry.memory_events.length, 0)
})

test("balanced Solana windows advance through internally consistent slot ranges", () => {
  const windows = fixtureModule.balanced.display_events
    .filter(event => event.source === "solana")

  for (const [index, event] of windows.entries()) {
    assert.equal(
      event.metrics.last_slot - event.metrics.first_slot + 1,
      event.metrics.slot_count + event.metrics.gap_count,
    )
    if (index > 0) {
      assert.equal(event.metrics.first_slot, windows[index - 1].metrics.last_slot + 1)
    }
  }
})

test("all eight signal families have fixed accessible palette roles", () => {
  assert.deepEqual(Object.keys(signalPalette), [
    "wikimedia",
    "bluesky",
    "ripe_ris",
    "solana",
    "drand",
    "usgs",
    "open_meteo",
    "visitor",
  ])
  assert.equal(new Set(Object.values(signalPalette).map(palette => palette.family)).size, 8)
})

test("the live-edge placement surface remains importable without a DOM", () => {
  const bounds = {left: 0, top: 0, width: 800, height: 600}
  assert.equal(withinLiveEdgeTarget(790, bounds), true)
  assert.equal(laneFromClientY(300, bounds), 0.5)
})

function offsetsThrough(start, end, cadence) {
  return Array.from(
    {length: Math.floor((end - start) / cadence) + 1},
    (_entry, index) => start + index * cadence,
  )
}
