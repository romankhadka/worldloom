import assert from "node:assert/strict"
import test from "node:test"

import {commandsForScene} from "../js/worldloom/geometry.js"
import {Renderer} from "../js/worldloom/renderer.js"

const instruction = sequence => ({
  sequence,
  kind: sequence % 4 === 0 ? "weather" : "wikimedia",
  source: sequence % 4 === 0 ? "open_meteo" : "wikimedia",
  occurred_at: `2026-08-03T12:${String(Math.floor(sequence / 60) % 60).padStart(2, "0")}:${String(sequence % 60).padStart(2, "0")}.000000Z`,
  render_version: 1,
  seed: sequence,
  lane: (sequence % 10) / 10,
  intensity: 0.5,
  visual: {spread: 0.5, bend: 0.1, pulse: 0.7},
  summary: `Formation ${sequence}`,
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

test("queues out-of-order events, consumes empty-gap watermarks, and drains in order", () => {
  const gaps = []
  const renderer = new Renderer(null, {onGap: gap => gaps.push(gap)})
  renderer.setEvents([instruction(10)])

  renderer.receiveEvent(instruction(13))
  renderer.receiveEvent(instruction(14))
  assert.deepEqual(gaps, [{after: 10, through: 12}])
  assert.deepEqual(renderer.events.map(event => event.sequence), [10])

  renderer.applyCatchUp([], 12)
  assert.deepEqual(renderer.events.map(event => event.sequence), [10, 13, 14])
  assert.equal(renderer.watermark, 14)
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

  renderer.setEvents([instruction(1)])
  renderer.receiveEvent(instruction(2))
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
  renderer.setEvents([instruction(1), instruction(2)])
  assert.equal(projections, beforeSceneChange + 1)
  const afterSceneChange = projections

  renderer.step(16)
  renderer.step(32)
  assert.equal(projections, afterSceneChange)

  renderer.receiveEvent(instruction(3))
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

test("bounds active transitions and settles the oldest when a ninth arrives", () => {
  const renderer = new Renderer(null, {width: 800, height: 600})
  renderer.setEvents([instruction(1)])

  for (let sequence = 2; sequence <= 10; sequence++) {
    renderer.receiveEvent({...instruction(sequence), kind: "wikimedia", source: "wikimedia"})
  }

  assert.equal(renderer.activeTransitions.size, 8)
  assert.equal(renderer.activeTransitions.has(2), false)
  assert.deepEqual([...renderer.activeTransitions.keys()], [3, 4, 5, 6, 7, 8, 9, 10])
})

test("settles ambient weather directly without an empty transition", () => {
  const renderer = new Renderer(null)
  renderer.setEvents([instruction(1)])

  renderer.receiveEvent({...instruction(2), kind: "weather", source: "open_meteo"})

  assert.equal(renderer.activeTransitions.size, 0)
})

test("settles unsupported render versions as fallback marks without empty transitions", () => {
  const renderer = new Renderer(null)
  renderer.setEvents([instruction(1)])

  renderer.receiveEvent({...instruction(2), render_version: 99})

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
  renderer.setEvents([instruction(1)])
  renderer.receiveEvent(instruction(2))
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
  renderer.setEvents([instruction(1)])
  cache.calls.length = 0
  canvas.calls.length = 0

  renderer.receiveEvent(instruction(2))

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
    renderer.setEvents([instruction(1)])
    canvas.calls.length = 0

    renderer.receiveEvent(instruction(2))

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
  renderer.setEvents([instruction(1)])
  renderer.receiveEvent(instruction(2))
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
  renderer.setEvents([instruction(1)])
  renderer.receiveEvent(instruction(2))
  canvas.calls.length = 0

  renderer.step(600)

  assert.equal(canvas.calls.some(([name]) => name === "bezierCurveTo"), true)
  assert.equal(canvas.calls.some(([name]) => name === "arc"), true)
})

test("scene reconstruction settles active transitions immediately", () => {
  const mutations = [
    ["resize", renderer => renderer.resize(120, 80, 2)],
    ["history", renderer => renderer.prependHistory([instruction(0)])],
    ["catch-up", renderer => renderer.applyCatchUp([], 2)],
    ["pan", renderer => renderer.panBy(10)],
    ["ambient", renderer => renderer.setAmbient(instruction(3))],
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
  renderer.setEvents([instruction(1)])
  renderer.receiveEvent(instruction(2))
  assert.equal(renderer.activeTransitions.size, 1)
  return renderer
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
    drawImage: record("drawImage"),
    translate: record("translate"),
    set lineWidth(value) { calls.push(["lineWidth", value]) },
    set strokeStyle(value) { calls.push(["strokeStyle", value]) },
    set fillStyle(value) { calls.push(["fillStyle", value]) },
    set globalAlpha(value) { calls.push(["globalAlpha", value]) },
  }

  return {width: 0, height: 0, style: {}, calls, getContext: () => context}
}
