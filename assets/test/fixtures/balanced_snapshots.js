const windowStart = "2026-08-08T12:00:00.000Z"
const windowEnd = "2026-08-08T12:01:00.000Z"
const quicknetGenesisUnixSecond = 1_692_803_367
const firstDrandRound =
  (Date.parse(windowStart) / 1_000 - quicknetGenesisUnixSecond) / 3 + 1

const sourceContracts = {
  bluesky: {
    kind: "public_activity",
    renderVersion: 2,
    lane: 0.32,
    intensity: 0.55,
    visual: {spread: 0.52, bend: -0.18, pulse: 0.62},
    summary: "Public Bluesky activity moved through the weave",
  },
  drand: {
    kind: "randomness",
    renderVersion: 2,
    lane: 0.5,
    intensity: 0.6,
    visual: {spread: 0.44, bend: 0.04, pulse: 0.82},
    summary: "A drand Quicknet round pulsed through the weave",
  },
  open_meteo: {
    kind: "weather",
    renderVersion: 1,
    lane: 0.48,
    intensity: 0.38,
    visual: {spread: 0.7, bend: 0.02, pulse: 0.28},
    summary: "Open-Meteo weather shaped the atmosphere",
  },
  ripe_ris: {
    kind: "route_change",
    renderVersion: 2,
    lane: 0.68,
    intensity: 0.58,
    visual: {spread: 0.46, bend: 0.2, pulse: 0.7},
    summary: "Public RIPE route changes moved through the weave",
  },
  solana: {
    kind: "slot",
    renderVersion: 2,
    lane: 0.78,
    intensity: 0.64,
    visual: {spread: 0.36, bend: 0.08, pulse: 0.74},
    summary: "Public Solana slots advanced through the weave",
  },
  usgs: {
    kind: "earthquake",
    renderVersion: 1,
    lane: 0.84,
    intensity: 0.72,
    visual: {spread: 0.68, bend: 0.1, pulse: 0.76},
    summary: "A USGS earthquake remained in recent memory",
  },
  visitor: {
    kind: "illuminate",
    renderVersion: 1,
    lane: 0.42,
    intensity: 0.62,
    visual: {spread: 0.56, bend: -0.06, pulse: 0.8},
    summary: "A visitor gesture remained in recent memory",
  },
  wikimedia: {
    kind: "wikimedia",
    renderVersion: 1,
    lane: 0.2,
    intensity: 0.5,
    visual: {spread: 0.4, bend: -0.1, pulse: 0.48},
    summary: "Wikimedia editing activity moved through the weave",
  },
}

const balancedDisplaySpecs = [
  ...offsetsThrough(0, 60, 4).map(offset => scheduledSpec("wikimedia", offset * 1_000)),
  ...offsetsThrough(1, 60, 4).map(offset => scheduledSpec("bluesky", offset * 1_000)),
  ...offsetsThrough(2, 60, 4).map(offset => scheduledSpec("ripe_ris", offset * 1_000)),
  ...offsetsThrough(3, 60, 4).map(offset => scheduledSpec("solana", offset * 1_000)),
  ...offsetsThrough(0, 60, 3).map((offset, index) =>
    scheduledSpec("drand", offset * 1_000, {metrics: {round: firstDrandRound + index}})
  ),
]

const memorySpecs = [
  {source: "usgs", occurredAt: "2026-08-08T11:42:00.000Z"},
  {
    source: "visitor",
    kind: "tug",
    occurredAt: "2026-08-08T11:51:00.000Z",
    lane: 0.24,
    summary: "A visitor tug remained in recent memory",
  },
  {
    source: "visitor",
    kind: "knot",
    occurredAt: "2026-08-08T11:54:00.000Z",
    lane: 0.5,
    summary: "A visitor knot remained in recent memory",
  },
  {source: "visitor", occurredAt: "2026-08-08T11:57:00.000Z", lane: 0.76},
]

const ambientSpec = {
  source: "open_meteo",
  occurredAt: "2026-08-08T11:59:30.000Z",
}

export const balanced = buildSnapshot({
  sequenceBase: 1_000,
  displaySpecs: balancedDisplaySpecs,
  memorySpecs,
  ambientSpec,
})

export const wikimediaSurge = buildSnapshot({
  sequenceBase: 2_000,
  displaySpecs: balancedDisplaySpecs.map(spec =>
    spec.source === "wikimedia"
      ? {
        ...spec,
        intensity: 0.85,
        summary: "A Wikimedia surge moved through the weave",
      }
      : spec
  ),
  memorySpecs,
  ambientSpec,
})

export const delayedRecovery = buildSnapshot({
  sequenceBase: 3_000,
  displaySpecs: balancedDisplaySpecs.filter(spec =>
    spec.source !== "ripe_ris" || spec.offsetMilliseconds >= 30_000
  ),
  memorySpecs,
  ambientSpec,
})

export const totalOutage = buildSnapshot({
  sequenceBase: 4_000,
  displaySpecs: balancedDisplaySpecs,
  memorySpecs,
  ambientSpec: {
    ...ambientSpec,
    occurredAt: "2026-08-08T11:30:00.000Z",
    summary: "The last weather atmosphere is stale",
  },
})

export const memoryExpiry = buildSnapshot({
  sequenceBase: 5_000,
  displaySpecs: balancedDisplaySpecs,
  memorySpecs: [],
  ambientSpec,
})

function scheduledSpec(source, offsetMilliseconds, overrides = {}) {
  return {
    source,
    offsetMilliseconds,
    metrics: metricsFor(source, offsetMilliseconds),
    ...overrides,
  }
}

function offsetsThrough(start, end, cadence) {
  return Array.from(
    {length: Math.floor((end - start) / cadence) + 1},
    (_entry, index) => start + index * cadence,
  )
}

function metricsFor(source, offsetMilliseconds) {
  const variation = Math.floor(offsetMilliseconds / 1_000) % 5

  switch (source) {
    case "bluesky":
      return {
        window_count: 1,
        window_span_seconds: 4,
        total_actions: 12 + variation,
        original_posts: 4 + variation,
        replies: 2,
        reposts: 1,
        creates: 8 + variation,
        updates: 3,
        deletes: 1,
        truncated: false,
      }
    case "ripe_ris":
      return {
        window_count: 1,
        window_span_seconds: 4,
        announced: 31 + variation,
        withdrawn: 4,
        ipv4: 28 + variation,
        ipv6: 7,
        collector_observations: 2,
        peer_observations: 18,
        truncated: false,
      }
    case "solana":
      return solanaMetrics(Math.floor(offsetMilliseconds / 4_000))
    default:
      return undefined
  }
}

function solanaMetrics(windowIndex) {
  const firstSlot = 1_200_000 + windowIndex * 5

  return {
    window_count: 1,
    window_span_seconds: 4,
    slot_count: 4,
    first_slot: firstSlot,
    last_slot: firstSlot + 4,
    gap_count: 1,
    truncated: false,
  }
}

function buildSnapshot({sequenceBase, displaySpecs, memorySpecs, ambientSpec}) {
  let sequence = sequenceBase
  const committedMemoryEvents = [...memorySpecs]
    .sort(compareSpecs)
    .map(spec => instructionFor(++sequence, spec))
  const memoryEvents = projectMemoryEvents(committedMemoryEvents)
  const displayEvents = [...displaySpecs]
    .sort(compareSpecs)
    .map(spec => instructionFor(++sequence, spec))
  const ambient = ambientSpec ? instructionFor(++sequence, ambientSpec) : null

  return {
    snapshot_version: 1,
    window_end: windowEnd,
    commit_watermark: sequence,
    display_events: displayEvents,
    memory_events: memoryEvents,
    ambient,
  }
}

function projectMemoryEvents(events) {
  const newerFirst = [...events].sort((left, right) =>
    Date.parse(right.occurred_at) - Date.parse(left.occurred_at) ||
      right.sequence - left.sequence
  )
  const earthquake = newerFirst.find(event =>
    event.source === "usgs" && event.kind === "earthquake"
  )
  const visitors = newerFirst.filter(event => event.source === "visitor").slice(0, 3)

  return [...(earthquake ? [earthquake] : []), ...visitors]
}

function instructionFor(sequence, spec) {
  const contract = sourceContracts[spec.source]
  const occurredAt = spec.occurredAt ?? timestampAt(spec.offsetMilliseconds)
  const instruction = {
    sequence,
    kind: spec.kind ?? contract.kind,
    source: spec.source,
    occurred_at: occurredAt,
    render_version: contract.renderVersion,
    seed: sequence * 17,
    lane: spec.lane ?? contract.lane,
    intensity: spec.intensity ?? contract.intensity,
    visual: {...contract.visual},
    summary: spec.summary ?? contract.summary,
  }

  return spec.metrics === undefined ? instruction : {...instruction, metrics: {...spec.metrics}}
}

function timestampAt(offsetMilliseconds) {
  return new Date(Date.parse(windowStart) + offsetMilliseconds).toISOString()
}

function compareSpecs(left, right) {
  const timeDifference = Date.parse(specTimestamp(left)) - Date.parse(specTimestamp(right))
  return timeDifference || left.source.localeCompare(right.source)
}

function specTimestamp(spec) {
  return spec.occurredAt ?? timestampAt(spec.offsetMilliseconds)
}
