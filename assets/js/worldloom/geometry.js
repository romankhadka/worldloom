import {xorshift32} from "./random.js"
import {buildTopology} from "./topology.js"

export const signalPalette = Object.freeze({
  wikimedia: {stroke: "#63d7d1", glow: "#b6fff8"},
  usgs: {stroke: "#ec8d55", glow: "#ffc08e"},
  open_meteo: {stroke: "#8ba66d", glow: "#d3bb70"},
  visitor: {stroke: "#f3ead4", glow: "#fff9e9"},
})

const supportedRenderVersion = 1
const defaultSpacing = 28
const maximumVisitorBandSpan = 8

export function sequenceToX(sequence, viewport) {
  const padding = viewport.padding ?? 40
  const spacing = viewport.spacing ?? defaultSpacing
  const displayPosition = viewport.displayPositions?.get(sequence) ?? sequence
  const maxSequence = viewport.maxSequence ?? sequence
  const maxDisplayPosition = viewport.displayPositions?.get(maxSequence) ?? maxSequence
  const panOffset = viewport.panOffset ?? 0
  return viewport.width - padding - (maxDisplayPosition - displayPosition) * spacing + panOffset
}

export function laneToY(lane, viewport) {
  const padding = viewport.padding ?? 40
  const boundedLane = Math.min(1, Math.max(0, Number(lane)))
  return padding + boundedLane * Math.max(0, viewport.height - padding * 2)
}

export function commandsForEvent(instruction, viewport) {
  const x = sequenceToX(instruction.sequence, viewport)
  const y = laneToY(instruction.lane, viewport)
  const palette = signalPalette[instruction.source] ?? signalPalette.visitor
  const intensity = boundedNumber(instruction.intensity, 0.5)
  const visual = visualParameters(instruction)
  const hitSize = Math.max(20, 22 + intensity * 30)

  const common = {
    sequence: instruction.sequence,
    x,
    y,
    intensity,
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
      return [{...common, type: "ambient", coverage: 0.2 + intensity * 0.5}]
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
  {ambient = null, projectionInstructions = instructions, hitInstructions = instructions} = {},
) {
  const ordered = uniqueInstructions(instructions)
  const projectionOrdered = uniqueInstructions(projectionInstructions)
  const hitOrdered = uniqueInstructions(hitInstructions)
  const maxSequence = viewport.maxSequence ?? ordered.at(-1)?.sequence ?? ambient?.sequence ?? 0
  const projectedViewport = {
    ...viewport,
    maxSequence,
    displayPositions: displayPositionsFor(projectionOrdered),
  }
  const topology = buildTopology(ordered)
  const ambientInstruction = topology.ambient ?? ambient
  const ambientCommands = ambientInstruction
    ? commandsForEvent(ambientInstruction, projectedViewport)
    : []

  return [
    ...ambientCommands,
    ...chapterSeams(ordered, projectedViewport),
    ...spineCommands(topology, projectedViewport),
    ...capillaryCommands(topology, projectedViewport),
    ...fiberCommands(topology, projectedViewport),
    ...formationCommands(topology, projectedViewport),
    ...topology.fallbacks.map(fallback => fallbackCommand(fallback, projectedViewport)),
    ...hitOrdered.map(instruction => hitCommand(instruction, projectedViewport)),
  ]
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

    return {
      id: `spine-edge:${point.sequence}`,
      sequence: point.sequence,
      transitionSequence: point.sequence,
      curve,
      length: approximateCurveLength(curve),
      intensity: point.intensity,
      visual: point.visual,
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
    const segment = {
      id: `capillary:${anchor.sequence}`,
      sequence: anchor.sequence,
      transitionSequence: anchor.sequence,
      curve,
      length: approximateCurveLength(curve),
      intensity: anchor.intensity,
      visual: anchor.visual,
    }

    return [{
      type: "fiber-path",
      id: `path:capillary:${anchor.sequence}`,
      role: "capillary",
      sequence: anchor.sequence,
      segments: [segment],
      stroke: signalPalette.wikimedia.stroke,
      glow: signalPalette.wikimedia.glow,
      intensity: anchor.intensity,
      material: materialFor("capillary", anchor.intensity),
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

      return {
        id: edge.id,
        sequence: edge.sequence,
        transitionSequence: edge.sequence,
        curve,
        length: approximateCurveLength(curve),
        intensity: target.intensity,
        visual: target.visual,
      }
    })

    for (const chunk of chunkSegments(segments, viewport.width)) {
      const target = anchorsById.get(orderedEdges.find(edge => edge.id === chunk.at(-1).id).to)
      const palette = signalPalette[target.source] ?? signalPalette.wikimedia
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
      const palette = signalPalette[target?.source] ?? signalPalette.wikimedia
      const segment = {
        id: edge.id,
        role: edge.role,
        sequence: edge.sequence,
        transitionSequence: edge.sequence,
        curve,
        length: approximateCurveLength(curve),
        intensity: target?.intensity ?? 0.5,
        visual: target?.visual ?? {spread: 0.5, bend: 0, pulse: 0.5},
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
        intensity: segment.intensity,
        material: materialFor(edge.role, segment.intensity),
      }
    })
}

function formationCommands(topology, viewport) {
  const anchorsById = new Map(topology.anchors.map(anchor => [anchor.id, anchor]))
  const edgesById = new Map(topology.edges.map(edge => [edge.id, edge]))

  return topology.formations.flatMap(formation => {
    const palette = signalPalette[formation.source] ?? signalPalette.visitor
    const common = {
      id: formation.id,
      sequence: formation.sequence,
      transitionSequence: formation.sequence,
      intensity: formation.intensity,
      visual: formation.visual,
      stroke: palette.stroke,
      glow: palette.glow,
    }

    switch (formation.kind) {
      case "earthquake": {
        const point = formationPoint(formation, formation.anchorId, anchorsById, viewport)
        return [{...common, type: "ripple", ...point, radius: 10 + formation.intensity * 42}]
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
          radius: 14 + formation.visual.pulse * 34,
          glowCurves: illuminationCurves(formation, topology.edges, anchorsById, viewport),
        }]
      }
      default:
        return []
    }
  })
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
    ? connectorCurve(from, to, formation.visual, viewport)
    : loopCurve(from, formation.intensity, viewport)
  const crossover = cubicPrefix(curve, 0.5).to

  return {
    ...common,
    type: "knot-connector",
    curve,
    x: crossover.x,
    y: crossover.y,
    radius: 7 + formation.intensity * 15,
    loop: !edge,
  }
}

function formationPoint(formation, anchorId, anchorsById, viewport) {
  const anchor = anchorsById.get(anchorId)
  return anchor
    ? projectAnchor(anchor, viewport)
    : {x: sequenceToX(formation.sequence, viewport), y: laneToY(formation.lane, viewport)}
}

function illuminationCurves(formation, edges, anchorsById, viewport) {
  const anchor = anchorsById.get(formation.anchorId)
  if (!anchor) return []

  const point = projectAnchor(anchor, viewport)
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
    x,
    y,
    hit: {x: x - hitSize / 2, y: y - hitSize / 2, width: hitSize, height: hitSize},
  }
}

function fallbackCommand(fallback, viewport) {
  const palette = signalPalette[fallback.source] ?? signalPalette.visitor
  const x = sequenceToX(fallback.sequence, viewport)
  const y = laneToY(fallback.lane, viewport)
  return {
    type: "fallback",
    contractVersion: supportedRenderVersion,
    sequence: fallback.sequence,
    x,
    y,
    intensity: fallback.intensity,
    visual: fallback.visual,
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
  const radius = 12 + intensity * 18
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

function visualParameters(instruction) {
  if (validVisual(instruction.visual)) return instruction.visual

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

function uniqueInstructions(instructions) {
  const bySequence = new Map()
  for (const instruction of instructions) bySequence.set(instruction.sequence, instruction)
  return [...bySequence.values()].sort((left, right) => left.sequence - right.sequence)
}

function displayPositionsFor(instructions) {
  const positions = new Map()
  if (instructions.length === 0) return positions

  let previousSequence = instructions[0].sequence
  let previousPosition = previousSequence
  positions.set(previousSequence, previousPosition)

  for (let index = 1; index < instructions.length;) {
    if (instructions[index].source !== "visitor") {
      const instruction = instructions[index]
      previousPosition += instruction.sequence - previousSequence
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
    const displaySpan = Math.min(maximumVisitorBandSpan, rawSpan)
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

function utcDate(encodedTime) {
  const timestamp = Date.parse(encodedTime)
  return Number.isNaN(timestamp) ? "unknown" : new Date(timestamp).toISOString().slice(0, 10)
}

function boundedNumber(number, fallback) {
  return Number.isFinite(number) ? Math.min(1, Math.max(0, number)) : fallback
}

function roundSix(number) {
  return Number(number.toFixed(6))
}
