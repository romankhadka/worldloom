import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

import {
  chapterSeams,
  cubicPrefix,
  commandsForEvent,
  commandsForScene,
  laneToY,
  sequenceToX,
} from "../js/worldloom/geometry.js"

const contract = JSON.parse(
  await readFile(new URL("../../test/support/fixtures/render_contract_v1.json", import.meta.url)),
)

const viewport = {width: 1000, height: 600, maxSequence: 106, spacing: 40, padding: 50}

test("projects sequence horizontally and lane vertically", () => {
  assert.equal(sequenceToX(106, viewport), 950)
  assert.equal(sequenceToX(101, viewport), 750)
  assert.equal(sequenceToX(101, {...viewport, panOffset: 25}), 775)
  assert.equal(laneToY(0, viewport), 50)
  assert.equal(laneToY(0.5, viewport), 300)
  assert.equal(laneToY(1, viewport), 550)
})

test("generates stable commands and hit regions for every signal and gesture", () => {
  const expectedTypes = {
    wikimedia: "fiber",
    earthquake: "ripple",
    weather: "ambient",
    tug: "tug",
    knot: "knot",
    illuminate: "glow",
  }

  for (const instruction of contract) {
    const first = commandsForEvent(instruction, viewport)
    const second = commandsForEvent(instruction, viewport)

    assert.deepEqual(first, second)
    assert.equal(first[0].type, expectedTypes[instruction.kind])
    assert.equal(first[0].sequence, instruction.sequence)
    assert.ok(first[0].hit.width >= 20)
    assert.ok(first[0].hit.height >= 20)
  }
})

test("falls back safely when a future render version is encountered", () => {
  const [instruction] = contract
  const [command] = commandsForEvent({...instruction, render_version: 99}, viewport)

  assert.equal(command.type, "fallback")
  assert.equal(command.contractVersion, 1)
})

test("holds ambient weather outside the visible event window", () => {
  const visible = contract.filter(instruction => instruction.kind !== "weather")
  const ambient = contract.find(instruction => instruction.kind === "weather")
  const commands = commandsForScene(visible, viewport, {ambient})

  assert.equal(commands.filter(command => command.type === "ambient").length, 1)
})

test("adds UTC chapter seams at date transitions", () => {
  const events = [
    {...contract[0], occurred_at: "2026-08-03T23:59:59.000000Z"},
    {...contract[1], occurred_at: "2026-08-04T00:00:00.000000Z"},
  ]

  assert.deepEqual(chapterSeams(events, viewport), [
    {
      type: "seam",
      date: "2026-08-04",
      x: sequenceToX(events[1].sequence, viewport),
    },
  ])
})

test("reprojects from normalized instructions after resize", () => {
  const instruction = contract[0]
  const [small] = commandsForEvent(instruction, {...viewport, width: 500, height: 300})
  const [large] = commandsForEvent(instruction, {...viewport, width: 1000, height: 600})

  assert.equal((small.y - 50) / (300 - 100), instruction.lane)
  assert.equal((large.y - 50) / (600 - 100), instruction.lane)
  assert.notEqual(large.x, small.x)
  assert.equal(large.sequence, small.sequence)
})

test("projects long connected paths with continuous shared tangents", () => {
  const instructions = Array.from({length: 40}, (_item, index) => ({
    ...contract[0],
    sequence: index + 1,
    seed: index + 101,
    lane: 0.42 + Math.sin(index / 5) * 0.18,
  }))
  const denseViewport = {...viewport, maxSequence: 40}
  const paths = commandsForScene(instructions, denseViewport).filter(
    command => command.type === "fiber-path",
  )

  assert.ok(paths.length >= 2)
  assert.ok(paths.slice(0, -1).every(path => path.width >= denseViewport.width * 0.35))
  assert.ok(paths.every(path => path.width <= denseViewport.width * 0.65))

  const segments = paths.flatMap(path => path.segments)
  for (let index = 1; index < segments.length; index++) {
    const previous = segments[index - 1].curve
    const current = segments[index].curve
    assert.deepEqual(previous.to, current.from)
    assert.ok(tangentDifference(previous, current) < 1e-6)
  }
})

test("projects earthquakes and visitor gestures as distinct structural commands", () => {
  const commands = commandsForScene(contract, viewport)
  const types = new Set(commands.map(command => command.type))

  assert.ok(types.has("ripple"))
  assert.ok(types.has("tug-response"))
  assert.ok(types.has("knot-connector"))
  assert.ok(types.has("illuminate-bloom"))

  const knot = commands.find(command => command.type === "knot-connector")
  const crossover = cubicPrefix(knot.curve, 0.5).to
  assert.deepEqual({x: knot.x, y: knot.y}, crossover)

  const illuminateInstruction = contract.find(instruction => instruction.kind === "illuminate")
  const illuminatedScene = commandsForScene([
    {...contract[0], sequence: 1, lane: 0.25},
    {...contract[0], sequence: 2, lane: 0.35},
    {...illuminateInstruction, sequence: 3, lane: 0.3},
  ], {...viewport, maxSequence: 3})
  const illuminate = illuminatedScene.find(command => command.type === "illuminate-bloom")
  assert.ok(illuminate.glowCurves.length >= 1)
  assert.ok(illuminate.glowCurves.length <= 3)
  assert.ok(illuminate.glowCurves.every(curve =>
    curve.from.x === illuminate.x && curve.from.y === illuminate.y
  ))
})

test("connects a new branch back into the established weave", () => {
  const instructions = [
    {...contract[0], sequence: 1, lane: 0},
    {...contract[0], sequence: 2, lane: 1},
  ]
  const connector = commandsForScene(instructions, {...viewport, maxSequence: 2}).find(
    command => command.type === "fiber-path" && command.role === "connector",
  )

  assert.equal(connector.segments.length, 1)
  assert.equal(connector.segments[0].sequence, 2)
  assert.notDeepEqual(connector.segments[0].curve.from, connector.segments[0].curve.to)
})

test("keeps older spline coordinates on the offscreen timeline for panning", () => {
  const instructions = Array.from({length: 40}, (_item, index) => ({
    ...contract[0],
    sequence: index + 1,
    lane: 0.5,
  }))
  const paths = commandsForScene(instructions, {...viewport, maxSequence: 40}).filter(
    command => command.type === "fiber-path",
  )
  const points = paths.flatMap(path => path.segments.flatMap(segment => [
    segment.curve.from,
    segment.curve.to,
  ]))

  assert.ok(points.some(point => point.x < viewport.padding))
  assert.ok(points.every(point => point.y >= viewport.padding))
  assert.ok(points.every(point => point.y <= viewport.height - viewport.padding))
})

test("extracts deterministic cubic prefixes for growth animation", () => {
  const curve = {
    from: {x: 0, y: 0},
    control1: {x: 25, y: 50},
    control2: {x: 75, y: -50},
    to: {x: 100, y: 0},
  }

  assert.deepEqual(cubicPrefix(curve, 0), {
    from: curve.from,
    control1: curve.from,
    control2: curve.from,
    to: curve.from,
  })
  assert.deepEqual(cubicPrefix(curve, 1), curve)
  assert.deepEqual(cubicPrefix(curve, 2), curve)
})

test("keeps malformed scene commands finite", () => {
  const commands = commandsForScene([{...contract[0], lane: Number.NaN}], viewport)
  const hit = commands.find(command => command.type === "anchor-hit")
  const fallback = commands.find(command => command.type === "fallback")

  assert.ok(Number.isFinite(hit.x))
  assert.ok(Number.isFinite(hit.y))
  assert.ok(Number.isFinite(hit.hit.x))
  assert.ok(Number.isFinite(hit.hit.y))
  assert.ok(Number.isFinite(fallback.x))
  assert.ok(Number.isFinite(fallback.y))
})

function tangentDifference(previous, current) {
  const outgoing = normalize({
    x: previous.to.x - previous.control2.x,
    y: previous.to.y - previous.control2.y,
  })
  const incoming = normalize({
    x: current.control1.x - current.from.x,
    y: current.control1.y - current.from.y,
  })
  return Math.hypot(outgoing.x - incoming.x, outgoing.y - incoming.y)
}

function normalize(vector) {
  const length = Math.hypot(vector.x, vector.y) || 1
  return {x: vector.x / length, y: vector.y / length}
}
