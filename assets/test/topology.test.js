import assert from "node:assert/strict"
import test from "node:test"

import {buildTopology} from "../js/worldloom/topology.js"

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
