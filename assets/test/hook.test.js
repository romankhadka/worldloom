import assert from "node:assert/strict"
import test from "node:test"

import {
  Worldloom,
  selectedSequenceFromClick,
  shouldClearSelectionFromClick,
} from "../js/worldloom/hook.js"

test("stops propagation only when a canvas click selects a formation", () => {
  let stopped = false
  const event = {
    clientX: 45,
    clientY: 70,
    stopPropagation() {
      stopped = true
    },
  }
  const element = {
    getBoundingClientRect: () => ({left: 20, top: 30}),
  }
  const renderer = {
    hitTest(x, y) {
      assert.deepEqual([x, y], [25, 40])
      return 17
    },
  }

  assert.equal(selectedSequenceFromClick(event, element, renderer), 17)
  assert.equal(stopped, true)
})

test("lets a canvas click without a formation continue propagating", () => {
  let stopped = false
  const event = {
    clientX: 45,
    clientY: 70,
    stopPropagation() {
      stopped = true
    },
  }
  const element = {
    getBoundingClientRect: () => ({left: 20, top: 30}),
  }
  const renderer = {hitTest: () => null}

  assert.equal(selectedSequenceFromClick(event, element, renderer), null)
  assert.equal(stopped, false)
})

test("classifies only ordinary clicks outside formation detail for dismissal", () => {
  const detailTarget = target("detail")
  const accessibleTarget = target("accessible")
  const outsideTarget = target("outside")
  const detail = {
    contains: candidate => candidate === detailTarget,
  }

  assert.equal(shouldClearSelectionFromClick({target: outsideTarget}, null), false)
  assert.equal(shouldClearSelectionFromClick({target: detailTarget}, detail), false)
  assert.equal(shouldClearSelectionFromClick({target: accessibleTarget}, detail), false)
  assert.equal(shouldClearSelectionFromClick({target: outsideTarget}, detail), true)
})

test("captures direct pointer placement and commits only its final lane", t => {
  const harness = hookHarness(t)

  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 7, clientY: 430}))
  assert.deepEqual(harness.el.capturedPointers, [7])
  assert.deepEqual(harness.pushes, [])

  harness.el.dispatch("pointerup", pointerEvent({pointerId: 8, clientY: 430}))
  assert.deepEqual(harness.pushes, [])
  assert.equal(harness.el.hasPointerCapture(7), true)

  harness.el.dispatch("pointerup", pointerEvent({pointerId: 7, clientY: 430}))
  assert.deepEqual(harness.lanePushes(), [{lane: "0.75"}])
  assert.deepEqual(harness.el.releasedPointers, [7])

  harness.el.dispatch("click", {clientX: 200, clientY: 200})
  assert.equal(harness.renderer.hitTests.length, 0)

  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 9, clientY: 170}))
  harness.el.dispatch("pointercancel", pointerEvent({pointerId: 9, clientY: 170}))
  assert.deepEqual(harness.lanePushes(), [{lane: "0.75"}])
  assert.equal(harness.renderer.targetLanes.at(-1), 0.75)

  harness.el.dispatch("click", {clientX: 200, clientY: 200})
  assert.equal(harness.renderer.hitTests.length, 1)

  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 10, clientY: 170}))
  harness.el.dispatch("lostpointercapture", pointerEvent({pointerId: 10, clientY: 170}))
  harness.el.dispatch("click", {clientX: 200, clientY: 200})
  assert.equal(harness.renderer.hitTests.length, 2)

  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 11, clientY: 170}))
  harness.el.dispatch("pointerup", pointerEvent({pointerId: 11, clientY: 170}))
  assert.equal(harness.scheduled.size, 1)

  const [timer, resetClickSuppression] = harness.scheduled.entries().next().value
  harness.scheduled.delete(timer)
  resetClickSuppression()
  harness.el.dispatch("click", {clientX: 200, clientY: 200})
  assert.equal(harness.renderer.hitTests.length, 3)

  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 12, clientY: 430}))
  harness.el.dispatch("pointerup", pointerEvent({pointerId: 12, clientY: 430}))
  assert.equal(harness.scheduled.size, 1)
  harness.hook.destroyed()
  assert.equal(harness.scheduled.size, 0)
  assert.equal([...harness.el.listeners.values()].every(listeners => listeners.length === 0), true)
  assert.equal([...harness.window.listeners.values()].every(listeners => listeners.length === 0), true)
})

test("touch placement cancels cleanly and commits a normal end at most once", t => {
  const harness = hookHarness(t)

  harness.el.dispatch("touchstart", touchEvent(430))
  harness.el.dispatch("touchmove", touchEvent(431))
  harness.el.dispatch("touchcancel", touchEvent())
  assert.deepEqual(harness.lanePushes(), [])
  assert.equal(harness.renderer.targetLanes.at(-1), 0.5)

  harness.el.dispatch("click", {clientX: 200, clientY: 200})
  assert.equal(harness.renderer.hitTests.length, 1)

  harness.el.dispatch("touchstart", touchEvent(430))
  harness.el.dispatch("touchend", touchEvent())
  harness.el.dispatch("touchend", touchEvent())
  assert.deepEqual(harness.lanePushes(), [{lane: "0.75"}])
})

test("deduplicates snapped placement updates and synchronizes only on release", t => {
  const harness = hookHarness(t)

  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 3, clientY: 420}))
  harness.el.dispatch("pointermove", pointerEvent({pointerId: 3, clientY: 421}))
  harness.el.dispatch("pointermove", pointerEvent({pointerId: 3, clientY: 430}))
  harness.el.dispatch("pointermove", pointerEvent({pointerId: 3, clientY: 440}))

  assert.deepEqual(harness.renderer.targetLanes, [0.75])
  assert.deepEqual(harness.lanePushes(), [])

  harness.el.dispatch("pointerup", pointerEvent({pointerId: 3, clientY: 440}))
  assert.deepEqual(harness.renderer.targetLanes, [0.75])
  assert.deepEqual(harness.lanePushes(), [{lane: "0.75"}])
})

test("keeps active pointer and touch placement paths isolated", t => {
  const harness = hookHarness(t)

  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 3, clientY: 430}))
  harness.el.dispatch("touchstart", touchEvent(170))
  harness.el.dispatch("touchmove", touchEvent(170))
  harness.el.dispatch("pointerup", pointerEvent({pointerId: 3, clientY: 430}))
  assert.deepEqual(harness.renderer.targetLanes, [0.75])

  harness.el.dispatch("click", {clientX: 200, clientY: 200})
  harness.el.dispatch("touchstart", touchEvent(170))
  harness.el.dispatch("pointermove", pointerEvent({pointerId: 4, clientY: 430}))
  harness.el.dispatch("touchend", touchEvent())
  assert.deepEqual(harness.renderer.targetLanes, [0.75, 0.25])
})

test("server route and disabled lane contracts preserve read-only pan paths", t => {
  const historical = hookHarness(t, {live: false})

  historical.el.dispatch("pointerdown", pointerEvent({pointerId: 1, clientY: 430}))
  historical.el.dispatch("pointermove", pointerEvent({pointerId: 1, clientY: 431}))
  historical.el.dispatch("pointerup", pointerEvent({pointerId: 1, clientY: 431}))
  historical.el.dispatch("touchstart", touchEvent(430))
  historical.el.dispatch("touchmove", touchEvent(431))
  historical.el.dispatch("touchend", touchEvent())

  assert.equal(historical.renderer.pointerDowns.length, 1)
  assert.equal(historical.renderer.pointerMoves.length, 1)
  assert.equal(historical.renderer.pointerUps, 1)
  assert.equal(historical.renderer.touchStarts.length, 1)
  assert.equal(historical.renderer.touchMoves.length, 1)
  assert.equal(historical.renderer.touchEnds, 1)
  assert.deepEqual(historical.lanePushes(), [])

  const disabled = hookHarness(t, {laneDisabled: true})
  disabled.el.dispatch("pointerdown", pointerEvent({pointerId: 2, clientY: 430}))
  disabled.el.dispatch("pointerup", pointerEvent({pointerId: 2, clientY: 430}))
  assert.equal(disabled.renderer.pointerDowns.length, 1)
  assert.equal(disabled.renderer.pointerUps, 1)
  disabled.el.dispatch("touchstart", touchEvent(430))
  disabled.el.dispatch("touchmove", touchEvent(431))
  disabled.el.dispatch("touchend", touchEvent())
  assert.equal(disabled.renderer.touchStarts.length, 1)
  assert.equal(disabled.renderer.touchMoves.length, 1)
  assert.equal(disabled.renderer.touchEnds, 1)
  assert.deepEqual(disabled.lanePushes(), [])
})

test("outside dismissal clears local selection before one trusted server push", t => {
  const harness = hookHarness(t)
  const outside = target("outside")
  const inside = target("detail")
  const accessible = target("accessible")
  harness.detail.contains = candidate => candidate === inside

  harness.window.dispatch("click", {target: outside})
  assert.equal(harness.renderer.clearSelections, 1)
  assert.deepEqual(harness.clearPushes(), [{}])
  assert.deepEqual(harness.effects.slice(0, 2), [
    "renderer.clearSelection",
    "push.clear-selection",
  ])

  harness.window.dispatch("click", {target: inside})
  harness.window.dispatch("click", {target: accessible})
  assert.equal(harness.renderer.clearSelections, 1)
  assert.deepEqual(harness.clearPushes(), [{}])

  harness.window.dispatch("keydown", {key: "Escape"})
  assert.equal(harness.renderer.clearSelections, 2)
  assert.deepEqual(harness.clearPushes(), [{}])
})

test("reload and return-live server events reconcile local selection", t => {
  const harness = hookHarness(t)

  harness.serverEvents.get("worldloom:reload")({
    instructions: [{sequence: 17}],
    watermark: 17,
    selected_sequence: 17,
  })
  assert.deepEqual(harness.renderer.selections, [17])

  harness.serverEvents.get("worldloom:reload")({instructions: [], watermark: 18})
  assert.equal(harness.renderer.clearSelections, 1)

  harness.serverEvents.get("worldloom:return-live")({instructions: [], watermark: 19})
  assert.equal(harness.renderer.clearSelections, 2)
  assert.deepEqual(harness.renderer.lifecycle.slice(-2), ["returnLive", "clearSelection"])
})

test("updated reapplies introduction dismissal to replacement nodes", t => {
  const harness = hookHarness(t)

  harness.el.dispatch("wheel", {preventDefault() {}})
  assert.equal(harness.introduction.dataset.dismissed, "true")

  const replacement = new FakeTarget()
  harness.introduction.isConnected = false
  harness.nodes.introduction = replacement
  harness.hook.updated()

  assert.equal(replacement.dataset.dismissed, "true")
})

test("updated reconciles changed lane data and binds replacement controls once", t => {
  const harness = hookHarness(t)

  harness.el.dataset.gestureLane = "0.75"
  harness.hook.updated()
  harness.hook.updated()
  assert.deepEqual(harness.renderer.targetLanes, [0.75])

  const replacement = new FakeTarget({value: "0.8"})
  harness.laneInput.isConnected = false
  harness.nodes.laneInput = replacement
  harness.hook.updated()
  harness.hook.updated()
  replacement.value = "0.8"
  replacement.dispatch("input")
  assert.deepEqual(harness.renderer.targetLanes, [0.75, 0.8])
  harness.el.dataset.gestureLane = "0.8"

  const replacementButton = new FakeTarget()
  harness.nodes.gestureButtons = [replacementButton]
  harness.hook.updated()
  harness.hook.updated()
  assert.equal(replacementButton.listeners.get("click").length, 1)

  harness.hook.placingLane = true
  harness.el.dataset.gestureLane = "0.3"
  harness.hook.updated()
  assert.deepEqual(harness.renderer.targetLanes, [0.75, 0.8])
  harness.hook.placingLane = false

  harness.el.dataset.gestureLane = "0.8"
  harness.el.dispatch("pointerdown", pointerEvent({pointerId: 8, clientY: 456}))
  harness.el.dispatch("pointerup", pointerEvent({pointerId: 8, clientY: 456}))
  assert.deepEqual(harness.lanePushes(), [])
})

test("copyLink provides truthful success, fallback, and missing-target feedback", async t => {
  const harness = hookHarness(t)
  let copiedUrl = null
  replaceGlobal(t, "navigator", {
    clipboard: {writeText: async url => { copiedUrl = url }},
  })

  await harness.hook.copyLink("https://example.test/live")
  assert.equal(copiedUrl, "https://example.test/live")
  assert.equal(harness.shareStatus.textContent, "Link copied.")
  assert.equal(harness.fallbackField.hidden, true)
  assert.deepEqual(harness.announcements, ["Link copied."])

  replaceGlobal(t, "navigator", {
    clipboard: {writeText: async () => { throw new Error("denied") }},
  })
  await harness.hook.copyLink("https://example.test/chapter")
  assert.equal(harness.fallbackField.hidden, false)
  assert.equal(harness.fallbackInput.value, "https://example.test/chapter")
  assert.equal(harness.fallbackInput.focused, true)
  assert.equal(harness.fallbackInput.selected, true)
  assert.equal(harness.shareStatus.textContent, "Select and copy this permanent link.")
  assert.deepEqual(harness.announcements, [
    "Link copied.",
    "Select and copy this permanent link.",
  ])

  replaceGlobal(t, "navigator", {
    clipboard: {writeText: async () => {}},
  })
  await harness.hook.copyLink("https://example.test/recovered")
  assert.equal(harness.fallbackField.hidden, true)
  assert.equal(harness.shareStatus.textContent, "Link copied.")

  harness.nodes.fallbackField = null
  harness.nodes.fallbackInput = null
  replaceGlobal(t, "navigator", {
    clipboard: {writeText: async () => { throw new Error("denied") }},
  })
  await harness.hook.copyLink("https://example.test/missing")
  assert.equal(
    harness.shareStatus.textContent,
    "Copy failed. Use the address bar to copy this link.",
  )
})

function target(location) {
  return {
    closest(selector) {
      return selector === "#accessible-formations" && location === "accessible" ? {} : null
    },
  }
}

function hookHarness(t, {live = true, laneDisabled = false} = {}) {
  const window = new FakeTarget()
  const el = new FakeTarget()
  el.dataset = {gestureLane: "0.5", live: String(live)}
  el.getBoundingClientRect = () => ({left: 0, top: 0, width: 800, height: 600})
  el.capturedPointers = []
  el.releasedPointers = []
  el.pointerCaptures = new Set()
  el.setPointerCapture = pointerId => {
    el.pointerCaptures.add(pointerId)
    el.capturedPointers.push(pointerId)
  }
  el.hasPointerCapture = pointerId => el.pointerCaptures.has(pointerId)
  el.releasePointerCapture = pointerId => {
    el.pointerCaptures.delete(pointerId)
    el.releasedPointers.push(pointerId)
  }

  const laneInput = new FakeTarget({value: "0.5", disabled: laneDisabled})
  const introduction = new FakeTarget()
  const shareStatus = new FakeTarget({textContent: ""})
  const fallbackField = new FakeTarget({hidden: true})
  const fallbackInput = new FakeTarget({value: ""})
  const detail = new FakeTarget()
  const gestureButton = new FakeTarget()
  const nodes = {
    laneInput,
    introduction,
    shareStatus,
    fallbackField,
    fallbackInput,
    detail,
    gestureButtons: [gestureButton],
  }
  const document = {
    querySelector(selector) {
      return {
        "#gesture-lane": nodes.laneInput,
        "#worldloom-introduction": nodes.introduction,
        "#share-status": nodes.shareStatus,
        "#share-fallback-field": nodes.fallbackField,
        "#share-fallback": nodes.fallbackInput,
        "#signal-detail": nodes.detail,
      }[selector] ?? null
    },
    querySelectorAll(selector) {
      return selector === ".gesture-button" ? nodes.gestureButtons : []
    },
  }
  replaceGlobal(t, "window", window)
  replaceGlobal(t, "document", document)

  const pushes = []
  const effects = []
  const announcements = []
  const renderer = fakeRenderer(effects)
  const serverEvents = new Map()
  const scheduled = new Map()
  let nextTimer = 1
  const hook = Object.assign(Object.create(Worldloom), {
    el,
    renderer,
    laneInput,
    introduction,
    shareStatus,
    listeners: [],
    placingLane: false,
    placedLane: false,
    activePointerId: null,
    activePointerType: null,
    pendingLane: null,
    placementStartLane: null,
    localLane: 0.5,
    lastServerLane: 0.5,
    introductionDismissed: false,
    boundLaneInputs: new WeakSet(),
    boundGestureButtons: new WeakSet(),
    scheduleTimeout(callback) {
      const timer = nextTimer++
      scheduled.set(timer, callback)
      return timer
    },
    cancelTimeout(timer) {
      scheduled.delete(timer)
    },
    pushEvent(name, payload) {
      pushes.push({name, payload})
      effects.push(`push.${name}`)
    },
    handleEvent(name, handler) {
      serverEvents.set(name, handler)
    },
    dismissIntroduction(...args) {
      if (typeof Worldloom.dismissIntroduction === "function") {
        return Worldloom.dismissIntroduction.apply(this, args)
      }
      this.introduction.dataset.dismissed = "true"
    },
    announceShare(message) {
      announcements.push(message)
      if (typeof Worldloom.announceShare === "function") {
        return Worldloom.announceShare.call(this, message)
      }
      this.shareStatus.textContent = message
    },
  })

  hook.installListeners()
  hook.installServerEvents()

  return {
    hook,
    el,
    window,
    renderer,
    pushes,
    effects,
    announcements,
    serverEvents,
    scheduled,
    nodes,
    laneInput,
    introduction,
    shareStatus,
    fallbackField,
    fallbackInput,
    detail,
    lanePushes: () => pushes.filter(push => push.name === "lane-change").map(push => push.payload),
    clearPushes: () => pushes.filter(push => push.name === "clear-selection").map(push => push.payload),
  }
}

class FakeTarget {
  constructor(properties = {}) {
    this.listeners = new Map()
    this.dataset = {}
    this.isConnected = true
    Object.assign(this, properties)
  }

  addEventListener(name, listener, options) {
    const listeners = this.listeners.get(name) ?? []
    listeners.push({listener, options})
    this.listeners.set(name, listeners)
  }

  removeEventListener(name, listener, options) {
    const listeners = this.listeners.get(name) ?? []
    this.listeners.set(name, listeners.filter(item => item.listener !== listener || item.options !== options))
  }

  dispatch(name, event = {}) {
    if (event.target === undefined) event.target = this
    if (event.stopPropagation === undefined) event.stopPropagation = () => {}
    for (const {listener} of this.listeners.get(name) ?? []) listener(event)
    return event
  }

  contains(candidate) {
    return candidate === this
  }

  focus() {
    this.focused = true
  }

  select() {
    this.selected = true
  }
}

function fakeRenderer(effects = []) {
  return {
    reducedMotion: false,
    watermark: 0,
    targetLanes: [],
    pointerDowns: [],
    pointerMoves: [],
    pointerUps: 0,
    touchStarts: [],
    touchMoves: [],
    touchEnds: 0,
    hitTests: [],
    selections: [],
    clearSelections: 0,
    lifecycle: [],
    atLiveEdge: () => true,
    setTargetLane(lane) { this.targetLanes.push(lane) },
    pointerDown(event) { this.pointerDowns.push(event) },
    pointerMove(event) { this.pointerMoves.push(event) },
    pointerUp() { this.pointerUps += 1 },
    touchStart(event) { this.touchStarts.push(event) },
    touchMove(event) { this.touchMoves.push(event) },
    touchEnd() { this.touchEnds += 1 },
    handleWheel() {},
    hitTest(x, y) {
      this.hitTests.push([x, y])
      return 17
    },
    setSelection(sequence) {
      this.selections.push(sequence)
      this.lifecycle.push("setSelection")
    },
    clearSelection() {
      this.clearSelections += 1
      this.lifecycle.push("clearSelection")
      effects.push("renderer.clearSelection")
    },
    reload(instructions, watermark) {
      this.lifecycle.push(["reload", instructions, watermark])
    },
    returnLive() { this.lifecycle.push("returnLive") },
    receiveEvent() {},
    applyCatchUp() {},
    prependHistory() {},
    setViewerCount() {},
    destroy() { this.destroyed = true },
  }
}

function pointerEvent({pointerId, clientY, pointerType = "mouse"}) {
  return {pointerId, pointerType, clientX: 790, clientY}
}

function touchEvent(clientY) {
  const touches = clientY === undefined ? [] : [{clientX: 790, clientY}]
  return {touches, preventDefault() { this.defaultPrevented = true }}
}

function replaceGlobal(t, name, value) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, name)
  Object.defineProperty(globalThis, name, {configurable: true, writable: true, value})
  t.after(() => {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor)
    else delete globalThis[name]
  })
}
