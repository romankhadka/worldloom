import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {buildTopology} from "../js/worldloom/topology.js"
import {
  balanced,
  delayedRecovery,
  memoryExpiry,
  totalOutage,
  wikimediaSurge,
} from "./fixtures/balanced_snapshots.js"

const versionTwoContract = JSON.parse(
  readFileSync(
    new URL("../../test/support/fixtures/render_contract_v2.json", import.meta.url),
    "utf8",
  ),
)
const namedSnapshots = {
  balanced,
  wikimediaSurge,
  delayedRecovery,
  totalOutage,
  memoryExpiry,
}

const assertFiniteTopology = topology => {
  const visit = current => {
    if (typeof current === "number") assert.ok(Number.isFinite(current))
    if (Array.isArray(current)) current.forEach(visit)
    if (current && typeof current === "object") Object.values(current).forEach(visit)
  }

  visit(topology)
  for (const collection of [
    topology.spine,
    topology.anchors,
    topology.edges,
    topology.formations,
    topology.fallbacks,
    topology.memory ?? [],
  ]) {
    assert.ok(collection.length <= 600)
  }
}

const assertBoundedFallback = fallback => {
  assert.ok(fallback.lane >= 0 && fallback.lane <= 1)
  assert.ok(fallback.intensity >= 0 && fallback.intensity <= 1)
  assert.ok(fallback.visual.spread >= 0 && fallback.visual.spread <= 1)
  assert.ok(fallback.visual.bend >= -1 && fallback.visual.bend <= 1)
  assert.ok(fallback.visual.pulse >= 0 && fallback.visual.pulse <= 1)
}

const sourceForKind = kind => {
  if (kind === "wikimedia") return "wikimedia"
  if (kind === "earthquake") return "usgs"
  if (kind === "weather") return "open_meteo"
  return "visitor"
}

const instruction = (sequence, kind = "wikimedia", overrides = {}) => ({
  sequence,
  kind,
  source: sourceForKind(kind),
  occurred_at: `2026-08-03T12:00:${String(sequence % 60).padStart(2, "0")}.000000Z`,
  render_version: 1,
  seed: sequence * 7919,
  lane: (sequence % 8) / 8,
  intensity: 0.6,
  visual: {spread: 0.5, bend: 0.25, pulse: 0.75},
  summary: `Formation ${sequence}`,
  ...overrides,
})

test("builds the same bounded topology regardless of input order and duplicates", () => {
  const ordered = Array.from({length: 24}, (_item, index) => instruction(index + 1))
  const first = buildTopology(ordered)
  const second = buildTopology([...ordered].reverse().concat(ordered[5]))

  assert.deepEqual(second, first)
  assert.equal(first.anchors.length, 24)
  assert.ok(first.edges.length > 0)
  assert.ok(first.edges.every(edge => first.anchors.some(anchor => anchor.id === edge.from)))
  assert.ok(first.edges.every(edge => first.anchors.some(anchor => anchor.id === edge.to)))
})

test("derives one calm primary spine through a busy public window", () => {
  const instructions = Array.from({length: 48}, (_item, index) =>
    instruction(index + 1, "wikimedia", {
      lane: index % 2 === 0 ? 0.08 : 0.92,
      visual: {spread: 0.5, bend: index % 3 === 0 ? 0.8 : -0.8, pulse: 0.75},
    }),
  )

  const topology = buildTopology(instructions)

  assert.equal(topology.spine.length, 48)
  assert.deepEqual(
    topology.spine.map(point => point.sequence),
    instructions.map(item => item.sequence),
  )
  for (let index = 1; index < topology.spine.length; index++) {
    assert.ok(Math.abs(topology.spine[index].lane - topology.spine[index - 1].lane) <= 0.25)
  }
})

test("bounds primary spine transitions at opposing lane and bend extrema", () => {
  const transitions = [
    [
      instruction(1, "wikimedia", {lane: 0}),
      instruction(2, "wikimedia", {
        lane: 1,
        visual: {spread: 0.5, bend: 1, pulse: 0.75},
      }),
    ],
    [
      instruction(1, "wikimedia", {lane: 1}),
      instruction(2, "wikimedia", {
        lane: 0,
        visual: {spread: 0.5, bend: -1, pulse: 0.75},
      }),
    ],
    [
      instruction(1, "wikimedia", {lane: 0.0000006}),
      instruction(2, "wikimedia", {
        lane: 1,
        visual: {spread: 0.5, bend: 1, pulse: 0.75},
      }),
    ],
    [
      instruction(1, "wikimedia", {lane: 0.9999994}),
      instruction(2, "wikimedia", {
        lane: 0,
        visual: {spread: 0.5, bend: -1, pulse: 0.75},
      }),
    ],
  ]

  for (const instructions of transitions) {
    const topology = buildTopology(instructions)

    assert.deepEqual(
      topology.spine.map(point => point.sequence),
      instructions.map(item => item.sequence),
    )
    for (let index = 1; index < topology.spine.length; index++) {
      const laneDelta = Math.abs(topology.spine[index].lane - topology.spine[index - 1].lane)
      assert.ok(
        laneDelta <= 0.25,
        `expected adjacent spine delta ${laneDelta} to be at most 0.25`,
      )
    }
  }
})

test("keeps spine derivation deterministic, bounded, and viewport independent", () => {
  const instructions = Array.from({length: 700}, (_item, index) => instruction(index + 1))
  const first = buildTopology(instructions)
  const second = buildTopology([...instructions].reverse().concat(instructions[500]))

  assert.deepEqual(second.spine, first.spine)
  assert.equal(first.spine.length, 600)
  assert.equal(first.spine[0].sequence, 101)
})

test("derives structural tug, knot, and illuminate effects", () => {
  const fibers = Array.from({length: 18}, (_item, index) => instruction(index + 1))
  const topology = buildTopology([
    ...fibers,
    instruction(19, "tug", {lane: 0.8}),
    instruction(20, "knot", {lane: 0.5}),
    instruction(21, "illuminate", {lane: 0.25}),
  ])

  const tug = topology.formations.find(item => item.kind === "tug")
  const knot = topology.formations.find(item => item.kind === "knot")
  const illuminate = topology.formations.find(item => item.kind === "illuminate")

  assert.ok(tug.affectedAnchorIds.length >= 1)
  assert.ok(tug.beforeLanes.some((lane, index) => lane !== tug.afterLanes[index]))
  assert.ok(tug.affectedSpineIds.length >= 1)
  assert.ok(
    tug.beforeSpineLanes.some(
      (lane, index) => lane !== tug.afterSpineLanes[index],
    ),
  )
  assert.ok(knot.edgeId || knot.loopAnchorId)
  assert.ok(illuminate.anchorId)
})

test("keeps malformed and unsupported instructions as bounded fallbacks", () => {
  const topology = buildTopology([
    instruction(1),
    {...instruction(2), lane: Number.NaN},
    {...instruction(3), render_version: 99},
  ])

  assert.equal(topology.fallbacks.length, 2)
  assert.equal(topology.anchors.length, 1)
})

test("preserves the legacy finite visual and intensity contract for version one", () => {
  const legacyInstruction = instruction(1, "wikimedia", {
    intensity: 3,
    visual: {spread: 2, bend: -4, pulse: 5},
  })

  const topology = buildTopology([legacyInstruction])

  assert.equal(topology.fallbacks.length, 0)
  assert.equal(topology.spine.length, 1)
  assert.equal(topology.anchors.length, 1)
  assert.equal(topology.anchors[0].intensity, 3)
  assert.deepEqual(topology.anchors[0].visual, legacyInstruction.visual)
  assertFiniteTopology(topology)
})

test("renders every valid version two contract instruction through its source grammar", () => {
  const expectedRoles = ["conversation-fan", "route-fork", "slot-braid", "public-pulse"]

  for (const [index, contractInstruction] of versionTwoContract.entries()) {
    const first = buildTopology([contractInstruction])
    const second = buildTopology([structuredClone(contractInstruction)])

    assert.deepEqual(second, first)
    assert.equal(first.fallbacks.length, 0)
    assert.equal(first.formations.length, 1)
    assert.equal(first.formations[0].role, expectedRoles[index])
    assert.equal(first.formations[0].grammar.role, expectedRoles[index])
    assertFiniteTopology(first)
  }
})

test("keeps the Wikimedia spine while every named fixture retains non-spine anchors", () => {
  for (const [name, snapshot] of Object.entries(namedSnapshots)) {
    const topology = topologyFor(snapshot)
    const wikimediaSequences = snapshot.display_events
      .filter(item => item.source === "wikimedia")
      .map(item => item.sequence)

    assert.deepEqual(
      topology.spine.map(point => point.sequence),
      wikimediaSequences,
      `${name} must retain the server-selected Wikimedia spine`,
    )
    assert.ok(
      topology.anchors.some(anchor => anchor.source !== "wikimedia"),
      `${name} must retain source anchors outside the spine`,
    )
    assert.ok(topology.spine.every(point => point.grammar.role === "backbone"))
    assert.equal(topology.fallbacks.length, 0)
    assertFiniteTopology(topology)
  }
})

test("attaches bounded Bluesky fans without displacing or fabricating the spine", () => {
  const topology = topologyFor(balanced)
  const fans = topology.formations.filter(formation => formation.role === "conversation-fan")
  const blueskyInstructions = balanced.display_events.filter(item => item.source === "bluesky")

  assert.equal(fans.length, blueskyInstructions.length)
  assert.deepEqual(fans.map(fan => fan.sequence), blueskyInstructions.map(item => item.sequence))
  assert.ok(fans.every(fan => fan.attachmentSpineId?.startsWith("spine:")))
  assert.ok(fans.every(fan => fan.branches.length === fan.grammar.branchCount))
  assert.ok(fans.every(fan => fan.branches.length >= 1 && fan.branches.length <= 8))
  assert.ok(fans.every(fan => fan.branches.every((branch, index) => branch.order === index)))

  const isolated = buildTopology([structuredClone(blueskyInstructions[0])])
  assert.equal(isolated.spine.length, 0)
  assert.equal(isolated.anchors.length, 1)
  assert.equal(isolated.formations[0].attachmentSpineId, null)
})

test("never promotes a source attachment into the Wikimedia fiber chain", () => {
  const bluesky = {
    ...structuredClone(versionTwoContract[0]),
    sequence: 2,
    lane: 0.5,
  }
  const topology = buildTopology([
    instruction(1, "wikimedia", {lane: 0.9}),
    bluesky,
    instruction(3, "wikimedia", {lane: 0.5}),
  ])
  const finalFiber = topology.edges.find(edge => edge.role === "fiber" && edge.sequence === 3)

  assert.equal(finalFiber.from, "anchor:1")
  assert.equal(finalFiber.to, "anchor:3")
  assert.ok(topology.anchors.find(anchor => anchor.id === finalFiber.from).source === "wikimedia")
})

test("builds RIPE angular forks with explicit inward withdrawal controls", () => {
  const topology = topologyFor(balanced)
  const forks = topology.formations.filter(formation => formation.role === "route-fork")
  const ripeInstructions = balanced.display_events.filter(item => item.source === "ripe_ris")

  assert.equal(forks.length, ripeInstructions.length)
  assert.deepEqual(forks.map(fork => fork.sequence), ripeInstructions.map(item => item.sequence))
  assert.ok(forks.every(fork => fork.segments.length === fork.grammar.forkCount))
  assert.ok(forks.every(fork => fork.segments.length >= 1 && fork.segments.length <= 6))
  assert.ok(forks.every(fork => fork.segments.every(segment =>
    segment.pathStyle === "angular-fork" &&
      segment.withdrawalControl.direction === "inward" &&
      segment.withdrawalControl.amount === fork.grammar.pinch
  )))
})

test("centers singular fans and forks without inventing lateral direction", () => {
  const [bluesky, ripeRis] = versionTwoContract
  const quietBluesky = {
    ...structuredClone(bluesky),
    metrics: {...bluesky.metrics, total_actions: 1},
  }
  const quietRipe = {
    ...structuredClone(ripeRis),
    metrics: {...ripeRis.metrics, announced: 1, withdrawn: 0},
  }
  const topology = buildTopology([quietBluesky, quietRipe])
  const fan = topology.formations.find(formation => formation.role === "conversation-fan")
  const fork = topology.formations.find(formation => formation.role === "route-fork")

  assert.equal(fan.branches.length, 1)
  assert.equal(fan.branches[0].lane, quietBluesky.lane)
  assert.equal(fork.segments.length, 1)
  assert.equal(fork.segments[0].angle, 0)
})

test("keeps Solana beads and explicit gap markers in bounded slot order", () => {
  const topology = topologyFor(balanced)
  const braids = topology.formations.filter(formation => formation.role === "slot-braid")
  const solanaInstructions = balanced.display_events.filter(item => item.source === "solana")

  assert.equal(braids.length, solanaInstructions.length)
  assert.deepEqual(braids.map(braid => braid.sequence), solanaInstructions.map(item => item.sequence))
  for (const [index, braid] of braids.entries()) {
    const metrics = solanaInstructions[index].metrics
    assert.deepEqual(braid.slotRange, {first: metrics.first_slot, last: metrics.last_slot})
    assert.deepEqual(braid.beads.map(bead => bead.slotOrder),
      Array.from({length: braid.grammar.beadCount}, (_item, order) => order))
    assert.deepEqual(
      braid.gapMarkers.map(marker => marker.afterSlotOrder),
      [...braid.gapMarkers]
        .map(marker => marker.afterSlotOrder)
        .sort((left, right) => left - right),
    )
    assert.equal(braid.gapMarkers.length, braid.grammar.gapBreakCount)
  }
})

test("emits exactly one public pulse for each genuine drand round", () => {
  const topology = topologyFor(balanced)
  const pulseFormations = topology.formations.filter(formation => formation.role === "public-pulse")
  const drandInstructions = balanced.display_events.filter(item => item.source === "drand")

  assert.equal(pulseFormations.length, drandInstructions.length)
  assert.deepEqual(pulseFormations.map(formation => formation.sequence),
    drandInstructions.map(item => item.sequence))
  assert.deepEqual(pulseFormations.flatMap(formation => formation.pulses.map(pulse => pulse.round)),
    drandInstructions.map(item => item.metrics.round))
  assert.ok(pulseFormations.every(formation => formation.pulses.length === 1))
})

test("keeps earthquake and visitor memory in a separate quiet contextual band", () => {
  for (const [name, snapshot] of Object.entries(namedSnapshots)) {
    const primary = buildTopology(snapshot.display_events)
    const withMemory = topologyFor(snapshot)

    assert.deepEqual(withMemory.spine, primary.spine, `${name} memory must not bend the spine`)
    assert.deepEqual(withMemory.anchors, primary.anchors, `${name} memory must not add anchors`)
    assert.deepEqual(withMemory.edges, primary.edges, `${name} memory must not add edges`)
    assert.deepEqual(withMemory.memory.map(trace => trace.sequence),
      snapshot.memory_events.map(item => item.sequence))
    assert.ok(withMemory.memory.every(trace => trace.band === "quiet-context"))
    assert.ok(withMemory.memory.every(trace => trace.anchorId === null))
    assert.ok(withMemory.memory.every(trace =>
      trace.role === "rupture" || trace.role === "intervention"
    ))
  }
})

test("keeps named-fixture topology deterministic across copies and reload order", () => {
  for (const snapshot of Object.values(namedSnapshots)) {
    const first = topologyFor(snapshot)
    const copy = topologyFor(structuredClone(snapshot))
    const reloaded = buildTopology([...structuredClone(snapshot.display_events)].reverse(), {
      memoryInstructions: [...structuredClone(snapshot.memory_events)].reverse(),
    })

    assert.deepEqual(copy, first)
    assert.deepEqual(reloaded, first)
  }
})

test("honors server source selection, sequence identity, and the six-hundred display limit", () => {
  const repeatedSelection = Array.from({length: 604}, (_item, index) => ({
    ...structuredClone(balanced.display_events[index % balanced.display_events.length]),
    sequence: 10_000 + index,
  }))
  const topology = buildTopology(repeatedSelection, {
    memoryInstructions: structuredClone(balanced.memory_events),
  })
  const selected = repeatedSelection.slice(-600)
  const selectedSequences = new Set(selected.map(item => item.sequence))
  const topologySequences = new Set([
    ...topology.spine,
    ...topology.anchors,
    ...topology.formations,
    ...topology.fallbacks,
  ].map(item => item.sequence))

  assert.deepEqual([...topologySequences].sort((left, right) => left - right),
    [...selectedSequences].sort((left, right) => left - right))
  assert.deepEqual(topology.anchors.map(anchor => anchor.sequence),
    selected
      .filter(item => item.source !== "drand")
      .map(item => item.sequence))
  assert.equal(topology.memory.length, 4)
  assert.equal(topology.spine[0].sequence,
    selected.find(item => item.source === "wikimedia").sequence)
  assertFiniteTopology(topology)
})

test("preserves JSON-safe Solana positions beyond the uint32 counter range", () => {
  const solana = structuredClone(versionTwoContract[2])
  solana.metrics = {
    ...solana.metrics,
    slot_count: 1,
    first_slot: Number.MAX_SAFE_INTEGER,
    last_slot: Number.MAX_SAFE_INTEGER,
    gap_count: 0,
    truncated: false,
  }

  const topology = buildTopology([solana])

  assert.equal(topology.fallbacks.length, 0)
  assert.equal(topology.formations[0].role, "slot-braid")
  assert.deepEqual(topology.formations[0].slotRange, {
    first: Number.MAX_SAFE_INTEGER,
    last: Number.MAX_SAFE_INTEGER,
  })
})

test("preserves JSON-safe drand rounds beyond the uint32 counter range", () => {
  const drand = structuredClone(versionTwoContract[3])
  drand.metrics.round = Number.MAX_SAFE_INTEGER

  const topology = buildTopology([drand])

  assert.equal(topology.fallbacks.length, 0)
  assert.equal(topology.formations[0].role, "public-pulse")
  assert.equal(topology.formations[0].pulses[0].round, Number.MAX_SAFE_INTEGER)
})

test("requires one Solana slot exactly when both endpoints are equal", () => {
  const solana = structuredClone(versionTwoContract[2])
  const oneSlot = {
    ...solana,
    metrics: {
      ...solana.metrics,
      slot_count: 1,
      first_slot: 104,
      last_slot: 104,
      gap_count: 0,
    },
  }
  const malformedOneSlot = {
    ...solana,
    metrics: {
      ...solana.metrics,
      slot_count: 1,
      first_slot: 101,
      last_slot: 105,
      gap_count: 4,
      truncated: false,
    },
  }

  const oneSlotTopology = buildTopology([oneSlot])
  const multiSlotTopology = buildTopology([solana])
  const malformedTopology = buildTopology([malformedOneSlot])

  assert.equal(oneSlotTopology.formations[0].role, "slot-braid")
  assert.equal(multiSlotTopology.formations[0].role, "slot-braid")
  assert.equal(malformedTopology.fallbacks[0].kind, "fallback")
  assert.equal(malformedTopology.fallbacks[0].source, "visitor")
})

test("accepts Solana window-cap truncation without accepting impossible endpoints", () => {
  const solana = structuredClone(versionTwoContract[2])
  const maximumWindowCount = Math.floor(0xFFFFFFFF / 4)
  const windowCapped = {
    ...solana,
    metrics: {
      ...solana.metrics,
      window_count: maximumWindowCount,
      window_span_seconds: maximumWindowCount * 4,
      truncated: true,
    },
  }
  const impossible = {
    ...windowCapped,
    metrics: {...windowCapped.metrics, slot_count: 6, first_slot: 101, last_slot: 105},
  }

  const validTopology = buildTopology([windowCapped])
  const invalidTopology = buildTopology([impossible])

  assert.equal(validTopology.formations[0].role, "slot-braid")
  assert.equal(validTopology.formations[0].source, "solana")
  assert.equal(invalidTopology.fallbacks[0].kind, "fallback")
  assert.equal(invalidTopology.fallbacks[0].source, "visitor")
})

test("neutralizes mismatched or malformed version two contracts", () => {
  const [bluesky, ripeRis, solana, drand] = versionTwoContract
  const malformed = [
    {...structuredClone(bluesky), source: "ripe_ris"},
    {
      ...structuredClone(bluesky),
      metrics: {...bluesky.metrics, private_identifier: 1},
    },
    {
      ...structuredClone(bluesky),
      metrics: {...bluesky.metrics, truncated: "false"},
    },
    {
      ...structuredClone(ripeRis),
      metrics: {...ripeRis.metrics, window_span_seconds: 4},
    },
    {
      ...structuredClone(solana),
      metrics: {...solana.metrics, first_slot: solana.metrics.last_slot + 1},
    },
    {
      ...structuredClone(solana),
      metrics: {...solana.metrics, first_slot: Number.MAX_SAFE_INTEGER + 1},
    },
    {
      ...structuredClone(solana),
      metrics: {...solana.metrics, slot_count: 6},
    },
    {
      ...structuredClone(solana),
      metrics: {...solana.metrics, truncated: "false"},
    },
    {
      ...structuredClone(solana),
      metrics: {...solana.metrics, truncated: true},
    },
    {
      ...structuredClone(drand),
      metrics: {...drand.metrics, round: 0},
    },
    {
      ...structuredClone(drand),
      metrics: {...drand.metrics, round: Number.MAX_SAFE_INTEGER + 1},
    },
  ].map((contractInstruction, index) => ({
    ...contractInstruction,
    sequence: 300 + index,
  }))

  const topology = buildTopology(malformed)

  assert.equal(topology.fallbacks.length, malformed.length)
  for (const fallback of topology.fallbacks) {
    assert.equal(fallback.kind, "fallback")
    assert.equal(fallback.source, "visitor")
    assertBoundedFallback(fallback)
  }
  assertFiniteTopology(topology)
})

test("rejects JSON object and array source-kind values without coercion or throws", () => {
  const nonStringPairs = [
    JSON.parse('{"source":{"toString":null},"kind":"wikimedia"}'),
    JSON.parse('{"source":["wikimedia"],"kind":"wikimedia"}'),
    JSON.parse('{"source":"wikimedia","kind":["wikimedia"]}'),
  ].map((pair, index) => ({
    ...instruction(400 + index),
    ...pair,
  }))
  let topology

  assert.doesNotThrow(() => {
    topology = buildTopology(nonStringPairs)
  })
  assert.equal(topology.fallbacks.length, nonStringPairs.length)
  for (const fallback of topology.fallbacks) {
    assert.equal(fallback.kind, "fallback")
    assert.equal(fallback.source, "visitor")
    assertBoundedFallback(fallback)
  }
  assertFiniteTopology(topology)
})

test("contains inherited fields, accessors, and revoked proxies at the topology boundary", () => {
  const inherited = Object.create(instruction(500))
  const sourceAccessor = instruction(501)
  Object.defineProperty(sourceAccessor, "source", {
    enumerable: true,
    get() {
      throw new Error("source getter must not run")
    },
  })
  const revokedInstruction = Proxy.revocable(instruction(502), {})
  revokedInstruction.revoke()
  const revokedMetrics = Proxy.revocable({}, {})
  revokedMetrics.revoke()
  const invalidMetrics = {
    ...structuredClone(versionTwoContract[0]),
    sequence: 503,
    metrics: revokedMetrics.proxy,
  }
  const hostileOptions = {}
  Object.defineProperty(hostileOptions, "memoryInstructions", {
    enumerable: true,
    get() {
      throw new Error("options getter must not run")
    },
  })
  const hostileMemoryTimestamp = instruction(504, "illuminate", {
    occurred_at: {
      toString() {
        throw new Error("timestamp coercion must not run")
      },
    },
  })
  let topology

  assert.doesNotThrow(() => {
    topology = buildTopology(
      [inherited, sourceAccessor, revokedInstruction.proxy, invalidMetrics],
      hostileOptions,
    )
  })
  assert.deepEqual(topology.fallbacks.map(fallback => fallback.sequence), [501, 503])
  assert.ok(topology.fallbacks.every(fallback => fallback.kind === "fallback"))
  assert.equal(topology.memory.length, 0)
  assertFiniteTopology(topology)
  assert.doesNotThrow(() =>
    buildTopology([], {memoryInstructions: [hostileMemoryTimestamp]})
  )
})

test("keeps unsupported positive render versions as finite semantic fallbacks", () => {
  const futureInstruction = {
    ...structuredClone(versionTwoContract[0]),
    render_version: 99,
    lane: -20,
    intensity: 40,
    visual: {spread: 80, bend: -90, pulse: 100},
  }

  const topology = buildTopology([futureInstruction])
  const [fallback] = topology.fallbacks

  assert.equal(fallback.kind, futureInstruction.kind)
  assert.equal(fallback.source, futureInstruction.source)
  assertBoundedFallback(fallback)
  assertFiniteTopology(topology)
})

test("caps topology at the newest six hundred instructions", () => {
  const instructions = Array.from({length: 700}, (_item, index) => instruction(index + 1))
  const topology = buildTopology(instructions)

  assert.equal(topology.anchors.length, 600)
  assert.equal(topology.anchors[0].sequence, 101)
  assert.equal(topology.anchors.at(-1).sequence, 700)
})

test("extends a branch only from its terminal anchor", () => {
  const topology = buildTopology([
    instruction(1, "wikimedia", {lane: 0}),
    instruction(2, "wikimedia", {lane: 0.4}),
    instruction(3, "wikimedia", {lane: 0}),
  ])
  const finalEdge = topology.edges.find(edge => edge.sequence === 3 && edge.role === "fiber")

  assert.equal(finalEdge.from, "anchor:2")
  assert.equal(finalEdge.to, "anchor:3")
})

test("illuminates the nearest junction instead of the newest junction", () => {
  const topology = buildTopology([
    instruction(1, "wikimedia", {lane: 0.1}),
    instruction(2, "wikimedia", {lane: 0.9}),
    instruction(3, "wikimedia", {lane: 0.1}),
    instruction(4, "wikimedia", {lane: 0.9}),
    instruction(5, "knot", {lane: 0.5}),
    instruction(6, "knot", {lane: 0.5}),
    instruction(7, "wikimedia", {lane: 0.1}),
    instruction(8, "wikimedia", {lane: 0.9}),
    instruction(9, "knot", {lane: 0.5}),
    instruction(10, "knot", {lane: 0.5}),
    instruction(11, "illuminate", {lane: 0.1}),
  ])

  const illuminate = topology.formations.find(item => item.kind === "illuminate")
  assert.equal(illuminate.anchorId, "anchor:7")
})

function topologyFor(snapshot) {
  return buildTopology(snapshot.display_events, {
    memoryInstructions: snapshot.memory_events,
  })
}
