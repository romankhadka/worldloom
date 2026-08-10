import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

import {
  chapterSeams,
  cubicPrefix,
  commandsForEvent,
  commandsForScene,
  eventTimeToX,
  laneToY,
  sequenceToX,
} from "../js/worldloom/geometry.js"
import {signalPalette} from "../js/worldloom/palette.js"
import {balanced} from "./fixtures/balanced_snapshots.js"

const contract = JSON.parse(
  await readFile(new URL("../../test/support/fixtures/render_contract_v1.json", import.meta.url)),
)
const balancedSnapshot = JSON.parse(
  await readFile(
    new URL("../../test/support/fixtures/live_snapshots/balanced_v1.json", import.meta.url),
  ),
)
const versionTwoContract = JSON.parse(
  await readFile(new URL("../../test/support/fixtures/render_contract_v2.json", import.meta.url)),
)

const viewport = {width: 1000, height: 600, maxSequence: 106, spacing: 40, padding: 50}

test("projects one five and fifteen minute axes exactly across the drawable width", () => {
  const projectionViewport = {width: 800, height: 600, padding: 40}

  for (const durationMilliseconds of [60_000, 300_000, 900_000]) {
    const axis = {
      end: "2026-08-09T12:15:00.000Z",
      durationMilliseconds,
    }
    const start = new Date(Date.parse(axis.end) - durationMilliseconds).toISOString()

    assert.equal(eventTimeToX(start, axis, projectionViewport), projectionViewport.padding)
    assert.equal(
      eventTimeToX(axis.end, axis, projectionViewport),
      projectionViewport.width - projectionViewport.padding,
    )
  }
})

test("uses one fifteen-minute axis for structural and hit geometry", () => {
  const instruction = {
    ...structuredClone(versionTwoContract[0]),
    sequence: 90_001,
    occurred_at: "2026-08-09T12:07:30.000Z",
  }
  const axis = {
    end: "2026-08-09T12:15:00.000Z",
    durationMilliseconds: 900_000,
  }
  const commands = commandsForScene([instruction], viewport, {
    axis,
    displayInstructions: [instruction],
    projectionInstructions: [instruction],
    hitInstructions: [instruction],
  })
  const formation = commands.find(command => command.sequence === instruction.sequence &&
    command.type !== "anchor-hit")
  const hit = commands.find(command => command.sequence === instruction.sequence &&
    command.type === "anchor-hit")

  assert.equal(formation.x, viewport.width / 2)
  assert.equal(hit.x, formation.x)
  assert.equal(hit.hit.x + hit.hit.width / 2, formation.x)
})

test("projects the snapshot minute exactly across the drawable width", () => {
  const projectionViewport = {width: 1001, height: 600, padding: 50}
  const xFor = occurredAt => eventTimeToX(
    occurredAt,
    timelineAxis(balancedSnapshot.window_end),
    projectionViewport,
  )

  assert.equal(xFor("2026-08-08T12:00:00Z"), projectionViewport.padding)
  assert.equal(
    xFor("2026-08-08T12:00:30Z"),
    projectionViewport.padding + 0.5 * (projectionViewport.width - 2 * projectionViewport.padding),
  )
  assert.equal(
    xFor("2026-08-08T12:01:00Z"),
    projectionViewport.width - projectionViewport.padding,
  )
})

test("keeps equal event times in one column while lanes remain distinct", () => {
  const first = {
    ...balancedSnapshot.display_events[0],
    sequence: 1,
    occurred_at: "2026-08-08T12:00:30Z",
    lane: 0.2,
  }
  const second = {
    ...balancedSnapshot.display_events[1],
    sequence: 9_001,
    occurred_at: first.occurred_at,
    lane: 0.8,
  }
  const commands = balancedSceneCommands({displayInstructions: [first, second]})
  const hits = commands.filter(command => command.type === "anchor-hit")

  assert.deepEqual(hits.map(hit => hit.x), [viewport.width / 2, viewport.width / 2])
  assert.notEqual(hits[0].y, hits[1].y)
  assert.deepEqual(hits.map(hit => hit.sequence), [first.sequence, second.sequence])
})

test("projects every valid version two topology formation into one visible structural command", () => {
  const expectedRoles = new Map([
    ["bluesky", "conversation-fan"],
    ["ripe_ris", "route-fork"],
    ["solana", "slot-braid"],
    ["drand", "public-pulse"],
  ])
  const axis = timelineAxis("2026-08-03T12:01:03.000Z")

  for (const instruction of versionTwoContract) {
    const commands = commandsForScene([instruction], viewport, {
      axis,
      displayInstructions: [instruction],
      projectionInstructions: [instruction],
      hitInstructions: [instruction],
    })
    const structural = commands.filter(command =>
      command.sequence === instruction.sequence && command.type !== "anchor-hit"
    )

    assert.equal(structural.length, 1, `${instruction.source} must not disappear after topology`)
    assert.equal(structural[0].role, expectedRoles.get(instruction.source))
    assert.equal(structural[0].source, instruction.source)
    assert.equal(
      structural[0].x,
      eventTimeToX(instruction.occurred_at, axis, viewport),
    )
    assert.ok(projectedPoints(structural[0]).length > 0)
    assert.equal(commands.filter(command => command.type === "anchor-hit").length, 1)
  }
})

test("derives each source material from its bounded grammar width", () => {
  for (const instruction of versionTwoContract) {
    const commands = commandsForScene([instruction], viewport, {
      axis: timelineAxis("2026-08-03T12:01:03.000Z"),
      displayInstructions: [instruction],
      projectionInstructions: [instruction],
      hitInstructions: [instruction],
    })
    const structural = commands.find(command =>
      command.sequence === instruction.sequence && command.type !== "anchor-hit"
    )

    assert.equal(structural.material.core.width, structural.width)
    assert.ok(structural.material.body.width > structural.material.core.width)
    assert.ok(structural.material.glow.width > structural.material.body.width)
  }
})

test("separates equal-time source families without leaving the shared event-time column", () => {
  const occurredAt = "2026-08-08T12:00:30.000Z"
  const instructions = versionTwoContract.map((instruction, index) => ({
    ...structuredClone(instruction),
    sequence: 20_000 + index,
    occurred_at: occurredAt,
    lane: 0.5,
  }))
  const commands = balancedSceneCommands({
    displayInstructions: instructions,
    memoryInstructions: [],
    ambient: null,
  })
  const structural = commands.filter(command =>
    instructions.some(instruction => instruction.sequence === command.sequence) &&
      command.type !== "anchor-hit"
  )
  const expectedX = eventTimeToX(
    occurredAt,
    timelineAxis(balancedSnapshot.window_end),
    viewport,
  )

  assert.equal(structural.length, instructions.length)
  assert.ok(structural.every(command => command.x === expectedX))
  assert.equal(new Set(structural.map(command => command.y)).size, instructions.length)
  assert.equal(new Set(structural.map(command => command.role)).size, instructions.length)
  assert.ok(structural.every(command => projectedPoints(command).length > 0))
  for (const point of structural.flatMap(projectedPoints)) {
    assert.ok(point.x >= viewport.padding && point.x <= viewport.width - viewport.padding)
    assert.ok(point.y >= viewport.padding && point.y <= viewport.height - viewport.padding)
  }
  assertCanvasSafeNumbers(structural)
})

test("separates every public material above the mobile interaction dock", () => {
  const mobileViewport = {width: 390, height: 844, padding: 40}
  const commands = balancedSceneCommands({
    displayInstructions: balanced.display_events,
    memoryInstructions: balanced.memory_events,
    ambient: balanced.ambient,
  }, mobileViewport)
  const roles = ["conversation-fan", "route-fork", "public-pulse", "slot-braid"]
  const roleY = roles.map(role =>
    commands.find(command => command.role === role)?.y
  )

  assert.ok(roleY.every(Number.isFinite))
  assert.ok(roleY.every((y, index) => index === 0 || y - roleY[index - 1] >= 80))
  assert.ok(
    commands
      .filter(command => roles.includes(command.role))
      .flatMap(projectedPoints)
      .every(point => point.y <= 620),
  )
})

test("keeps source structures bounded before command creation", () => {
  const commands = balancedSceneCommands({
    displayInstructions: balanced.display_events,
    memoryInstructions: balanced.memory_events,
    ambient: balanced.ambient,
  })
  const sourceCommands = commands.filter(command =>
    ["conversation-fan", "route-fork", "slot-braid", "public-pulse"].includes(command.role)
  )
  const sourceInstructions = balanced.display_events.filter(instruction =>
    ["bluesky", "ripe_ris", "solana", "drand"].includes(instruction.source)
  )

  assert.equal(sourceCommands.length, sourceInstructions.length)
  assert.ok(sourceCommands.filter(command => command.role === "conversation-fan")
    .every(command => command.branches.length >= 1 && command.branches.length <= 8))
  assert.ok(sourceCommands.filter(command => command.role === "route-fork")
    .every(command => command.segments.length >= 1 && command.segments.length <= 6))
  assert.ok(sourceCommands.filter(command => command.role === "slot-braid")
    .every(command => command.beads.length >= 1 && command.beads.length <= 12))
  assert.ok(sourceCommands.filter(command => command.role === "slot-braid")
    .every(command => command.gapMarkers.length <= 11))
  assert.ok(sourceCommands.filter(command => command.role === "public-pulse")
    .every(command => command.crystals.length === 1))
  assert.ok(sourceCommands.some(command => command.attachment !== null))
  assert.ok(sourceCommands.filter(command => command.attachment !== null)
    .every(command => projectedPoints(command.attachment).length === 1))
  assert.ok(commands.length <= 4000)
  assert.equal(commands.some(command => command.type.endsWith("-glow-copy")), false)
})

test("projects version two history linearly left on the shared event-time scale", () => {
  const live = {
    ...structuredClone(versionTwoContract[0]),
    sequence: 30_001,
    occurred_at: "2026-08-08T12:00:30.000Z",
  }
  const history = {
    ...structuredClone(versionTwoContract[1]),
    sequence: 30_000,
    occurred_at: "2026-08-08T11:59:30.000Z",
  }
  const commands = balancedSceneCommands({
    displayInstructions: [live],
    historyInstructions: [history],
    memoryInstructions: [],
    ambient: null,
  })
  const liveCommand = commands.find(command =>
    command.sequence === live.sequence && command.role === "conversation-fan"
  )
  const historyCommand = commands.find(command =>
    command.sequence === history.sequence && command.role === "route-fork"
  )
  const usableWidth = viewport.width - viewport.padding * 2

  assert.equal(liveCommand.x, viewport.padding + usableWidth / 2)
  assert.equal(historyCommand.x, viewport.padding - usableWidth / 2)
  assert.equal(liveCommand.x - historyCommand.x, usableWidth)
})

test("drops display rows older than the snapshot minute before building topology", () => {
  const expired = {
    ...balancedSnapshot.display_events[0],
    sequence: 800,
    occurred_at: "2026-08-08T11:59:59Z",
  }
  const current = {
    ...balancedSnapshot.display_events[1],
    sequence: 801,
    occurred_at: "2026-08-08T12:00:30Z",
  }

  const commands = balancedSceneCommands({displayInstructions: [expired, current]})

  assert.equal(commands.some(command => command.sequence === expired.sequence), false)
  assert.equal(commands.some(command => command.sequence === current.sequence), true)
})

test("matches the server's whole-second membership at both live-window boundaries", () => {
  const timestamps = [
    [1, "2026-08-08T12:00:00Z"],
    [2, "2026-08-08T12:00:00.999Z"],
    [3, "2026-08-08T12:01:00Z"],
    [4, "2026-08-08T12:01:00.999Z"],
    [5, "2026-08-08T11:59:59.999Z"],
    [6, "2026-08-08T12:01:01Z"],
  ]
  const display = timestamps.map(([sequence, occurredAt]) => ({
    ...balancedSnapshot.display_events[0],
    sequence,
    occurred_at: occurredAt,
  }))

  const commands = balancedSceneCommands({displayInstructions: display})
  const hits = commands.filter(command => command.type === "anchor-hit")
  const hitBySequence = new Map(hits.map(hit => [hit.sequence, hit]))
  const usableWidth = viewport.width - viewport.padding * 2

  assert.deepEqual([...hitBySequence.keys()], [1, 2, 3, 4])
  assert.equal(hitBySequence.get(1).x, viewport.padding)
  assert.equal(hitBySequence.get(2).x, viewport.padding + usableWidth * (0.999 / 60))
  assert.equal(hitBySequence.get(3).x, viewport.width - viewport.padding)
  assert.equal(hitBySequence.get(4).x, viewport.width - viewport.padding)
  const topologySequences = new Set(commands.flatMap(command => [
    command.sequence,
    ...(command.segments ?? []).map(segment => segment.sequence),
  ]))
  assert.equal(topologySequences.has(5), false)
  assert.equal(topologySequences.has(6), false)
})

test("keeps contextual memory in a labeled quiet band with its real identity", () => {
  const memory = balancedSnapshot.memory_events[0]
  const commands = balancedSceneCommands()
  const band = commands.find(command => command.type === "memory-band")
  const trace = commands.find(command =>
    command.type === "memory-trace" && command.sequence === memory.sequence
  )

  assert.ok(band)
  assert.equal(band.label, "Earlier traces")
  assert.equal(band.role, "contextual-memory")
  assert.ok(trace)
  assert.equal(trace.role, "contextual-memory")
  assert.equal(trace.occurredAt, memory.occurred_at)
  assert.equal(trace.sequence, memory.sequence)
  assert.ok(trace.hit)
  assert.ok(trace.y > viewport.height - viewport.padding)
  assert.equal(
    commands.some(command =>
      command.type === "anchor-hit" && command.sequence === memory.sequence
    ),
    false,
  )
})

test("preserves the server's canonical contextual memory order", () => {
  const commands = balancedSceneCommands({
    displayInstructions: balanced.display_events,
    memoryInstructions: balanced.memory_events,
    ambient: balanced.ambient,
  })
  const traceSequences = commands
    .filter(command => command.type === "memory-trace")
    .map(command => command.sequence)

  assert.deepEqual(
    traceSequences,
    balanced.memory_events.map(instruction => instruction.sequence),
  )
})

test("uses a neutral palette for non-string, inherited, and future ambient or memory sources", () => {
  const weather = contract.find(instruction => instruction.kind === "weather")
  const memory = balancedSnapshot.memory_events[0]
  const untrustedSources = JSON.parse(
    '[{"toString":null},["wikimedia"],"__proto__","constructor","bluesky"]',
  )

  for (const [index, source] of untrustedSources.entries()) {
    let ambientCommands
    let memoryCommands

    assert.doesNotThrow(() => {
      ambientCommands = commandsForScene([], viewport, {
        ambient: {...weather, sequence: 200 + index, source},
      })
      memoryCommands = commandsForScene([], viewport, {
        ambient: null,
        memoryInstructions: [{...memory, sequence: 300 + index, source}],
      })
    })

    const ambientCommand = ambientCommands.find(command => command.type === "ambient")
    const memoryCommand = memoryCommands.find(command => command.type === "memory-trace")
    for (const command of [ambientCommand, memoryCommand]) {
      assert.equal(command.stroke, signalPalette.visitor.stroke)
      assert.equal(command.glow, signalPalette.visitor.glow)
    }
    assertCanvasSafeNumbers(ambientCommands)
    assertCanvasSafeNumbers(memoryCommands)
  }
})

test("preserves every known version one source palette", () => {
  for (const contractInstruction of contract) {
    const [command] = commandsForEvent(contractInstruction, viewport)

    assert.equal(command.stroke, signalPalette[contractInstruction.source].stroke)
    assert.equal(command.glow, signalPalette[contractInstruction.source].glow)
  }
})

test("renders a loaded memory event once in its real historical position", () => {
  const memory = balancedSnapshot.memory_events[0]
  const historyAnchor = {
    ...balancedSnapshot.display_events[0],
    sequence: memory.sequence - 1,
    occurred_at: "2026-08-08T11:03:00Z",
  }
  const commands = balancedSceneCommands({historyInstructions: [historyAnchor, memory]})
  const formation = commands.find(command =>
    command.type === "illuminate-bloom" && command.sequence === memory.sequence
  )

  assert.equal(
    commands.some(command =>
      command.type === "memory-trace" && command.sequence === memory.sequence
    ),
    false,
  )
  assert.equal(
    commands.some(command =>
      command.type === "anchor-hit" && command.sequence === memory.sequence
    ),
    true,
  )
  assert.ok(formation)
  assert.equal(formation.hit, undefined)
  assert.ok(Number.isFinite(formation.x))
  assert.ok(Number.isFinite(formation.y))
  assert.equal(formation.occurredAt, memory.occurred_at)
  assert.equal(
    formation.x,
    eventTimeToX(memory.occurred_at, timelineAxis(balancedSnapshot.window_end), viewport, {
      clampToWindow: false,
    }),
  )
})

test("extends historical pages left at the live pixels-per-second scale", () => {
  const history = {
    ...balancedSnapshot.display_events[0],
    sequence: 700,
    occurred_at: "2026-08-08T11:59:30Z",
  }
  const windowStart = {
    ...balancedSnapshot.display_events[0],
    sequence: 701,
    occurred_at: "2026-08-08T12:00:00Z",
  }
  const windowEnd = {
    ...balancedSnapshot.display_events[1],
    sequence: 702,
    occurred_at: "2026-08-08T12:01:00Z",
  }
  const commands = balancedSceneCommands({
    displayInstructions: [windowStart, windowEnd],
    historyInstructions: [history],
  })
  const xBySequence = new Map(
    commands
      .filter(command => command.type === "anchor-hit")
      .map(command => [command.sequence, command.x]),
  )
  const usableWidth = viewport.width - viewport.padding * 2

  assert.equal(xBySequence.get(history.sequence), viewport.padding - usableWidth / 2)
  assert.equal(xBySequence.get(windowStart.sequence), viewport.padding)
  assert.equal(xBySequence.get(windowEnd.sequence), viewport.width - viewport.padding)
  assert.equal(
    (xBySequence.get(windowStart.sequence) - xBySequence.get(history.sequence)) / 30,
    (xBySequence.get(windowEnd.sequence) - xBySequence.get(windowStart.sequence)) / 60,
  )
})

test("keeps six hundred dense Wikimedia rows inside the primary viewport", () => {
  const template = balancedSnapshot.display_events.find(event => event.source === "wikimedia")
  const windowStartMilliseconds = Date.parse(balancedSnapshot.window_end) - 60_000
  const dense = Array.from({length: 600}, (_entry, index) => ({
    ...template,
    sequence: index + 1,
    occurred_at: new Date(windowStartMilliseconds + index * 100).toISOString(),
    lane: 0.2 + (index % 7) * 0.1,
  }))

  const commands = balancedSceneCommands({
    displayInstructions: dense,
    memoryInstructions: [],
    ambient: null,
  })
  const hits = commands.filter(command => command.type === "anchor-hit")

  assert.equal(hits.length, 600)
  assert.ok(hits.every(hit => hit.x >= viewport.padding))
  assert.ok(hits.every(hit => hit.x <= viewport.width - viewport.padding))
  assert.ok(commands.length <= 4000)
})

test("keeps six hundred simultaneous Wikimedia rows finite in one time column", () => {
  const template = balancedSnapshot.display_events.find(event => event.source === "wikimedia")
  const simultaneous = Array.from({length: 600}, (_entry, index) => ({
    ...template,
    sequence: index + 1,
    occurred_at: "2026-08-08T12:00:30Z",
    lane: (index % 11) / 10,
  }))

  const commands = balancedSceneCommands({
    displayInstructions: simultaneous,
    memoryInstructions: [],
    ambient: null,
  })
  const hits = commands.filter(command => command.type === "anchor-hit")
  const midpoint = viewport.padding + (viewport.width - viewport.padding * 2) / 2

  assert.equal(hits.length, 600)
  assert.ok(hits.every(hit => hit.x === midpoint))
  assert.ok(hits.every(hit => Number.isFinite(hit.x) && Number.isFinite(hit.y)))
  assert.ok(commands.length <= 4000)
})

test("ignores sequence distance and scaffold density when placing live events", () => {
  const occurredAt = "2026-08-08T12:00:30Z"
  const display = [
    {...balancedSnapshot.display_events[0], sequence: 2, occurred_at: occurredAt},
    {...balancedSnapshot.display_events[1], sequence: 2_000_000, occurred_at: occurredAt},
  ]
  const scaffold = Array.from({length: 12}, (_entry, index) => ({
    ...balancedSnapshot.display_events[0],
    sequence: 10_000 + index * 73,
    occurred_at: `2026-08-08T11:59:${String(40 + index).padStart(2, "0")}Z`,
  }))
  const withoutScaffold = balancedSceneCommands({displayInstructions: display})
  const withScaffold = balancedSceneCommands({
    displayInstructions: display,
    scaffoldInstructions: scaffold,
  })
  const liveXs = commands => commands
    .filter(command => command.type === "anchor-hit" &&
      display.some(instruction => instruction.sequence === command.sequence))
    .map(command => command.x)
  const midpoint = viewport.padding + 0.5 * (viewport.width - viewport.padding * 2)

  assert.deepEqual(liveXs(withoutScaffold), [midpoint, midpoint])
  assert.deepEqual(liveXs(withScaffold), [midpoint, midpoint])
})

test("projects live scaffold context on its actual event-time coordinate", () => {
  const scaffold = [
    {
      ...balancedSnapshot.display_events[0],
      sequence: 10,
      occurred_at: "2026-08-08T11:59:30Z",
    },
    {
      ...balancedSnapshot.display_events[1],
      sequence: 500_000,
      occurred_at: "2026-08-08T12:00:00Z",
    },
  ]
  const commands = commandsForScene(scaffold, viewport, {
    axis: timelineAxis(balancedSnapshot.window_end),
    displayInstructions: [],
    memoryInstructions: [],
    ambient: null,
    historyInstructions: [],
    scaffoldInstructions: scaffold,
    projectionInstructions: scaffold,
    hitInstructions: scaffold,
  })
  const hits = commands.filter(command => command.type === "anchor-hit")
  const usableWidth = viewport.width - viewport.padding * 2

  assert.deepEqual(hits.map(hit => hit.x), [
    viewport.padding - usableWidth / 2,
    viewport.padding,
  ])
})

test("projects sequence horizontally and lane vertically", () => {
  assert.equal(sequenceToX(106, viewport), 950)
  assert.equal(sequenceToX(101, viewport), 750)
  assert.equal(sequenceToX(101, {...viewport, panOffset: 25}), 775)
  assert.equal(laneToY(0, viewport), 50)
  assert.equal(laneToY(0.5, viewport), 300)
  assert.equal(laneToY(1, viewport), 550)
})

test("caps sparse durable sequence gaps without changing normal public cadence", () => {
  const publicTemplate = contract.find(instruction => instruction.kind === "wikimedia")
  const publicPair = sequences => sequences.map(sequence => ({
    ...publicTemplate,
    sequence,
  }))
  const hitXs = instructions => commandsForScene(
    instructions,
    {...viewport, maxSequence: instructions.at(-1).sequence},
  )
    .filter(command => command.type === "anchor-hit")
    .map(command => command.x)

  const normalXs = hitXs(publicPair([1, 5]))
  const sparseXs = hitXs(publicPair([1, 1000]))

  assert.equal(normalXs[1] - normalXs[0], viewport.spacing * 4)
  assert.equal(sparseXs[1] - sparseXs[0], viewport.spacing * 8)
  assert.deepEqual(
    commandsForScene(publicPair([1, 1000]), {...viewport, maxSequence: 1000})
      .filter(command => command.type === "anchor-hit")
      .map(command => command.sequence),
    [1, 1000],
  )
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

test("keeps weather atmospheric without covering the lacquer surface", () => {
  const weather = contract.find(instruction => instruction.kind === "weather")
  const [quietAtmosphere] = commandsForEvent({...weather, intensity: 0}, viewport)
  const [strongAtmosphere] = commandsForEvent({...weather, intensity: 1}, viewport)
  const embeddedAtmosphere = commandsForScene([
    {...weather, intensity: 1, visual: {...weather.visual, spread: 1}},
  ], viewport).find(command => command.type === "ambient")

  assert.ok(quietAtmosphere.coverage >= 0.05)
  assert.ok([strongAtmosphere, embeddedAtmosphere].every(command => command.coverage <= 0.22))
  assert.ok(strongAtmosphere.coverage > quietAtmosphere.coverage)
})

test("held ambient weather does not re-space the visible event projection", () => {
  const publicInstruction = {...contract[0], sequence: 100, source: "wikimedia", kind: "wikimedia"}
  const visitorTemplate = contract.find(instruction => instruction.source === "visitor")
  const visible = [
    publicInstruction,
    ...Array.from({length: 70}, (_entry, index) => index + 101)
      .filter(sequence => sequence !== 135)
      .map(sequence => ({
        ...visitorTemplate,
        sequence,
        lane: 0.5,
      })),
  ]
  const ambient = {
    ...contract.find(instruction => instruction.kind === "weather"),
    sequence: 135,
  }
  const projectionViewport = {...viewport, maxSequence: 170}

  const withoutAmbient = commandsForScene(visible, projectionViewport)
  const withAmbient = commandsForScene(visible, projectionViewport, {ambient})

  assert.deepEqual(
    withAmbient
      .filter(command => command.type === "anchor-hit")
      .map(command => [command.sequence, command.x]),
    withoutAmbient
      .filter(command => command.type === "anchor-hit")
      .map(command => [command.sequence, command.x]),
  )
  assert.equal(withAmbient.filter(command => command.type === "ambient").length, 1)
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
    command => command.type === "fiber-path" &&
      command.role !== "spine" &&
      command.role !== "capillary",
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

test("projects a viewport-spanning primary spine with bounded material", () => {
  const instructions = Array.from({length: 40}, (_item, index) => ({
    ...contract[0],
    sequence: index + 1,
    lane: index % 2 === 0 ? 0.1 : 0.9,
  }))
  const scene = commandsForScene(instructions, {...viewport, maxSequence: 40})
  const spine = scene.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )

  assert.ok(spine)
  assert.ok(spine.segments.length > 20)
  assert.deepEqual(Object.keys(spine.material), ["glow", "body", "core"])
  assert.ok(spine.material.glow.width > spine.material.body.width)
  assert.ok(spine.material.body.width > spine.material.core.width)
  assert.ok(spine.material.glow.alpha <= 0.18)
})

test("projects a bounded public scaffold as a coherent viewport-spanning spine", () => {
  const publicTemplate = contract.find(instruction => instruction.kind === "wikimedia")
  const visitorTemplate = contract.find(instruction => instruction.source === "visitor")
  const scaffold = Array.from({length: 12}, (_entry, index) => ({
    ...publicTemplate,
    sequence: index * 4 + 1,
    lane: 0.5 + Math.sin(index / 3) * 0.16,
  }))
  const visitors = Array.from({length: 600}, (_entry, index) => ({
    ...visitorTemplate,
    sequence: index + 46,
    lane: 0.5,
  }))
  const topologyInstructions = [...scaffold, ...visitors.slice(-588)]

  const scene = commandsForScene(
    topologyInstructions,
    {...viewport, maxSequence: 645, spacing: 28},
    {
      projectionInstructions: [...scaffold, ...visitors],
      hitInstructions: visitors,
    },
  )
  const spine = scene.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  const visibleXs = spine.segments.flatMap(segment => [
    Math.max(viewport.padding, Math.min(viewport.width - viewport.padding, segment.curve.from.x)),
    Math.max(viewport.padding, Math.min(viewport.width - viewport.padding, segment.curve.to.x)),
  ])

  assert.equal(spine.segments.length, 11)
  assert.ok(Math.max(...visibleXs) - Math.min(...visibleXs) >= viewport.width * 0.65)
  assert.deepEqual(
    scene
      .filter(command => command.type === "anchor-hit")
      .map(command => command.sequence),
    visitors.map(visitor => visitor.sequence),
  )
  assert.ok(scene.length <= 4000)
})

test("keeps legacy chapter scaffold coordinates linearly sequence-spaced", () => {
  const {scaffold, visitors} = publicSurgeInstructions()
  const desktop = {width: 1600, height: 900, padding: 40, spacing: 28, maxSequence: 612}
  const scene = projectedPublicSurge(scaffold, visitors, desktop)
  const spine = scene.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  const visitorHits = scene.filter(command => command.type === "anchor-hit")

  assert.deepEqual(
    spine.segments.map(segment => segment.sequence),
    scaffold.slice(1).map(instruction => instruction.sequence),
  )
  assert.equal(
    spine.segments.at(-1).curve.to.x - spine.segments[0].curve.from.x,
    11 * desktop.spacing,
  )
  assert.equal(
    visitorHits.at(-1).x - spine.segments.at(-1).curve.to.x,
    8 * desktop.spacing,
  )
  assert.deepEqual(
    visitorHits.map(command => command.sequence),
    visitors.map(visitor => visitor.sequence),
  )
})

test("reserves narrow live-edge width for multiple real scaffold segments", () => {
  const {scaffold, visitors} = publicSurgeInstructions()
  const narrow = {width: 390, height: 844, padding: 40, spacing: 28, maxSequence: 612}
  const scene = projectedPublicSurge(scaffold, visitors, narrow)
  const spine = scene.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  const visitorHits = scene.filter(command => command.type === "anchor-hit")
  const visible = visibleSpineMetrics(spine, narrow)

  assert.equal(
    visitorHits.at(-1).x - spine.segments.at(-1).curve.to.x,
    3 * narrow.spacing,
  )
  assert.ok(visible.segmentCount >= 3)
  assert.ok(visible.span >= (narrow.width - narrow.padding * 2) * 0.65)
  assert.deepEqual(
    visitorHits.map(command => command.sequence),
    visitors.map(visitor => visitor.sequence),
  )
})

test("derives cosmetic fiber layers from one structural command", () => {
  const instructions = Array.from({length: 60}, (_item, index) => ({
    ...contract[0],
    sequence: index + 1,
    lane: 0.5 + Math.sin(index / 8) * 0.2,
  }))
  const scene = commandsForScene(instructions, {...viewport, maxSequence: 60})
  const structuralPaths = scene.filter(command => command.type === "fiber-path")

  assert.ok(structuralPaths.every(command => command.material))
  assert.ok(scene.length <= 4000)
  assert.equal(scene.some(command => command.type === "fiber-glow-copy"), false)
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

test("bounds extreme finite version one values at every geometry projection boundary", () => {
  const extremeVisual = {
    spread: Number.MAX_VALUE,
    bend: -Number.MAX_VALUE,
    pulse: Number.MAX_VALUE,
  }
  const extremeInstructions = [
    {...contract[0], sequence: 1, intensity: Number.MAX_VALUE, visual: extremeVisual},
    {
      ...contract[0],
      sequence: 2,
      lane: 0.8,
      intensity: Number.MAX_VALUE,
      visual: extremeVisual,
    },
    ...contract.slice(1).map((contractInstruction, index) => ({
      ...contractInstruction,
      sequence: index + 3,
      intensity: Number.MAX_VALUE,
      visual: extremeVisual,
    })),
  ]

  const directCommands = extremeInstructions.flatMap(contractInstruction =>
    commandsForEvent(contractInstruction, {...viewport, maxSequence: 7})
  )
  const sceneCommands = commandsForScene(
    extremeInstructions,
    {...viewport, maxSequence: 7},
  )

  assertCanvasSafeNumbers(directCommands)
  assertCanvasSafeNumbers(sceneCommands)
  assert.ok(sceneCommands.some(command => command.type === "ripple"))
  assert.ok(sceneCommands.some(command => command.type === "knot-connector"))
  assert.ok(sceneCommands.some(command => command.type === "illuminate-bloom"))
})

function publicSurgeInstructions() {
  const publicTemplate = contract.find(instruction => instruction.kind === "wikimedia")
  const visitorTemplate = contract.find(instruction => instruction.source === "visitor")
  const scaffold = Array.from({length: 12}, (_entry, index) => ({
    ...publicTemplate,
    sequence: index + 1,
    lane: 0.5 + Math.sin(index / 3) * 0.16,
  }))
  const visitors = Array.from({length: 600}, (_entry, index) => ({
    ...visitorTemplate,
    sequence: index + 13,
    lane: 0.5,
  }))
  return {scaffold, visitors}
}

function projectedPublicSurge(scaffold, visitors, projectionViewport) {
  return commandsForScene(
    [...scaffold, ...visitors.slice(-588)],
    projectionViewport,
    {
      projectionInstructions: [...scaffold, ...visitors],
      hitInstructions: visitors,
    },
  )
}

function visibleSpineMetrics(spine, projectionViewport) {
  const minimumX = projectionViewport.padding
  const maximumX = projectionViewport.width - projectionViewport.padding
  const visibleSegments = spine.segments.filter(segment =>
    segment.curve.to.x >= minimumX && segment.curve.from.x <= maximumX
  )
  const clippedXs = visibleSegments.flatMap(segment => [
    Math.max(minimumX, Math.min(maximumX, segment.curve.from.x)),
    Math.max(minimumX, Math.min(maximumX, segment.curve.to.x)),
  ])

  return {
    segmentCount: visibleSegments.length,
    span: clippedXs.length > 0 ? Math.max(...clippedXs) - Math.min(...clippedXs) : 0,
  }
}

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

function balancedSceneCommands({
  displayInstructions = balancedSnapshot.display_events,
  memoryInstructions = balancedSnapshot.memory_events,
  historyInstructions = [],
  scaffoldInstructions = [],
  ambient = balancedSnapshot.ambient,
} = {}, projectionViewport = viewport) {
  const topologyInstructions = [
    ...scaffoldInstructions,
    ...historyInstructions,
    ...displayInstructions,
  ]

  return commandsForScene(topologyInstructions, projectionViewport, {
    axis: timelineAxis(balancedSnapshot.window_end),
    displayInstructions,
    memoryInstructions,
    ambient,
    historyInstructions,
    scaffoldInstructions,
    projectionInstructions: topologyInstructions,
    hitInstructions: [...historyInstructions, ...displayInstructions],
  })
}

function timelineAxis(end, durationMilliseconds = 60_000) {
  return {end, durationMilliseconds}
}

function assertCanvasSafeNumbers(commands) {
  const inspect = current => {
    if (typeof current === "number") {
      assert.ok(Number.isFinite(current), `expected ${current} to be finite`)
      assert.ok(Math.abs(current) <= 1_000_000, `expected ${current} to be canvas-safe`)
      return
    }
    if (Array.isArray(current)) current.forEach(inspect)
    if (current && typeof current === "object") Object.values(current).forEach(inspect)
  }

  inspect(commands)
}

function projectedPoints(command) {
  const points = []
  const inspect = current => {
    if (Array.isArray(current)) {
      current.forEach(inspect)
      return
    }
    if (!current || typeof current !== "object") return
    if (Number.isFinite(current.x) && Number.isFinite(current.y)) {
      points.push({x: current.x, y: current.y})
    }
    Object.values(current).forEach(inspect)
  }

  inspect(command)
  return points
}
