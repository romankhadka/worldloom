import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {grammarFor} from "../js/worldloom/source_grammar.js"
import {balanced} from "./fixtures/balanced_snapshots.js"

const uint32Maximum = 4_294_967_295

const instructions = {
  wikimedia: displayInstruction("wikimedia"),
  bluesky: displayInstruction("bluesky"),
  ripeRis: displayInstruction("ripe_ris"),
  solana: displayInstruction("solana"),
  drand: displayInstruction("drand"),
  earthquake: balanced.memory_events.find(instruction => instruction.source === "usgs"),
  weather: balanced.ambient,
  visitor: balanced.memory_events.find(instruction => instruction.source === "visitor"),
}

test("assigns every public signal its exact structural role", () => {
  assert.equal(grammarFor(instructions.wikimedia).role, "backbone")
  assert.equal(grammarFor(instructions.bluesky).role, "conversation-fan")
  assert.equal(grammarFor(instructions.ripeRis).role, "route-fork")
  assert.equal(grammarFor(instructions.solana).role, "slot-braid")
  assert.equal(grammarFor(instructions.drand).role, "public-pulse")
  assert.equal(grammarFor(instructions.earthquake).role, "rupture")
  assert.equal(grammarFor(instructions.weather).role, "atmosphere")
  assert.equal(grammarFor(instructions.visitor).role, "intervention")
})

test("gives every signal a stable, unique, non-color structure signature", () => {
  const grammars = Object.values(instructions).map(instruction => grammarFor(instruction))
  const signatures = grammars.map(grammar =>
    [grammar.pathStyle, grammar.markerStyle, grammar.rhythm].join("\0")
  )

  assert.equal(new Set(signatures).size, grammars.length)
  for (const [index, grammar] of grammars.entries()) {
    assert.equal(grammar.structureSignature, signatures[index])
    assert.deepEqual(grammarFor(structuredClone(Object.values(instructions)[index])), grammar)
  }

  const source = readFileSync(
    new URL("../js/worldloom/source_grammar.js", import.meta.url),
    "utf8",
  )
  assert.doesNotMatch(source, /#[\da-f]{3,8}\b|\brgba?\s*\(/i)
})

test("keeps every structural number finite and inside explicit count and width bounds", () => {
  for (const instruction of Object.values(instructions)) {
    const grammar = grammarFor({
      ...structuredClone(instruction),
      lane: Number.POSITIVE_INFINITY,
      intensity: 1_000,
      visual: {spread: -1_000, bend: Number.NaN, pulse: 1_000},
    })

    assert.ok(grammar.count >= 1 && grammar.count <= 12)
    assert.ok(grammar.width >= 0.5 && grammar.width <= 8)
    assert.ok(grammar.lane >= 0 && grammar.lane <= 1)
    assert.ok(grammar.intensity >= 0 && grammar.intensity <= 1)
    assertFiniteNumbers(grammar)
  }
})

test("uses only allow-listed, clamped aggregate metrics", () => {
  const bluesky = structuredClone(instructions.bluesky)
  bluesky.metrics = {
    ...bluesky.metrics,
    total_actions: Number.MAX_SAFE_INTEGER,
    original_posts: -10,
    replies: Number.POSITIVE_INFINITY,
    reposts: 23.9,
    post_text: "must never enter the grammar",
  }

  const grammar = grammarFor(bluesky)

  assert.deepEqual(Object.keys(grammar.metrics).sort(), [
    "creates",
    "deletes",
    "original_posts",
    "replies",
    "reposts",
    "total_actions",
    "truncated",
    "updates",
    "window_count",
    "window_span_seconds",
  ])
  assert.equal(grammar.metrics.total_actions, uint32Maximum)
  assert.equal(grammar.metrics.original_posts, 0)
  assert.equal(grammar.metrics.replies, 0)
  assert.equal(grammar.metrics.reposts, 23)
  assert.equal(Object.hasOwn(grammar.metrics, "post_text"), false)
  assert.equal(JSON.stringify(grammar).includes("must never enter"), false)
  assert.equal(grammar.branchCount, 8)
})

test("ignores inherited metrics and never invokes metric accessors", () => {
  const inheritedMetrics = Object.create({
    total_actions: uint32Maximum,
    replies: uint32Maximum,
    reposts: uint32Maximum,
  })
  const inherited = grammarFor({...instructions.bluesky, metrics: inheritedMetrics})
  const accessorMetrics = {}
  Object.defineProperty(accessorMetrics, "total_actions", {
    enumerable: true,
    get() {
      throw new Error("metric getter must not run")
    },
  })
  const revokedMetrics = Proxy.revocable({}, {})
  revokedMetrics.revoke()

  assert.equal(inherited.metrics.total_actions, 0)
  assert.equal(inherited.metrics.replies, 0)
  assert.equal(inherited.metrics.reposts, 0)
  assert.equal(inherited.branchCount, 1)
  assert.doesNotThrow(() => grammarFor({...instructions.bluesky, metrics: accessorMetrics}))
  assert.equal(
    grammarFor({...instructions.bluesky, metrics: accessorMetrics}).metrics.total_actions,
    0,
  )
  assert.doesNotThrow(() =>
    grammarFor({...instructions.bluesky, metrics: revokedMetrics.proxy})
  )
  assert.equal(
    grammarFor({...instructions.bluesky, metrics: revokedMetrics.proxy}).metrics.total_actions,
    0,
  )
})

test("ignores inherited and accessor instruction fields without throwing", () => {
  const inheritedInstruction = Object.create(instructions.wikimedia)
  const sourceAccessor = {...instructions.wikimedia}
  Object.defineProperty(sourceAccessor, "source", {
    enumerable: true,
    get() {
      throw new Error("source getter must not run")
    },
  })
  const visualAccessors = {}
  Object.defineProperty(visualAccessors, "spread", {
    enumerable: true,
    get() {
      throw new Error("visual getter must not run")
    },
  })
  const hostileProxy = new Proxy({}, {
    getOwnPropertyDescriptor() {
      throw new Error("descriptor trap must be contained")
    },
  })
  const revokedInstruction = Proxy.revocable({}, {})
  revokedInstruction.revoke()

  assert.deepEqual(grammarFor(inheritedInstruction), grammarFor(null))
  assert.doesNotThrow(() => grammarFor(sourceAccessor))
  assert.deepEqual(grammarFor(sourceAccessor), grammarFor(null))
  assert.doesNotThrow(() => grammarFor({...instructions.wikimedia, visual: visualAccessors}))
  assert.equal(grammarFor({...instructions.wikimedia, visual: visualAccessors}).spread, 0.5)
  assert.doesNotThrow(() => grammarFor(hostileProxy))
  assert.deepEqual(grammarFor(hostileProxy), grammarFor(null))
  assert.doesNotThrow(() => grammarFor(revokedInstruction.proxy))
  assert.deepEqual(grammarFor(revokedInstruction.proxy), grammarFor(null))
})

test("derives bounded source behavior from genuine aggregate meaning", () => {
  const quietBluesky = grammarFor(withMetrics(instructions.bluesky, {
    total_actions: 1,
    replies: 0,
    reposts: 0,
  }))
  const busyBluesky = grammarFor(withMetrics(instructions.bluesky, {
    total_actions: 1_000,
    replies: 600,
    reposts: 300,
  }))
  assert.ok(quietBluesky.branchCount < busyBluesky.branchCount)
  assert.equal(busyBluesky.branchCount, 8)
  assert.ok(busyBluesky.divergence > quietBluesky.divergence)
  assert.ok(busyBluesky.returnStrength > quietBluesky.returnStrength)

  const ripe = grammarFor(withMetrics(instructions.ripeRis, {
    announced: 5_000,
    withdrawn: 2_500,
  }))
  assert.equal(ripe.forkCount, 6)
  assert.ok(ripe.extension > 0)
  assert.ok(ripe.pinch > 0)

  const solana = grammarFor(withMetrics(instructions.solana, {
    slot_count: 5_000,
    gap_count: 2_500,
  }))
  assert.equal(solana.beadCount, 12)
  assert.ok(solana.gapBreakCount >= 1 && solana.gapBreakCount <= 11)

  const drand = grammarFor(instructions.drand)
  assert.equal(drand.pulseCount, 1)
  assert.equal(drand.count, 1)
})

test("lets Wikimedia edit volume change thickness without multiplying its backbone", () => {
  const fine = grammarFor({...instructions.wikimedia, intensity: 0.1})
  const active = grammarFor({...instructions.wikimedia, intensity: 0.9})

  assert.equal(fine.count, 1)
  assert.equal(active.count, 1)
  assert.ok(active.width > fine.width)
})

test("keeps all visitor interventions structural and separately recognizable", () => {
  const visitor = instructions.visitor
  const grammars = ["tug", "knot", "illuminate"].map(kind =>
    grammarFor({...visitor, kind})
  )

  assert.ok(grammars.every(grammar => grammar.role === "intervention"))
  assert.equal(
    new Set(grammars.map(grammar => grammar.structureSignature)).size,
    grammars.length,
  )
})

test("denies unknown pairs and exact-version mismatches by returning a neutral fallback", () => {
  const unsupported = [
    {...instructions.wikimedia, source: "bluesky"},
    {...instructions.bluesky, kind: "slot"},
    {...instructions.wikimedia, render_version: 2},
    {...instructions.bluesky, render_version: 1},
    {...instructions.wikimedia, source: ["wikimedia"]},
    {...instructions.wikimedia, kind: {name: "wikimedia"}},
  ]

  for (const instruction of unsupported) {
    assert.deepEqual(grammarFor(instruction), grammarFor(null))
  }
})

test("returns the finite neutral fallback for every unknown positive render version", () => {
  for (const renderVersion of [3, 99, Number.MAX_SAFE_INTEGER]) {
    const grammar = grammarFor({
      ...instructions.bluesky,
      render_version: renderVersion,
      lane: -90,
      intensity: Number.NaN,
      visual: {spread: Infinity, bend: -Infinity, pulse: Number.NaN},
      metrics: {private_identifier: "discard me"},
    })

    assert.equal(grammar.role, "neutral")
    assert.equal(grammar.structureSignature, "neutral-line\0neutral-mark\0steady")
    assert.deepEqual(grammar.metrics, {})
    assert.ok(grammar.count >= 1 && grammar.count <= 12)
    assert.ok(grammar.width >= 0.5 && grammar.width <= 8)
    assertFiniteNumbers(grammar)
  }
})

function displayInstruction(source) {
  return balanced.display_events.find(instruction => instruction.source === source)
}

function withMetrics(instruction, overrides) {
  return {
    ...structuredClone(instruction),
    metrics: {...instruction.metrics, ...overrides},
  }
}

function assertFiniteNumbers(value) {
  if (typeof value === "number") {
    assert.ok(Number.isFinite(value), `expected ${value} to be finite`)
    return
  }
  if (Array.isArray(value)) {
    value.forEach(assertFiniteNumbers)
    return
  }
  if (value && typeof value === "object") {
    Object.values(value).forEach(assertFiniteNumbers)
  }
}
