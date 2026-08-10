import {signalPalette} from "./palette.js"
import {xorshift32} from "./random.js"
import {buildTopology} from "./topology.js"

const supportedRenderVersion = 1
const defaultSpacing = 28
const maximumVisitorBandSpan = 8
const maximumDurableDisplayStep = 8
const visitorBandViewportDivisor = 3
const palettePairs = new Set([
  "wikimedia\0wikimedia",
  "bluesky\0public_activity",
  "ripe_ris\0route_change",
  "solana\0slot",
  "drand\0randomness",
  "usgs\0earthquake",
  "open_meteo\0weather",
  "visitor\0tug",
  "visitor\0knot",
  "visitor\0illuminate",
])
const sourceMaterialRoles = new Set([
  "conversation-fan",
  "route-fork",
  "slot-braid",
  "public-pulse",
])

export function sequenceToX(sequence, viewport) {
  const panOffset = viewport.panOffset ?? 0
  const eventTimePosition = viewport.eventTimePositions?.get(sequence)
  if (Number.isFinite(eventTimePosition)) return eventTimePosition

  const padding = viewport.padding ?? 40
  const spacing = viewport.spacing ?? defaultSpacing
  const displayPosition = viewport.displayPositions?.get(sequence) ?? sequence
  const maxSequence = viewport.maxSequence ?? sequence
  const maxDisplayPosition = viewport.displayPositions?.get(maxSequence) ?? maxSequence
  return viewport.width - padding - (maxDisplayPosition - displayPosition) * spacing + panOffset
}

export function eventTimeToX(
  occurredAt,
  axis,
  viewport,
  {clampToWindow = true} = {},
) {
  const padding = viewport.padding ?? 40
  const usableWidth = Math.max(0, viewport.width - padding * 2)
  const windowEndMilliseconds = Date.parse(axis?.end)
  const durationMilliseconds = Number(axis?.durationMilliseconds)
  const occurredAtMilliseconds = Date.parse(occurredAt)
  if (![windowEndMilliseconds, durationMilliseconds, occurredAtMilliseconds]
    .every(Number.isFinite) || durationMilliseconds <= 0) return padding

  const windowStartMilliseconds = windowEndMilliseconds - durationMilliseconds
  const rawRatio = (occurredAtMilliseconds - windowStartMilliseconds) / durationMilliseconds
  const ratio = clampToWindow ? Math.min(1, Math.max(0, rawRatio)) : rawRatio
  return padding + ratio * usableWidth
}

export function laneToY(lane, viewport) {
  const padding = viewport.padding ?? 40
  const boundedLane = Math.min(1, Math.max(0, Number(lane)))
  return padding + boundedLane * Math.max(0, viewport.height - padding * 2)
}

export function commandsForEvent(instruction, viewport) {
  const x = sequenceToX(instruction.sequence, viewport)
  const y = laneToY(instruction.lane, viewport)
  const palette = paletteForInstruction(instruction)
  const intensity = boundedNumber(instruction.intensity, 0.5)
  const visual = visualParameters(instruction)
  const hitSize = Math.max(20, 22 + intensity * 30)

  const common = {
    sequence: instruction.sequence,
    x,
    y,
    intensity,
    source: instruction.source,
    paletteFamily: palette.family,
    stroke: palette.stroke,
    glow: palette.glow,
    visual,
    hit: {x: x - hitSize / 2, y: y - hitSize / 2, width: hitSize, height: hitSize},
  }

  if (instruction.render_version !== supportedRenderVersion) {
    return [{...common, type: "fallback", contractVersion: supportedRenderVersion}]
  }

  switch (instruction.kind) {
    case "wikimedia":
      return [{...common, type: "fiber", length: 40 + visual.spread * 90}]
    case "earthquake":
      return [{...common, type: "ripple", radius: 10 + intensity * 42}]
    case "weather":
      return [{...common, type: "ambient", coverage: 0.06 + intensity * 0.16}]
    case "tug":
      return [{...common, type: "tug", displacement: 12 + visual.spread * 32}]
    case "knot":
      return [{...common, type: "knot", radius: 7 + intensity * 15}]
    case "illuminate":
      return [{...common, type: "glow", radius: 14 + visual.pulse * 34}]
    default:
      return [{...common, type: "fallback", contractVersion: supportedRenderVersion}]
  }
}

export function chapterSeams(instructions, viewport) {
  let previousDate

  return instructions.flatMap(instruction => {
    const currentDate = utcDate(instruction.occurred_at)
    const seam = previousDate && currentDate !== previousDate
    previousDate = currentDate

    return seam
      ? [{type: "seam", date: currentDate, x: sequenceToX(instruction.sequence, viewport)}]
      : []
  })
}

export function commandsForScene(
  instructions,
  viewport,
  {
    ambient = null,
    projectionInstructions = instructions,
    hitInstructions = instructions,
    axis = null,
    displayInstructions = instructions,
    memoryInstructions = [],
    historyInstructions = [],
    scaffoldInstructions = [],
  } = {},
) {
  const currentDisplayInstructions = validTimeAxis(axis)
    ? displayInstructions.filter(instruction => withinTimeAxis(instruction, axis))
    : displayInstructions
  const currentDisplaySequences = new Set(
    currentDisplayInstructions.map(instruction => instruction.sequence),
  )
  const expiredDisplaySequences = new Set(
    displayInstructions
      .filter(instruction => !currentDisplaySequences.has(instruction.sequence))
      .map(instruction => instruction.sequence),
  )
  const withoutExpiredDisplay = collection => collection.filter(
    instruction => !expiredDisplaySequences.has(instruction.sequence),
  )
  const ordered = uniqueInstructions(withoutExpiredDisplay(instructions))
  const projectionOrdered = uniqueInstructions(withoutExpiredDisplay(projectionInstructions))
  const hitOrdered = uniqueInstructions(withoutExpiredDisplay(hitInstructions))
  const maxSequence = viewport.maxSequence ?? ordered.at(-1)?.sequence ?? ambient?.sequence ?? 0
  const projectedViewport = {
    ...viewport,
    maxSequence,
    displayPositions: displayPositionsFor(projectionOrdered, viewport),
    eventTimePositions: validTimeAxis(axis)
      ? eventTimePositionsFor(
          currentDisplayInstructions,
          historyInstructions,
          scaffoldInstructions,
          axis,
          viewport,
        )
      : null,
  }
  const topology = buildTopology(ordered)
  const topologySequences = new Set(ordered.map(instruction => instruction.sequence))
  const contextualMemory = memoryInstructions.filter(
    instruction => !topologySequences.has(instruction.sequence),
  )
  const ambientInstruction = topology.ambient ?? ambient
  const ambientCommands = ambientInstruction
    ? commandsForEvent(ambientInstruction, projectedViewport)
    : []

  return [
    ...ambientCommands,
    ...contextualMemoryCommands(contextualMemory, viewport),
    ...chapterSeams(ordered, projectedViewport),
    ...spineCommands(topology, projectedViewport),
    ...capillaryCommands(topology, projectedViewport),
    ...fiberCommands(topology, projectedViewport),
    ...formationCommands(topology, projectedViewport),
    ...topology.fallbacks.map(fallback => fallbackCommand(fallback, projectedViewport)),
    ...hitOrdered.map(instruction => hitCommand(instruction, projectedViewport)),
  ]
}

function contextualMemoryCommands(instructions, viewport) {
  const ordered = uniqueInstructionsInInputOrder(instructions, 4)
  if (ordered.length === 0) return []

  const padding = viewport.padding ?? 40
  const bandTop = viewport.height - padding + Math.min(8, padding * 0.2)
  const bandBottom = viewport.height - Math.min(8, padding * 0.2)
  const bandHeight = Math.max(0, bandBottom - bandTop)
  const usableWidth = Math.max(0, viewport.width - padding * 2)
  const traces = ordered.map((instruction, index) => {
    const x = padding + usableWidth * ((index + 1) / (ordered.length + 1))
    const y = bandTop + bandHeight / 2
    const intensity = boundedNumber(instruction.intensity, 0.5)
    const palette = paletteForInstruction(instruction)
    const hitSize = Math.max(20, 22 + intensity * 18)

    return {
      type: "memory-trace",
      role: "contextual-memory",
      sequence: instruction.sequence,
      occurredAt: instruction.occurred_at,
      x,
      y,
      intensity,
      source: instruction.source,
      paletteFamily: palette.family,
      stroke: palette.stroke,
      glow: palette.glow,
      visual: visualParameters(instruction),
      hit: {x: x - hitSize / 2, y: y - hitSize / 2, width: hitSize, height: hitSize},
    }
  })

  return [{
    type: "memory-band",
    role: "contextual-memory",
    label: "Earlier traces",
    x: padding,
    y: bandTop,
    width: usableWidth,
    height: bandHeight,
  }, ...traces]
}

function validTimeAxis(axis) {
  return Number.isFinite(Date.parse(axis?.end)) &&
    Number.isFinite(Number(axis?.durationMilliseconds)) &&
    Number(axis.durationMilliseconds) > 0
}

function withinTimeAxis(instruction, axis) {
  const occurredAtMilliseconds = Date.parse(instruction?.occurred_at)
  const windowEndMilliseconds = Date.parse(axis.end)
  const durationMilliseconds = Number(axis.durationMilliseconds)
  if (![occurredAtMilliseconds, windowEndMilliseconds].every(Number.isFinite)) return false
  const occurredAtSecond = Math.floor(occurredAtMilliseconds / 1000) * 1000
  const windowEndSecond = Math.floor(windowEndMilliseconds / 1000) * 1000
  return occurredAtSecond >= windowEndSecond - durationMilliseconds &&
    occurredAtSecond <= windowEndSecond
}

function eventTimePositionsFor(
  displayInstructions,
  historyInstructions,
  scaffoldInstructions,
  axis,
  viewport,
) {
  const positions = new Map()
  for (const instruction of displayInstructions) {
    positions.set(instruction.sequence, eventTimeToX(instruction.occurred_at, axis, viewport))
  }
  for (const instruction of [...historyInstructions, ...scaffoldInstructions]) {
    positions.set(
      instruction.sequence,
      eventTimeToX(instruction.occurred_at, axis, viewport, {clampToWindow: false}),
    )
  }
  return positions
}

export function catmullRomToBezier(previous, from, to, next) {
  const alpha = 0.5
  const t0 = 0
  const t1 = t0 + Math.max(distance(previous, from) ** alpha, 0.0001)
  const t2 = t1 + Math.max(distance(from, to) ** alpha, 0.0001)
  const t3 = t2 + Math.max(distance(to, next) ** alpha, 0.0001)
  const interval = t2 - t1
  const fromTangent = scaleVector(catmullTangent(previous, from, to, t0, t1, t2), interval)
  const toTangent = scaleVector(catmullTangent(from, to, next, t1, t2, t3), interval)

  return {
    from,
    control1: addVector(from, scaleVector(fromTangent, 1 / 3)),
    control2: addVector(to, scaleVector(toTangent, -1 / 3)),
    to,
  }
}

export function cubicPrefix(curve, progress) {
  const bounded = Math.min(1, Math.max(0, progress))
  const first = interpolate(curve.from, curve.control1, bounded)
  const second = interpolate(curve.control1, curve.control2, bounded)
  const third = interpolate(curve.control2, curve.to, bounded)
  const fourth = interpolate(first, second, bounded)
  const fifth = interpolate(second, third, bounded)

  return {
    from: curve.from,
    control1: first,
    control2: fourth,
    to: interpolate(fourth, fifth, bounded),
  }
}

function spineCommands(topology, viewport) {
  if (topology.spine.length < 2) return []

  const points = topology.spine.map(point => projectAnchor(point, viewport))
  const segments = topology.spine.slice(1).map((point, index) => {
    const previous = points[Math.max(0, index - 1)]
    const from = points[index]
    const to = points[index + 1]
    const next = points[Math.min(points.length - 1, index + 2)]
    const curve = clampCurve(catmullRomToBezier(previous, from, to, next), viewport)
    const intensity = boundedNumber(point.intensity, 0.5)

    return {
      id: `spine-edge:${point.sequence}`,
      sequence: point.sequence,
      transitionSequence: point.sequence,
      curve,
      length: approximateCurveLength(curve),
      intensity,
      visual: boundedVisualParameters(point.visual),
    }
  })
  const intensity = average(segments.map(segment => segment.intensity))

  return [{
    type: "fiber-path",
    id: `path:spine:${topology.spine[0].sequence}:${topology.spine.at(-1).sequence}`,
    role: "spine",
    sequence: topology.spine.at(-1).sequence,
    segments,
    stroke: signalPalette.wikimedia.stroke,
    glow: signalPalette.wikimedia.glow,
    source: "wikimedia",
    paletteFamily: signalPalette.wikimedia.family,
    intensity,
    material: materialFor("spine", intensity),
  }]
}

function capillaryCommands(topology, viewport) {
  const spineBySequence = new Map(topology.spine.map(point => [point.sequence, point]))

  return topology.anchors.flatMap(anchor => {
    const spinePoint = spineBySequence.get(anchor.sequence)
    if (!spinePoint || Math.abs(anchor.lane - spinePoint.lane) < 0.06) return []

    const curve = connectorCurve(
      projectAnchor(spinePoint, viewport),
      projectAnchor(anchor, viewport),
      anchor.visual,
      viewport,
    )
    const intensity = boundedNumber(anchor.intensity, 0.5)
    const segment = {
      id: `capillary:${anchor.sequence}`,
      sequence: anchor.sequence,
      transitionSequence: anchor.sequence,
      curve,
      length: approximateCurveLength(curve),
      intensity,
      visual: boundedVisualParameters(anchor.visual),
    }

    return [{
      type: "fiber-path",
      id: `path:capillary:${anchor.sequence}`,
      role: "capillary",
      sequence: anchor.sequence,
      segments: [segment],
      stroke: signalPalette.wikimedia.stroke,
      glow: signalPalette.wikimedia.glow,
      source: "wikimedia",
      paletteFamily: signalPalette.wikimedia.family,
      intensity,
      material: materialFor("capillary", intensity),
    }]
  })
}

function fiberCommands(topology, viewport) {
  const anchorsById = new Map(topology.anchors.map(anchor => [anchor.id, anchor]))
  const fiberEdges = topology.edges.filter(edge => edge.role === "fiber")
  const edgesByBranch = Map.groupBy(fiberEdges, edge => edge.branchId)
  const paths = []

  for (const [branchId, edges] of edgesByBranch) {
    const orderedEdges = [...edges].sort((left, right) => left.sequence - right.sequence)
    const branchAnchors = branchAnchorChain(orderedEdges, anchorsById)
    const segments = orderedEdges.map((edge, index) => {
      const previous = projectAnchor(branchAnchors[Math.max(0, index)], viewport)
      const from = projectAnchor(branchAnchors[index + 1], viewport)
      const to = projectAnchor(branchAnchors[index + 2], viewport)
      const next = projectAnchor(
        branchAnchors[Math.min(branchAnchors.length - 1, index + 3)],
        viewport,
      )
      const curve = clampCurve(catmullRomToBezier(previous, from, to, next), viewport)
      const target = anchorsById.get(edge.to)
      const intensity = boundedNumber(target.intensity, 0.5)

      return {
        id: edge.id,
        sequence: edge.sequence,
        transitionSequence: edge.sequence,
        curve,
        length: approximateCurveLength(curve),
        intensity,
        visual: boundedVisualParameters(target.visual),
      }
    })

    for (const chunk of chunkSegments(segments, viewport.width)) {
      const target = anchorsById.get(orderedEdges.find(edge => edge.id === chunk.at(-1).id).to)
      const palette = paletteFor(target.source, signalPalette.wikimedia)
      const intensity = average(chunk.map(segment => segment.intensity))
      paths.push({
        type: "fiber-path",
        id: `path:${branchId}:${chunk[0].sequence}:${chunk.at(-1).sequence}`,
        branchId,
        sequence: chunk.at(-1).sequence,
        segments: chunk,
        width: pathWidth(chunk),
        stroke: palette.stroke,
        glow: palette.glow,
        source: target.source,
        paletteFamily: palette.family,
        intensity,
        material: materialFor("fiber", intensity),
      })
    }
  }

  return [...paths, ...connectorCommands(topology, anchorsById, viewport)]
}

function branchAnchorChain(edges, anchorsById) {
  if (edges.length === 0) return []
  return [
    anchorsById.get(edges[0].from),
    anchorsById.get(edges[0].from),
    ...edges.map(edge => anchorsById.get(edge.to)),
  ]
}

function connectorCommands(topology, anchorsById, viewport) {
  return topology.edges
    .filter(edge => edge.role === "connector")
    .map(edge => {
      const from = projectAnchor(anchorsById.get(edge.from), viewport)
      const target = anchorsById.get(edge.to)
      const to = projectAnchor(target, viewport)
      const curve = connectorCurve(from, to, target?.visual, viewport)
      const palette = paletteFor(target?.source, signalPalette.wikimedia)
      const intensity = boundedNumber(target?.intensity, 0.5)
      const segment = {
        id: edge.id,
        role: edge.role,
        sequence: edge.sequence,
        transitionSequence: edge.sequence,
        curve,
        length: approximateCurveLength(curve),
        intensity,
        visual: boundedVisualParameters(target?.visual),
      }

      return {
        type: "fiber-path",
        role: edge.role,
        id: `path:${edge.id}`,
        branchId: edge.branchId,
        sequence: edge.sequence,
        segments: [segment],
        width: pathWidth([segment]),
        stroke: palette.stroke,
        glow: palette.glow,
        source: target?.source ?? "wikimedia",
        paletteFamily: palette.family,
        intensity: segment.intensity,
        material: materialFor(edge.role, segment.intensity),
      }
    })
}

function formationCommands(topology, viewport) {
  const anchorsById = new Map(topology.anchors.map(anchor => [anchor.id, anchor]))
  const spineById = new Map(topology.spine.map(point => [point.id, point]))
  const edgesById = new Map(topology.edges.map(edge => [edge.id, edge]))

  return topology.formations.flatMap(formation => {
    const palette = paletteFor(formation.source)
    const intensity = boundedNumber(formation.intensity, 0.5)
    const visual = boundedVisualParameters(formation.visual)
    const common = {
      id: formation.id,
      sequence: formation.sequence,
      transitionSequence: formation.sequence,
      occurredAt: formation.occurredAt,
      source: formation.source,
      role: formation.role,
      intensity,
      visual,
      paletteFamily: palette.family,
      stroke: palette.stroke,
      glow: palette.glow,
    }

    if (sourceMaterialRoles.has(formation.role)) {
      return [sourceMaterialCommand(common, formation, anchorsById, spineById, viewport)]
    }

    switch (formation.kind) {
      case "earthquake": {
        const point = formationPoint(formation, formation.anchorId, anchorsById, viewport)
        return [{...common, type: "ripple", ...point, radius: 10 + intensity * 42}]
      }
      case "tug":
        return [tugCommand(common, formation, anchorsById, viewport)]
      case "knot":
        return [knotCommand(common, formation, anchorsById, edgesById, viewport)]
      case "illuminate": {
        const point = formationPoint(formation, formation.anchorId, anchorsById, viewport)
        return [{
          ...common,
          type: "illuminate-bloom",
          ...point,
          radius: 14 + visual.pulse * 34,
          glowCurves: illuminationCurves(
            {...formation, visual},
            topology.edges,
            anchorsById,
            viewport,
          ),
        }]
      }
      default:
        return []
    }
  })
}

function sourceMaterialCommand(common, formation, anchorsById, spineById, viewport) {
  const anchor = anchorsById.get(formation.anchorId)
  const attachment = spineById.get(formation.attachmentSpineId)
  const x = sequenceToX(formation.sequence, viewport)
  const y = sourceRoleY(formation.role, anchor?.lane ?? formation.lane, viewport)
  const width = boundedRange(formation.grammar.width, 0.5, 8, 1)
  const structural = {
    ...common,
    type: formation.role,
    x,
    y,
    attachment: attachment ? projectAnchor(attachment, viewport) : null,
    pathStyle: formation.grammar.pathStyle,
    markerStyle: formation.grammar.markerStyle,
    rhythm: formation.grammar.rhythm,
    width,
    material: sourceMaterialFor(width, common.intensity),
  }

  switch (formation.role) {
    case "conversation-fan":
      return conversationFanCommand(structural, formation, viewport)
    case "route-fork":
      return routeForkCommand(structural, formation, viewport)
    case "slot-braid":
      return slotBraidCommand(structural, formation, viewport)
    default:
      return publicPulseCommand(structural, formation, viewport)
  }
}

function conversationFanCommand(common, formation, viewport) {
  const branchSpan = 14 + common.intensity * 20
  const branches = formation.branches.slice(0, 8).map((branch, index) => {
    const branchY = sourceRoleY("conversation-fan", branch.lane, viewport)
    const direction = index % 2 === 0 ? 1 : -1
    const end = materialPoint(common.x + branchSpan, branchY, common, viewport)
    const curve = {
      from: materialPoint(common.x, common.y, common, viewport),
      control1: materialPoint(
        common.x + branchSpan * 0.3,
        common.y + direction * (4 + common.visual.spread * 8),
        common,
        viewport,
      ),
      control2: materialPoint(
        common.x + branchSpan * 0.68,
        branchY - direction * (3 + common.visual.pulse * 5),
        common,
        viewport,
      ),
      to: end,
    }

    return {
      id: branch.id,
      order: branch.order,
      returns: Boolean(branch.returns),
      curve,
      returnPoint: branch.returns
        ? materialPoint(common.x + branchSpan * 0.46, common.y, common, viewport)
        : null,
    }
  })

  return {...common, branches}
}

function routeForkCommand(common, formation, viewport) {
  const forkSpan = 13 + common.intensity * 21
  const segments = formation.segments.slice(0, 6).map(segment => {
    const angularOffset = segment.angle * (18 + common.visual.spread * 12)
    const extendedY = common.y + angularOffset
    const pinch = boundedRange(segment.withdrawalControl?.amount, 0, 1, 0)
    const pinchedY = extendedY + (common.y - extendedY) * pinch * 0.72

    return {
      id: segment.id,
      order: segment.order,
      withdrawal: "inward",
      points: [
        materialPoint(common.x, common.y, common, viewport),
        materialPoint(common.x + forkSpan * 0.48, extendedY, common, viewport),
        materialPoint(common.x + forkSpan, pinchedY, common, viewport),
      ],
    }
  })

  return {...common, segments}
}

function slotBraidCommand(common, formation, viewport) {
  const beads = formation.beads.slice(0, 12)
  const halfSpan = 10 + common.intensity * 13
  const projectedBeads = beads.map(bead => {
    const x = common.x - halfSpan + bead.position * halfSpan * 2
    const y = common.y + (bead.slotOrder % 2 === 0 ? -4 : 4)
    return {
      id: bead.id,
      slotOrder: bead.slotOrder,
      ...materialPoint(x, y, common, viewport),
      radius: 1.8 + common.intensity * 1.5,
    }
  })
  const gapMarkers = formation.gapMarkers.slice(0, 11).map(marker => {
    const left = projectedBeads[marker.afterSlotOrder]
    const right = projectedBeads[marker.afterSlotOrder + 1]
    return {
      id: marker.id,
      afterSlotOrder: marker.afterSlotOrder,
      ...materialPoint(
        ((left?.x ?? common.x) + (right?.x ?? common.x)) / 2,
        common.y,
        common,
        viewport,
      ),
      size: 3 + common.intensity * 2,
    }
  })
  const strands = [0, 1].map(strand => projectedBeads.map(bead => ({
    x: bead.x,
    y: boundedCanvasY(bead.y + (strand === 0 ? -2.5 : 2.5), viewport),
  })))

  return {...common, beads: projectedBeads, gapMarkers, strands}
}

function publicPulseCommand(common, formation, viewport) {
  const crystals = formation.pulses.slice(0, 1).map(pulse => {
    const radius = 8 + common.intensity * 8
    const points = [
      [0, -radius],
      [radius * 0.72, 0],
      [0, radius],
      [-radius * 0.72, 0],
      [0, -radius],
    ].map(([xOffset, yOffset]) =>
      materialPoint(common.x + xOffset, common.y + yOffset, common, viewport)
    )

    return {id: pulse.id, order: pulse.order, round: pulse.round, points}
  })

  return {...common, crystals}
}

function sourceRoleY(role, lane, viewport) {
  const mobileLane = viewport.width <= 480
    ? {
        "conversation-fan": 0.2,
        "route-fork": 0.4,
        "public-pulse": 0.56,
        "slot-braid": 0.7,
      }[role]
    : null
  if (Number.isFinite(mobileLane)) return laneToY(mobileLane, viewport)

  const laneOffset = {
    "conversation-fan": -0.12,
    "route-fork": -0.04,
    "slot-braid": 0.06,
    "public-pulse": 0.14,
  }[role] ?? 0
  return laneToY(boundedRange(lane + laneOffset, 0, 1, 0.5), viewport)
}

function materialPoint(x, y, command, viewport) {
  const padding = viewport.padding ?? 40
  const liveColumn = command.x >= padding && command.x <= viewport.width - padding
  return {
    x: liveColumn
      ? Math.min(viewport.width - padding, Math.max(padding, x))
      : x,
    y: boundedCanvasY(y, viewport),
  }
}

function boundedCanvasY(y, viewport) {
  const padding = viewport.padding ?? 40
  return Math.min(viewport.height - padding, Math.max(padding, y))
}

function tugCommand(common, formation, anchorsById, viewport) {
  const affected = formation.affectedAnchorIds.map(id => anchorsById.get(id)).filter(Boolean)
  return {
    ...common,
    type: "tug-response",
    x: sequenceToX(formation.sequence, viewport),
    y: laneToY(formation.lane, viewport),
    affectedAnchorIds: affected.map(anchor => anchor.id),
    before: affected.map((anchor, index) => ({
      x: sequenceToX(anchor.sequence, viewport),
      y: laneToY(formation.beforeLanes[index], viewport),
    })),
    after: affected.map(anchor => projectAnchor(anchor, viewport)),
  }
}

function knotCommand(common, formation, anchorsById, edgesById, viewport) {
  const edge = edgesById.get(formation.edgeId)
  const loopAnchor = anchorsById.get(formation.loopAnchorId)
  const from = edge
    ? projectAnchor(anchorsById.get(edge.from), viewport)
    : formationPoint(formation, loopAnchor?.id, anchorsById, viewport)
  const to = edge ? projectAnchor(anchorsById.get(edge.to), viewport) : from
  const curve = edge
    ? connectorCurve(from, to, common.visual, viewport)
    : loopCurve(from, common.intensity, viewport)
  const crossover = cubicPrefix(curve, 0.5).to

  return {
    ...common,
    type: "knot-connector",
    curve,
    x: crossover.x,
    y: crossover.y,
    radius: 7 + common.intensity * 15,
    loop: !edge,
  }
}

function formationPoint(formation, anchorId, anchorsById, viewport) {
  const anchor = anchorsById.get(anchorId)
  return {
    x: sequenceToX(formation.sequence, viewport),
    y: laneToY(anchor?.lane ?? formation.lane, viewport),
  }
}

function illuminationCurves(formation, edges, anchorsById, viewport) {
  const anchor = anchorsById.get(formation.anchorId)
  if (!anchor) return []

  const point = formationPoint(formation, anchor.id, anchorsById, viewport)
  return edges
    .filter(edge => edge.from === anchor.id || edge.to === anchor.id)
    .sort((left, right) => right.sequence - left.sequence || left.id.localeCompare(right.id))
    .slice(0, 3)
    .map(edge => {
      const neighborId = edge.from === anchor.id ? edge.to : edge.from
      return connectorCurve(point, projectAnchor(anchorsById.get(neighborId), viewport), formation.visual, viewport)
    })
}

function hitCommand(instruction, viewport) {
  const x = sequenceToX(instruction.sequence, viewport)
  const y = laneToY(boundedNumber(instruction.lane, 0.5), viewport)
  const intensity = boundedNumber(instruction.intensity, 0.5)
  const hitSize = Math.max(20, 22 + intensity * 30)
  return {
    type: "anchor-hit",
    sequence: instruction.sequence,
    source: instruction.source,
    x,
    y,
    hit: {x: x - hitSize / 2, y: y - hitSize / 2, width: hitSize, height: hitSize},
  }
}

function fallbackCommand(fallback, viewport) {
  const palette = paletteFor(fallback.source)
  const x = sequenceToX(fallback.sequence, viewport)
  const y = laneToY(fallback.lane, viewport)
  return {
    type: "fallback",
    contractVersion: supportedRenderVersion,
    sequence: fallback.sequence,
    x,
    y,
    source: fallback.source,
    paletteFamily: palette.family,
    intensity: boundedNumber(fallback.intensity, 0.5),
    visual: boundedVisualParameters(fallback.visual),
    stroke: palette.stroke,
    glow: palette.glow,
  }
}

function projectAnchor(anchor, viewport) {
  if (!anchor) return {x: viewport.padding ?? 40, y: viewport.height / 2}
  return {x: sequenceToX(anchor.sequence, viewport), y: laneToY(anchor.lane, viewport)}
}

function connectorCurve(from, to, visual = {}, viewport) {
  const bend = boundedNumber(visual?.bend, 0)
  const delta = {x: to.x - from.x, y: to.y - from.y}
  const normal = normalizeVector({x: -delta.y, y: delta.x})
  const offset = bend * Math.min(48, Math.hypot(delta.x, delta.y) * 0.2)

  return clampCurve({
    from,
    control1: {
      x: from.x + delta.x / 3 + normal.x * offset,
      y: from.y + delta.y / 3 + normal.y * offset,
    },
    control2: {
      x: from.x + delta.x * 2 / 3 + normal.x * offset,
      y: from.y + delta.y * 2 / 3 + normal.y * offset,
    },
    to,
  }, viewport)
}

function loopCurve(point, intensity, viewport) {
  const radius = 12 + boundedNumber(intensity, 0.5) * 18
  return clampCurve({
    from: point,
    control1: {x: point.x - radius, y: point.y - radius},
    control2: {x: point.x + radius, y: point.y - radius},
    to: {x: point.x, y: point.y + 0.01},
  }, viewport)
}

function chunkSegments(segments, viewportWidth) {
  const minimumWidth = viewportWidth * 0.35
  const maximumWidth = viewportWidth * 0.65
  const chunks = []
  let current = []

  for (const segment of segments) {
    const candidate = [...current, segment]
    if (current.length > 0 && pathWidth(candidate) > maximumWidth) {
      chunks.push(current)
      current = [segment]
    } else {
      current = candidate
    }

    if (pathWidth(current) >= minimumWidth) {
      chunks.push(current)
      current = []
    }
  }

  if (current.length > 0) {
    const previous = chunks.at(-1)
    if (previous && pathWidth([...previous, ...current]) <= maximumWidth) {
      chunks[chunks.length - 1] = [...previous, ...current]
    } else {
      chunks.push(current)
    }
  }

  return chunks
}

function pathWidth(segments) {
  if (segments.length === 0) return 0
  return Math.abs(segments.at(-1).curve.to.x - segments[0].curve.from.x)
}

function clampCurve(curve, viewport) {
  return {
    from: clampPoint(curve.from, viewport),
    control1: clampPoint(curve.control1, viewport),
    control2: clampPoint(curve.control2, viewport),
    to: clampPoint(curve.to, viewport),
  }
}

function clampPoint(point, viewport) {
  const padding = viewport.padding ?? 40
  return {
    x: point.x,
    y: Math.min(viewport.height - padding, Math.max(padding, point.y)),
  }
}

function approximateCurveLength(curve) {
  let length = 0
  let previous = curve.from
  for (let index = 1; index <= 12; index++) {
    const point = cubicPoint(curve, index / 12)
    length += distance(previous, point)
    previous = point
  }
  return length
}

function cubicPoint(curve, progress) {
  const inverse = 1 - progress
  return {
    x: inverse ** 3 * curve.from.x + 3 * inverse ** 2 * progress * curve.control1.x + 3 * inverse * progress ** 2 * curve.control2.x + progress ** 3 * curve.to.x,
    y: inverse ** 3 * curve.from.y + 3 * inverse ** 2 * progress * curve.control1.y + 3 * inverse * progress ** 2 * curve.control2.y + progress ** 3 * curve.to.y,
  }
}

function catmullTangent(previous, current, next, t0, t1, t2) {
  return addVector(
    subtractVector(
      divideVector(subtractVector(current, previous), t1 - t0),
      divideVector(subtractVector(next, previous), t2 - t0),
    ),
    divideVector(subtractVector(next, current), t2 - t1),
  )
}

function addVector(left, right) {
  return {x: left.x + right.x, y: left.y + right.y}
}

function subtractVector(left, right) {
  return {x: left.x - right.x, y: left.y - right.y}
}

function scaleVector(vector, amount) {
  return {x: vector.x * amount, y: vector.y * amount}
}

function divideVector(vector, amount) {
  return scaleVector(vector, 1 / amount)
}

function distance(left, right) {
  return Math.hypot(right.x - left.x, right.y - left.y)
}

function interpolate(from, to, progress) {
  return {
    x: from.x + (to.x - from.x) * progress,
    y: from.y + (to.y - from.y) * progress,
  }
}

function normalizeVector(vector) {
  const length = Math.hypot(vector.x, vector.y) || 1
  return {x: vector.x / length, y: vector.y / length}
}

function average(numbers) {
  return numbers.reduce((sum, number) => sum + number, 0) / Math.max(1, numbers.length)
}

function materialFor(role, intensity) {
  const strength = Math.min(1, Math.max(0, intensity))
  const scale = role === "spine" ? 1.45 : role === "capillary" ? 0.58 : 1

  return {
    glow: {width: (7 + strength * 8) * scale, alpha: 0.08 + strength * 0.08},
    body: {width: (2.6 + strength * 2.8) * scale, alpha: 0.28 + strength * 0.22},
    core: {width: (0.7 + strength * 0.9) * scale, alpha: 0.72 + strength * 0.2},
  }
}

function sourceMaterialFor(width, intensity) {
  const strength = Math.min(1, Math.max(0, intensity))

  return {
    glow: {width: width * (3.4 + strength * 1.2), alpha: 0.08 + strength * 0.08},
    body: {width: width * (1.55 + strength * 0.35), alpha: 0.28 + strength * 0.22},
    core: {width, alpha: 0.72 + strength * 0.2},
  }
}

function visualParameters(instruction) {
  if (validVisual(instruction.visual)) return boundedVisualParameters(instruction.visual)

  const random = xorshift32(instruction.seed)
  return {
    spread: roundSix(random.nextFloat()),
    bend: roundSix(random.nextFloat() * 2 - 1),
    pulse: roundSix(random.nextFloat()),
  }
}

function validVisual(visual) {
  return visual && [visual.spread, visual.bend, visual.pulse].every(Number.isFinite)
}

function boundedVisualParameters(visual) {
  return {
    spread: boundedNumber(visual?.spread, 0.5),
    bend: boundedSignedNumber(visual?.bend, 0),
    pulse: boundedNumber(visual?.pulse, 0.5),
  }
}

function uniqueInstructions(instructions) {
  const bySequence = new Map()
  for (const instruction of instructions) bySequence.set(instruction.sequence, instruction)
  return [...bySequence.values()].sort((left, right) => left.sequence - right.sequence)
}

function uniqueInstructionsInInputOrder(instructions, limit) {
  const seenSequences = new Set()
  const unique = []

  for (const instruction of instructions) {
    if (seenSequences.has(instruction.sequence)) continue
    seenSequences.add(instruction.sequence)
    unique.push(instruction)
    if (unique.length === limit) break
  }

  return unique
}

function displayPositionsFor(instructions, viewport) {
  const positions = new Map()
  if (instructions.length === 0) return positions

  let previousSequence = instructions[0].sequence
  let previousPosition = previousSequence
  positions.set(previousSequence, previousPosition)

  for (let index = 1; index < instructions.length;) {
    if (instructions[index].source !== "visitor") {
      const instruction = instructions[index]
      const rawStep = instruction.sequence - previousSequence
      previousPosition += Math.min(
        maximumDurableDisplayStep,
        Math.max(1, rawStep),
      )
      previousSequence = instruction.sequence
      positions.set(instruction.sequence, previousPosition)
      index++
      continue
    }

    let runEnd = index
    while (
      runEnd + 1 < instructions.length &&
      instructions[runEnd + 1].source === "visitor"
    ) {
      runEnd++
    }

    const finalVisitorSequence = instructions[runEnd].sequence
    const rawSpan = finalVisitorSequence - previousSequence
    const displaySpan = Math.min(visitorBandSpan(viewport), rawSpan)
    for (let visitorIndex = index; visitorIndex <= runEnd; visitorIndex++) {
      const visitorSequence = instructions[visitorIndex].sequence
      const progress = (visitorSequence - previousSequence) / rawSpan
      positions.set(visitorSequence, previousPosition + displaySpan * progress)
    }

    previousSequence = finalVisitorSequence
    previousPosition += displaySpan
    index = runEnd + 1
  }

  return positions
}

function visitorBandSpan(viewport) {
  const width = Number(viewport.width)
  const padding = Number(viewport.padding ?? 40)
  const spacing = Number(viewport.spacing ?? defaultSpacing)
  if (![width, padding, spacing].every(Number.isFinite) || width <= 0 || spacing <= 0) {
    return maximumVisitorBandSpan
  }

  const usableWidth = Math.max(spacing, width - padding * 2)
  const responsiveSpan = Math.floor(usableWidth / (spacing * visitorBandViewportDivisor))
  return Math.max(1, Math.min(maximumVisitorBandSpan, responsiveSpan))
}

function utcDate(encodedTime) {
  const timestamp = Date.parse(encodedTime)
  return Number.isNaN(timestamp) ? "unknown" : new Date(timestamp).toISOString().slice(0, 10)
}

function boundedNumber(number, fallback) {
  return Number.isFinite(number) ? Math.min(1, Math.max(0, number)) : fallback
}

function boundedRange(number, minimum, maximum, fallback) {
  return Number.isFinite(number) ? Math.min(maximum, Math.max(minimum, number)) : fallback
}

function boundedSignedNumber(number, fallback) {
  return Number.isFinite(number) ? Math.min(1, Math.max(-1, number)) : fallback
}

function paletteFor(source, fallback = signalPalette.visitor) {
  if (typeof source !== "string" || !Object.hasOwn(signalPalette, source)) return fallback
  return signalPalette[source]
}

function paletteForInstruction(instruction, fallback = signalPalette.visitor) {
  if (typeof instruction?.source !== "string" || typeof instruction?.kind !== "string") {
    return fallback
  }
  return palettePairs.has(`${instruction.source}\0${instruction.kind}`)
    ? paletteFor(instruction.source, fallback)
    : fallback
}

function roundSix(number) {
  return Number(number.toFixed(6))
}
