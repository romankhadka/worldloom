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
  return !event.target?.closest?.("#accessible-formations")
}

export const Worldloom = {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    const reducedMotion = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false
    this.el.dataset.motion = reducedMotion ? "reduced" : "full"
    this.lastPointer = null
    this.listeners = []

    this.renderer = new Renderer(this.canvas, {
      reducedMotion,
      onGap: ({after, through}) => this.pushEvent("sequence-gap", {after, through}),
      onHistoryRequest: () => this.pushEvent("history-before", {}),
      onViewportChange: ({atLiveEdge}) =>
        this.pushEvent("viewport-state", {at_live_edge: atLiveEdge}),
      onSelect: sequence => {
        this.renderer.setSelection(sequence)
        this.pushEvent("select-formation", {sequence})
      },
      onReloadRequest: () => this.pushEvent("return-live", {}),
    })

    this.renderer.setEvents(parseJson(this.el.dataset.instructions, []), {
      ambient: parseJson(this.el.dataset.ambient, null),
    })
    this.laneInput = document.querySelector("#gesture-lane")
    this.renderer.setTargetLane(Number(this.el.dataset.gestureLane ?? 0.5))
    this.placingLane = false
    this.placedLane = false
    this.introduction = document.querySelector("#worldloom-introduction")
    this.shareStatus = document.querySelector("#share-status")
    this.dismissIntroduction = () => {
      if (!this.introduction?.isConnected) {
        this.introduction = document.querySelector("#worldloom-introduction")
      }
      if (this.introduction) this.introduction.dataset.dismissed = "true"
    }
    this.announceShare = message => {
      if (!this.shareStatus?.isConnected) this.shareStatus = document.querySelector("#share-status")
      if (this.shareStatus) this.shareStatus.textContent = message
    }

    this.installListeners()
    this.installServerEvents()
    this.installResizeObserver()
    this.renderer.start()
    this.syncRenderedSequence()
    this.el.dataset.ready = "true"
  },

  destroyed() {
    this.resizeObserver?.disconnect()
    for (const [target, event, listener, options] of this.listeners) {
      target.removeEventListener(event, listener, options)
    }
    this.renderer?.destroy()
  },

  updated() {
    if (!this.renderer) return
    this.syncRenderedSequence()
    this.el.dataset.ready = "true"
    this.el.dataset.motion = this.renderer.reducedMotion ? "reduced" : "full"
  },

  installServerEvents() {
    this.handleEvent("worldloom:event", instruction => {
      this.renderer.receiveEvent(instruction)
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:catch-up", payload => {
      this.renderer.applyCatchUp(payload.instructions ?? [], payload.watermark)
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:history", payload => {
      this.renderer.prependHistory(payload.instructions ?? [], {
        archiveStart: payload["archive_start?"] ?? payload.archive_start ?? false,
      })
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:reload", payload => {
      this.renderer.reload(payload.instructions ?? [], payload.watermark)
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:return-live", payload => {
      if (payload?.instructions) this.renderer.reload(payload.instructions, payload.watermark)
      this.renderer.returnLive()
      this.syncRenderedSequence()
    })

    this.handleEvent("worldloom:copy-link", ({url}) => this.copyLink(url))
    this.handleEvent("worldloom:presence", ({viewer_count: count}) =>
      this.renderer.setViewerCount(count),
    )
  },

  installListeners() {
    const placeLane = event => {
      const bounds = this.el.getBoundingClientRect()
      const lane = laneFromClientY(event.clientY, bounds)
      this.renderer.setTargetLane(lane)
      if (!this.laneInput?.isConnected) this.laneInput = document.querySelector("#gesture-lane")
      if (this.laneInput) this.laneInput.value = String(lane)
      this.pushEvent("lane-change", {lane: String(lane)})
      this.placedLane = true
    }

    if (this.laneInput) {
      this.listen(this.laneInput, "input", event => {
        this.dismissIntroduction()
        this.renderer.setTargetLane(Number(event.target.value))
      })
    }

    this.listen(this.el, "wheel", event => {
      this.dismissIntroduction()
      this.renderer.handleWheel(event)
    }, {passive: false})

    this.listen(this.el, "pointerdown", event => {
      this.dismissIntroduction()
      if (event.pointerType === "touch") return

      const bounds = this.el.getBoundingClientRect()
      if (withinLiveEdgeTarget(event.clientX, bounds) && this.renderer.atLiveEdge()) {
        this.placingLane = true
        placeLane(event)
        return
      }
      this.renderer.pointerDown(event)
    })
    this.listen(this.el, "pointermove", event => {
      if (event.pointerType === "touch") return
      if (this.placingLane) {
        placeLane(event)
        return
      }
      this.renderer.pointerMove(event)
    })
    this.listen(this.el, "pointerup", event => {
      if (event.pointerType === "touch") return
      this.placingLane = false
      this.renderer.pointerUp()
    })
    this.listen(this.el, "pointercancel", event => {
      if (event.pointerType === "touch") return
      this.placingLane = false
      this.renderer.pointerUp()
    })

    this.listen(this.el, "touchstart", event => {
      this.dismissIntroduction()
      if (event.touches?.length !== 1) return

      const touch = event.touches[0]
      const bounds = this.el.getBoundingClientRect()
      if (withinLiveEdgeTarget(touch.clientX, bounds) && this.renderer.atLiveEdge()) {
        this.placingLane = true
        placeLane(touch)
        return
      }
      this.renderer.touchStart(event)
    }, {passive: true})
    this.listen(this.el, "touchmove", event => {
      if (this.placingLane && event.touches?.length === 1) {
        event.preventDefault()
        placeLane(event.touches[0])
        return
      }
      this.renderer.touchMove(event)
    }, {passive: false})
    this.listen(this.el, "touchend", () => {
      this.placingLane = false
      this.renderer.touchEnd()
    })
    this.listen(this.el, "touchcancel", () => {
      this.placingLane = false
      this.renderer.touchEnd()
    })

    this.listen(this.el, "click", event => {
      if (this.placedLane) {
        this.placedLane = false
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
      if (shouldClearSelectionFromClick(event, detail)) this.pushEvent("clear-selection", {})
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

    for (const button of document.querySelectorAll(".gesture-button")) {
      this.listen(button, "click", this.dismissIntroduction)
    }
  },

  installResizeObserver() {
    const resize = () => {
      const bounds = this.el.getBoundingClientRect()
      this.renderer.resize(bounds.width, bounds.height, globalThis.devicePixelRatio ?? 1)
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
    this.el.dataset.renderedSequence = String(this.renderer.watermark)
  },

  async copyLink(url) {
    try {
      if (!globalThis.navigator?.clipboard?.writeText) throw new Error("clipboard unavailable")
      await globalThis.navigator.clipboard.writeText(url)
      this.announceShare("Link copied.")
    } catch (_error) {
      const input = document.querySelector("#share-link")
      if (input) {
        input.value = url
        input.focus()
        input.select()
      }
      this.announceShare("Select and copy this permanent link.")
    }
  },
}

function parseJson(encoded, fallback) {
  if (!encoded) return fallback
  try {
    return JSON.parse(encoded)
  } catch (_error) {
    return fallback
  }
}
