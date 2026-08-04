import {Renderer} from "./renderer.js"

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
      onSelect: sequence => this.pushEvent("select-formation", {sequence}),
      onReloadRequest: () => this.pushEvent("return-live", {}),
    })

    this.renderer.setEvents(parseJson(this.el.dataset.instructions, []), {
      ambient: parseJson(this.el.dataset.ambient, null),
    })

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
    this.listen(this.el, "wheel", event => this.renderer.handleWheel(event), {passive: false})
    this.listen(this.el, "pointerdown", event => this.renderer.pointerDown(event))
    this.listen(this.el, "pointermove", event => this.renderer.pointerMove(event))
    this.listen(this.el, "pointerup", () => this.renderer.pointerUp())
    this.listen(this.el, "pointercancel", () => this.renderer.pointerUp())
    this.listen(this.el, "touchstart", event => this.renderer.touchStart(event), {passive: true})
    this.listen(this.el, "touchmove", event => this.renderer.touchMove(event), {passive: false})
    this.listen(this.el, "touchend", () => this.renderer.touchEnd())

    this.listen(this.el, "click", event => {
      const bounds = this.el.getBoundingClientRect()
      const sequence = this.renderer.hitTest(event.clientX - bounds.left, event.clientY - bounds.top)
      if (sequence !== null) this.pushEvent("select-formation", {sequence})
    })

    this.listen(this.el, "keydown", event => {
      if (["ArrowLeft", "ArrowUp"].includes(event.key)) {
        event.preventDefault()
        this.renderer.selectNext(-1)
      } else if (["ArrowRight", "ArrowDown"].includes(event.key)) {
        event.preventDefault()
        this.renderer.selectNext(1)
      } else if (event.key === "Enter") {
        event.preventDefault()
        this.renderer.activateSelection()
      }
    })
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
      await navigator.clipboard.writeText(url)
    } catch (_error) {
      const input = document.querySelector("#share-link")
      if (input) {
        input.value = url
        input.focus()
        input.select()
      }
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
