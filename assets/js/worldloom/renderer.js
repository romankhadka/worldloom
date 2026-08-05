import {commandsForScene, cubicPrefix, laneToY} from "./geometry.js"

const maximumEvents = 600
const maximumCommands = 4000
const maximumViewerPulses = 12
const maximumActiveTransitions = 8
const maximumScaffoldEvents = 12
const defaultSpacing = 28
const animatedKinds = new Set(["wikimedia", "earthquake", "tug", "knot", "illuminate"])

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
    this.onGap = options.onGap ?? (() => {})
    this.onHistoryRequest = options.onHistoryRequest ?? (() => {})
    this.onViewportChange = options.onViewportChange ?? (() => {})
    this.onSelect = options.onSelect ?? (() => {})
    this.onReloadRequest = options.onReloadRequest ?? (() => {})
    this.events = []
    this.scaffold = []
    this.commands = []
    this.ambient = null
    this.panOffset = 0
    this.projectedPanOffset = 0
    this.watermark = 0
    this.queuedEvents = new Map()
    this.gapInFlight = false
    this.historyInFlight = false
    this.archiveStart = false
    this.newerEventsDropped = false
    this.pointerX = null
    this.touchX = null
    this.selectionIndex = -1
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
    this.events = boundedInstructions(instructions, "newest")
    this.scaffold = scaffoldInstructions([...scaffold, ...this.events])
    this.ambient = latestAmbientInstruction([ambient, ...this.events])
    this.watermark = this.events.at(-1)?.sequence ?? 0
    this.queuedEvents.clear()
    this.activeTransitions.clear()
    this.gapInFlight = false
    this.rebuild()
  }

  setAmbient(ambient) {
    this.activeTransitions.clear()
    this.ambient = ambient
    this.rebuild()
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
    const eventSequences = new Set(this.events.map(instruction => instruction.sequence))
    const scaffoldOnly = this.scaffold.filter(
      instruction => !eventSequences.has(instruction.sequence),
    )
    const topologyCapacity = maximumEvents - scaffoldOnly.length
    const topologyInstructions = [
      ...scaffoldOnly,
      ...this.events.slice(-topologyCapacity),
    ]
    this.commands = this.projectScene(topologyInstructions, viewport, {
      ambient: this.ambient,
      projectionInstructions: [...scaffoldOnly, ...this.events],
      hitInstructions: this.events,
    }).slice(-maximumCommands)
    const availableTransitions = transitionSequences(this.commands)
    for (const sequence of this.activeTransitions.keys()) {
      if (!availableTransitions.has(sequence)) this.activeTransitions.delete(sequence)
    }
    this.projectedPanOffset = this.panOffset
    this.cacheDirty = true
    this.rebuildCache()
    this.draw()
  }

  receiveEvent(instruction) {
    const sequence = instruction.sequence
    if (!Number.isSafeInteger(sequence) || sequence <= this.watermark) return

    if (sequence === this.watermark + 1) {
      this.appendCommitted(instruction, false)
      this.drainQueuedEvents()
      return
    }

    this.queuedEvents.set(sequence, instruction)
    this.trimQueue()

    if (!this.gapInFlight) {
      this.gapInFlight = true
      this.onGap({after: this.watermark, through: sequence - 1})
    }
  }

  applyCatchUp(instructions, watermark) {
    this.activeTransitions.clear()
    for (const instruction of instructions) {
      if (instruction.sequence > this.watermark) this.appendCommitted(instruction, false, false)
    }

    this.watermark = Math.max(this.watermark, watermark)
    this.gapInFlight = false
    this.drainQueuedEvents(false)
  }

  reload(instructions, watermark = null, {ambient = this.ambient, scaffold = []} = {}) {
    this.panOffset = 0
    this.returningToLive = false
    this.setEvents(instructions, {ambient, scaffold})
    if (Number.isSafeInteger(watermark)) this.watermark = watermark
    this.newerEventsDropped = false
    this.notifyViewport()
  }

  prependHistory(instructions, {archiveStart = false, scaffold = []} = {}) {
    this.activeTransitions.clear()
    const combined = [...instructions, ...this.events]
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

  returnLive() {
    if (this.newerEventsDropped) this.onReloadRequest()
    const hadTransitions = this.activeTransitions.size > 0
    this.activeTransitions.clear()
    if (hadTransitions) this.rebuildCache()

    if (this.reducedMotion) {
      this.panOffset = 0
      this.rebuild()
      this.notifyViewport()
    } else {
      this.returningToLive = true
    }
  }

  atLiveEdge() {
    return this.panOffset <= 1
  }

  hitTest(x, y) {
    const sceneX = x - this.viewTranslationX()
    const candidates = this.commands.filter(item => {
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
    const sequences = [...new Set(this.commands.filter(item => item.hit).map(item => item.sequence))]
    if (sequences.length === 0) return null

    this.selectionIndex =
      (this.selectionIndex + direction + sequences.length) % sequences.length
    return sequences[this.selectionIndex]
  }

  activateSelection() {
    const sequences = [...new Set(this.commands.filter(item => item.hit).map(item => item.sequence))]
    const sequence = sequences[this.selectionIndex]
    if (sequence !== undefined) this.onSelect(sequence)
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
      if (this.panOffset <= 1) {
        this.panOffset = 0
        this.returningToLive = false
        this.rebuild()
        this.notifyViewport()
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
    this.frameHandle = null
    this.activeTransitions.clear()
    this.scaffold = []
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
      panOffset: this.panOffset,
    }
  }

  viewTranslationX() {
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

  appendCommitted(instruction, rebuild = true, animate = !this.reducedMotion) {
    this.events = boundedInstructions([...this.events, instruction], "newest")
    if (instruction.source === "wikimedia") {
      this.scaffold = scaffoldInstructions([...this.scaffold, instruction])
    }
    if (instruction.source === "open_meteo" && instruction.kind === "weather") {
      this.ambient = instruction
    }
    this.watermark = Math.max(this.watermark, instruction.sequence)
    if (animate && animatedKinds.has(instruction.kind)) {
      this.activeTransitions.set(instruction.sequence, {
        sequence: instruction.sequence,
        startedAt: this.animationTime,
      })
      while (this.activeTransitions.size > maximumActiveTransitions) {
        this.activeTransitions.delete(this.activeTransitions.keys().next().value)
      }
    }
    if (rebuild) this.rebuild()
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

  drainQueuedEvents(animate = !this.reducedMotion) {
    while (this.queuedEvents.has(this.watermark + 1)) {
      const nextSequence = this.watermark + 1
      const instruction = this.queuedEvents.get(nextSequence)
      this.queuedEvents.delete(nextSequence)
      this.appendCommitted(instruction, false, animate)
    }
    this.rebuild()
  }

  trimQueue() {
    const ordered = [...this.queuedEvents.keys()].sort((left, right) => left - right)
    for (const sequence of ordered.slice(0, -maximumEvents)) this.queuedEvents.delete(sequence)
  }

  notifyViewport() {
    const liveEdge = this.atLiveEdge()
    if (liveEdge === this.lastLiveEdge) return
    this.lastLiveEdge = liveEdge
    this.onViewportChange({atLiveEdge: liveEdge})
  }
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

function drawCommand(context, command, width, height) {
  context.save()
  if (command.type === "fiber-path") {
    drawFiberPath(context, command)
    context.restore()
    return
  }

  context.strokeStyle = command.stroke ?? "#f3ead4"
  context.fillStyle = command.glow ?? command.stroke ?? "#f3ead4"
  context.lineWidth = 1 + (command.intensity ?? 0.2) * 2
  context.globalAlpha = 0.3 + (command.intensity ?? 0.2) * 0.6
  context.beginPath()

  switch (command.type) {
    case "ambient":
      context.globalAlpha = command.coverage ?? 0.2
      context.fillRect(0, 0, width, height)
      break
    case "ripple":
    case "knot":
    case "glow":
      context.arc(command.x, command.y, command.radius, 0, Math.PI * 2)
      command.type === "glow" ? context.fill() : context.stroke()
      break
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
      context.beginPath()
      context.arc(command.x, command.y, command.radius, 0, Math.PI * 2)
      context.stroke()
      context.beginPath()
      context.arc(command.x, command.y, command.radius * 0.3, 0, Math.PI * 2)
      context.fill()
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
      context.beginPath()
      context.arc(command.x, command.y, command.radius, 0, Math.PI * 2)
      context.stroke()
      context.beginPath()
      context.arc(command.x, command.y, command.radius * 0.3, 0, Math.PI * 2)
      context.fill()
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
      context.beginPath()
      context.globalAlpha = 0.12 + (command.intensity ?? 0.5) * 0.18
      context.arc(command.x, command.y, command.radius, 0, Math.PI * 2)
      context.fill()
      context.beginPath()
      context.globalAlpha = 0.7
      context.arc(command.x, command.y, Math.max(2.5, command.radius * 0.16), 0, Math.PI * 2)
      context.fill()
      break
    case "illuminate-bloom":
      context.globalAlpha = 0.12 + (command.intensity ?? 0.5) * 0.18
      context.arc(command.x, command.y, command.radius, 0, Math.PI * 2)
      context.fill()
      context.beginPath()
      context.globalAlpha = 0.7
      context.arc(command.x, command.y, Math.max(2.5, command.radius * 0.16), 0, Math.PI * 2)
      context.fill()
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
    case "seam":
      context.moveTo(command.x, 0)
      context.lineTo(command.x, height)
      context.stroke()
      break
    default:
      context.moveTo(command.x - 8, command.y)
      context.lineTo(command.x + 8, command.y)
      context.stroke()
  }

  context.restore()
}

function drawFiberPath(context, command) {
  const material = command.material ?? {
    glow: {width: 5, alpha: 0.08},
    body: {width: 2, alpha: 0.42},
    core: {width: 1, alpha: 0.82},
  }
  for (const [layer, style] of Object.entries(material)) {
    context.beginPath()
    context.lineWidth = style.width
    context.globalAlpha = style.alpha
    context.strokeStyle = layer === "glow" ? command.glow : command.stroke
    traceFiberSegments(context, command.segments)
    context.stroke()
  }
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

  context.save()
  context.fillStyle = "#f5ecd8"
  context.globalAlpha = 0.92
  context.beginPath()
  context.arc(viewport.width - 14, laneToY(lane, viewport), 3.5, 0, Math.PI * 2)
  context.fill()
  context.restore()
}

function drawSelectionHalo(context, commands, selectedSequence) {
  if (!Number.isSafeInteger(selectedSequence)) return
  const command = commands.find(item => item.sequence === selectedSequence && item.hit)
  if (!command) return

  const {hit} = command
  context.save()
  context.strokeStyle = "#f5ecd8"
  context.globalAlpha = 0.54
  context.lineWidth = 1
  context.beginPath()
  context.arc(
    hit.x + hit.width / 2,
    hit.y + hit.height / 2,
    Math.max(hit.width, hit.height) * 0.62,
    0,
    Math.PI * 2,
  )
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
    context.globalAlpha = 0.16
    context.fillStyle = "#f3ead4"
    context.beginPath()
    context.arc(width - 14, y, radius, 0, Math.PI * 2)
    context.fill()
    context.restore()
  }
}
