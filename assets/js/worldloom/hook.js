import {Renderer} from "./renderer.js"
import {laneFromClientY, withinLiveEdgeTarget} from "./placement.js"

export function selectedSequenceFromClick(event, element, renderer) {
  const bounds = element.getBoundingClientRect()
  const sequence = renderer.hitTest(event.clientX - bounds.left, event.clientY - bounds.top)

  if (sequence !== null) event.stopPropagation()
  return sequence
}

export function shouldClearSelectionFromClick(event, detail) {
  if (!detail || detail.contains(event.target)) return false
  return !event.target?.closest?.("#accessible-formations, [data-preserve-selection]")
}

export const Worldloom = {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    const reducedMotion = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false
    this.el.dataset.motion = reducedMotion ? "reduced" : "full"
    this.lastPointer = null
    this.listeners = []
    this.boundLaneInputs = new WeakSet()
    this.boundGestureButtons = new WeakSet()
    this.boundTimelineScaleButtons = new WeakSet()
    this.timelineGeneration = 0
    this.timelineDestroyed = false
    this.introductionDismissed = false
    this.placingLane = false
    this.placedLane = false
    this.activePointerId = null
    this.activePointerType = null
    this.activePointerCaptured = false
    this.pendingLane = null
    this.placementStartLane = null
    this.clickSuppressionTimer = null
    this.scheduleTimeout = (callback, delay) => globalThis.setTimeout(callback, delay)
    this.cancelTimeout = timer => globalThis.clearTimeout(timer)
    this.shareRequestGeneration = 0
    this.shareWriteQueue = Promise.resolve()
    this.shareDestroyed = false

    this.renderer = new Renderer(this.canvas, this.rendererOptions(reducedMotion))

    this.renderer.setScaffold(parseJson(this.el.dataset.scaffold, []))
    if (this.el.dataset.live === "true") {
      this.installInitialSnapshot()
    } else {
      this.renderer.setEvents(parseJson(this.el.dataset.instructions, []), {
        ambient: parseJson(this.el.dataset.ambient, null),
        scaffold: parseJson(this.el.dataset.scaffold, []),
      })
      if (this.el.dataset.anchorAt) this.renderer.setChapterAnchor(this.el.dataset.anchorAt)
    }
    this.laneInput = document.querySelector("#gesture-lane")
    this.localLane = normalizedLane(this.el.dataset.gestureLane, 0.5)
    this.lastServerLane = this.localLane
    this.renderer.setTargetLane(this.localLane)
    this.introduction = document.querySelector("#worldloom-introduction")
    this.shareStatus = document.querySelector("#share-status")
    this.lastSharePath = globalThis.location?.pathname ?? null
    this.lastSelectionPermalink = this.selectedPermalink()

    this.installListeners()
    this.installServerEvents()
    this.installResizeObserver()
    this.renderer.start()
    this.refreshTimelineControls()
    this.syncRenderedSequence()
    this.el.dataset.ready = "true"
  },

  rendererOptions(reducedMotion) {
    return {
      reducedMotion,
      liveMode: this.el.dataset.live === "true",
      scheduleTimeout: (callback, delay) => this.scheduleTimeout(callback, delay),
      cancelTimeout: timer => this.cancelTimeout(timer),
      onHistoryRequest: payload => this.pushEvent("history-before", payload),
      onTimelineRequest: payload => this.requestTimelineWindow(payload),
      onViewportChange: ({atLiveEdge}) =>
        this.pushEvent("viewport-state", {at_live_edge: atLiveEdge}),
      onSelect: sequence => {
        this.renderer.setSelection(sequence)
        this.pushEvent("select-formation", {sequence})
      },
      onReloadRequest: () => this.pushEvent("return-live", {}),
    }
  },

  installInitialSnapshot() {
    this.renderer.setSnapshot(snapshotFromDataset(this.el.dataset))
  },

  destroyed() {
    this.timelineDestroyed = true
    this.timelineGeneration = (this.timelineGeneration ?? 0) + 1
    this.shareDestroyed = true
    this.invalidateShareRequests()
    this.clearClickSuppression()
    this.resizeObserver?.disconnect()
    for (const [target, event, listener, options] of this.listeners) {
      target.removeEventListener(event, listener, options)
    }
    this.renderer?.destroy()
  },

  updated() {
    if (!this.renderer) return
    this.refreshIntroduction()
    this.bindExternalControls()
    this.reconcileShareFallback()
    if (this.placingLane && !this.directPlacementEnabled()) this.cancelPlacement()
    this.reconcileServerLane()
    this.refreshTimelineControls()
    this.syncRenderedSequence()
    this.el.dataset.ready = "true"
    this.el.dataset.motion = this.renderer.reducedMotion ? "reduced" : "full"
  },

  installServerEvents() {
    this.handleEvent("worldloom:snapshot", envelope => {
      this.renderer.setSnapshot(envelope)
      this.refreshTimelineControls()
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:history", payload => {
      this.renderer.prependHistory(payload.instructions ?? [], {
        archiveStart: payload["archive_start?"] ?? payload.archive_start ?? false,
        scaffold: payload.scaffold ?? [],
      })
      this.refreshTimelineControls()
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:reload", payload => {
      this.renderer.reload(payload.instructions ?? [], payload.watermark, {
        ambient: payload.ambient ?? null,
        scaffold: payload.scaffold ?? [],
      })
      if (payload.anchor_at) this.renderer.setChapterAnchor(payload.anchor_at)
      this.refreshTimelineControls()
      if (Number.isSafeInteger(payload.selected_sequence) && payload.selected_sequence > 0) {
        this.renderer.setSelection(payload.selected_sequence)
      } else {
        this.renderer.clearSelection()
      }
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:return-live", payload => {
      if (this.renderer.snapshotVersion !== 1) this.renderer.resetLiveScaffold()
      this.renderer.setSnapshot(payload)
      this.renderer.returnLive()
      this.renderer.clearSelection()
      this.refreshTimelineControls()
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:copy-link", ({url}) => this.copyLink(url))
    this.handleEvent("worldloom:presence", ({viewer_count: count}) =>
      this.renderer.setViewerCount(count),
    )
  },

  installListeners() {
    this.bindExternalControls()

    this.listen(this.el, "wheel", event => {
      this.dismissIntroduction()
      this.renderer.handleWheel(event)
    }, {passive: false})

    this.listen(this.el, "pointerdown", event => {
      this.dismissIntroduction()
      if (event.pointerType === "touch") return
      if (this.placingLane) return

      const bounds = this.el.getBoundingClientRect()
      if (withinLiveEdgeTarget(event.clientX, bounds) && this.directPlacementEnabled()) {
        this.beginPlacement(event, "pointer")
        return
      }
      this.renderer.pointerDown(event)
    })
    this.listen(this.el, "pointermove", event => {
      if (event.pointerType === "touch") return
      if (this.placingLane) {
        if (event.pointerId !== this.activePointerId) return
        this.placeLane(event)
        return
      }
      this.renderer.pointerMove(event)
    })
    this.listen(this.el, "pointerup", event => {
      if (event.pointerType === "touch") return
      if (this.placingLane) {
        if (event.pointerId !== this.activePointerId) return
        this.completePlacement(event)
        return
      }
      this.renderer.pointerUp()
    })
    this.listen(this.el, "pointercancel", event => {
      if (event.pointerType === "touch") return
      if (this.placingLane) {
        if (event.pointerId !== this.activePointerId) return
        this.cancelPlacement()
        return
      }
      this.renderer.pointerUp()
    })
    this.listen(this.el, "lostpointercapture", event => {
      if (!this.placingLane || event.pointerId !== this.activePointerId) return
      this.cancelPlacement({releasePointer: false})
    })

    this.listen(this.el, "touchstart", event => {
      this.dismissIntroduction()
      if (this.placingLane) {
        if (this.activePointerType === "touch" && event.touches?.length !== 1) {
          this.cancelPlacement()
        }
        return
      }
      if (event.touches?.length !== 1) return

      const touch = event.touches[0]
      const bounds = this.el.getBoundingClientRect()
      if (withinLiveEdgeTarget(touch.clientX, bounds) && this.directPlacementEnabled()) {
        this.beginPlacement(touch, "touch")
        return
      }
      this.renderer.touchStart(event)
    }, {passive: true})
    this.listen(this.el, "touchmove", event => {
      if (this.placingLane) {
        if (this.activePointerType !== "touch") return
        if (event.touches?.length === 1) {
          event.preventDefault()
          this.placeLane(event.touches[0])
          return
        }
      }
      this.renderer.touchMove(event)
    }, {passive: false})
    this.listen(this.el, "touchend", () => {
      if (this.placingLane && this.activePointerType === "touch") this.completePlacement()
      this.renderer.touchEnd()
    })
    this.listen(this.el, "touchcancel", () => {
      if (this.placingLane && this.activePointerType === "touch") this.cancelPlacement()
      this.renderer.touchEnd()
    })

    this.listen(this.el, "click", event => {
      if (this.placedLane) {
        this.clearClickSuppression()
        return
      }

      const sequence = selectedSequenceFromClick(event, this.el, this.renderer)
      if (sequence !== null) {
        this.renderer.setSelection(sequence)
        this.pushEvent("select-formation", {sequence})
      }
    })

    this.listen(globalThis.window, "click", event => {
      const detail = globalThis.document.querySelector("#signal-detail")
      if (shouldClearSelectionFromClick(event, detail)) this.clearSelection()
    })

    this.listen(this.el, "keydown", event => {
      if (["ArrowLeft", "ArrowUp"].includes(event.key)) {
        this.dismissIntroduction()
        event.preventDefault()
        this.renderer.selectNext(-1)
      } else if (["ArrowRight", "ArrowDown"].includes(event.key)) {
        this.dismissIntroduction()
        event.preventDefault()
        this.renderer.selectNext(1)
      } else if (event.key === "Enter") {
        this.dismissIntroduction()
        event.preventDefault()
        this.renderer.activateSelection()
      }
    })

    this.listen(globalThis.window, "keydown", event => {
      if (event.key === "Escape") this.renderer.clearSelection()
    })
  },

  bindExternalControls() {
    const laneInput = document.querySelector("#gesture-lane")
    this.laneInput = laneInput
    if (laneInput && !this.boundLaneInputs.has(laneInput)) {
      this.listen(laneInput, "input", event => this.handleLaneInput(event))
      this.boundLaneInputs.add(laneInput)
    }

    for (const button of document.querySelectorAll(".gesture-button")) {
      if (this.boundGestureButtons.has(button)) continue
      this.listen(button, "click", () => this.dismissIntroduction())
      this.boundGestureButtons.add(button)
    }

    for (const button of document.querySelectorAll(".timeline-scale-button")) {
      if (this.boundTimelineScaleButtons.has(button)) continue
      this.listen(button, "click", () => {
        const durationSeconds = Number(button.dataset.durationSeconds)
        if (this.renderer.setTimelineDuration(durationSeconds * 1000)) {
          this.dismissIntroduction()
          this.refreshTimelineControls()
          this.syncRenderedSequence()
        }
      })
      this.boundTimelineScaleButtons.add(button)
    }
  },

  requestTimelineWindow(payload) {
    const generation = this.timelineGeneration ?? 0
    this.pushEvent("timeline-window", payload, reply => {
      if (this.timelineDestroyed || generation !== this.timelineGeneration) return
      this.renderer.completeTimelineRequest(reply)
      this.refreshTimelineControls()
      this.syncRenderedSequence()
    })
  },

  refreshTimelineControls() {
    if (!this.renderer) return
    const duration = this.renderer.timelineDurationMilliseconds
    for (const button of document.querySelectorAll(".timeline-scale-button")) {
      const pressed = Number(button.dataset.durationSeconds) * 1000 === duration
      button.setAttribute("aria-pressed", String(pressed))
    }

    const range = document.querySelector("#timeline-range")
    const axis = this.renderer.timelineAxis?.()
    if (range) range.textContent = timelineRangeText(axis, duration)
  },

  handleLaneInput(event) {
    this.dismissIntroduction()
    const lane = normalizedLane(event.target.value, this.localLane)
    this.updateLocalLane(lane)
    this.lastServerLane = lane
    this.pendingLane = null
  },

  refreshIntroduction() {
    this.introduction = document.querySelector("#worldloom-introduction")
    if (this.introductionDismissed && this.introduction) {
      this.introduction.dataset.dismissed = "true"
    }
  },

  dismissIntroduction() {
    this.introductionDismissed = true
    this.refreshIntroduction()
  },

  announceShare(message) {
    const shareStatus = document.querySelector("#share-status")
    if (shareStatus) this.shareStatus = shareStatus
    if (this.shareStatus?.isConnected === false) this.shareStatus = null
    if (this.shareStatus) this.shareStatus.textContent = message
  },

  selectedPermalink() {
    return document.querySelector("#share-link")?.value ?? null
  },

  reconcileShareFallback() {
    const sharePath = globalThis.location?.pathname ?? null
    const selectionPermalink = this.selectedPermalink()
    const pathChanged = this.lastSharePath !== undefined && sharePath !== this.lastSharePath
    const selectionChanged = this.lastSelectionPermalink !== undefined &&
      selectionPermalink !== this.lastSelectionPermalink

    if (pathChanged || selectionChanged) {
      this.invalidateShareRequests()
      this.resetShareFallback()
    }
    this.lastSharePath = sharePath
    this.lastSelectionPermalink = selectionPermalink
  },

  invalidateShareRequests() {
    this.shareRequestGeneration = (this.shareRequestGeneration ?? 0) + 1
  },

  expectedSharePath() {
    const selectedPermalink = this.selectedPermalink()
    if (selectedPermalink) return this.sharePathFromUrl(selectedPermalink)
    return globalThis.location?.pathname ?? null
  },

  sharePathFromUrl(url) {
    if (typeof url !== "string" || url.trim() === "") return null

    try {
      const base = globalThis.location?.origin ?? "https://worldloom.invalid"
      return new URL(url, base).pathname
    } catch (_error) {
      return null
    }
  },

  currentShareRequest(generation, path) {
    return this.shareDestroyed !== true &&
      generation === this.shareRequestGeneration &&
      path === this.expectedSharePath()
  },

  resetShareFallback() {
    const fallbackField = document.querySelector("#share-fallback-field")
    const fallbackInput = document.querySelector("#share-fallback")
    const shareStatus = document.querySelector("#share-status")
    if (fallbackField) fallbackField.hidden = true
    if (fallbackInput) fallbackInput.value = ""
    if (shareStatus) shareStatus.textContent = ""
  },

  reconcileServerLane() {
    if (this.placingLane) return
    const lane = normalizedLane(
      this.el.dataset.gestureLane,
      this.lastServerLane ?? this.localLane ?? 0.5,
    )
    this.lastServerLane = lane
    this.updateLocalLane(lane)
  },

  directPlacementEnabled() {
    return this.el.dataset.live === "true" &&
      !this.laneInput?.disabled &&
      this.renderer.atLiveEdge()
  },

  beginPlacement(event, inputType) {
    this.clearClickSuppression()
    this.placingLane = true
    this.pendingLane = null
    this.placementStartLane = this.localLane
    this.activePointerId = inputType === "pointer" ? event.pointerId : null
    this.activePointerType = inputType === "pointer" ? event.pointerType : "touch"
    this.activePointerCaptured = false

    if (inputType === "pointer" && this.el.setPointerCapture) {
      try {
        this.el.setPointerCapture(event.pointerId)
        this.activePointerCaptured = this.el.hasPointerCapture?.(event.pointerId) ?? true
      } catch (_error) {
        this.activePointerCaptured = false
      }
    }

    this.placeLane(event)
  },

  placeLane(event) {
    const bounds = this.el.getBoundingClientRect()
    const lane = laneFromClientY(event.clientY, bounds)
    this.pendingLane = lane
    this.updateLocalLane(lane)
  },

  updateLocalLane(lane) {
    if (lane !== this.localLane) {
      this.localLane = lane
      this.renderer.setTargetLane(lane)
    }
    if (this.laneInput && this.laneInput.value !== String(lane)) {
      this.laneInput.value = String(lane)
    }
  },

  completePlacement(event) {
    if (!this.placingLane) return
    if (Number.isFinite(event?.clientY)) this.placeLane(event)

    const pointerId = this.activePointerId
    const pointerCaptured = this.activePointerCaptured
    const lane = this.pendingLane
    this.placingLane = false
    this.activePointerId = null
    this.activePointerType = null
    this.activePointerCaptured = false
    this.pendingLane = null
    this.placementStartLane = null

    this.releasePointer(pointerId, pointerCaptured)
    if (lane !== null && lane !== this.lastServerLane) {
      this.pushEvent("lane-change", {lane: String(lane)})
      this.lastServerLane = lane
    }
    this.armClickSuppression()
  },

  cancelPlacement({releasePointer = true} = {}) {
    if (!this.placingLane) return

    const pointerId = this.activePointerId
    const pointerCaptured = this.activePointerCaptured
    const placementStartLane = this.placementStartLane
    this.placingLane = false
    this.activePointerId = null
    this.activePointerType = null
    this.activePointerCaptured = false
    this.pendingLane = null
    this.placementStartLane = null
    this.clearClickSuppression()
    if (placementStartLane !== null) this.updateLocalLane(placementStartLane)
    if (releasePointer) this.releasePointer(pointerId, pointerCaptured)
  },

  releasePointer(pointerId, captured) {
    if (!captured || pointerId === null || !this.el.releasePointerCapture) return
    try {
      if (!this.el.hasPointerCapture || this.el.hasPointerCapture(pointerId)) {
        this.el.releasePointerCapture(pointerId)
      }
    } catch (_error) {
      // Pointer capture may already have been released by the browser.
    }
  },

  armClickSuppression() {
    this.clearClickSuppression()
    this.placedLane = true
    const schedule = this.scheduleTimeout ?? ((callback, delay) => globalThis.setTimeout(callback, delay))
    this.clickSuppressionTimer = schedule(() => {
      this.clickSuppressionTimer = null
      this.placedLane = false
    }, 250)
  },

  clearClickSuppression() {
    if (this.clickSuppressionTimer !== null && this.clickSuppressionTimer !== undefined) {
      const cancel = this.cancelTimeout ?? (timer => globalThis.clearTimeout(timer))
      cancel(this.clickSuppressionTimer)
    }
    this.clickSuppressionTimer = null
    this.placedLane = false
  },

  clearSelection() {
    this.renderer.clearSelection()
    this.pushEvent("clear-selection", {})
  },

  installResizeObserver() {
    const resize = () => {
      const bounds = this.el.getBoundingClientRect()
      this.renderer.resize(bounds.width, bounds.height, globalThis.devicePixelRatio ?? 1)
      this.syncRenderedSequence()
    }

    if (globalThis.ResizeObserver) {
      this.resizeObserver = new ResizeObserver(resize)
      this.resizeObserver.observe(this.el)
    }
    resize()
  },

  listen(target, event, listener, options) {
    target.addEventListener(event, listener, options)
    this.listeners.push([target, event, listener, options])
  },

  syncRenderedSequence() {
    this.el.dataset.renderedSequence = String(this.renderer.commitWatermark)
    this.el.dataset.commitWatermark = String(this.renderer.commitWatermark)
    if (this.renderer.snapshotVersion === null) {
      delete this.el.dataset.snapshotVersion
    } else {
      this.el.dataset.snapshotVersion = String(this.renderer.snapshotVersion)
    }
    if (this.renderer.windowEnd === null) {
      delete this.el.dataset.windowEnd
    } else {
      this.el.dataset.windowEnd = this.renderer.windowEnd
    }
    if (this.el.dataset.sceneDiagnosticsEnabled !== "true") {
      delete this.el.dataset.sceneDiagnostics
    } else {
      const sceneDiagnostics = this.renderer.settledSceneDiagnostics?.()
      if (sceneDiagnostics === undefined) {
        delete this.el.dataset.sceneDiagnostics
      } else {
        this.el.dataset.sceneDiagnostics = canonicalJson(sceneDiagnostics)
      }
    }
  },

  copyLink(url) {
    const requestedPath = this.sharePathFromUrl(url)
    if (
      this.shareDestroyed === true ||
      requestedPath === null ||
      requestedPath !== this.expectedSharePath()
    ) {
      return Promise.resolve(false)
    }

    this.shareRequestGeneration = (this.shareRequestGeneration ?? 0) + 1
    const generation = this.shareRequestGeneration
    this.lastSharePath = globalThis.location?.pathname ?? null
    this.lastSelectionPermalink = this.selectedPermalink()
    this.resetShareFallback()

    const writeLink = async () => {
      if (!this.currentShareRequest(generation, requestedPath)) return false

      try {
        const clipboard = globalThis.navigator?.clipboard
        if (!clipboard?.writeText) throw new Error("clipboard unavailable")
        if (!this.currentShareRequest(generation, requestedPath)) return false
        await clipboard.writeText(url)
        if (!this.currentShareRequest(generation, requestedPath)) return false

        const fallbackField = document.querySelector("#share-fallback-field")
        if (fallbackField) fallbackField.hidden = true
        this.announceShare("Link copied.")
        return true
      } catch (_error) {
        if (!this.currentShareRequest(generation, requestedPath)) return false

        const fallbackField = document.querySelector("#share-fallback-field")
        const fallbackInput = document.querySelector("#share-fallback")
        if (fallbackField && fallbackInput) {
          fallbackField.hidden = false
          fallbackInput.value = url
          fallbackInput.focus()
          fallbackInput.select()
          this.announceShare("Select and copy this permanent link.")
        } else {
          this.announceShare("Copy failed. Use the address bar to copy this link.")
        }
        return false
      }
    }

    const previousWrite = this.shareWriteQueue ?? Promise.resolve()
    const completion = previousWrite.catch(() => false).then(writeLink)
    this.shareWriteQueue = completion.catch(() => false)
    return completion
  },
}

export function snapshotFromDataset(dataset) {
  return {
    snapshot_version: Number(dataset.snapshotVersion),
    window_end: dataset.windowEnd || null,
    commit_watermark: Number(dataset.commitWatermark),
    display_events: parseJson(dataset.displayEvents, []),
    memory_events: parseJson(dataset.memoryEvents, []),
    ambient: parseJson(dataset.ambient, null),
  }
}

function parseJson(encoded, fallback) {
  if (!encoded) return fallback
  try {
    return JSON.parse(encoded)
  } catch (_error) {
    return fallback
  }
}

function normalizedLane(encoded, fallback) {
  const lane = Number(encoded)
  if (!Number.isFinite(lane)) return fallback
  return Math.min(1, Math.max(0, lane))
}

function timelineRangeText(axis, durationMilliseconds) {
  const minutes = Number(durationMilliseconds) / 60_000
  const durationLabel = minutes === 1 ? "1 minute" : `${minutes} minutes`
  if (!axis || !Number.isFinite(Date.parse(axis.start)) || !Number.isFinite(Date.parse(axis.end))) {
    return `${durationLabel} · UTC range unavailable`
  }

  return `${durationLabel} · ${utcHourMinute(axis.start)} UTC–${utcHourMinute(axis.end)} UTC`
}

function utcHourMinute(timestamp) {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).format(new Date(timestamp))
}

function canonicalJson(value) {
  return JSON.stringify(canonicalValue(value))
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue)
  if (value === null || typeof value !== "object") return value

  return Object.keys(value).sort().reduce((canonical, key) => {
    canonical[key] = canonicalValue(value[key])
    return canonical
  }, {})
}
