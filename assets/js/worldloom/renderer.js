import {commandsForScene, cubicPrefix, laneToY} from "./geometry.js"
import {canvasPalette} from "./palette.js"
import {xorshift32} from "./random.js"

const maximumEvents = 600
const maximumMemoryEvents = 4
const maximumCommands = 4000
const maximumViewerPulses = 12
const maximumActiveTransitions = 8
const maximumScaffoldEvents = 12
const defaultSpacing = 28
const supportedTimelineDurations = new Set([60_000, 300_000, 900_000])
const animatedKinds = new Set(["wikimedia", "earthquake", "tug", "knot", "illuminate"])
const sourceMaterialRoles = new Set([
  "conversation-fan",
  "route-fork",
  "slot-braid",
  "public-pulse",
])

export class Renderer {
  constructor(canvas, options = {}) {
    this.canvas = canvas
    this.context = canvas?.getContext?.("2d") ?? null
    this.width = options.width ?? 1
    this.height = options.height ?? 1
    this.dpr = options.dpr ?? 1
    this.spacing = options.spacing ?? defaultSpacing
    this.padding = options.padding ?? 40
    this.reducedMotion = options.reducedMotion ?? false
    this.projectScene = options.projectScene ?? commandsForScene
    this.createCanvas = options.createCanvas ?? (() => globalThis.document?.createElement?.("canvas") ?? null)
    this.requestFrame = options.requestFrame ?? (callback => globalThis.requestAnimationFrame(callback))
    this.cancelFrame = options.cancelFrame ?? (handle => globalThis.cancelAnimationFrame(handle))
    this.onHistoryRequest = options.onHistoryRequest ?? (() => {})
    this.onViewportChange = options.onViewportChange ?? (() => {})
    this.onSelect = options.onSelect ?? (() => {})
    this.onReloadRequest = options.onReloadRequest ?? (() => {})
    this.onTimelineRequest = options.onTimelineRequest ?? (() => {})
    this.scheduleTimeout = options.scheduleTimeout ?? ((callback, delay) =>
      globalThis.setTimeout(callback, delay))
    this.cancelTimeout = options.cancelTimeout ?? (timer => globalThis.clearTimeout(timer))
    this.events = []
    this.instructions = []
    this.memoryInstructions = []
    this.historyInstructions = []
    this.scaffold = []
    this.liveScaffold = []
    this.commands = []
    this.ambient = null
    this.panOffset = 0
    this.projectedPanOffset = 0
    this.watermark = 0
    this.commitWatermark = 0
    this.snapshotVersion = null
    this.windowEnd = null
    this.liveMode = options.liveMode ?? true
    this.timelineDurationMilliseconds = 60_000
    this.viewLagMilliseconds = 0
    this.chapterAnchorMilliseconds = null
    this.timelineRequestInFlight = null
    this.latestTimelineIntent = null
    this.timelineRetryTimer = null
    this.archiveStartMilliseconds = null
    this.historyInFlight = false
    this.archiveStart = false
    this.newerEventsDropped = false
    this.pointerX = null
    this.touchX = null
    this.pendingSelectionSequence = null
    this.targetLane = 0.5
    this.selectedSequence = null
    this.viewerPulses = 0
    this.animationTime = 0
    this.frameHandle = null
    this.activeTransitions = new Map()
    this.cacheCanvas = this.createCanvas()
    this.cacheContext = this.cacheCanvas?.getContext?.("2d") ?? null
    this.cacheDirty = true
    this.lastLiveEdge = true
    this.returningToLive = false
    this.resize(this.width, this.height, this.dpr)
  }

  setEvents(instructions, {ambient = this.ambient, scaffold = []} = {}) {
    this.instructions = boundedInstructions(instructions, "newest")
    this.memoryInstructions = []
    this.historyInstructions = []
    this.events = this.instructions
    this.liveScaffold = scaffoldInstructions([...scaffold, ...this.events])
    this.scaffold = this.liveScaffold
    this.ambient = latestAmbientInstruction([ambient, ...this.events])
    this.watermark = this.events.at(-1)?.sequence ?? 0
    this.commitWatermark = this.watermark
    this.snapshotVersion = null
    this.windowEnd = null
    this.activeTransitions.clear()
    this.rebuild()
  }

  setScaffold(instructions) {
    this.liveScaffold = scaffoldInstructions(instructions)
    this.scaffold = this.liveScaffold
  }

  resetLiveScaffold() {
    this.liveScaffold = []
  }

  setSnapshot(envelope) {
    const snapshot = validatedSnapshot(envelope)
    const historicalCenter = this.viewLagMilliseconds > 1
      ? this.timelineAxis()?.centerMilliseconds ?? null
      : null
    const instructions = snapshot.displayEvents.slice(0, maximumEvents)
    const memoryInstructions = snapshot.memoryEvents.slice(0, maximumMemoryEvents)
    const events = this.atLiveEdge()
      ? instructions
      : boundedInstructions([...this.historyInstructions, ...instructions], "oldest")
    const animateNewEvents =
      this.snapshotVersion === 1 && this.atLiveEdge() && !this.reducedMotion
    const activeTransitions = animateNewEvents
      ? new Map(this.activeTransitions)
      : new Map()
    const previousSequences = new Set(this.instructions.map(instruction => instruction.sequence))
    if (animateNewEvents) {
      for (const instruction of instructions) {
        if (previousSequences.has(instruction.sequence) || !animatedKinds.has(instruction.kind)) {
          continue
        }
        activeTransitions.set(instruction.sequence, {
          sequence: instruction.sequence,
          startedAt: this.animationTime,
        })
      }
      while (activeTransitions.size > maximumActiveTransitions) {
        activeTransitions.delete(activeTransitions.keys().next().value)
      }
    }
    const authorizedSequences = new Set(
      [...events, ...memoryInstructions].map(instruction => instruction.sequence),
    )
    const selectedSequence = authorizedSequences.has(this.selectedSequence)
      ? this.selectedSequence
      : null
    const liveScaffold = scaffoldInstructions([...this.liveScaffold, ...instructions])
    const scaffold = this.atLiveEdge() ? liveScaffold : this.scaffold

    this.instructions = instructions
    this.memoryInstructions = memoryInstructions
    this.events = events
    this.liveScaffold = liveScaffold
    this.scaffold = scaffold
    this.ambient = snapshot.ambient
    this.commitWatermark = snapshot.commitWatermark
    this.watermark = snapshot.commitWatermark
    this.snapshotVersion = snapshot.snapshotVersion
    this.windowEnd = snapshot.windowEnd
    if (historicalCenter !== null) {
      this.viewLagMilliseconds = this.lagForCenter(historicalCenter)
    }
    this.selectedSequence = selectedSequence
    this.activeTransitions = activeTransitions
    this.newerEventsDropped = false
    this.rebuild()
  }

  setTimelineDuration(durationMilliseconds) {
    const duration = Number(durationMilliseconds)
    if (!supportedTimelineDurations.has(duration)) return false
    if (duration === this.timelineDurationMilliseconds) return true

    const wasAtLiveEdge = this.atLiveEdge()
    const previousDuration = this.timelineDurationMilliseconds
    if (this.liveMode && !wasAtLiveEdge) {
      this.viewLagMilliseconds += (previousDuration - duration) / 2
    }
    this.timelineDurationMilliseconds = duration
    this.viewLagMilliseconds = this.clampViewLag(this.viewLagMilliseconds)
    this.activeTransitions.clear()
    this.rebuild()
    this.notifyViewport()
    this.requestTimelineWindow()
    return true
  }

  timelineAxis() {
    const canonicalEnd = Date.parse(this.windowEnd)
    const durationMilliseconds = this.timelineDurationMilliseconds
    let endMilliseconds

    if (this.liveMode && Number.isFinite(canonicalEnd)) {
      endMilliseconds = canonicalEnd - this.viewLagMilliseconds
    } else if (!this.liveMode && Number.isFinite(this.chapterAnchorMilliseconds)) {
      const centerMilliseconds = this.chapterAnchorMilliseconds - this.viewLagMilliseconds
      endMilliseconds = centerMilliseconds + durationMilliseconds / 2
    } else {
      return null
    }

    return {
      start: new Date(endMilliseconds - durationMilliseconds).toISOString(),
      end: this.liveMode && this.viewLagMilliseconds <= 1
        ? this.windowEnd
        : new Date(endMilliseconds).toISOString(),
      durationMilliseconds,
      durationSeconds: durationMilliseconds / 1000,
      centerMilliseconds: endMilliseconds - durationMilliseconds / 2,
    }
  }

  setChapterAnchor(anchorAt) {
    if (!validUtcTimestamp(anchorAt)) return false
    this.liveMode = false
    this.chapterAnchorMilliseconds = Date.parse(anchorAt)
    this.viewLagMilliseconds = 0
    this.rebuild()
    this.requestTimelineWindow()
    return true
  }

  setTimelineWindow(payload) {
    const timelineWindow = validatedTimelineWindow(payload)
    this.instructions = timelineWindow.instructions.slice(0, maximumEvents)
    this.historyInstructions = []
    this.events = this.instructions
    this.scaffold = scaffoldInstructions([
      ...timelineWindow.scaffold,
      ...this.instructions,
    ])
    if (this.liveMode && timelineWindow.endAt !== null) this.windowEnd = timelineWindow.endAt
    this.ambient = timelineWindow.ambient
    this.archiveStartMilliseconds = timelineWindow.archiveStartAt === null
      ? null
      : Date.parse(timelineWindow.archiveStartAt)
    this.archiveStart = this.archiveStartMilliseconds !== null &&
      Date.parse(timelineWindow.startAt) <= this.archiveStartMilliseconds
    this.viewLagMilliseconds = this.clampViewLag(this.viewLagMilliseconds)
    this.activeTransitions.clear()
    this.rebuild()
    this.notifyViewport()
    return true
  }

  completeTimelineRequest(reply) {
    const completedIntent = this.timelineRequestInFlight
    if (completedIntent === null || !reply || typeof reply !== "object") return false

    if (reply.status === "throttled") {
      const retryAfterMilliseconds = Math.max(1, Math.min(500, Number(reply.retry_after_ms) || 1))
      this.timelineRequestInFlight = null
      if (this.timelineRetryTimer !== null) this.cancelTimeout(this.timelineRetryTimer)
      this.timelineRetryTimer = this.scheduleTimeout(() => {
        this.timelineRetryTimer = null
        this.dispatchLatestTimelineIntent()
      }, retryAfterMilliseconds)
      return true
    }

    this.timelineRequestInFlight = null
    const latestIntent = this.latestTimelineIntent
    if (reply.status === "accepted" && latestIntent?.key === completedIntent.key) {
      this.setTimelineWindow(reply)
    }
    if (latestIntent !== null && latestIntent.key !== completedIntent.key) {
      this.dispatchLatestTimelineIntent()
    }
    return reply.status === "accepted" || reply.status === "invalid"
  }

  setTargetLane(lane) {
    this.targetLane = Math.min(1, Math.max(0, Number(lane) || 0))
    this.draw()
  }

  setSelection(sequence) {
    this.selectedSequence = Number.isSafeInteger(sequence) ? sequence : null
    this.draw()
  }

  clearSelection() {
    this.selectedSequence = null
    this.draw()
  }

  resize(width, height, dpr = this.dpr) {
    this.activeTransitions.clear()
    this.width = Math.max(1, width)
    this.height = Math.max(1, height)
    this.dpr = Math.max(1, dpr)

    if (this.canvas) {
      this.canvas.width = Math.round(this.width * this.dpr)
      this.canvas.height = Math.round(this.height * this.dpr)
      this.canvas.style.width = `${this.width}px`
      this.canvas.style.height = `${this.height}px`
    }

    if (this.cacheCanvas) {
      this.cacheCanvas.width = Math.round(this.width * this.dpr)
      this.cacheCanvas.height = Math.round(this.height * this.dpr)
    }

    this.rebuild()
  }

  rebuild() {
    const viewport = this.viewport()
    const axis = this.timelineAxis()
    const sceneEvents = this.timelineDurationMilliseconds > 60_000
      ? timelineLevelOfDetail(
          this.events,
          timelineLevelOfDetailCapacity(this.width, this.padding),
          this.selectedSequence,
        )
      : this.events
    const eventSequences = new Set(sceneEvents.map(instruction => instruction.sequence))
    const scaffoldOnly = this.scaffold.filter(
      instruction => !eventSequences.has(instruction.sequence),
    )
    const topologyCapacity = maximumEvents - scaffoldOnly.length
    const topologyInstructions = [
      ...scaffoldOnly,
      ...sceneEvents.slice(-topologyCapacity),
    ]
    this.commands = this.projectScene(topologyInstructions, viewport, {
      axis,
      displayInstructions: this.instructions.filter(instruction =>
        eventSequences.has(instruction.sequence)
      ),
      memoryInstructions: this.memoryInstructions,
      ambient: this.ambient,
      historyInstructions: this.historyInstructions.filter(instruction =>
        eventSequences.has(instruction.sequence)
      ),
      scaffoldInstructions: scaffoldOnly,
      projectionInstructions: [...scaffoldOnly, ...sceneEvents],
      hitInstructions: sceneEvents,
    }).slice(-maximumCommands)
    this.reconcilePendingSelection()
    const availableTransitions = transitionSequences(this.commands)
    for (const sequence of this.activeTransitions.keys()) {
      if (!availableTransitions.has(sequence)) this.activeTransitions.delete(sequence)
    }
    this.projectedPanOffset = this.panOffset
    this.cacheDirty = true
    this.rebuildCache()
    this.draw()
  }

  reload(instructions, watermark = null, {ambient = this.ambient, scaffold = []} = {}) {
    this.panOffset = 0
    this.viewLagMilliseconds = 0
    this.returningToLive = false
    this.setEvents(instructions, {ambient, scaffold})
    if (Number.isSafeInteger(watermark)) {
      this.watermark = watermark
      this.commitWatermark = watermark
    }
    this.newerEventsDropped = false
    this.notifyViewport()
  }

  prependHistory(instructions, {archiveStart = false, scaffold = []} = {}) {
    this.activeTransitions.clear()
    this.historyInstructions = boundedInstructions(
      [...instructions, ...this.historyInstructions],
      "oldest",
    )
    const combined = [...this.historyInstructions, ...this.instructions]
    const preference = this.atLiveEdge() ? "newest" : "oldest"
    this.newerEventsDropped = preference === "oldest" && uniqueCount(combined) > maximumEvents
    this.events = boundedInstructions(combined, preference)
    this.scaffold = scaffoldInstructions([...scaffold, ...this.events])
    this.archiveStart = Boolean(archiveStart)
    this.historyInFlight = false
    this.rebuild()
  }

  panBy(delta) {
    this.activeTransitions.clear()
    const axis = this.timelineAxis()
    if (axis !== null) {
      const usableWidth = Math.max(1, this.width - this.padding * 2)
      const elapsedMilliseconds = Number(delta) *
        this.timelineDurationMilliseconds / usableWidth
      this.viewLagMilliseconds = this.clampViewLag(
        this.viewLagMilliseconds + elapsedMilliseconds,
      )
      this.rebuild()
      this.notifyViewport()
      this.requestTimelineWindow()
      return
    }

    const hitPositions = this.commands
      .filter(command => command.type === "anchor-hit" && Number.isFinite(command.x))
      .map(command => command.x)
    const maximumPan = hitPositions.length >= 2
      ? Math.max(...hitPositions) - Math.min(...hitPositions)
      : Math.max(0, (this.events.length - 1) * this.spacing)
    this.panOffset = Math.min(maximumPan, Math.max(0, this.panOffset + delta))
    this.rebuild()
    this.notifyViewport()
    this.maybeRequestHistory()
  }

  handleWheel(event) {
    event.preventDefault?.()
    const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? -event.deltaX : -event.deltaY
    this.panBy(delta)
  }

  pointerDown(event) {
    this.pointerX = event.clientX
  }

  pointerMove(event) {
    if (this.pointerX === null) return
    const delta = event.clientX - this.pointerX
    this.pointerX = event.clientX
    this.panBy(delta)
  }

  pointerUp() {
    this.pointerX = null
  }

  touchStart(event) {
    this.touchX = event.touches?.length === 1 ? event.touches[0].clientX : null
  }

  touchMove(event) {
    if (this.touchX === null || event.touches?.length !== 1) return
    event.preventDefault?.()
    const nextX = event.touches[0].clientX
    this.panBy(nextX - this.touchX)
    this.touchX = nextX
  }

  touchEnd() {
    this.touchX = null
  }

  maybeRequestHistory() {
    if (this.historyInFlight || this.archiveStart || this.events.length === 0) return

    const oldest = this.events[0]
    const oldestX = this.commands.find(command => command.sequence === oldest.sequence)?.x
    if (oldestX !== undefined && oldestX >= this.padding * 2.4) {
      this.historyInFlight = true
      this.onHistoryRequest({before: oldest.sequence})
    }
  }

  requestTimelineWindow() {
    const axis = this.timelineAxis()
    if (axis === null || this.timelineAtArchiveStart(axis)) return false

    const intent = {
      end_at: axis.end,
      duration_seconds: axis.durationSeconds,
    }
    intent.key = `${intent.end_at}\0${intent.duration_seconds}`
    this.latestTimelineIntent = intent
    this.dispatchLatestTimelineIntent()
    return true
  }

  dispatchLatestTimelineIntent() {
    if (this.timelineRequestInFlight !== null || this.latestTimelineIntent === null) return
    this.timelineRequestInFlight = this.latestTimelineIntent
    const {end_at, duration_seconds} = this.timelineRequestInFlight
    this.onTimelineRequest({end_at, duration_seconds})
  }

  returnLive() {
    if (this.newerEventsDropped) this.onReloadRequest()
    const hadTransitions = this.activeTransitions.size > 0
    const showingHistory = this.events !== this.instructions
    this.activeTransitions.clear()
    if (showingHistory) {
      this.events = this.instructions
      this.scaffold = this.liveScaffold
      this.newerEventsDropped = false
    }
    this.historyInstructions = []
    this.historyInFlight = false
    this.archiveStart = false
    this.archiveStartMilliseconds = null
    const liveSequences = new Set(
      [...this.instructions, ...this.memoryInstructions].map(instruction => instruction.sequence),
    )
    if (!liveSequences.has(this.selectedSequence)) this.selectedSequence = null
    if (hadTransitions) this.rebuildCache()

    if (this.reducedMotion) {
      this.panOffset = 0
      this.viewLagMilliseconds = 0
      this.rebuild()
      this.notifyViewport()
      if (this.timelineDurationMilliseconds > 60_000) this.requestTimelineWindow()
    } else {
      if (showingHistory) this.rebuild()
      this.returningToLive = true
    }
  }

  atLiveEdge() {
    return this.panOffset <= 1 && this.viewLagMilliseconds <= 1
  }

  lagForCenter(centerMilliseconds) {
    const canonicalEnd = Date.parse(this.windowEnd)
    if (!Number.isFinite(canonicalEnd)) return this.viewLagMilliseconds
    return this.clampViewLag(
      canonicalEnd - centerMilliseconds - this.timelineDurationMilliseconds / 2,
    )
  }

  clampViewLag(lagMilliseconds) {
    const lag = Math.max(0, Number(lagMilliseconds) || 0)
    if (this.archiveStartMilliseconds === null || !this.liveMode) return lag
    const canonicalEnd = Date.parse(this.windowEnd)
    if (!Number.isFinite(canonicalEnd)) return lag
    const maximumLag = Math.max(
      0,
      canonicalEnd - this.timelineDurationMilliseconds - this.archiveStartMilliseconds,
    )
    return Math.min(lag, maximumLag)
  }

  timelineAtArchiveStart(axis = this.timelineAxis()) {
    return axis !== null && this.archiveStartMilliseconds !== null &&
      Date.parse(axis.start) <= this.archiveStartMilliseconds
  }

  hitTest(x, y) {
    const sceneX = x - this.viewTranslationX()
    const candidates = selectableCommands(this.commands).filter(item => {
      const hit = item.hit
      return hit && sceneX >= hit.x && sceneX <= hit.x + hit.width && y >= hit.y && y <= hit.y + hit.height
    })
    const nearest = candidates.reduce((closest, command) => {
      const centerX = Number.isFinite(command.x) ? command.x : command.hit.x + command.hit.width / 2
      const centerY = Number.isFinite(command.y) ? command.y : command.hit.y + command.hit.height / 2
      const distance = (sceneX - centerX) ** 2 + (y - centerY) ** 2
      if (!closest || distance < closest.distance - 1e-9) return {command, distance}
      if (Math.abs(distance - closest.distance) <= 1e-9 && command.sequence > closest.command.sequence) {
        return {command, distance}
      }
      return closest
    }, null)
    return nearest?.command.sequence ?? null
  }

  selectNext(direction) {
    const sequences = [...new Set(selectableCommands(this.commands).map(item => item.sequence))]
    if (sequences.length === 0) {
      this.pendingSelectionSequence = null
      return null
    }

    const step = direction < 0 ? -1 : 1
    const currentIndex = sequences.indexOf(this.pendingSelectionSequence)
    const nextIndex = currentIndex === -1
      ? (step === 1 ? 0 : sequences.length - 1)
      : (currentIndex + step + sequences.length) % sequences.length
    this.pendingSelectionSequence = sequences[nextIndex]
    return this.pendingSelectionSequence
  }

  activateSelection() {
    const sequences = [...new Set(selectableCommands(this.commands).map(item => item.sequence))]
    if (sequences.includes(this.pendingSelectionSequence)) {
      this.onSelect(this.pendingSelectionSequence)
    }
  }

  reconcilePendingSelection() {
    if (this.pendingSelectionSequence === null) return

    const selectableSequences = new Set(
      selectableCommands(this.commands).map(command => command.sequence),
    )
    if (!selectableSequences.has(this.pendingSelectionSequence)) {
      this.pendingSelectionSequence = null
    }
  }

  setViewerCount(viewerCount) {
    this.viewerPulses = this.reducedMotion
      ? 0
      : Math.min(maximumViewerPulses, Math.max(0, Number(viewerCount) || 0))
  }

  start() {
    if (this.reducedMotion || this.frameHandle !== null) {
      this.draw()
      return
    }

    this.frameHandle = this.requestFrame(timestamp => this.tick(timestamp))
  }

  step(timestamp) {
    this.animationTime = timestamp
    this.completeTransitions(timestamp)

    if (this.returningToLive) {
      this.panOffset *= 0.68
      this.viewLagMilliseconds *= 0.68
      if (this.panOffset <= 1 && this.viewLagMilliseconds <= 1) {
        this.panOffset = 0
        this.viewLagMilliseconds = 0
        this.returningToLive = false
        this.rebuild()
        this.notifyViewport()
        if (this.timelineDurationMilliseconds > 60_000) this.requestTimelineWindow()
      }
    }

    this.draw()
  }

  tick(timestamp) {
    this.frameHandle = null
    this.step(timestamp)
    this.start()
  }

  destroy() {
    if (this.frameHandle !== null) this.cancelFrame(this.frameHandle)
    if (this.timelineRetryTimer !== null) this.cancelTimeout(this.timelineRetryTimer)
    this.frameHandle = null
    this.timelineRetryTimer = null
    this.activeTransitions.clear()
    this.instructions = []
    this.memoryInstructions = []
    this.historyInstructions = []
    this.scaffold = []
    this.liveScaffold = []
    this.pendingSelectionSequence = null
    this.cacheCanvas = null
    this.cacheContext = null
  }

  viewport() {
    return {
      width: this.width,
      height: this.height,
      maxSequence: this.events.at(-1)?.sequence ?? this.watermark,
      spacing: this.spacing,
      padding: this.padding,
      panOffset: this.timelineAxis() === null ? this.panOffset : 0,
    }
  }

  settledSceneDiagnostics() {
    const noActiveTransitions = new Map()
    const timelineAxis = this.timelineAxis()
    const axis = timelineAxis === null ? null : {
      start: timelineAxis.start,
      end: timelineAxis.end,
      durationSeconds: timelineAxis.durationSeconds,
    }

    return {
      snapshotVersion: this.snapshotVersion,
      commitWatermark: this.commitWatermark,
      axis,
      viewport: {
        width: this.width,
        height: this.height,
        dpr: this.dpr,
        padding: this.padding,
        spacing: this.spacing,
      },
      displaySequences: this.instructions.map(instruction => instruction.sequence),
      memorySequences: this.memoryInstructions.map(instruction => instruction.sequence),
      ambientSequence: this.ambient?.sequence ?? null,
      paintCommands: this.commands
        .map(command => settledCommand(command, noActiveTransitions))
        .filter(command => command !== null),
    }
  }

  viewTranslationX() {
    if (this.timelineAxis() !== null) return 0
    return this.panOffset - this.projectedPanOffset
  }

  draw() {
    if (!this.context) return
    const context = this.context
    const translationX = this.viewTranslationX()
    context.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    context.clearRect(0, 0, this.width, this.height)

    if (this.cacheCanvas && !this.cacheDirty) {
      if (this.reducedMotion) {
        drawTranslated(context, translationX, () =>
          drawCachedScene(context, this.cacheCanvas, this.width, this.height),
        )
      } else if (this.activeTransitions.size === 0) {
        const breathPhase = this.animationTime / 12_000 * Math.PI * 2
        context.save()
        context.globalAlpha = 0.96 + Math.sin(breathPhase) * 0.04
        context.translate(translationX, Math.sin(breathPhase) * 1.25)
        drawCachedScene(context, this.cacheCanvas, this.width, this.height)
        context.restore()
      } else {
        drawTranslated(context, translationX, () =>
          drawCachedScene(context, this.cacheCanvas, this.width, this.height),
        )
      }
    } else {
      drawTranslated(context, translationX, () => {
        for (const command of this.commands) drawCommand(context, command, this.width, this.height)
      })
    }
    drawTranslated(context, translationX, () =>
      drawActiveTransitions(
        context,
        this.commands,
        this.activeTransitions,
        this.animationTime,
        this.width,
        this.height,
      ),
    )
    drawTargetSeed(context, this.targetLane, this.viewport(), this.atLiveEdge())
    drawTranslated(context, translationX, () =>
      drawSelectionHalo(context, this.commands, this.selectedSequence),
    )
    drawViewerPulses(context, this.viewerPulses, this.width, this.height, this.animationTime)
  }

  rebuildCache() {
    if (!this.cacheContext) return
    this.cacheContext.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    this.cacheContext.clearRect(0, 0, this.width, this.height)
    for (const command of this.commands) {
      const settled = settledCommand(command, this.activeTransitions)
      if (settled) drawCommand(this.cacheContext, settled, this.width, this.height)
    }
    this.cacheDirty = false
  }

  completeTransitions(timestamp) {
    let settled = false
    for (const [sequence, transition] of this.activeTransitions) {
      if (timestamp - transition.startedAt >= transitionDuration(this.commands, sequence)) {
        this.activeTransitions.delete(sequence)
        settled = true
      }
    }
    if (settled) this.rebuildCache()
  }

  notifyViewport() {
    const liveEdge = this.atLiveEdge()
    if (liveEdge === this.lastLiveEdge) return
    this.lastLiveEdge = liveEdge
    this.onViewportChange({atLiveEdge: liveEdge})
  }
}

function selectableCommands(commands) {
  return commands.filter(command =>
    command.type === "anchor-hit" || command.type === "memory-trace"
  )
}

function drawCachedScene(context, cacheCanvas, width, height) {
  context.drawImage(
    cacheCanvas,
    0,
    0,
    cacheCanvas.width,
    cacheCanvas.height,
    0,
    0,
    width,
    height,
  )
}

function drawTranslated(context, translationX, draw) {
  if (translationX === 0) {
    draw()
    return
  }

  context.save()
  context.translate(translationX, 0)
  draw()
  context.restore()
}

function settledCommand(command, activeTransitions) {
  if (command.type === "fiber-path") {
    const segments = command.segments.filter(
      segment => !activeTransitions.has(segment.transitionSequence),
    )
    return segments.length > 0 ? {...command, segments} : null
  }

  return activeTransitions.has(command.transitionSequence) ? null : command
}

function drawActiveTransitions(context, commands, activeTransitions, timestamp, width, height) {
  for (const [sequence, transition] of activeTransitions) {
    const duration = transitionDuration(commands, sequence)
    const progress = Math.min(1, Math.max(0, (timestamp - transition.startedAt) / duration))

    for (const command of commands) {
      if (command.type === "fiber-path") {
        const segments = command.segments
          .filter(segment => segment.transitionSequence === sequence)
          .map(segment => ({...segment, curve: cubicPrefix(segment.curve, progress)}))
        if (segments.length > 0) drawCommand(context, {...command, segments}, width, height)
      } else if (command.transitionSequence === sequence) {
        drawCommand(context, transientCommand(command, progress), width, height)
      }
    }
  }
}

function transientCommand(command, progress) {
  const eased = 1 - (1 - progress) ** 3

  switch (command.type) {
    case "tug-response":
      return {
        ...command,
        after: command.before.map((point, index) =>
          interpolatePoint(point, command.after[index] ?? point, eased),
        ),
      }
    case "knot-connector":
      return knotTransitionCommand(command, eased)
    case "illuminate-bloom":
      return {
        ...command,
        type: "illuminate-transition",
        curves: (command.glowCurves ?? []).map(curve => cubicPrefix(curve, eased)),
        radius: command.radius * eased,
      }
    case "ripple":
      return {...command, radius: command.radius * eased}
    default:
      return command
  }
}

function knotTransitionCommand(command, progress) {
  const reverse = {
    from: command.curve.to,
    control1: command.curve.control2,
    control2: command.curve.control1,
    to: command.curve.from,
  }
  const midpoint = cubicPrefix(command.curve, 0.5).to
  return {
    ...command,
    type: "knot-transition",
    curves: [
      cubicPrefix(command.curve, progress * 0.5),
      cubicPrefix(reverse, progress * 0.5),
    ],
    x: midpoint.x,
    y: midpoint.y,
    radius: command.radius * progress,
  }
}

function interpolatePoint(from, to, progress) {
  return {
    x: from.x + (to.x - from.x) * progress,
    y: from.y + (to.y - from.y) * progress,
  }
}

function transitionDuration(commands, sequence) {
  for (const command of commands) {
    if (command.type === "fiber-path") {
      const segment = command.segments.find(item => item.transitionSequence === sequence)
      if (segment) return Math.min(1300, Math.max(700, segment.length * 1.8))
    }
    if (command.transitionSequence !== sequence) continue
    if (command.type === "tug-response") return 600
    if (command.type === "illuminate-bloom") return 1200
    if (command.type === "knot-connector" || command.type === "ripple") return 900
  }
  return 900
}

function transitionSequences(commands) {
  const sequences = new Set()
  for (const command of commands) {
    if (command.type === "fiber-path") {
      for (const segment of command.segments) sequences.add(segment.transitionSequence)
    } else if (Number.isSafeInteger(command.transitionSequence)) {
      sequences.add(command.transitionSequence)
    }
  }
  return sequences
}

function boundedInstructions(instructions, preference) {
  const bySequence = new Map()
  for (const item of instructions) {
    if (Number.isSafeInteger(item?.sequence)) bySequence.set(item.sequence, item)
  }
  const ordered = [...bySequence.values()].sort((left, right) => left.sequence - right.sequence)
  return preference === "oldest" ? ordered.slice(0, maximumEvents) : ordered.slice(-maximumEvents)
}

function timelineLevelOfDetailCapacity(width, padding) {
  const drawableWidth = Math.max(0, Number(width) - Number(padding) * 2)
  return Math.max(60, Math.min(240, Math.floor(drawableWidth / 6)))
}

function timelineLevelOfDetail(instructions, capacity, selectedSequence) {
  if (instructions.length <= capacity) return instructions

  const sourceGroups = Map.groupBy(instructions, instruction => instruction.source)
  const sources = [...sourceGroups.keys()].sort()
  const baseSize = Math.floor(capacity / sources.length)
  let remainder = capacity % sources.length
  const selected = []

  for (const source of sources) {
    const sourceInstructions = sourceGroups.get(source).sort(compareTimelineInstructions)
    const sourceCapacity = baseSize + (remainder > 0 ? 1 : 0)
    remainder = Math.max(0, remainder - 1)
    selected.push(...evenlySpacedInstructions(sourceInstructions, sourceCapacity))
  }

  const selectedInstruction = instructions.find(
    instruction => instruction.sequence === selectedSequence,
  )
  if (selectedInstruction && !selected.some(item => item.sequence === selectedSequence)) {
    selected[Math.floor(selected.length / 2)] = selectedInstruction
  }

  return selected.sort(compareTimelineInstructions)
}

function evenlySpacedInstructions(instructions, capacity) {
  if (instructions.length <= capacity) return instructions
  const lastIndex = instructions.length - 1
  const indices = new Set(
    Array.from({length: capacity}, (_entry, index) =>
      Math.round(index * lastIndex / (capacity - 1))
    ),
  )
  return [...indices].map(index => instructions[index])
}

function compareTimelineInstructions(left, right) {
  return Date.parse(left.occurred_at) - Date.parse(right.occurred_at) ||
    left.sequence - right.sequence
}

function validatedSnapshot(envelope) {
  if (!envelope || typeof envelope !== "object" || Array.isArray(envelope)) {
    throw new TypeError("snapshot envelope must be an object")
  }
  if (envelope.snapshot_version !== 1) {
    throw new TypeError("snapshot_version must be 1")
  }
  if (!Number.isSafeInteger(envelope.commit_watermark) || envelope.commit_watermark < 0) {
    throw new TypeError("commit watermark must be a non-negative safe integer")
  }
  if (!Array.isArray(envelope.display_events) || !Array.isArray(envelope.memory_events)) {
    throw new TypeError("snapshot event roles must be arrays")
  }
  if (envelope.ambient !== null && (typeof envelope.ambient !== "object" || Array.isArray(envelope.ambient))) {
    throw new TypeError("snapshot ambient must be an instruction or null")
  }
  if (envelope.window_end !== null && !validUtcTimestamp(envelope.window_end)) {
    throw new TypeError("window_end must be a parseable canonical UTC timestamp or null")
  }

  const allInstructions = [
    ...envelope.display_events,
    ...envelope.memory_events,
    ...(envelope.ambient === null ? [] : [envelope.ambient]),
  ]
  for (const instruction of allInstructions) {
    if (!Number.isSafeInteger(instruction?.sequence) || instruction.sequence <= 0) {
      throw new TypeError("snapshot instruction sequence must be a positive safe integer")
    }
    if (instruction.sequence > envelope.commit_watermark) {
      throw new TypeError("snapshot instruction sequence cannot exceed its commit watermark")
    }
    if (!validUtcTimestamp(instruction.occurred_at)) {
      throw new TypeError("snapshot instruction occurred_at must be a parseable canonical UTC timestamp")
    }
  }
  if (envelope.commit_watermark === 0 && allInstructions.length > 0) {
    throw new TypeError("commit watermark zero is reserved for an empty snapshot")
  }
  const primaryInstructions = [...envelope.display_events, ...envelope.memory_events]
  if (envelope.window_end === null && primaryInstructions.length > 0) {
    throw new TypeError("window_end may be null only when primary snapshot roles are empty")
  }

  return {
    snapshotVersion: envelope.snapshot_version,
    windowEnd: envelope.window_end,
    commitWatermark: envelope.commit_watermark,
    displayEvents: deepCloneSnapshotValue(envelope.display_events),
    memoryEvents: deepCloneSnapshotValue(envelope.memory_events),
    ambient: deepCloneSnapshotValue(envelope.ambient),
  }
}

function validatedTimelineWindow(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new TypeError("timeline window must be an object")
  }
  const durationSeconds = Number(payload.axis?.duration_seconds)
  if (!supportedTimelineDurations.has(durationSeconds * 1000)) {
    throw new TypeError("timeline window duration must be supported")
  }
  if (!validUtcTimestamp(payload.axis?.end_at)) {
    throw new TypeError("timeline window end_at must be canonical UTC")
  }
  const startAt = payload.axis?.start_at ?? new Date(
    Date.parse(payload.axis.end_at) - durationSeconds * 1000,
  ).toISOString()
  if (!validUtcTimestamp(startAt)) {
    throw new TypeError("timeline window start_at must be canonical UTC")
  }
  if (!Array.isArray(payload.instructions) || !Array.isArray(payload.scaffold)) {
    throw new TypeError("timeline window instruction roles must be arrays")
  }
  if (payload.ambient !== null &&
      (typeof payload.ambient !== "object" || Array.isArray(payload.ambient))) {
    throw new TypeError("timeline window ambient must be an instruction or null")
  }
  if (payload.archive_start_at !== null && payload.archive_start_at !== undefined &&
      !validUtcTimestamp(payload.archive_start_at)) {
    throw new TypeError("timeline window archive_start_at must be canonical UTC or null")
  }

  const roles = [
    ...payload.instructions,
    ...payload.scaffold,
    ...(payload.ambient === null ? [] : [payload.ambient]),
  ]
  for (const instruction of roles) {
    if (!Number.isSafeInteger(instruction?.sequence) || instruction.sequence <= 0) {
      throw new TypeError("timeline instruction sequence must be a positive safe integer")
    }
    if (!validUtcTimestamp(instruction.occurred_at)) {
      throw new TypeError("timeline instruction occurred_at must be canonical UTC")
    }
  }

  return {
    startAt,
    endAt: payload.axis.end_at,
    durationSeconds,
    instructions: deepCloneSnapshotValue(payload.instructions),
    scaffold: deepCloneSnapshotValue(payload.scaffold),
    ambient: deepCloneSnapshotValue(payload.ambient),
    archiveStartAt: payload.archive_start_at ?? null,
  }
}

function validUtcTimestamp(timestamp) {
  if (typeof timestamp !== "string") return false
  const match = timestamp.match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$/,
  )
  if (!match) return false
  const milliseconds = Date.parse(timestamp)
  if (!Number.isFinite(milliseconds)) return false

  const parsed = new Date(milliseconds)
  const expected = match.slice(1, 7).map(Number)
  const actual = [
    parsed.getUTCFullYear(),
    parsed.getUTCMonth() + 1,
    parsed.getUTCDate(),
    parsed.getUTCHours(),
    parsed.getUTCMinutes(),
    parsed.getUTCSeconds(),
  ]
  return actual.every((component, index) => component === expected[index])
}

function deepCloneSnapshotValue(value) {
  if (Array.isArray(value)) return value.map(deepCloneSnapshotValue)
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [key, deepCloneSnapshotValue(nested)]),
    )
  }
  return value
}

function scaffoldInstructions(instructions) {
  return boundedInstructions(
    instructions.filter(instruction => instruction?.source === "wikimedia"),
    "newest",
  ).slice(-maximumScaffoldEvents)
}

function latestAmbientInstruction(instructions) {
  return instructions
    .filter(instruction =>
      instruction?.source === "open_meteo" &&
      instruction.kind === "weather" &&
      Number.isSafeInteger(instruction.sequence)
    )
    .sort((left, right) => left.sequence - right.sequence)
    .at(-1) ?? null
}

function withAlpha(color, alpha) {
  let channels = rgbChannelCache.get(color)
  if (!channels) {
    channels = [1, 3, 5].map(offset => Number.parseInt(color.slice(offset, offset + 2), 16))
    rgbChannelCache.set(color, channels)
  }
  return `rgba(${channels[0]}, ${channels[1]}, ${channels[2]}, ${alpha})`
}

const rgbChannelCache = new Map()

function radialBloom(context, x, y, radius, color, coreAlpha) {
  const gradient = context.createRadialGradient(x, y, 0, x, y, Math.max(0.1, radius))
  gradient.addColorStop(0, withAlpha(color, coreAlpha))
  gradient.addColorStop(0.55, withAlpha(color, coreAlpha * 0.35))
  gradient.addColorStop(1, withAlpha(color, 0))
  return gradient
}

function commandTint(command) {
  return command.glow ?? command.stroke ?? canvasPalette.fallback
}

function drawStar(context, x, y, radius, glow, {spikes = false, coreScale = 0.3} = {}) {
  context.globalCompositeOperation = "lighter"
  context.globalAlpha = 1
  context.fillStyle = radialBloom(context, x, y, radius, glow, 0.5)
  context.beginPath()
  context.arc(x, y, radius, 0, Math.PI * 2)
  context.fill()
  if (spikes) drawDiffractionSpikes(context, x, y, radius * 2.4, glow)
  context.globalCompositeOperation = "source-over"
  context.fillStyle = canvasPalette.starCore
  context.globalAlpha = 0.95
  context.beginPath()
  context.arc(x, y, Math.max(0.9, radius * coreScale), 0, Math.PI * 2)
  context.fill()
}

function drawDiffractionSpikes(context, x, y, reach, glow) {
  const horizontal = context.createLinearGradient(x - reach, y, x + reach, y)
  horizontal.addColorStop(0, withAlpha(glow, 0))
  horizontal.addColorStop(0.5, withAlpha(glow, 0.55))
  horizontal.addColorStop(1, withAlpha(glow, 0))
  context.lineWidth = 0.8
  context.strokeStyle = horizontal
  context.beginPath()
  context.moveTo(x - reach, y)
  context.lineTo(x + reach, y)
  context.stroke()
  const vertical = context.createLinearGradient(x, y - reach, x, y + reach)
  vertical.addColorStop(0, withAlpha(glow, 0))
  vertical.addColorStop(0.5, withAlpha(glow, 0.55))
  vertical.addColorStop(1, withAlpha(glow, 0))
  context.strokeStyle = vertical
  context.beginPath()
  context.moveTo(x, y - reach)
  context.lineTo(x, y + reach)
  context.stroke()
}

function drawCommand(context, command, width, height) {
  context.save()
  if (command.type === "fiber-path") {
    drawFiberPath(context, command)
    context.restore()
    return
  }
  if (sourceMaterialRoles.has(command.role) && command.type === command.role) {
    drawSourceMaterial(context, command)
    context.restore()
    return
  }

  context.strokeStyle = command.stroke ?? canvasPalette.fallback
  context.fillStyle = command.glow ?? command.stroke ?? canvasPalette.fallback
  context.lineWidth = 1 + (command.intensity ?? 0.2) * 2
  context.globalAlpha = 0.3 + (command.intensity ?? 0.2) * 0.6
  context.lineCap = "round"
  context.lineJoin = "round"
  context.beginPath()

  switch (command.type) {
    case "ambient": {
      const coverage = command.coverage ?? 0.2
      const sky = context.createLinearGradient(0, 0, 0, height)
      sky.addColorStop(0, withAlpha(commandTint(command), coverage))
      sky.addColorStop(0.62, withAlpha(commandTint(command), coverage * 0.42))
      sky.addColorStop(1, withAlpha(commandTint(command), 0))
      context.globalAlpha = 1
      context.fillStyle = sky
      context.fillRect(0, 0, width, height)
      drawAuroraCurtains(context, command, width, height)
      break
    }
    case "memory-band": {
      const shelf = context.createLinearGradient(0, command.y, 0, command.y + command.height)
      shelf.addColorStop(0, withAlpha(commandTint(command), 0))
      shelf.addColorStop(1, withAlpha(commandTint(command), 0.07))
      context.globalAlpha = 1
      context.fillStyle = shelf
      context.fillRect(command.x, command.y, command.width, command.height)
      context.globalAlpha = 0.5
      context.fillStyle = commandTint(command)
      context.fillText(command.label, command.x + 6, command.y + Math.max(10, command.height * 0.55))
      break
    }
    case "memory-trace": {
      const strength = command.intensity ?? 0.5
      const radius = 3 + strength * 4
      context.globalCompositeOperation = "lighter"
      context.globalAlpha = 1
      context.fillStyle = radialBloom(
        context, command.x, command.y, radius * 2.6, commandTint(command), 0.18,
      )
      context.arc(command.x, command.y, radius * 2.6, 0, Math.PI * 2)
      context.fill()
      context.globalCompositeOperation = "source-over"
      context.beginPath()
      context.globalAlpha = 0.4 + strength * 0.25
      context.fillStyle = commandTint(command)
      context.arc(command.x, command.y, radius * 0.72, 0, Math.PI * 2)
      context.fill()
      break
    }
    case "ripple": {
      const radius = Math.max(1, command.radius)
      const strength = command.intensity ?? 0.5
      context.globalCompositeOperation = "lighter"
      context.globalAlpha = 1
      context.fillStyle = radialBloom(
        context, command.x, command.y, radius, commandTint(command), 0.1 + strength * 0.14,
      )
      context.arc(command.x, command.y, radius, 0, Math.PI * 2)
      context.fill()
      context.globalCompositeOperation = "source-over"
      context.beginPath()
      context.globalAlpha = 0.5 + strength * 0.3
      context.lineWidth = 1 + strength * 1.4
      context.arc(command.x, command.y, radius, 0, Math.PI * 2)
      context.stroke()
      context.beginPath()
      context.globalAlpha = 0.26 + strength * 0.2
      context.lineWidth = 1
      context.arc(command.x, command.y, radius * 0.62, 0, Math.PI * 2)
      context.stroke()
      context.beginPath()
      context.globalAlpha = 0.14 + strength * 0.12
      context.arc(command.x, command.y, radius * 1.24, 0, Math.PI * 2)
      context.stroke()
      drawStar(context, command.x, command.y, 2.4 + strength * 2, commandTint(command))
      break
    }
    case "knot":
      drawKnotNode(context, command)
      break
    case "glow": {
      const strength = command.intensity ?? 0.5
      context.globalCompositeOperation = "lighter"
      context.globalAlpha = 1
      context.fillStyle = radialBloom(
        context, command.x, command.y, command.radius, commandTint(command),
        0.3 + strength * 0.3,
      )
      context.arc(command.x, command.y, command.radius, 0, Math.PI * 2)
      context.fill()
      context.globalCompositeOperation = "source-over"
      context.beginPath()
      context.globalAlpha = 0.9
      context.arc(command.x, command.y, Math.max(2, command.radius * 0.14), 0, Math.PI * 2)
      context.fill()
      break
    }
    case "tug-response": {
      const points = command.after ?? []
      if (points.length < 2) break
      context.moveTo(points[0].x, points[0].y)
      for (let index = 1; index < points.length - 1; index++) {
        const midpoint = {
          x: (points[index].x + points[index + 1].x) / 2,
          y: (points[index].y + points[index + 1].y) / 2,
        }
        context.quadraticCurveTo(points[index].x, points[index].y, midpoint.x, midpoint.y)
      }
      const penultimate = points.at(-2)
      const last = points.at(-1)
      context.quadraticCurveTo(penultimate.x, penultimate.y, last.x, last.y)
      context.stroke()
      drawStar(
        context, last.x, last.y,
        2.6 + (command.intensity ?? 0.5) * 2.2, commandTint(command),
      )
      break
    }
    case "knot-connector":
      context.moveTo(command.curve.from.x, command.curve.from.y)
      context.bezierCurveTo(
        command.curve.control1.x,
        command.curve.control1.y,
        command.curve.control2.x,
        command.curve.control2.y,
        command.curve.to.x,
        command.curve.to.y,
      )
      context.stroke()
      drawKnotNode(context, command)
      break
    case "knot-transition":
      for (const curve of command.curves) {
        context.moveTo(curve.from.x, curve.from.y)
        context.bezierCurveTo(
          curve.control1.x,
          curve.control1.y,
          curve.control2.x,
          curve.control2.y,
          curve.to.x,
          curve.to.y,
        )
      }
      context.stroke()
      drawKnotNode(context, command)
      break
    case "illuminate-transition":
      context.globalAlpha = 0.35 + (command.intensity ?? 0.5) * 0.35
      for (const curve of command.curves) {
        context.moveTo(curve.from.x, curve.from.y)
        context.bezierCurveTo(
          curve.control1.x,
          curve.control1.y,
          curve.control2.x,
          curve.control2.y,
          curve.to.x,
          curve.to.y,
        )
      }
      context.stroke()
      drawIlluminateBloom(context, command)
      break
    case "illuminate-bloom":
      drawIlluminateBloom(context, command)
      break
    case "anchor-hit":
      break
    case "fiber":
    case "tug":
      context.moveTo(command.x - (command.length ?? command.displacement), command.y)
      context.bezierCurveTo(
        command.x - 12,
        command.y + command.visual.bend * 28,
        command.x + 12,
        command.y - command.visual.bend * 28,
        command.x + 20,
        command.y,
      )
      context.stroke()
      break
    case "seam": {
      const seam = context.createLinearGradient(0, 0, 0, height)
      seam.addColorStop(0, withAlpha(command.stroke ?? canvasPalette.fallback, 0))
      seam.addColorStop(0.5, withAlpha(command.stroke ?? canvasPalette.fallback, 0.36))
      seam.addColorStop(1, withAlpha(command.stroke ?? canvasPalette.fallback, 0))
      context.globalAlpha = 1
      context.lineWidth = 1
      context.strokeStyle = seam
      context.moveTo(command.x, 0)
      context.lineTo(command.x, height)
      context.stroke()
      break
    }
    default:
      context.moveTo(command.x - 8, command.y)
      context.lineTo(command.x + 8, command.y)
      context.stroke()
      drawStar(
        context, command.x, command.y,
        2 + (command.intensity ?? 0.5) * 1.6, commandTint(command),
      )
  }

  context.restore()
}

function drawAuroraCurtains(context, command, width, height) {
  const random = xorshift32(command.sequence)
  const coverage = command.coverage ?? 0.2
  context.globalCompositeOperation = "lighter"
  context.lineCap = "round"
  for (let index = 0; index < 3; index++) {
    const x = width * (0.12 + random.nextFloat() * 0.76)
    const sway = (random.nextFloat() - 0.5) * width * 0.06
    const drop = height * (0.3 + random.nextFloat() * 0.18)
    const band = context.createLinearGradient(0, 0, 0, drop)
    band.addColorStop(0, withAlpha(commandTint(command), coverage * 0.85))
    band.addColorStop(1, withAlpha(commandTint(command), 0))
    context.strokeStyle = band
    context.lineWidth = 34 + random.nextFloat() * 44
    context.globalAlpha = 1
    context.beginPath()
    context.moveTo(x, 0)
    context.quadraticCurveTo(x + sway, drop * 0.55, x + sway * 1.6, drop)
    context.stroke()
  }
  context.globalCompositeOperation = "source-over"
}

function drawKnotNode(context, command) {
  const strength = command.intensity ?? 0.5
  const separation = Math.max(2.4, command.radius * 0.42)
  const angle = (command.visual?.bend ?? 0) * Math.PI
  const offsetX = Math.cos(angle) * separation
  const offsetY = Math.sin(angle) * separation
  context.globalCompositeOperation = "lighter"
  context.globalAlpha = 1
  context.fillStyle = radialBloom(
    context, command.x, command.y, command.radius * 2.1, commandTint(command),
    0.16 + strength * 0.14,
  )
  context.beginPath()
  context.arc(command.x, command.y, command.radius * 2.1, 0, Math.PI * 2)
  context.fill()
  context.globalCompositeOperation = "source-over"
  context.beginPath()
  context.globalAlpha = 0.4 + strength * 0.25
  context.lineWidth = 1
  context.strokeStyle = command.stroke ?? canvasPalette.fallback
  context.arc(command.x, command.y, separation * 1.7, 0, Math.PI * 2)
  context.stroke()
  drawStar(
    context, command.x - offsetX, command.y - offsetY,
    2.2 + strength * 1.8, commandTint(command),
  )
  drawStar(
    context, command.x + offsetX, command.y + offsetY,
    1.7 + strength * 1.4, commandTint(command),
  )
}

function drawIlluminateBloom(context, command) {
  const strength = command.intensity ?? 0.5
  const radius = Math.max(1, command.radius)
  context.globalCompositeOperation = "lighter"
  context.globalAlpha = 1
  context.fillStyle = radialBloom(
    context, command.x, command.y, radius, commandTint(command), 0.26 + strength * 0.3,
  )
  context.beginPath()
  context.arc(command.x, command.y, radius, 0, Math.PI * 2)
  context.fill()
  drawDiffractionSpikes(context, command.x, command.y, radius * 1.6, commandTint(command))
  context.globalCompositeOperation = "source-over"
  context.beginPath()
  context.globalAlpha = 0.92
  context.fillStyle = canvasPalette.starCore
  context.arc(command.x, command.y, Math.max(2.5, radius * 0.16), 0, Math.PI * 2)
  context.fill()
}

function drawSourceMaterial(context, command) {
  switch (command.role) {
    case "conversation-fan":
      drawConversationFan(context, command)
      break
    case "route-fork":
      drawRouteFork(context, command)
      break
    case "slot-braid":
      drawSlotBraid(context, command)
      break
    case "public-pulse":
      drawPublicPulse(context, command)
      break
  }
}

function drawConversationFan(context, command) {
  drawMaterialAttachment(context, command)
  context.lineCap = "round"
  context.lineJoin = "round"
  context.setLineDash([1, 4])
  context.beginPath()
  context.lineWidth = 1
  context.globalAlpha = 0.38 + command.intensity * 0.22
  context.strokeStyle = command.stroke
  for (const branch of command.branches) {
    const {curve} = branch
    context.moveTo(curve.from.x, curve.from.y)
    context.bezierCurveTo(
      curve.control1.x,
      curve.control1.y,
      curve.control2.x,
      curve.control2.y,
      curve.to.x,
      curve.to.y,
    )
    if (branch.returns && branch.returnPoint) {
      context.lineTo(branch.returnPoint.x, branch.returnPoint.y)
    }
  }
  context.stroke()
  context.setLineDash([])

  for (const branch of command.branches) {
    const point = branch.curve.to
    drawStar(context, point.x, point.y, 2.2 + command.intensity * 1.8, command.glow)
  }
  drawStar(context, command.x, command.y, 3.6 + command.intensity * 3, command.glow, {
    spikes: command.intensity > 0.55,
  })
}

function drawRouteFork(context, command) {
  drawMaterialAttachment(context, command)
  context.lineCap = "round"
  context.lineJoin = "miter"
  context.setLineDash([])
  context.beginPath()
  context.lineWidth = 1
  context.globalAlpha = 0.42 + command.intensity * 0.22
  context.strokeStyle = command.stroke
  for (const segment of command.segments) {
    const [origin, elbow, endpoint] = segment.points
    context.moveTo(origin.x, origin.y)
    context.lineTo(elbow.x, elbow.y)
    context.lineTo(endpoint.x, endpoint.y)
  }
  context.stroke()

  for (const segment of command.segments) {
    const [, elbow, endpoint] = segment.points
    drawStar(context, elbow.x, elbow.y, 1.5 + command.intensity, command.glow)
    drawStar(context, endpoint.x, endpoint.y, 2 + command.intensity * 1.6, command.glow)
  }
  drawStar(context, command.x, command.y, 3.2 + command.intensity * 2.4, command.glow)
}

function drawSlotBraid(context, command) {
  const gaps = new Set(command.gapMarkers.map(marker => marker.afterSlotOrder))
  drawMaterialAttachment(context, command)
  context.lineCap = "round"
  context.lineJoin = "round"
  context.setLineDash([])
  context.beginPath()
  context.lineWidth = 1
  context.globalAlpha = 0.3 + command.intensity * 0.16
  context.strokeStyle = command.stroke
  for (let index = 0; index < command.beads.length - 1; index++) {
    if (gaps.has(index)) continue
    context.moveTo(command.beads[index].x, command.beads[index].y)
    context.lineTo(command.beads[index + 1].x, command.beads[index + 1].y)
  }
  context.stroke()

  for (const bead of command.beads) {
    drawStar(context, bead.x, bead.y, bead.radius + 1.2, command.glow)
  }
  context.strokeStyle = command.glow
  context.globalAlpha = 0.55
  context.lineWidth = 1
  for (const marker of command.gapMarkers) {
    context.beginPath()
    context.moveTo(marker.x - marker.size, marker.y - marker.size)
    context.lineTo(marker.x + marker.size, marker.y + marker.size)
    context.moveTo(marker.x + marker.size, marker.y - marker.size)
    context.lineTo(marker.x - marker.size, marker.y + marker.size)
    context.stroke()
  }
}

function drawPublicPulse(context, command) {
  drawMaterialAttachment(context, command)
  context.lineCap = "round"
  context.lineJoin = "miter"
  context.setLineDash([])
  context.beginPath()
  context.lineWidth = 1
  context.globalAlpha = 0.55
  context.strokeStyle = command.stroke
  for (const crystal of command.crystals) tracePolyline(context, crystal.points)
  context.stroke()

  const ringRadius = (8 + command.intensity * 8) * 1.15
  context.globalCompositeOperation = "lighter"
  context.beginPath()
  context.globalAlpha = 0.2
  context.strokeStyle = command.glow
  context.arc(command.x, command.y, ringRadius, 0, Math.PI * 2)
  context.stroke()
  context.globalCompositeOperation = "source-over"
  drawStar(context, command.x, command.y, 2.8 + command.intensity * 2.2, command.glow, {
    spikes: true,
  })
}

function tracePolyline(context, points) {
  if (points.length === 0) return
  context.moveTo(points[0].x, points[0].y)
  for (const point of points.slice(1)) context.lineTo(point.x, point.y)
}

function drawMaterialAttachment(context, command) {
  if (!command.attachment) return
  context.beginPath()
  context.lineCap = "round"
  context.setLineDash([1, 6])
  context.lineWidth = 1
  context.globalAlpha = 0.2 + (command.intensity ?? 0.5) * 0.12
  context.strokeStyle = command.glow ?? command.stroke ?? canvasPalette.fallback
  context.moveTo(command.attachment.x, command.attachment.y)
  context.lineTo(command.x, command.y)
  context.stroke()
  context.setLineDash([])
}

function drawFiberPath(context, command) {
  context.lineCap = "round"
  context.lineJoin = "round"
  if (command.role === "spine") {
    drawNebulaPath(context, command)
    return
  }
  drawFilamentPath(context, command)
}

function drawNebulaPath(context, command) {
  const nebulaLayers = [
    {width: 34, alpha: 0.045},
    {width: 18, alpha: 0.075},
    {width: 8, alpha: 0.11},
  ]
  context.globalCompositeOperation = "lighter"
  for (const layer of nebulaLayers) {
    context.beginPath()
    context.lineWidth = layer.width
    context.globalAlpha = layer.alpha
    context.strokeStyle = command.glow
    traceFiberSegments(context, command.segments)
    context.stroke()
  }
  context.globalCompositeOperation = "source-over"
  context.beginPath()
  context.lineWidth = 1
  context.globalAlpha = 0.5
  context.strokeStyle = command.stroke
  traceFiberSegments(context, command.segments)
  context.stroke()
  drawStarDust(context, command, {drift: 26, density: 16})
}

function drawFilamentPath(context, command) {
  const chartLine = command.role === "connector" || command.role === "capillary"
  context.setLineDash(chartLine ? [1, 5] : [])
  context.beginPath()
  context.lineWidth = 1
  context.globalAlpha = 0.18 + (command.intensity ?? 0.5) * 0.16
  context.strokeStyle = command.glow
  traceFiberSegments(context, command.segments)
  context.stroke()
  context.setLineDash([])
  drawStarDust(context, command, {drift: 8, density: 44})
  for (const segment of command.segments) {
    const tip = segment.curve.to
    drawStar(
      context,
      tip.x,
      tip.y,
      1.7 + (segment.intensity ?? 0.5) * 1.9,
      command.glow ?? command.stroke ?? canvasPalette.fallback,
    )
  }
}

function drawStarDust(context, command, {drift, density}) {
  context.globalCompositeOperation = "lighter"
  for (const segment of command.segments) {
    const random = xorshift32(segment.transitionSequence ?? command.sequence)
    const count = Math.max(1, Math.min(9, Math.round((segment.length ?? 30) / density)))
    for (let index = 0; index < count; index++) {
      const along = cubicPrefix(segment.curve, random.nextFloat()).to
      const scatter = (random.nextFloat() - 0.5) * drift
      const radius = 0.5 + random.nextFloat() * 1.1
      context.globalAlpha = 0.2 + random.nextFloat() * 0.4
      context.fillStyle = command.glow ?? canvasPalette.starCore
      context.beginPath()
      context.arc(along.x, along.y + scatter, radius, 0, Math.PI * 2)
      context.fill()
    }
  }
  context.globalCompositeOperation = "source-over"
  context.globalAlpha = 1
}

function traceFiberSegments(context, segments) {
  for (const segment of segments) {
    context.moveTo(segment.curve.from.x, segment.curve.from.y)
    context.bezierCurveTo(
      segment.curve.control1.x, segment.curve.control1.y,
      segment.curve.control2.x, segment.curve.control2.y,
      segment.curve.to.x, segment.curve.to.y,
    )
  }
}

function drawTargetSeed(context, lane, viewport, atLiveEdge) {
  if (!atLiveEdge) return

  const x = viewport.width - 14
  const y = laneToY(lane, viewport)
  context.save()
  context.globalCompositeOperation = "lighter"
  context.globalAlpha = 1
  context.fillStyle = radialBloom(context, x, y, 16, canvasPalette.targetSeed, 0.34)
  context.beginPath()
  context.arc(x, y, 16, 0, Math.PI * 2)
  context.fill()
  context.globalCompositeOperation = "source-over"
  context.fillStyle = canvasPalette.targetSeed
  context.globalAlpha = 0.92
  context.beginPath()
  context.arc(x, y, 3.5, 0, Math.PI * 2)
  context.fill()
  context.restore()
}

function drawSelectionHalo(context, commands, selectedSequence) {
  if (!Number.isSafeInteger(selectedSequence)) return
  const command = commands.find(item => item.sequence === selectedSequence && item.hit)
  if (!command) return

  const {hit} = command
  const centerX = hit.x + hit.width / 2
  const centerY = hit.y + hit.height / 2
  const radius = Math.max(hit.width, hit.height) * 0.62
  context.save()
  context.globalCompositeOperation = "lighter"
  context.globalAlpha = 1
  context.fillStyle = radialBloom(context, centerX, centerY, radius * 1.7, canvasPalette.selectionHalo, 0.16)
  context.beginPath()
  context.arc(centerX, centerY, radius * 1.7, 0, Math.PI * 2)
  context.fill()
  context.globalCompositeOperation = "source-over"
  context.strokeStyle = canvasPalette.selectionHalo
  context.globalAlpha = 0.66
  context.lineWidth = 1
  context.beginPath()
  context.arc(centerX, centerY, radius, 0, Math.PI * 2)
  context.stroke()
  context.globalAlpha = 0.3
  context.beginPath()
  context.arc(centerX, centerY, radius + 4, 0, Math.PI * 2)
  context.stroke()
  context.restore()
}

function uniqueCount(instructions) {
  return new Set(instructions.map(item => item.sequence)).size
}

function drawViewerPulses(context, count, width, height, animationTime) {
  for (let index = 0; index < count; index++) {
    const phase = animationTime / 1800 + index * 1.7
    const y = ((index + 1) / (count + 1)) * height
    const radius = 2.5 + (Math.sin(phase) + 1) * 1.5
    context.save()
    context.globalCompositeOperation = "lighter"
    context.globalAlpha = 1
    context.fillStyle = radialBloom(context, width - 14, y, radius * 3, canvasPalette.viewerPulse, 0.14)
    context.beginPath()
    context.arc(width - 14, y, radius * 3, 0, Math.PI * 2)
    context.fill()
    context.globalCompositeOperation = "source-over"
    context.globalAlpha = 0.3
    context.fillStyle = canvasPalette.viewerPulse
    context.beginPath()
    context.arc(width - 14, y, radius * 0.9, 0, Math.PI * 2)
    context.fill()
    context.restore()
  }
}
