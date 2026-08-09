import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {buildTopology} from "../js/worldloom/topology.js"

const versionTwoContract = JSON.parse(
  readFileSync(
    new URL("../../test/support/fixtures/render_contract_v2.json", import.meta.url),
    "utf8",
  ),
)

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

test("renders every version two contract instruction as a deterministic neutral fiber fallback", () => {
  for (const contractInstruction of versionTwoContract) {
    const first = buildTopology([contractInstruction])
    const second = buildTopology([structuredClone(contractInstruction)])

    assert.deepEqual(second, first)
    assert.equal(first.fallbacks.length, 1)
    assert.equal(first.fallbacks[0].kind, contractInstruction.kind)
    assert.equal(first.fallbacks[0].source, contractInstruction.source)
    assertBoundedFallback(first.fallbacks[0])
    assertFiniteTopology(first)
  }
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

  assert.equal(topology.fallbacks.length, 1)
  assert.equal(topology.fallbacks[0].kind, "slot")
  assert.equal(topology.fallbacks[0].source, "solana")
})

test("preserves JSON-safe drand rounds beyond the uint32 counter range", () => {
  const drand = structuredClone(versionTwoContract[3])
  drand.metrics.round = Number.MAX_SAFE_INTEGER

  const topology = buildTopology([drand])

  assert.equal(topology.fallbacks.length, 1)
  assert.equal(topology.fallbacks[0].kind, "randomness")
  assert.equal(topology.fallbacks[0].source, "drand")
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

  assert.equal(oneSlotTopology.fallbacks[0].kind, "slot")
  assert.equal(multiSlotTopology.fallbacks[0].kind, "slot")
  assert.equal(malformedTopology.fallbacks[0].kind, "fallback")
  assert.equal(malformedTopology.fallbacks[0].source, "visitor")
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
