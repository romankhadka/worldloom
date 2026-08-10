import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {
  Worldloom,
  selectedSequenceFromClick,
  shouldClearSelectionFromClick,
  snapshotFromDataset,
} from "../js/worldloom/hook.js"

const balancedSnapshot = JSON.parse(readFileSync(
  new URL("../../test/support/fixtures/live_snapshots/balanced_v1.json", import.meta.url),
  "utf8",
))

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
  const shareTarget = target("share")
  const outsideTarget = target("outside")
  const detail = {
    contains: candidate => candidate === detailTarget,
  }

  assert.equal(shouldClearSelectionFromClick({target: outsideTarget}, null), false)
  assert.equal(shouldClearSelectionFromClick({target: detailTarget}, detail), false)
  assert.equal(shouldClearSelectionFromClick({target: accessibleTarget}, detail), false)
  assert.equal(shouldClearSelectionFromClick({target: shareTarget}, detail), false)
  assert.equal(shouldClearSelectionFromClick({target: outsideTarget}, detail), true)
})

test("decodes and installs the initial six-field snapshot exactly once", t => {
  const harness = hookHarness(t)
  harness.el.dataset.snapshotVersion = String(balancedSnapshot.snapshot_version)
  harness.el.dataset.windowEnd = balancedSnapshot.window_end
  harness.el.dataset.commitWatermark = String(balancedSnapshot.commit_watermark)
  harness.el.dataset.displayEvents = JSON.stringify(balancedSnapshot.display_events)
  harness.el.dataset.memoryEvents = JSON.stringify(balancedSnapshot.memory_events)
  harness.el.dataset.ambient = JSON.stringify(balancedSnapshot.ambient)

  assert.deepEqual(snapshotFromDataset(harness.el.dataset), balancedSnapshot)

  harness.hook.installInitialSnapshot()
  assert.deepEqual(harness.renderer.snapshots, [balancedSnapshot])
})

test("installs a weather-only initial snapshot without inventing a live window", t => {
  const harness = hookHarness(t)
  const weatherOnly = {
    snapshot_version: 1,
    window_end: null,
    commit_watermark: balancedSnapshot.ambient.sequence,
    display_events: [],
    memory_events: [],
    ambient: balancedSnapshot.ambient,
  }
  harness.el.dataset.snapshotVersion = String(weatherOnly.snapshot_version)
  harness.el.dataset.commitWatermark = String(weatherOnly.commit_watermark)
  harness.el.dataset.displayEvents = "[]"
  harness.el.dataset.memoryEvents = "[]"
  harness.el.dataset.ambient = JSON.stringify(weatherOnly.ambient)

  assert.deepEqual(snapshotFromDataset(harness.el.dataset), weatherOnly)
  assert.doesNotThrow(() => harness.hook.installInitialSnapshot())
  assert.deepEqual(harness.renderer.snapshots, [weatherOnly])
  assert.equal(harness.renderer.snapshots[0].window_end, null)
  assert.deepEqual(harness.renderer.snapshots[0].ambient, weatherOnly.ambient)
  assert.deepEqual(harness.renderer.snapshots[0].display_events, [])
  assert.deepEqual(harness.renderer.snapshots[0].memory_events, [])
})

test("replaces a server snapshot once without sequence-gap repair", t => {
  const harness = hookHarness(t)

  harness.serverEvents.get("worldloom:snapshot")(balancedSnapshot)

  assert.deepEqual(harness.renderer.snapshots, [balancedSnapshot])
  assert.equal(harness.serverEvents.has("worldloom:event"), false)
  assert.equal(harness.serverEvents.has("worldloom:catch-up"), false)
  assert.deepEqual(
    harness.pushes.filter(push => push.name === "sequence-gap"),
    [],
  )
  assert.equal(harness.el.dataset.renderedSequence, "906")
  assert.equal(harness.el.dataset.commitWatermark, "906")
  assert.equal(harness.el.dataset.snapshotVersion, "1")
  assert.equal(harness.el.dataset.windowEnd, "2026-08-08T12:01:00Z")
})

test("serializes settled scene diagnostics with canonical object keys", t => {
  const harness = hookHarness(t)
  harness.el.dataset.sceneDiagnosticsEnabled = "true"
  harness.renderer.settledSceneDiagnostics = () => ({
    paintCommands: [{type: "fiber", sequence: 3}],
    axis: {end: "2026-08-08T12:01:00Z", start: "2026-08-08T12:00:00Z"},
  })

  harness.hook.syncRenderedSequence()

  assert.equal(
    harness.el.dataset.sceneDiagnostics,
    '{"axis":{"end":"2026-08-08T12:01:00Z","start":"2026-08-08T12:00:00Z"},"paintCommands":[{"sequence":3,"type":"fiber"}]}',
  )
})

test("does not build scene diagnostics outside the acceptance environment", t => {
  const harness = hookHarness(t)
  let diagnosticsBuilt = 0
  harness.renderer.settledSceneDiagnostics = () => {
    diagnosticsBuilt += 1
    return {paintCommands: []}
  }

  harness.hook.syncRenderedSequence()

  assert.equal(diagnosticsBuilt, 0)
  assert.equal(harness.el.dataset.sceneDiagnostics, undefined)
})

test("forwards the renderer history cursor unchanged", t => {
  const harness = hookHarness(t)

  harness.hook.rendererOptions(false).onHistoryRequest({before: 31})

  assert.deepEqual(harness.pushes.at(-1), {
    name: "history-before",
    payload: {before: 31},
  })
})

test("binds timeline scales once and publishes an explicit UTC range", t => {
  const harness = hookHarness(t)
  const fifteenMinutes = harness.nodes.scaleButtons[2]

  fifteenMinutes.dispatch("click")
  harness.hook.updated()
  harness.hook.updated()

  assert.deepEqual(harness.renderer.timelineDurations, [900_000])
  assert.equal(fifteenMinutes.getAttribute("aria-pressed"), "true")
  assert.equal(harness.nodes.scaleButtons[0].getAttribute("aria-pressed"), "false")
  assert.match(harness.nodes.timelineRange.textContent, /15 minutes · .* UTC–.* UTC/)
  assert.equal(fifteenMinutes.listeners.get("click").length, 1)
})

test("forwards only active-generation timeline replies", t => {
  const harness = hookHarness(t)
  const request = {end_at: balancedSnapshot.window_end, duration_seconds: 300}
  const options = harness.hook.rendererOptions(false)

  options.onTimelineRequest(request)
  assert.deepEqual(harness.pushes.at(-1), {name: "timeline-window", payload: request})
  harness.timelineCallbacks.at(-1)({status: "accepted"})
  assert.deepEqual(harness.renderer.timelineReplies, [{status: "accepted"}])

  options.onTimelineRequest({...request, duration_seconds: 900})
  harness.hook.destroyed()
  harness.timelineCallbacks.at(-1)({status: "accepted"})
  assert.deepEqual(harness.renderer.timelineReplies, [{status: "accepted"}])
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

test("a second touch cancels direct placement without committing its preview lane", t => {
  const harness = hookHarness(t)
  const firstTouch = {clientX: 790, clientY: 430}
  const secondTouch = {clientX: 760, clientY: 170}

  harness.el.dispatch("touchstart", {touches: [firstTouch]})
  assert.equal(harness.renderer.targetLanes.at(-1), 0.75)

  harness.el.dispatch("touchstart", {touches: [firstTouch, secondTouch]})
  harness.el.dispatch("touchend", touchEvent())

  assert.deepEqual(harness.lanePushes(), [])
  assert.equal(harness.renderer.targetLanes.at(-1), 0.5)
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

test("reload and snapshot-based return-live events reconcile local selection", t => {
  const harness = hookHarness(t)
  const scaffold = [{sequence: 3}, {sequence: 7}]
  const ambient = {sequence: 11, source: "open_meteo", kind: "weather"}

  harness.serverEvents.get("worldloom:reload")({
    instructions: [{sequence: 17}],
    scaffold,
    ambient,
    watermark: 17,
    selected_sequence: 17,
  })
  assert.deepEqual(
    harness.renderer.lifecycle[0],
    ["reload", [{sequence: 17}], 17, {scaffold, ambient}],
  )
  assert.deepEqual(harness.renderer.selections, [17])

  harness.serverEvents.get("worldloom:reload")({instructions: [], watermark: 18})
  assert.equal(harness.renderer.clearSelections, 1)

  const returnSnapshot = {...structuredClone(balancedSnapshot), commit_watermark: 919}
  harness.serverEvents.get("worldloom:return-live")(returnSnapshot)
  assert.equal(harness.renderer.clearSelections, 2)
  assert.deepEqual(harness.renderer.snapshots, [returnSnapshot])
  assert.deepEqual(harness.renderer.lifecycle.slice(-4), [
    "resetLiveScaffold",
    ["setSnapshot", returnSnapshot],
    "returnLive",
    "clearSelection",
  ])
})

test("ordinary panned return-live keeps the existing live scaffold seed", t => {
  const harness = hookHarness(t)
  harness.renderer.snapshotVersion = 1

  harness.serverEvents.get("worldloom:return-live")(balancedSnapshot)

  assert.equal(harness.renderer.lifecycle.includes("resetLiveScaffold"), false)
  assert.deepEqual(harness.renderer.lifecycle.slice(-3), [
    ["setSnapshot", balancedSnapshot],
    "returnLive",
    "clearSelection",
  ])
})

test("history paging forwards a scaffold for the retained historical window", t => {
  const harness = hookHarness(t)
  const instructions = [{sequence: 1}, {sequence: 2}]
  const scaffold = [{sequence: 1}]

  harness.serverEvents.get("worldloom:history")({
    instructions,
    scaffold,
    "archive_start?": true,
  })

  assert.deepEqual(harness.renderer.lifecycle, [
    ["prependHistory", instructions, {archiveStart: true, scaffold}],
  ])
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

test("updated clears a revealed share fallback when the selected permalink changes", t => {
  const harness = hookHarness(t)
  harness.hook.lastSelectionPermalink = "/chapters/2026-08-04/1"
  harness.nodes.shareLink = new FakeTarget({value: "/chapters/2026-08-04/2"})
  harness.fallbackField.hidden = false
  harness.fallbackInput.value = "https://example.test/chapters/2026-08-04/1"
  harness.shareStatus.textContent = "Select and copy this permanent link."

  harness.hook.updated()

  assert.equal(harness.fallbackField.hidden, true)
  assert.equal(harness.fallbackInput.value, "")
  assert.equal(harness.shareStatus.textContent, "")
  assert.equal(harness.hook.lastSelectionPermalink, "/chapters/2026-08-04/2")

  harness.fallbackField.hidden = false
  harness.fallbackInput.value = "https://example.test/chapters/2026-08-04/2"
  harness.shareStatus.textContent = "Select and copy this permanent link."
  harness.hook.updated()

  assert.equal(harness.fallbackField.hidden, false)
  assert.equal(harness.fallbackInput.value, "https://example.test/chapters/2026-08-04/2")
  assert.equal(harness.shareStatus.textContent, "Select and copy this permanent link.")
})

test("copyLink provides truthful success, fallback, and missing-target feedback", async t => {
  const harness = hookHarness(t)
  const location = {origin: "https://example.test", pathname: "/live"}
  replaceGlobal(t, "location", location)
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
  location.pathname = "/chapter"
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
  location.pathname = "/recovered"
  await harness.hook.copyLink("https://example.test/recovered")
  assert.equal(harness.fallbackField.hidden, true)
  assert.equal(harness.shareStatus.textContent, "Link copied.")

  harness.nodes.fallbackField = null
  harness.nodes.fallbackInput = null
  replaceGlobal(t, "navigator", {
    clipboard: {writeText: async () => { throw new Error("denied") }},
  })
  location.pathname = "/missing"
  await harness.hook.copyLink("https://example.test/missing")
  assert.equal(
    harness.shareStatus.textContent,
    "Copy failed. Use the address bar to copy this link.",
  )
})

test("delayed clipboard resolution cannot announce after the share context changes", async t => {
  const harness = hookHarness(t)
  const shareContext = installShareContext(t, harness, "/chapters/2026-08-04/1")
  const pendingWrite = deferred()
  const writes = []
  replaceGlobal(t, "navigator", {
    clipboard: {
      writeText(url) {
        writes.push(url)
        return pendingWrite.promise
      },
    },
  })

  const oldRequest = harness.hook.copyLink("https://example.test/chapters/2026-08-04/1")
  await flushPromises()
  assert.deepEqual(writes, ["https://example.test/chapters/2026-08-04/1"])

  shareContext.setPath("/chapters/2026-08-04/2")
  harness.hook.updated()
  pendingWrite.resolve()
  await oldRequest

  assert.equal(harness.fallbackField.hidden, true)
  assert.equal(harness.fallbackInput.value, "")
  assert.equal(harness.shareStatus.textContent, "")
  assert.deepEqual(harness.announcements, [])
})

test("delayed clipboard rejection cannot restore fallback after the share context changes", async t => {
  const harness = hookHarness(t)
  const shareContext = installShareContext(t, harness, "/chapters/2026-08-04/1")
  const pendingWrite = deferred()
  replaceGlobal(t, "navigator", {
    clipboard: {writeText: () => pendingWrite.promise},
  })

  const oldRequest = harness.hook.copyLink("https://example.test/chapters/2026-08-04/1")
  await flushPromises()
  shareContext.setPath("/chapters/2026-08-04/2")
  harness.hook.updated()
  pendingWrite.reject(new Error("denied late"))
  await oldRequest

  assert.equal(harness.fallbackField.hidden, true)
  assert.equal(harness.fallbackInput.value, "")
  assert.equal(harness.shareStatus.textContent, "")
  assert.deepEqual(harness.announcements, [])
})

test("a delayed stale URL is dropped without disturbing the current share", async t => {
  const harness = hookHarness(t)
  installShareContext(t, harness, "/chapters/2026-08-04/2")
  const writes = []
  replaceGlobal(t, "navigator", {
    clipboard: {writeText: async url => writes.push(url)},
  })
  harness.fallbackField.hidden = false
  harness.fallbackInput.value = "https://example.test/chapters/2026-08-04/2"
  harness.shareStatus.textContent = "Select and copy this permanent link."

  await harness.hook.copyLink("https://example.test/chapters/2026-08-04/1")

  assert.deepEqual(writes, [])
  assert.equal(harness.fallbackField.hidden, false)
  assert.equal(
    harness.fallbackInput.value,
    "https://example.test/chapters/2026-08-04/2",
  )
  assert.equal(harness.shareStatus.textContent, "Select and copy this permanent link.")
  assert.deepEqual(harness.announcements, [])
})

test("concurrent shares serialize writes so the latest valid URL finishes last", async t => {
  const harness = hookHarness(t)
  const shareContext = installShareContext(t, harness, "/chapters/2026-08-04/1")
  const firstWrite = deferred()
  const secondWrite = deferred()
  const writes = []
  let clipboardText = ""
  replaceGlobal(t, "navigator", {
    clipboard: {
      writeText(url) {
        writes.push(url)
        const pending = url.endsWith("/1") ? firstWrite : secondWrite
        return pending.promise.then(() => { clipboardText = url })
      },
    },
  })

  const firstRequest = harness.hook.copyLink("https://example.test/chapters/2026-08-04/1")
  await flushPromises()
  shareContext.setPath("/chapters/2026-08-04/2")
  harness.hook.updated()
  const secondRequest = harness.hook.copyLink("https://example.test/chapters/2026-08-04/2")

  secondWrite.resolve()
  await flushPromises()
  assert.deepEqual(writes, ["https://example.test/chapters/2026-08-04/1"])

  firstWrite.resolve()
  await Promise.all([firstRequest, secondRequest])

  assert.deepEqual(writes, [
    "https://example.test/chapters/2026-08-04/1",
    "https://example.test/chapters/2026-08-04/2",
  ])
  assert.equal(clipboardText, "https://example.test/chapters/2026-08-04/2")
  assert.equal(harness.fallbackField.hidden, true)
  assert.equal(harness.shareStatus.textContent, "Link copied.")
  assert.deepEqual(harness.announcements, ["Link copied."])
})

test("a latest queued rejection owns fallback after the older write resolves", async t => {
  const harness = hookHarness(t)
  const shareContext = installShareContext(t, harness, "/chapters/2026-08-04/1")
  const firstWrite = deferred()
  const secondWrite = deferred()
  const writes = []
  replaceGlobal(t, "navigator", {
    clipboard: {
      writeText(url) {
        writes.push(url)
        return url.endsWith("/1") ? firstWrite.promise : secondWrite.promise
      },
    },
  })

  const firstRequest = harness.hook.copyLink("https://example.test/chapters/2026-08-04/1")
  await flushPromises()
  shareContext.setPath("/chapters/2026-08-04/2")
  harness.hook.updated()
  const secondRequest = harness.hook.copyLink("https://example.test/chapters/2026-08-04/2")

  secondWrite.reject(new Error("latest clipboard denied"))
  await flushPromises()
  firstWrite.resolve()
  await Promise.all([firstRequest, secondRequest])

  assert.deepEqual(writes, [
    "https://example.test/chapters/2026-08-04/1",
    "https://example.test/chapters/2026-08-04/2",
  ])
  assert.equal(harness.fallbackField.hidden, false)
  assert.equal(
    harness.fallbackInput.value,
    "https://example.test/chapters/2026-08-04/2",
  )
  assert.equal(harness.fallbackInput.focused, true)
  assert.equal(harness.fallbackInput.selected, true)
  assert.equal(harness.shareStatus.textContent, "Select and copy this permanent link.")
  assert.deepEqual(harness.announcements, ["Select and copy this permanent link."])
})

test("destroying the hook invalidates pending share completion", async t => {
  const harness = hookHarness(t)
  installShareContext(t, harness, "/chapters/2026-08-04/1")
  const pendingWrite = deferred()
  replaceGlobal(t, "navigator", {
    clipboard: {writeText: () => pendingWrite.promise},
  })

  const request = harness.hook.copyLink("https://example.test/chapters/2026-08-04/1")
  await flushPromises()
  harness.hook.destroyed()
  pendingWrite.resolve()
  await request

  assert.equal(harness.fallbackField.hidden, true)
  assert.equal(harness.fallbackInput.value, "")
  assert.equal(harness.shareStatus.textContent, "")
  assert.deepEqual(harness.announcements, [])
})

function target(location) {
  return {
    closest(selector) {
      if (selector.includes("#accessible-formations") && location === "accessible") return {}
      if (selector.includes("[data-preserve-selection]") && location === "share") return {}
      return null
    },
  }
}

function installShareContext(t, harness, path) {
  const location = {origin: "https://example.test", pathname: path}
  replaceGlobal(t, "location", location)
  harness.nodes.shareLink = new FakeTarget({value: path})
  harness.hook.lastSharePath = path
  harness.hook.lastSelectionPermalink = path

  return {
    setPath(nextPath) {
      location.pathname = nextPath
      harness.nodes.shareLink.value = nextPath
    },
  }
}

function deferred() {
  let resolve
  let reject
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  promise.catch(() => {})
  return {promise, resolve, reject}
}

async function flushPromises() {
  await Promise.resolve()
  await Promise.resolve()
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
  const scaleButtons = [60, 300, 900].map(duration => new FakeTarget({
    dataset: {durationSeconds: String(duration)},
  }))
  const timelineRange = new FakeTarget({textContent: ""})
  const nodes = {
    laneInput,
    introduction,
    shareStatus,
    fallbackField,
    fallbackInput,
    shareLink: null,
    detail,
    gestureButtons: [gestureButton],
    scaleButtons,
    timelineRange,
  }
  const document = {
    querySelector(selector) {
      return {
        "#gesture-lane": nodes.laneInput,
        "#worldloom-introduction": nodes.introduction,
        "#share-status": nodes.shareStatus,
        "#share-fallback-field": nodes.fallbackField,
        "#share-fallback": nodes.fallbackInput,
        "#share-link": nodes.shareLink,
        "#signal-detail": nodes.detail,
        "#timeline-range": nodes.timelineRange,
      }[selector] ?? null
    },
    querySelectorAll(selector) {
      if (selector === ".gesture-button") return nodes.gestureButtons
      if (selector === ".timeline-scale-button") return nodes.scaleButtons
      return []
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
  const timelineCallbacks = []
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
    boundTimelineScaleButtons: new WeakSet(),
    timelineGeneration: 0,
    scheduleTimeout(callback) {
      const timer = nextTimer++
      scheduled.set(timer, callback)
      return timer
    },
    cancelTimeout(timer) {
      scheduled.delete(timer)
    },
    pushEvent(name, payload, callback) {
      pushes.push({name, payload})
      if (name === "timeline-window" && typeof callback === "function") {
        timelineCallbacks.push(callback)
      }
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
    timelineCallbacks,
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

  setAttribute(name, value) {
    this.attributes ??= new Map()
    this.attributes.set(name, String(value))
  }

  getAttribute(name) {
    return this.attributes?.get(name) ?? null
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
    commitWatermark: 0,
    snapshotVersion: null,
    windowEnd: null,
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
    snapshots: [],
    timelineDurations: [],
    timelineReplies: [],
    timelineDurationMilliseconds: 60_000,
    lifecycle: [],
    atLiveEdge: () => true,
    timelineAxis() {
      const end = Date.parse(balancedSnapshot.window_end)
      const duration = this.timelineDurationMilliseconds
      return {
        start: new Date(end - duration).toISOString(),
        end: new Date(end).toISOString(),
        durationMilliseconds: duration,
        durationSeconds: duration / 1000,
      }
    },
    setTimelineDuration(duration) {
      this.timelineDurations.push(duration)
      this.timelineDurationMilliseconds = duration
      return true
    },
    completeTimelineRequest(reply) { this.timelineReplies.push(reply) },
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
    setSnapshot(snapshot) {
      this.snapshots.push(snapshot)
      this.lifecycle.push(["setSnapshot", snapshot])
      this.watermark = snapshot.commit_watermark
      this.commitWatermark = snapshot.commit_watermark
      this.snapshotVersion = snapshot.snapshot_version
      this.windowEnd = snapshot.window_end
    },
    setScaffold() {},
    resetLiveScaffold() { this.lifecycle.push("resetLiveScaffold") },
    reload(instructions, watermark, options) {
      this.lifecycle.push(["reload", instructions, watermark, options])
      this.watermark = watermark
      this.commitWatermark = watermark
      this.snapshotVersion = null
      this.windowEnd = null
    },
    returnLive() { this.lifecycle.push("returnLive") },
    prependHistory(instructions, options) {
      this.lifecycle.push(["prependHistory", instructions, options])
    },
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
