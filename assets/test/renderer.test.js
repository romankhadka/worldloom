import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {commandsForScene, eventTimeToX, signalPalette} from "../js/worldloom/geometry.js"
import {Renderer} from "../js/worldloom/renderer.js"
import {balanced} from "./fixtures/balanced_snapshots.js"

const balancedSnapshot = JSON.parse(readFileSync(
  new URL("../../test/support/fixtures/live_snapshots/balanced_v1.json", import.meta.url),
  "utf8",
))

const instruction = sequence => ({
  sequence,
  kind: sequence % 4 === 0 ? "weather" : "wikimedia",
  source: sequence % 4 === 0 ? "open_meteo" : "wikimedia",
  occurred_at: new Date(
    Date.parse("2026-08-08T12:00:00Z") + (sequence % 600) * 100,
  ).toISOString(),
  render_version: 1,
  seed: sequence,
  lane: (sequence % 10) / 10,
  intensity: 0.5,
  visual: {spread: 0.5, bend: 0.1, pulse: 0.7},
  summary: `Formation ${sequence}`,
})

test("replaces live state from one complete snapshot envelope", () => {
  const renderer = new Renderer(null)

  renderer.setSnapshot(structuredClone(balancedSnapshot))

  assert.equal(renderer.commitWatermark, balancedSnapshot.commit_watermark)
  assert.equal(renderer.watermark, balancedSnapshot.commit_watermark)
  assert.equal(renderer.snapshotVersion, 1)
  assert.deepEqual(renderer.instructions, balancedSnapshot.display_events)
  assert.deepEqual(renderer.memoryInstructions, balancedSnapshot.memory_events)
  assert.equal(renderer.windowEnd, balancedSnapshot.window_end)
  assert.deepEqual(renderer.ambient, balancedSnapshot.ambient)
})

test("reports a complete deterministic settled scene on the event-time axis", () => {
  const renderer = new Renderer(null, {
    width: 1_000,
    height: 600,
    reducedMotion: true,
  })
  renderer.setSnapshot(structuredClone(balancedSnapshot))

  const firstDiagnostics = renderer.settledSceneDiagnostics()
  renderer.resize(1_000, 600, 1)
  const rebuiltDiagnostics = renderer.settledSceneDiagnostics()

  assert.deepEqual(firstDiagnostics.axis, {
    start: "2026-08-08T12:00:00.000Z",
    end: balancedSnapshot.window_end,
    durationSeconds: 60,
  })
  assert.equal(firstDiagnostics.paintCommands.length, renderer.commands.length)
  assert.ok(firstDiagnostics.paintCommands.length > 0)
  assert.deepEqual(firstDiagnostics, rebuiltDiagnostics)
})

test("passes every snapshot role to geometry as explicit scene input", () => {
  const projectedScenes = []
  const renderer = new Renderer(null, {
    projectScene: (_instructions, _viewport, scene) => {
      projectedScenes.push(scene)
      return []
    },
  })

  renderer.setSnapshot(structuredClone(balancedSnapshot))

  const scene = projectedScenes.at(-1)
  assert.equal(scene.windowEnd, balancedSnapshot.window_end)
  assert.deepEqual(scene.displayInstructions, balancedSnapshot.display_events)
  assert.deepEqual(scene.memoryInstructions, balancedSnapshot.memory_events)
  assert.deepEqual(scene.ambient, balancedSnapshot.ambient)
  assert.deepEqual(scene.historyInstructions, [])
})

test("keeps contextual memory selectable in its quiet band", () => {
  const renderer = new Renderer(null, {width: 1000, height: 600, padding: 50})

  renderer.setSnapshot(structuredClone(balancedSnapshot))

  const memory = balancedSnapshot.memory_events[0]
  const trace = renderer.commands.find(command =>
    command.type === "memory-trace" && command.sequence === memory.sequence
  )
  assert.ok(trace)
  assert.equal(renderer.hitTest(trace.x, trace.y), memory.sequence)
  assert.equal(trace.occurredAt, memory.occurred_at)
})

test("excludes ambient weather from pointer and keyboard selection", () => {
  const selected = []
  const renderer = new Renderer(null, {
    width: 1_000,
    height: 600,
    padding: 50,
    onSelect: sequence => selected.push(sequence),
  })
  renderer.setSnapshot(structuredClone(balancedSnapshot))
  const ambientCommand = renderer.commands.find(
    command => command.type === "ambient",
  )

  assert.equal(renderer.hitTest(ambientCommand.x, ambientCommand.y), null)
  assert.equal(renderer.selectNext(1), balancedSnapshot.memory_events[0].sequence)
  renderer.activateSelection()
  assert.deepEqual(selected, [balancedSnapshot.memory_events[0].sequence])
})

test("paints the contextual band and its restrained memory mark", () => {
  const bandCalls = cachedCallsFor({
    type: "memory-band",
    role: "contextual-memory",
    label: "Earlier traces",
    x: 10,
    y: 50,
    width: 80,
    height: 10,
  })
  const traceCalls = cachedCallsFor({
    type: "memory-trace",
    role: "contextual-memory",
    sequence: 899,
    occurredAt: "2026-08-08T11:03:17Z",
    x: 50,
    y: 55,
    intensity: 0.4,
    stroke: "#f3ead4",
    glow: "#fff9e9",
  })

  assert.equal(bandCalls.some(([name]) => name === "fillRect"), true)
  assert.equal(
    bandCalls.some(([name, label]) => name === "fillText" && label === "Earlier traces"),
    true,
  )
  assert.equal(traceCalls.some(([name]) => name === "arc"), true)
  assert.equal(traceCalls.some(([name]) => name === "fill"), true)
})

test("accepts legal display omissions as full replacements without gap repair", () => {
  const renderer = new Renderer(null)
  renderer.setSnapshot(structuredClone(balancedSnapshot))
  const replacement = {
    ...structuredClone(balancedSnapshot),
    commit_watermark: 907,
    display_events: [
      balancedSnapshot.display_events[1],
      {...instruction(907), occurred_at: "2026-08-08T12:01:00Z"},
    ],
  }

  renderer.setSnapshot(replacement)

  assert.deepEqual(renderer.instructions, replacement.display_events)
  assert.equal(renderer.commitWatermark, 907)
  assert.equal(renderer.receiveEvent, undefined)
  assert.equal(renderer.applyCatchUp, undefined)
})

test("validates an entire snapshot before mutating live state", () => {
  const renderer = new Renderer(null)
  renderer.setSnapshot(structuredClone(balancedSnapshot))
  renderer.setSelection(balancedSnapshot.display_events[0].sequence)
  const before = {
    commitWatermark: renderer.commitWatermark,
    snapshotVersion: renderer.snapshotVersion,
    instructions: structuredClone(renderer.instructions),
    memoryInstructions: structuredClone(renderer.memoryInstructions),
    ambient: structuredClone(renderer.ambient),
    windowEnd: renderer.windowEnd,
    selectedSequence: renderer.selectedSequence,
  }
  const malformed = structuredClone(balancedSnapshot)
  malformed.memory_events[0].sequence = Number.NaN

  assert.throws(() => renderer.setSnapshot(malformed), /sequence/i)
  assert.deepEqual({
    commitWatermark: renderer.commitWatermark,
    snapshotVersion: renderer.snapshotVersion,
    instructions: renderer.instructions,
    memoryInstructions: renderer.memoryInstructions,
    ambient: renderer.ambient,
    windowEnd: renderer.windowEnd,
    selectedSequence: renderer.selectedSequence,
  }, before)
})

test("rejects invalid instruction occurrence times before mutating state", () => {
  const malformedSnapshots = [
    snapshotWithInstructionMutation("display_events", instruction => {
      delete instruction.occurred_at
    }),
    snapshotWithInstructionMutation("display_events", instruction => {
      instruction.occurred_at = "not-a-timestamp"
    }),
    snapshotWithInstructionMutation("memory_events", instruction => {
      instruction.occurred_at = "2026-08-08T06:01:00-06:00"
    }),
    snapshotWithInstructionMutation("ambient", instruction => {
      instruction.occurred_at = "2026-02-31T12:01:00Z"
    }),
  ]

  for (const malformed of malformedSnapshots) {
    const renderer = new Renderer(null)
    renderer.setSnapshot(structuredClone(balancedSnapshot))
    const before = rendererState(renderer)

    assert.throws(() => renderer.setSnapshot(malformed), /occurred_at/i)
    assert.deepEqual(rendererState(renderer), before)
  }
})

test("owns a deep copy of every accepted snapshot instruction", () => {
  const renderer = new Renderer(null)
  const envelope = structuredClone(balancedSnapshot)

  renderer.setSnapshot(envelope)
  const installed = rendererState(renderer)
  envelope.display_events[0].summary = "mutated outside renderer"
  envelope.display_events[0].visual.spread = 99
  envelope.memory_events[0].visual.pulse = 99
  envelope.ambient.visual.bend = 99

  assert.deepEqual(rendererState(renderer), installed)
  assert.notEqual(renderer.instructions[0], envelope.display_events[0])
  assert.notEqual(renderer.instructions[0].visual, envelope.display_events[0].visual)
})

test("accepts watermark zero only for the empty initial snapshot", () => {
  const renderer = new Renderer(null)
  const emptySnapshot = {
    snapshot_version: 1,
    window_end: null,
    commit_watermark: 0,
    display_events: [],
    memory_events: [],
    ambient: null,
  }

  renderer.setSnapshot(emptySnapshot)
  assert.equal(renderer.commitWatermark, 0)
  assert.equal(renderer.windowEnd, null)

  assert.throws(
    () => renderer.setSnapshot({...emptySnapshot, display_events: [instruction(1)]}),
    /watermark/i,
  )
  assert.throws(
    () => renderer.setSnapshot({
      ...emptySnapshot,
      commit_watermark: 1,
      display_events: [instruction(1)],
    }),
    /window_end/i,
  )
})

test("accepts a weather-only snapshot without fabricating a live window", () => {
  const renderer = new Renderer(null, {width: 1000, height: 600})
  const weatherOnly = {
    snapshot_version: 1,
    window_end: null,
    commit_watermark: balancedSnapshot.ambient.sequence,
    display_events: [],
    memory_events: [],
    ambient: structuredClone(balancedSnapshot.ambient),
  }

  assert.doesNotThrow(() => renderer.setSnapshot(weatherOnly))
  assert.equal(renderer.windowEnd, null)
  assert.deepEqual(renderer.instructions, [])
  assert.deepEqual(renderer.memoryInstructions, [])
  assert.deepEqual(renderer.ambient, balancedSnapshot.ambient)
  assert.deepEqual(renderer.commands.map(command => command.type), ["ambient"])
})

test("keeps malformed historical timestamps on the legacy chapter coordinate path", () => {
  const renderer = new Renderer(null, {width: 800, height: 600})
  const historical = [{...instruction(41), occurred_at: "legacy timestamp unavailable"}]

  assert.doesNotThrow(() => renderer.setEvents(historical))
  const hit = renderer.commands.find(command => command.type === "anchor-hit")
  assert.ok(hit)
  assert.ok(Number.isFinite(hit.x))
  assert.equal(renderer.windowEnd, null)
})

test("rejects unsupported versions and non-UTC window anchors transactionally", () => {
  const renderer = new Renderer(null)
  renderer.setSnapshot(structuredClone(balancedSnapshot))

  assert.throws(
    () => renderer.setSnapshot({...structuredClone(balancedSnapshot), snapshot_version: 2}),
    /snapshot_version/i,
  )
  assert.throws(
    () => renderer.setSnapshot({
      ...structuredClone(balancedSnapshot),
      window_end: "2026-08-08T06:01:00-06:00",
    }),
    /window_end/i,
  )
  assert.equal(renderer.windowEnd, balancedSnapshot.window_end)
})

test("caps live roles, preserves bounded history separately, and reconciles selection", () => {
  const renderer = new Renderer(null)
  renderer.setEvents([instruction(1)])
  renderer.prependHistory([instruction(1), instruction(2)])
  renderer.setSelection(2)
  const display = Array.from({length: 601}, (_entry, index) => instruction(index + 100))
  const memory = Array.from({length: 5}, (_entry, index) => instruction(index + 701))
  const envelope = {
    snapshot_version: 1,
    window_end: "2026-08-08T12:01:00Z",
    commit_watermark: 705,
    display_events: display,
    memory_events: memory,
    ambient: null,
  }

  renderer.setSnapshot(envelope)

  assert.equal(renderer.instructions.length, 600)
  assert.equal(renderer.memoryInstructions.length, 4)
  assert.deepEqual(renderer.historyInstructions.map(event => event.sequence), [1, 2])
  assert.equal(renderer.selectedSequence, null)

  renderer.setSelection(701)
  renderer.setSnapshot(envelope)
  assert.equal(renderer.selectedSequence, 701)
})

test("returns from retained history to the latest complete live snapshot", () => {
  const renderer = new Renderer(null, {width: 300, height: 200, reducedMotion: true})
  renderer.setSnapshot(structuredClone(balancedSnapshot))
  renderer.panOffset = 100
  renderer.prependHistory([instruction(12), instruction(13)])
  renderer.setSelection(12)
  const replacement = {
    ...structuredClone(balancedSnapshot),
    commit_watermark: 907,
    display_events: [{...instruction(907), occurred_at: "2026-08-08T12:01:00Z"}],
  }
  renderer.setSnapshot(replacement)
  assert.deepEqual(renderer.historyInstructions.map(event => event.sequence), [12, 13])
  assert.equal(renderer.selectedSequence, 12)

  renderer.returnLive()

  assert.deepEqual(renderer.events, replacement.display_events)
  assert.deepEqual(renderer.instructions, replacement.display_events)
  assert.deepEqual(renderer.historyInstructions, [])
  assert.equal(renderer.archiveStart, false)
  assert.equal(renderer.historyInFlight, false)
  assert.equal(renderer.selectedSequence, null)
  assert.equal(renderer.panOffset, 0)
})

test("restores the live public scaffold after browsing historical pages", () => {
  const renderer = new Renderer(null, {width: 300, height: 200, reducedMotion: true})
  const liveScaffold = [publicInstruction(900)]
  const liveVisitor = {...instruction(951), kind: "illuminate", source: "visitor"}
  renderer.setScaffold(liveScaffold)
  renderer.setSnapshot({
    snapshot_version: 1,
    window_end: "2026-08-08T12:01:00Z",
    commit_watermark: 951,
    display_events: [liveVisitor],
    memory_events: [],
    ambient: null,
  })
  renderer.panOffset = 100
  renderer.prependHistory([instruction(20)], {scaffold: [publicInstruction(10)]})
  assert.deepEqual(renderer.scaffold.map(event => event.sequence), [10])

  renderer.setSnapshot({
    snapshot_version: 1,
    window_end: "2026-08-08T12:01:00Z",
    commit_watermark: 952,
    display_events: [{...liveVisitor, sequence: 952, seed: 952}],
    memory_events: [],
    ambient: null,
  })
  renderer.returnLive()

  assert.deepEqual(renderer.scaffold.map(event => event.sequence), [900])
})

test("reseeds live scaffold when a historical route returns to a snapshot", () => {
  const renderer = new Renderer(null, {reducedMotion: true})
  renderer.reload([publicInstruction(10)], 10, {scaffold: [publicInstruction(10)]})
  renderer.resetLiveScaffold()
  renderer.setSnapshot(snapshotEnvelope([
    {...instruction(20), kind: "illuminate", source: "visitor"},
  ], {watermark: 20}))
  renderer.returnLive()
  assert.deepEqual(renderer.scaffold, [])

  renderer.reload([publicInstruction(10)], 10, {scaffold: [publicInstruction(10)]})
  renderer.resetLiveScaffold()
  renderer.setSnapshot(snapshotEnvelope([publicInstruction(21)], {watermark: 21}))
  renderer.returnLive()
  assert.deepEqual(renderer.scaffold.map(event => event.sequence), [21])
})

test("bounds events and drawing commands", () => {
  const renderer = new Renderer(null, {width: 800, height: 600})
  renderer.setEvents(Array.from({length: 700}, (_entry, index) => instruction(index + 1)))

  assert.equal(renderer.events.length, 600)
  assert.ok(renderer.commands.length <= 4000)
  assert.equal(renderer.watermark, 700)
})

test("preserves deterministic reconstruction through device-pixel-ratio resize", () => {
  const canvas = fakeCanvas()
  const renderer = new Renderer(canvas, {width: 400, height: 300, dpr: 1})
  renderer.setEvents([instruction(1), instruction(2)])
  const before = structuredClone(renderer.commands)

  renderer.resize(800, 600, 2)

  assert.equal(canvas.width, 1600)
  assert.equal(canvas.height, 1200)
  assert.notDeepEqual(renderer.commands, before)
  assert.deepEqual(renderer.events.map(event => event.sequence), [1, 2])
})

test("pans with wheel, pointer, and one-finger touch and reports live-edge changes once", () => {
  const states = []
  const renderer = new Renderer(null, {
    width: 300,
    height: 200,
    reducedMotion: true,
    onViewportChange: state => states.push(state.atLiveEdge),
  })
  renderer.setEvents(Array.from({length: 30}, (_entry, index) => instruction(index + 1)))

  renderer.handleWheel({deltaX: 0, deltaY: -100, preventDefault() {}})
  renderer.pointerDown({clientX: 100})
  renderer.pointerMove({clientX: 130})
  renderer.pointerUp()
  renderer.touchStart({touches: [{clientX: 130}]})
  renderer.touchMove({touches: [{clientX: 150}], preventDefault() {}})
  renderer.touchEnd()

  assert.ok(renderer.panOffset > 0)
  assert.deepEqual(states, [false])

  renderer.returnLive()
  assert.equal(renderer.panOffset, 0)
  assert.deepEqual(states, [false, true])
})

test("requests one bounded older page near the edge and stops at archive start", () => {
  const requests = []
  const renderer = new Renderer(null, {
    width: 300,
    height: 200,
    onHistoryRequest: request => requests.push(request),
  })
  renderer.setEvents(Array.from({length: 30}, (_entry, index) => instruction(index + 31)))
  renderer.panBy(10_000)
  renderer.maybeRequestHistory()
  renderer.maybeRequestHistory()

  assert.deepEqual(requests, [{before: 31}])

  renderer.prependHistory([instruction(30)], {archiveStart: true})
  renderer.maybeRequestHistory()
  assert.equal(requests.length, 1)
})

test("exposes no incremental event or sequence-gap ingestion state", () => {
  const renderer = new Renderer(null, {onGap: () => assert.fail("obsolete gap callback")})

  assert.equal(renderer.receiveEvent, undefined)
  assert.equal(renderer.applyCatchUp, undefined)
  assert.equal(renderer.appendCommitted, undefined)
  assert.equal(renderer.setAmbient, undefined)
  assert.equal(renderer.onGap, undefined)
  assert.equal(renderer.queuedEvents, undefined)
  assert.equal(renderer.gapInFlight, undefined)
})

test("supports hit testing and keyboard formation traversal", () => {
  const selected = []
  const renderer = new Renderer(null, {
    width: 800,
    height: 600,
    onSelect: sequence => selected.push(sequence),
  })
  renderer.setEvents([instruction(1), instruction(2)])

  const firstHit = renderer.commands.find(command => command.sequence === 1).hit
  assert.equal(renderer.hitTest(firstHit.x + 1, firstHit.y + 1), 1)
  assert.equal(renderer.selectNext(1), 1)
  assert.equal(renderer.selectNext(1), 2)
  renderer.activateSelection()
  assert.deepEqual(selected, [2])
})

test("does not activate a replacement row after the pending keyboard target disappears", () => {
  const selected = []
  const renderer = new Renderer(null, {
    width: 800,
    height: 600,
    onSelect: sequence => selected.push(sequence),
  })
  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))
  assert.equal(renderer.selectNext(1), 1)

  renderer.setSnapshot(snapshotEnvelope([instruction(2), instruction(3)]))
  renderer.activateSelection()

  assert.deepEqual(selected, [])
  assert.equal(renderer.pendingSelectionSequence, null)
})

test("activates the same pending sequence when a snapshot inserts memory before it", () => {
  const selected = []
  const renderer = new Renderer(null, {
    width: 800,
    height: 600,
    onSelect: sequence => selected.push(sequence),
  })
  const display = [instruction(1), instruction(2)]
  renderer.setSnapshot(snapshotEnvelope(display))
  assert.equal(renderer.selectNext(1), 1)

  renderer.setSnapshot(snapshotEnvelope(display, {
    memoryEvents: [{
      ...instruction(99),
      kind: "illuminate",
      source: "visitor",
      occurred_at: "2026-08-08T11:55:00Z",
    }],
  }))
  renderer.activateSelection()

  assert.deepEqual(selected, [1])
})

test("cycles through memory and history by identity and clears history on return live", () => {
  const selected = []
  const renderer = new Renderer(null, {
    width: 800,
    height: 600,
    reducedMotion: true,
    onSelect: sequence => selected.push(sequence),
  })
  renderer.setSnapshot(structuredClone(balancedSnapshot))
  assert.equal(renderer.selectNext(1), balancedSnapshot.memory_events[0].sequence)
  renderer.activateSelection()
  assert.deepEqual(selected, [balancedSnapshot.memory_events[0].sequence])
  selected.length = 0

  const historical = {...instruction(800), occurred_at: "2026-08-08T11:59:00Z"}
  renderer.panBy(100)
  renderer.prependHistory([historical])
  for (let attempt = 0; attempt < 10 && renderer.pendingSelectionSequence !== 800; attempt++) {
    renderer.selectNext(1)
  }
  assert.equal(renderer.pendingSelectionSequence, 800)

  renderer.returnLive()
  renderer.activateSelection()

  assert.equal(renderer.pendingSelectionSequence, null)
  assert.deepEqual(selected, [])
})

test("keeps the living spine visible through a trailing visitor surge", () => {
  const selected = []
  const renderer = new Renderer(null, {
    width: 1000,
    height: 600,
    padding: 50,
    reducedMotion: true,
    onSelect: sequence => selected.push(sequence),
  })
  renderer.setEvents(visitorSurgeInstructions())

  const liveSpine = renderer.commands.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  const liveSpineEnd = liveSpine.segments.at(-1).curve.to
  const liveHits = renderer.commands.filter(command => command.type === "anchor-hit")
  assert.ok(liveSpineEnd.x >= renderer.padding)
  assert.ok(liveSpineEnd.x <= renderer.width - renderer.padding)
  assert.deepEqual(
    liveHits.map(command => command.sequence),
    Array.from({length: 190}, (_entry, index) => index + 1),
  )
  assert.ok(liveHits.slice(1).every((hit, index) => hit.x > liveHits[index].x))
  assert.equal(renderer.hitTest(liveHits.at(-1).x, liveHits.at(-1).y), 190)

  for (let index = 0; index < liveHits.length; index++) renderer.selectNext(1)
  renderer.activateSelection()
  assert.deepEqual(selected, [190])
})

test("hit tests the nearest formation center inside a dense visitor band", () => {
  const renderer = new Renderer(null, {
    width: 1000,
    height: 600,
    padding: 50,
    reducedMotion: true,
  })
  renderer.setEvents(visitorSurgeInstructions({visitorLane: 0.5}))

  const visitorHits = renderer.commands.filter(
    command => command.type === "anchor-hit" && command.sequence >= 121,
  )
  for (const hit of visitorHits) {
    assert.equal(renderer.hitTest(hit.x, hit.y), hit.sequence)
  }

  const [first, second] = visitorHits
  assert.equal(
    renderer.hitTest((first.x + second.x) / 2, first.y),
    second.sequence,
  )
})

test("extends the visible spine when public activity resumes after a visitor surge", () => {
  const renderer = new Renderer(null, {
    width: 1000,
    height: 600,
    padding: 50,
    reducedMotion: true,
  })

  renderer.setEvents([...visitorSurgeInstructions(), publicInstruction(191)])

  const resumedSpine = renderer.commands.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  const resumedSegment = resumedSpine.segments.at(-1)
  const resumedHits = renderer.commands.filter(command => command.type === "anchor-hit")
  assert.ok(resumedSegment.curve.from.x >= renderer.padding)
  assert.equal(resumedSegment.curve.to.x, renderer.width - renderer.padding)
  assert.equal(
    resumedSegment.curve.to.x - resumedSegment.curve.from.x,
    (8 + 1) * renderer.spacing,
  )
  assert.deepEqual(
    resumedHits.map(command => command.sequence),
    Array.from({length: 191}, (_entry, index) => index + 1),
  )
  assert.ok(resumedHits.slice(1).every((hit, index) => hit.x > resumedHits[index].x))
})

test("bounds archive panning to the compressed visitor projection", () => {
  const renderer = new Renderer(null, {
    width: 1000,
    height: 600,
    padding: 50,
    reducedMotion: true,
  })
  renderer.setEvents(visitorSurgeInstructions())

  renderer.panBy(Number.MAX_SAFE_INTEGER)

  const archivedHits = renderer.commands.filter(command => command.type === "anchor-hit")
  assert.equal(archivedHits[0].sequence, 1)
  assert.equal(archivedHits.at(-1).sequence, 190)
  assert.ok(archivedHits.slice(1).every((hit, index) => hit.x > archivedHits[index].x))
  assert.equal(archivedHits[0].x, renderer.width - renderer.padding)
})

test("retains a bounded public scaffold through all-visitor reloads and snapshots", () => {
  const renderer = new Renderer(null, {
    width: 1000,
    height: 600,
    padding: 50,
    reducedMotion: true,
  })
  const scaffold = Array.from(
    {length: 12},
    (_entry, index) => publicInstruction(index * 4 + 1),
  )
  const visitorKinds = ["tug", "knot", "illuminate"]
  const visitors = Array.from({length: 600}, (_entry, index) => ({
    ...instruction(index + 46),
    kind: visitorKinds[index % visitorKinds.length],
    source: "visitor",
    lane: 0.5,
  }))

  renderer.setEvents(visitors, {scaffold})
  assertVisibleScaffold(renderer)
  assert.equal(visitorBandWidth(renderer), renderer.spacing * 8)
  assert.deepEqual(
    renderer.commands
      .filter(command => command.type === "anchor-hit")
      .map(command => command.sequence),
    visitors.map(visitor => visitor.sequence),
  )
  assert.equal(renderer.events.length, 600)
  assert.equal(renderer.watermark, 645)
  assert.ok(renderer.commands.length <= 4000)

  renderer.reload(visitors, 645, {scaffold})
  const laterVisitors = Array.from({length: 70}, (_entry, index) => {
    const sequence = index + 646
    return {
      ...instruction(sequence),
      kind: visitorKinds[sequence % visitorKinds.length],
      source: "visitor",
      lane: 0.5,
    }
  })
  renderer.setSnapshot(snapshotEnvelope(
    [...visitors, ...laterVisitors].slice(-600),
    {watermark: 715},
  ))

  assertEventTimeScaffold(renderer, scaffold, "2026-08-08T12:01:00Z")
  const liveHits = renderer.commands.filter(command => command.type === "anchor-hit")
  assert.ok(liveHits.every(hit => hit.x >= renderer.padding))
  assert.ok(liveHits.every(hit => hit.x <= renderer.width - renderer.padding))
  assert.equal(renderer.events.length, 600)
  assert.equal(renderer.events[0].sequence, 116)
  assert.equal(renderer.watermark, 715)
  assert.ok(renderer.commands.length <= 4000)
})

test("reserves narrow live-edge width for multiple real scaffold segments", () => {
  const renderer = new Renderer(null, {
    width: 390,
    height: 844,
    padding: 40,
    reducedMotion: true,
  })
  const scaffold = Array.from(
    {length: 12},
    (_entry, index) => publicInstruction(index * 4 + 1),
  )
  const visitors = Array.from({length: 600}, (_entry, index) => ({
    ...instruction(index + 46),
    kind: "knot",
    source: "visitor",
    lane: 0.5,
  }))

  renderer.setEvents(visitors, {scaffold})

  const spine = renderer.commands.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  const visible = visibleSpineMetrics(renderer, spine)
  assert.equal(visitorBandWidth(renderer), renderer.spacing * 3)
  assert.ok(visible.segmentCount >= 3)
  assert.ok(visible.span >= (renderer.width - renderer.padding * 2) * 0.65)
  assert.deepEqual(
    renderer.commands
      .filter(command => command.type === "anchor-hit")
      .map(command => command.sequence),
    visitors.map(visitor => visitor.sequence),
  )
  assert.equal(renderer.watermark, 645)
  assert.ok(renderer.commands.length <= 4000)
})

test("replaces future scaffold anchors when historical paging drops newer events", () => {
  const renderer = new Renderer(null, {
    width: 1000,
    height: 600,
    padding: 50,
    reducedMotion: true,
  })
  const liveVisitors = Array.from({length: 600}, (_entry, index) => ({
    ...instruction(index + 951),
    kind: "illuminate",
    source: "visitor",
  }))
  renderer.setEvents(liveVisitors, {
    scaffold: [publicInstruction(900), publicInstruction(950)],
  })
  renderer.panBy(100)

  const historicalEvents = Array.from({length: 600}, (_entry, index) => {
    const sequence = index + 1
    if (sequence === 100 || sequence === 200) return publicInstruction(sequence)
    return {...instruction(sequence), kind: "illuminate", source: "visitor"}
  })
  const historicalScaffold = [publicInstruction(100), publicInstruction(200)]

  renderer.prependHistory(historicalEvents, {
    archiveStart: true,
    scaffold: historicalScaffold,
  })

  const spine = renderer.commands.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  assert.ok(spine.segments.every(segment => segment.sequence <= 600))
  assert.deepEqual(
    renderer.commands
      .filter(command => command.type === "anchor-hit")
      .map(command => command.sequence),
    historicalEvents.map(event => event.sequence),
  )
  assert.equal(renderer.events[0].sequence, 1)
  assert.equal(renderer.events.at(-1).sequence, 600)
  assert.equal(renderer.watermark, 1550)
  assert.equal(renderer.newerEventsDropped, true)
})

test("handles zero or one real public scaffold instruction as an intentional germ state", () => {
  const visitors = Array.from({length: 600}, (_entry, index) => ({
    ...instruction(index + 2),
    kind: "illuminate",
    source: "visitor",
  }))

  for (const scaffold of [[], [publicInstruction(1)]]) {
    const renderer = new Renderer(null, {
      width: 1000,
      height: 600,
      padding: 50,
      reducedMotion: true,
    })
    renderer.setEvents(visitors, {scaffold})

    assert.equal(
      renderer.commands.some(
        command => command.type === "fiber-path" && command.role === "spine",
      ),
      false,
    )
    assert.deepEqual(
      renderer.commands
        .filter(command => command.type === "anchor-hit")
        .map(command => command.sequence),
      visitors.map(visitor => visitor.sequence),
    )
    assert.equal(renderer.events.length, 600)
    assert.equal(renderer.watermark, 601)
    assert.ok(renderer.commands.length <= 4000)
  }
})

test("retains newer ambient weather after it ages out of the live window", () => {
  const renderer = new Renderer(null, {
    width: 1000,
    height: 600,
    padding: 50,
    reducedMotion: true,
  })
  const oldAmbient = {
    ...instruction(2),
    kind: "weather",
    source: "open_meteo",
  }
  const initialVisitors = Array.from({length: 598}, (_entry, index) => ({
    ...instruction(index + 3),
    kind: "illuminate",
    source: "visitor",
  }))
  renderer.setSnapshot(snapshotEnvelope(
    [publicInstruction(1), ...initialVisitors],
    {ambient: oldAmbient, watermark: 600},
  ))

  const newAmbient = {
    ...instruction(601),
    kind: "weather",
    source: "open_meteo",
  }
  const laterVisitors = Array.from({length: 600}, (_entry, index) => {
    const sequence = index + 602
    return {
      ...instruction(sequence),
      kind: "illuminate",
      source: "visitor",
    }
  })
  renderer.setSnapshot(snapshotEnvelope(laterVisitors, {
    ambient: newAmbient,
    watermark: 1201,
  }))

  const ambientCommands = renderer.commands.filter(command => command.type === "ambient")
  assert.equal(renderer.events.length, 600)
  assert.equal(renderer.events[0].sequence, 602)
  assert.equal(renderer.watermark, 1201)
  assert.deepEqual(ambientCommands.map(command => command.sequence), [601])
})

test("requests a fresh live window when history panning dropped newer events", () => {
  let reloadRequests = 0
  const renderer = new Renderer(null, {onReloadRequest: () => reloadRequests++})
  renderer.setEvents(Array.from({length: 600}, (_entry, index) => instruction(index + 101)))
  renderer.panBy(100)
  renderer.prependHistory(Array.from({length: 100}, (_entry, index) => instruction(index + 1)))

  assert.equal(renderer.events.at(-1).sequence, 600)
  renderer.returnLive()
  assert.equal(reloadRequests, 1)
})

test("reload reconstructs directly in the live-edge coordinate frame", () => {
  const projectedOffsets = []
  const renderer = new Renderer(null, {
    projectScene: (...arguments_) => {
      projectedOffsets.push(arguments_[1].panOffset)
      return commandsForScene(...arguments_)
    },
  })
  const instructions = Array.from({length: 20}, (_entry, index) => instruction(index + 1))
  renderer.setEvents(instructions)
  renderer.panBy(300)

  renderer.reload(instructions)

  assert.equal(projectedOffsets.at(-1), 0)
  assert.equal(renderer.projectedPanOffset, 0)
  assert.equal(renderer.viewTranslationX(), 0)
})

test("animates return-to-live when motion is allowed", () => {
  const renderer = new Renderer(null)
  renderer.setEvents(Array.from({length: 20}, (_entry, index) => instruction(index + 1)))
  renderer.panBy(300)
  renderer.returnLive()

  assert.ok(renderer.panOffset > 0)
  for (let frame = 0; frame < 20; frame++) renderer.step(frame * 16)
  assert.equal(renderer.panOffset, 0)
  assert.equal(renderer.atLiveEdge(), true)
})

test("animates return-to-live without projecting topology on intermediate ticks", () => {
  let projections = 0
  const renderer = new Renderer(null, {
    projectScene: (...arguments_) => {
      projections++
      return commandsForScene(...arguments_)
    },
  })
  renderer.setEvents(Array.from({length: 20}, (_entry, index) => instruction(index + 1)))
  renderer.panBy(300)
  renderer.returnLive()
  const beforeTicks = projections

  renderer.step(16)
  renderer.step(32)
  renderer.step(48)

  assert.equal(renderer.returningToLive, true)
  assert.equal(projections, beforeTicks)
})

test("uses aggregate viewer pulses and stepped reduced motion", () => {
  let frameRequests = 0
  const canvas = fakeCanvas()
  const cache = fakeCanvas()
  const renderer = new Renderer(canvas, {
    reducedMotion: true,
    createCanvas: () => cache,
    requestFrame: () => frameRequests++,
  })

  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))
  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))
  renderer.setViewerCount(23)
  renderer.start()
  canvas.calls.length = 0
  renderer.step(1000)

  assert.equal(renderer.viewerPulses, 0)
  assert.equal(renderer.animationTime, 1000)
  assert.equal(frameRequests, 0)
  assert.equal(renderer.activeTransitions.size, 0)
  assert.equal(canvas.calls.some(([name]) => name === "translate"), false)
})

test("rebuilds projection on scene changes but never during animation ticks", () => {
  let projections = 0
  const renderer = new Renderer(null, {
    width: 800,
    height: 600,
    projectScene: (...arguments_) => {
      projections++
      return commandsForScene(...arguments_)
    },
  })

  const beforeSceneChange = projections
  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))
  assert.equal(projections, beforeSceneChange + 1)
  const afterSceneChange = projections

  renderer.step(16)
  renderer.step(32)
  assert.equal(projections, afterSceneChange)

  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2), instruction(3)]))
  assert.equal(projections, afterSceneChange + 1)
})

test("renders settled splines into a detached cache and composites it on ticks", () => {
  const canvas = fakeCanvas()
  const cache = fakeCanvas()
  const renderer = new Renderer(canvas, {
    width: 800,
    height: 600,
    createCanvas: () => cache,
  })

  renderer.setEvents(Array.from({length: 20}, (_item, index) => instruction(index + 1)))
  const cachedCurves = cache.calls.filter(([name]) => name === "bezierCurveTo").length
  assert.ok(cachedCurves > 0)
  assert.equal(renderer.cacheDirty, false)

  renderer.step(1_000)
  assert.equal(cache.calls.filter(([name]) => name === "bezierCurveTo").length, cachedCurves)
  assert.ok(canvas.calls.some(([name]) => name === "drawImage"))
})

test("paints each fiber as glow, body, and luminous core", () => {
  const calls = cachedCallsFor({
    type: "fiber-path",
    sequence: 2,
    intensity: 0.7,
    stroke: "#63d7d1",
    glow: "#b6fff8",
    material: {
      glow: {width: 12, alpha: 0.12},
      body: {width: 4, alpha: 0.42},
      core: {width: 1.2, alpha: 0.86},
    },
    segments: [{
      sequence: 2,
      transitionSequence: 2,
      length: 100,
      curve: {
        from: {x: 10, y: 30},
        control1: {x: 35, y: 10},
        control2: {x: 65, y: 50},
        to: {x: 90, y: 30},
      },
    }],
  })

  assert.deepEqual(
    calls.filter(([name]) => name === "lineWidth").map(([_name, width]) => width),
    [12, 4, 1.2],
  )
  assert.equal(calls.filter(([name]) => name === "stroke").length, 3)
})

test("assigns every world signal its restrained source palette family", () => {
  const expectedFamilies = {
    wikimedia: "cyan-verdigris",
    bluesky: "violet",
    ripe_ris: "electric",
    solana: "amber",
    drand: "crystalline",
    usgs: "ember",
    open_meteo: "moss-gold",
    visitor: "ivory",
  }

  assert.deepEqual(
    Object.fromEntries(
      Object.entries(signalPalette).map(([source, palette]) => [source, palette.family]),
    ),
    expectedFamilies,
  )

  const renderer = new Renderer(null, {width: 1_000, height: 600, reducedMotion: true})
  renderer.setSnapshot(structuredClone(balanced))

  assert.deepEqual(
    new Set(renderer.commands.map(command => command.paletteFamily).filter(Boolean)),
    new Set(Object.values(expectedFamilies)),
  )
})

test("paints bounded role materials from one structural command per formation", () => {
  const canvas = fakeCanvas()
  const cache = fakeCanvas()
  const renderer = new Renderer(canvas, {
    width: 1_000,
    height: 600,
    reducedMotion: true,
    createCanvas: () => cache,
  })

  renderer.setSnapshot(structuredClone(balanced))

  const roles = ["conversation-fan", "route-fork", "slot-braid", "public-pulse"]
  const structural = renderer.commands.filter(command => roles.includes(command.role))
  const versionTwoInstructions = balanced.display_events.filter(instruction =>
    ["bluesky", "ripe_ris", "solana", "drand"].includes(instruction.source)
  )

  assert.equal(structural.length, versionTwoInstructions.length)
  assert.deepEqual(
    structural.map(command => command.sequence),
    versionTwoInstructions.map(instruction => instruction.sequence),
  )
  assert.ok(structural.every(command =>
    Object.keys(command.material).join(",") === "glow,body,core"
  ))
  assert.equal(renderer.commands.some(command => command.cosmeticOf), false)

  for (const palette of Object.values(signalPalette)) {
    assert.ok(cache.calls.some(([name, color]) =>
      (name === "strokeStyle" || name === "fillStyle") &&
        (color === palette.stroke || color === palette.glow)
    ), `expected ${palette.family} paint calls`)
  }
  assert.ok(cache.calls.filter(([name]) => name === "setLineDash").length > 0)
  assert.ok(cache.calls.filter(([name]) => name === "arc").length > 0)
  assert.ok(cache.calls.filter(([name]) => name === "lineTo").length > 0)
})

test("reduced motion paints the same settled source roles without a continuing scheduler", () => {
  let motionFrameRequests = 0
  let reducedFrameRequests = 0
  const motionRenderer = new Renderer(null, {
    width: 1_000,
    height: 600,
    requestFrame: () => ++motionFrameRequests,
  })
  const reducedRenderer = new Renderer(null, {
    width: 1_000,
    height: 600,
    reducedMotion: true,
    requestFrame: () => ++reducedFrameRequests,
  })

  motionRenderer.setSnapshot(structuredClone(balanced))
  reducedRenderer.setSnapshot(structuredClone(balanced))
  motionRenderer.start()
  reducedRenderer.start()

  const settledIdentity = renderer => renderer.settledSceneDiagnostics().paintCommands.map(
    command => [command.sequence, command.type, command.role, command.paletteFamily],
  )
  assert.deepEqual(settledIdentity(reducedRenderer), settledIdentity(motionRenderer))
  assert.equal(reducedRenderer.activeTransitions.size, 0)
  assert.equal(reducedRenderer.viewerPulses, 0)
  assert.equal(reducedFrameRequests, 0)
  assert.equal(motionFrameRequests, 1)
})

test("draws a bounded lane seed and selected-formation halo", () => {
  const canvas = fakeCanvas()
  const renderer = new Renderer(canvas, {width: 800, height: 600, reducedMotion: true})
  renderer.setEvents([instruction(1), instruction(2)])
  renderer.setTargetLane(0.25)
  renderer.setSelection(2)
  canvas.calls.length = 0

  renderer.draw()

  const arcs = canvas.calls.filter(([name]) => name === "arc")
  assert.ok(arcs.some(([_name, x, y]) => x === 786 && y === 170))
  assert.ok(arcs.length >= 2)
  assert.equal(renderer.targetLane, 0.25)
  assert.equal(renderer.selectedSequence, 2)
})

test("bounds active transitions and settles the oldest when a ninth arrives", () => {
  const renderer = new Renderer(null, {width: 800, height: 600})
  let instructions = [instruction(1)]
  renderer.setSnapshot(snapshotEnvelope(instructions))

  for (let sequence = 2; sequence <= 10; sequence++) {
    instructions = [
      ...instructions,
      {...instruction(sequence), kind: "wikimedia", source: "wikimedia"},
    ]
    renderer.setSnapshot(snapshotEnvelope(instructions))
  }

  assert.equal(renderer.activeTransitions.size, 8)
  assert.equal(renderer.activeTransitions.has(2), false)
  assert.deepEqual([...renderer.activeTransitions.keys()], [3, 4, 5, 6, 7, 8, 9, 10])
})

test("settles ambient weather directly without an empty transition", () => {
  const renderer = new Renderer(null)
  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))

  renderer.setSnapshot(snapshotEnvelope([instruction(1)], {
    ambient: {...instruction(2), kind: "weather", source: "open_meteo"},
    watermark: 2,
  }))

  assert.equal(renderer.activeTransitions.size, 0)
})

test("settles unsupported render versions as fallback marks without empty transitions", () => {
  const renderer = new Renderer(null)
  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))

  renderer.setSnapshot(snapshotEnvelope([instruction(1), {...instruction(2), render_version: 99}]))

  assert.equal(renderer.activeTransitions.size, 0)
  assert.equal(renderer.commands.some(command => command.type === "fallback"), true)
})

test("destroy cancels animation and releases transition and cache state", () => {
  const cache = fakeCanvas()
  const cancelled = []
  const renderer = new Renderer(null, {
    createCanvas: () => cache,
    requestFrame: () => 41,
    cancelFrame: handle => cancelled.push(handle),
  })
  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))
  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))
  renderer.start()

  renderer.destroy()

  assert.deepEqual(cancelled, [41])
  assert.equal(renderer.frameHandle, null)
  assert.equal(renderer.activeTransitions.size, 0)
  assert.equal(renderer.cacheCanvas, null)
  assert.equal(renderer.cacheContext, null)
})

test("grows a newly committed spline outside the settled cache then settles it", () => {
  const canvas = fakeCanvas()
  const cache = fakeCanvas()
  let projections = 0
  const curve = {
    from: {x: 10, y: 30},
    control1: {x: 35, y: 5},
    control2: {x: 65, y: 55},
    to: {x: 90, y: 30},
  }
  const renderer = new Renderer(canvas, {
    width: 100,
    height: 60,
    createCanvas: () => cache,
    projectScene: instructions => {
      projections++
      return instructions.some(item => item.sequence === 2)
        ? [{
            type: "fiber-path",
            sequence: 2,
            intensity: 0.7,
            stroke: "#63d7d1",
            segments: [{sequence: 2, transitionSequence: 2, length: 100, curve}],
          }]
        : []
    },
  })
  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))
  cache.calls.length = 0
  canvas.calls.length = 0

  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))

  assert.equal(cache.calls.some(([name]) => name === "bezierCurveTo"), false)
  assert.equal(canvas.calls.some(([name]) => name === "bezierCurveTo"), true)
  assert.equal(renderer.activeTransitions.has(2), true)
  const afterCommit = projections

  renderer.step(700)

  assert.equal(renderer.activeTransitions.size, 0)
  assert.equal(cache.calls.some(([name]) => name === "bezierCurveTo"), true)
  assert.equal(projections, afterCommit)
})

test("renders visitor formations as a deformation, bridge, and bloom", () => {
  const tugCalls = cachedCallsFor({
    type: "tug-response",
    sequence: 1,
    intensity: 0.8,
    before: [{x: 10, y: 30}, {x: 50, y: 30}, {x: 90, y: 30}],
    after: [{x: 10, y: 30}, {x: 50, y: 48}, {x: 90, y: 30}],
  })
  assert.equal(tugCalls.some(([name]) => name === "quadraticCurveTo"), true)

  const knotCalls = cachedCallsFor({
    type: "knot-connector",
    sequence: 1,
    intensity: 0.8,
    radius: 11,
    x: 50,
    y: 30,
    curve: {
      from: {x: 15, y: 20},
      control1: {x: 35, y: 5},
      control2: {x: 65, y: 55},
      to: {x: 85, y: 40},
    },
  })
  assert.equal(knotCalls.some(([name]) => name === "bezierCurveTo"), true)
  assert.equal(knotCalls.some(([name]) => name === "arc"), true)
  assert.equal(knotCalls.some(([name]) => name === "fill"), true)
  assert.deepEqual(knotCalls.find(([name]) => name === "arc").slice(1, 3), [50, 30])

  const illuminateCalls = cachedCallsFor({
    type: "illuminate-bloom",
    sequence: 1,
    intensity: 0.8,
    x: 50,
    y: 30,
    radius: 24,
  })
  assert.ok(illuminateCalls.filter(([name]) => name === "arc").length >= 2)
  assert.equal(illuminateCalls.some(([name]) => name === "fill"), true)
})

test("animates each visitor response for its bounded gesture duration", () => {
  const cases = [
    {
      duration: 600,
      expectedCall: "quadraticCurveTo",
      command: {
        type: "tug-response",
        sequence: 2,
        transitionSequence: 2,
        intensity: 0.8,
        before: [{x: 10, y: 30}, {x: 50, y: 30}, {x: 90, y: 30}],
        after: [{x: 10, y: 30}, {x: 50, y: 48}, {x: 90, y: 30}],
      },
    },
    {
      duration: 900,
      expectedCall: "bezierCurveTo",
      command: {
        type: "knot-connector",
        sequence: 2,
        transitionSequence: 2,
        intensity: 0.8,
        radius: 11,
        x: 50,
        y: 30,
        curve: {
          from: {x: 15, y: 20},
          control1: {x: 35, y: 5},
          control2: {x: 65, y: 55},
          to: {x: 85, y: 40},
        },
      },
    },
    {
      duration: 1200,
      expectedCall: "arc",
      command: {
        type: "illuminate-bloom",
        sequence: 2,
        transitionSequence: 2,
        intensity: 0.8,
        x: 50,
        y: 30,
        radius: 24,
      },
    },
  ]

  for (const {command, duration, expectedCall} of cases) {
    const canvas = fakeCanvas()
    const cache = fakeCanvas()
    const renderer = new Renderer(canvas, {
      width: 100,
      height: 60,
      createCanvas: () => cache,
      projectScene: instructions => instructions.some(item => item.sequence === 2) ? [command] : [],
    })
    renderer.setSnapshot(snapshotEnvelope([instruction(1)]))
    canvas.calls.length = 0

    renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))

    assert.equal(canvas.calls.some(([name]) => name === expectedCall), true)
    renderer.step(duration - 1)
    assert.equal(renderer.activeTransitions.has(2), true)
    renderer.step(duration)
    assert.equal(renderer.activeTransitions.has(2), false)
  }
})

test("grows a knot bridge from both ends toward its crossover", () => {
  const canvas = fakeCanvas()
  const cache = fakeCanvas()
  const command = {
    type: "knot-connector",
    sequence: 2,
    transitionSequence: 2,
    intensity: 0.8,
    radius: 11,
    x: 50,
    y: 30,
    curve: {
      from: {x: 15, y: 20},
      control1: {x: 35, y: 5},
      control2: {x: 65, y: 55},
      to: {x: 85, y: 40},
    },
  }
  const renderer = new Renderer(canvas, {
    width: 100,
    height: 60,
    createCanvas: () => cache,
    projectScene: instructions => instructions.some(item => item.sequence === 2) ? [command] : [],
  })
  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))
  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))
  canvas.calls.length = 0

  renderer.step(450)

  assert.equal(canvas.calls.filter(([name]) => name === "bezierCurveTo").length, 2)
  assert.equal(canvas.calls.some(([name]) => name === "arc"), true)
})

test("carries an illuminate bloom along its connected curves", () => {
  const canvas = fakeCanvas()
  const cache = fakeCanvas()
  const command = {
    type: "illuminate-bloom",
    sequence: 2,
    transitionSequence: 2,
    intensity: 0.8,
    x: 50,
    y: 30,
    radius: 24,
    glowCurves: [{
      from: {x: 50, y: 30},
      control1: {x: 60, y: 20},
      control2: {x: 70, y: 40},
      to: {x: 82, y: 32},
    }],
  }
  const renderer = new Renderer(canvas, {
    width: 100,
    height: 60,
    createCanvas: () => cache,
    projectScene: instructions => instructions.some(item => item.sequence === 2) ? [command] : [],
  })
  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))
  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))
  canvas.calls.length = 0

  renderer.step(600)

  assert.equal(canvas.calls.some(([name]) => name === "bezierCurveTo"), true)
  assert.equal(canvas.calls.some(([name]) => name === "arc"), true)
})

test("scene reconstruction settles active transitions immediately", () => {
  const mutations = [
    ["resize", renderer => renderer.resize(120, 80, 2)],
    ["history", renderer => renderer.prependHistory([instruction(0)])],
    ["pan", renderer => renderer.panBy(10)],
    ["reload", renderer => renderer.reload([instruction(1), instruction(2)])],
    ["return live", renderer => renderer.returnLive()],
  ]

  for (const [name, mutate] of mutations) {
    const renderer = rendererWithActiveTransition()
    mutate(renderer)
    assert.equal(renderer.activeTransitions.size, 0, `${name} left a transition active`)
  }
})

function rendererWithActiveTransition() {
  const curve = {
    from: {x: 10, y: 30},
    control1: {x: 35, y: 5},
    control2: {x: 65, y: 55},
    to: {x: 90, y: 30},
  }
  const renderer = new Renderer(null, {
    width: 100,
    height: 60,
    projectScene: () => [{
      type: "fiber-path",
      sequence: 2,
      segments: [{sequence: 2, transitionSequence: 2, length: 100, curve}],
    }],
  })
  renderer.setSnapshot(snapshotEnvelope([instruction(1)]))
  renderer.setSnapshot(snapshotEnvelope([instruction(1), instruction(2)]))
  assert.equal(renderer.activeTransitions.size, 1)
  return renderer
}

function publicInstruction(sequence) {
  return {...instruction(sequence), kind: "wikimedia", source: "wikimedia"}
}

function snapshotEnvelope(
  displayEvents,
  {memoryEvents = [], ambient = null, watermark = null, windowEnd = "2026-08-08T12:01:00Z"} = {},
) {
  const sequences = [
    ...displayEvents,
    ...memoryEvents,
    ...(ambient === null ? [] : [ambient]),
  ].map(event => event.sequence)

  return {
    snapshot_version: 1,
    window_end: windowEnd,
    commit_watermark: watermark ?? Math.max(0, ...sequences),
    display_events: displayEvents,
    memory_events: memoryEvents,
    ambient,
  }
}

function snapshotWithInstructionMutation(role, mutate) {
  const snapshot = structuredClone(balancedSnapshot)
  const instruction = role === "ambient" ? snapshot.ambient : snapshot[role][0]
  mutate(instruction)
  return snapshot
}

function rendererState(renderer) {
  return structuredClone({
    commitWatermark: renderer.commitWatermark,
    snapshotVersion: renderer.snapshotVersion,
    instructions: renderer.instructions,
    memoryInstructions: renderer.memoryInstructions,
    ambient: renderer.ambient,
    windowEnd: renderer.windowEnd,
    selectedSequence: renderer.selectedSequence,
    scaffold: renderer.scaffold,
    commands: renderer.commands,
  })
}

function visitorSurgeInstructions({visitorLane = null} = {}) {
  const publicInstructions = Array.from(
    {length: 120},
    (_entry, index) => publicInstruction(index + 1),
  )
  const visitorKinds = ["tug", "knot", "illuminate"]
  const visitorInstructions = Array.from({length: 70}, (_entry, index) => ({
    ...instruction(index + 121),
    kind: visitorKinds[index % visitorKinds.length],
    source: "visitor",
    ...(visitorLane === null ? {} : {lane: visitorLane}),
  }))

  return [...publicInstructions, ...visitorInstructions]
}

function assertVisibleScaffold(renderer) {
  const spine = renderer.commands.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  assert.ok(spine)
  assert.ok(spine.segments.length >= 10)
  assert.ok(spine.segments.at(-1).curve.to.x >= renderer.padding)
  assert.ok(spine.segments.at(-1).curve.to.x <= renderer.width - renderer.padding)
  const visibleXs = spine.segments.flatMap(segment => [
    Math.max(renderer.padding, Math.min(renderer.width - renderer.padding, segment.curve.from.x)),
    Math.max(renderer.padding, Math.min(renderer.width - renderer.padding, segment.curve.to.x)),
  ])
  assert.ok(Math.max(...visibleXs) - Math.min(...visibleXs) >= renderer.width * 0.65)
}

function assertEventTimeScaffold(renderer, scaffold, windowEnd) {
  const spine = renderer.commands.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  assert.ok(spine)
  assert.equal(
    spine.segments[0].curve.from.x,
    eventTimeToX(scaffold[0].occurred_at, windowEnd, renderer.viewport()),
  )
  assert.equal(
    spine.segments.at(-1).curve.to.x,
    eventTimeToX(scaffold.at(-1).occurred_at, windowEnd, renderer.viewport()),
  )
}

function visitorBandWidth(renderer) {
  const spine = renderer.commands.find(
    command => command.type === "fiber-path" && command.role === "spine",
  )
  const newestHit = renderer.commands
    .filter(command => command.type === "anchor-hit")
    .at(-1)
  return newestHit.x - spine.segments.at(-1).curve.to.x
}

function visibleSpineMetrics(renderer, spine) {
  const minimumX = renderer.padding
  const maximumX = renderer.width - renderer.padding
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

function cachedCallsFor(command) {
  const cache = fakeCanvas()
  const renderer = new Renderer(null, {
    width: 100,
    height: 60,
    createCanvas: () => cache,
    projectScene: () => [command],
  })
  cache.calls.length = 0
  renderer.setEvents([instruction(1)])
  return cache.calls
}

function fakeCanvas() {
  const calls = []
  const record = name => (...arguments_) => calls.push([name, ...arguments_])
  const context = {
    setTransform: record("setTransform"),
    clearRect: record("clearRect"),
    beginPath: record("beginPath"),
    moveTo: record("moveTo"),
    lineTo: record("lineTo"),
    quadraticCurveTo: record("quadraticCurveTo"),
    bezierCurveTo: record("bezierCurveTo"),
    arc: record("arc"),
    stroke: record("stroke"),
    fill: record("fill"),
    save: record("save"),
    restore: record("restore"),
    fillRect: record("fillRect"),
    fillText: record("fillText"),
    drawImage: record("drawImage"),
    translate: record("translate"),
    setLineDash: record("setLineDash"),
    set lineWidth(value) { calls.push(["lineWidth", value]) },
    set strokeStyle(value) { calls.push(["strokeStyle", value]) },
    set fillStyle(value) { calls.push(["fillStyle", value]) },
    set globalAlpha(value) { calls.push(["globalAlpha", value]) },
    set lineCap(value) { calls.push(["lineCap", value]) },
    set lineJoin(value) { calls.push(["lineJoin", value]) },
  }

  return {width: 0, height: 0, style: {}, calls, getContext: () => context}
}
