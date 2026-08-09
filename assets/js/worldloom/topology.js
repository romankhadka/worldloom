const maximumInstructions = 600
const laneReach = 0.34
const maximumSequenceGap = 12
const maximumSpineLaneDelta = 0.25
const uint32Maximum = 4_294_967_295
const versionOnePairs = new Set([
  "wikimedia\0wikimedia",
  "usgs\0earthquake",
  "open_meteo\0weather",
  "visitor\0tug",
  "visitor\0knot",
  "visitor\0illuminate",
])
const versionTwoPairs = new Set([
  "bluesky\0public_activity",
  "ripe_ris\0route_change",
  "solana\0slot",
  "drand\0randomness",
])

export function buildTopology(instructions) {
  const topology = {
    spine: [],
    anchors: [],
    edges: [],
    formations: [],
    fallbacks: [],
    ambient: null,
  }

  for (const instruction of uniqueInstructions(instructions).slice(-maximumInstructions)) {
    const support = instructionSupport(instruction)
    if (support === "invalid") {
      topology.fallbacks.push(fallbackFor(instruction, false))
      continue
    }
    if (support === "future") {
      topology.fallbacks.push(fallbackFor(instruction, true))
      continue
    }

    switch (instruction.kind) {
      case "wikimedia":
        extendSpine(topology, instruction)
        extendFiber(topology, instruction)
        break
      case "earthquake":
        attachEarthquake(topology, instruction)
        break
      case "weather":
        topology.ambient = instruction
        break
      case "tug":
        applyTug(topology, instruction)
        break
      case "knot":
        applyKnot(topology, instruction)
        break
      case "illuminate":
        applyIlluminate(topology, instruction)
        break
      case "public_activity":
      case "route_change":
      case "slot":
      case "randomness":
        topology.fallbacks.push(fallbackFor(instruction, true))
        break
      default:
        topology.fallbacks.push(fallbackFor(instruction, false))
    }
  }

  return topology
}

function attachEarthquake(topology, instruction) {
  const anchor = nearestAnchor(topology.anchors, instruction)
  topology.formations.push({...formationFor(instruction), anchorId: anchor?.id ?? null})
}

function applyTug(topology, instruction) {
  const spineTug = tugSpine(topology, instruction)
  const target = nearestAnchor(topology.anchors, instruction)
  if (!target) {
    topology.formations.push({
      ...formationFor(instruction),
      affectedAnchorIds: [],
      beforeLanes: [],
      afterLanes: [],
      ...spineTug,
    })
    return
  }

  const branchAnchors = topology.anchors
    .filter(anchor => anchor.branchId === target.branchId)
    .sort((left, right) => left.sequence - right.sequence)
  const targetIndex = branchAnchors.findIndex(anchor => anchor.id === target.id)
  const affected = branchAnchors.slice(Math.max(0, targetIndex - 1), targetIndex + 2)
  const beforeLanes = affected.map(anchor => anchor.lane)

  for (const anchor of affected) {
    const neighborWeight = anchor.id === target.id ? 1 : 0.45
    const strength = (0.2 + instruction.intensity * 0.35) * neighborWeight
    const bend = instruction.visual.bend * 0.03 * neighborWeight
    anchor.lane = clampLane(anchor.lane + (instruction.lane - anchor.lane) * strength + bend)
  }

  topology.formations.push({
    ...formationFor(instruction),
    affectedAnchorIds: affected.map(anchor => anchor.id),
    beforeLanes,
    afterLanes: affected.map(anchor => anchor.lane),
    ...spineTug,
  })
}

function tugSpine(topology, instruction) {
  const target = nearestAnchor(topology.spine, instruction)
  if (!target) {
    return {affectedSpineIds: [], beforeSpineLanes: [], afterSpineLanes: []}
  }

  const targetIndex = topology.spine.findIndex(point => point.id === target.id)
  const affected = topology.spine.slice(Math.max(0, targetIndex - 1), targetIndex + 2)
  const beforeSpineLanes = affected.map(point => point.lane)

  for (const point of affected) {
    const neighborWeight = point.id === target.id ? 1 : 0.45
    const strength = (0.16 + instruction.intensity * 0.28) * neighborWeight
    point.lane = clampLane(point.lane + (instruction.lane - point.lane) * strength)
  }

  return {
    affectedSpineIds: affected.map(point => point.id),
    beforeSpineLanes,
    afterSpineLanes: affected.map(point => point.lane),
  }
}

function applyKnot(topology, instruction) {
  const branchAnchors = nearestDistinctBranches(topology.anchors, instruction)
  const formation = formationFor(instruction)

  if (branchAnchors.length >= 2) {
    const [first, second] = branchAnchors
    const edge = {
      id: `edge:knot:${instruction.sequence}`,
      from: first.id,
      to: second.id,
      branchId: `knot:${instruction.sequence}`,
      role: "knot",
      sequence: instruction.sequence,
    }
    topology.edges.push(edge)
    topology.formations.push({...formation, edgeId: edge.id, loopAnchorId: null})
  } else {
    topology.formations.push({
      ...formation,
      edgeId: null,
      loopAnchorId: branchAnchors[0]?.id ?? null,
    })
  }
}

function applyIlluminate(topology, instruction) {
  const anchor = nearestJunction(topology, instruction) ?? nearestAnchor(topology.anchors, instruction)
  topology.formations.push({...formationFor(instruction), anchorId: anchor?.id ?? null})
}

function nearestDistinctBranches(anchors, instruction) {
  const closestByBranch = new Map()

  for (const anchor of anchors) {
    const current = closestByBranch.get(anchor.branchId)
    if (!current || normalizedDistance(anchor, instruction) < normalizedDistance(current, instruction)) {
      closestByBranch.set(anchor.branchId, anchor)
    }
  }

  return [...closestByBranch.values()]
    .sort((left, right) => normalizedDistance(left, instruction) - normalizedDistance(right, instruction) || left.id.localeCompare(right.id))
    .slice(0, 2)
}

function nearestJunction(topology, instruction) {
  const degree = new Map()
  for (const edge of topology.edges) {
    degree.set(edge.from, (degree.get(edge.from) ?? 0) + 1)
    degree.set(edge.to, (degree.get(edge.to) ?? 0) + 1)
  }

  const junctionIds = new Set([...degree].filter(([_id, count]) => count >= 3).map(([id]) => id))
  return nearestAnchor(topology.anchors.filter(anchor => junctionIds.has(anchor.id)), instruction)
}

function formationFor(instruction) {
  return {
    id: `formation:${instruction.sequence}`,
    sequence: instruction.sequence,
    kind: instruction.kind,
    source: instruction.source,
    occurredAt: instruction.occurred_at,
    lane: instruction.lane,
    intensity: instruction.intensity,
    visual: instruction.visual,
  }
}

function clampLane(lane) {
  return Math.min(1, Math.max(0, Number(lane.toFixed(6))))
}

function boundedSpineLane(previousLane, candidateLane) {
  return clampLane(
    Math.min(
      previousLane + maximumSpineLaneDelta,
      Math.max(previousLane - maximumSpineLaneDelta, candidateLane),
    ),
  )
}

function extendSpine(topology, instruction) {
  const previous = topology.spine.at(-1)
  const lane = previous
    ? boundedSpineLane(
        previous.lane,
        previous.lane * 0.76 +
          instruction.lane * 0.24 +
          instruction.visual.bend * 0.012,
      )
    : clampLane(instruction.lane)

  topology.spine.push({
    id: `spine:${instruction.sequence}`,
    sequence: instruction.sequence,
    lane,
    source: instruction.source,
    intensity: instruction.intensity,
    visual: instruction.visual,
  })
}

function extendFiber(topology, instruction) {
  const predecessor = eligiblePredecessor(topology.anchors, instruction)
  const nearest = predecessor ?? nearestAnchor(topology.anchors, instruction)
  const branchId = predecessor?.branchId ?? `branch:${instruction.sequence}`
  const anchor = anchorFor(instruction, branchId)

  topology.anchors.push(anchor)

  if (predecessor) {
    topology.edges.push(edgeFor(predecessor, anchor, branchId, "fiber"))
  } else if (nearest) {
    topology.edges.push(edgeFor(nearest, anchor, branchId, "connector"))
  }
}

function eligiblePredecessor(anchors, instruction) {
  return branchTerminals(anchors)
    .filter(anchor => {
      const sequenceGap = instruction.sequence - anchor.sequence
      const allowedLaneDistance = laneReach + instruction.visual.spread * 0.2
      return sequenceGap > 0 && sequenceGap <= maximumSequenceGap &&
        Math.abs(instruction.lane - anchor.lane) <= allowedLaneDistance
    })
    .sort((left, right) => predecessorRank(left, instruction) - predecessorRank(right, instruction) || left.id.localeCompare(right.id))[0]
}

function branchTerminals(anchors) {
  const terminalByBranch = new Map()
  for (const anchor of anchors) terminalByBranch.set(anchor.branchId, anchor)
  return [...terminalByBranch.values()]
}

function predecessorRank(anchor, instruction) {
  return Math.abs(instruction.lane - anchor.lane) +
    (instruction.sequence - anchor.sequence) * 0.02
}

function nearestAnchor(anchors, instruction) {
  return [...anchors].sort((left, right) => {
    const leftDistance = normalizedDistance(left, instruction)
    const rightDistance = normalizedDistance(right, instruction)
    return leftDistance - rightDistance || left.id.localeCompare(right.id)
  })[0]
}

function normalizedDistance(anchor, instruction) {
  const sequenceDistance = Math.abs(instruction.sequence - anchor.sequence) / maximumSequenceGap
  return Math.hypot(instruction.lane - anchor.lane, sequenceDistance)
}

function anchorFor(instruction, branchId) {
  return {
    id: `anchor:${instruction.sequence}`,
    sequence: instruction.sequence,
    branchId,
    lane: instruction.lane,
    source: instruction.source,
    kind: instruction.kind,
    intensity: instruction.intensity,
    visual: instruction.visual,
  }
}

function edgeFor(from, to, branchId, role) {
  return {
    id: `edge:${from.id}:${to.id}`,
    from: from.id,
    to: to.id,
    branchId,
    role,
    sequence: to.sequence,
  }
}

function instructionSupport(instruction) {
  if (typeof instruction?.source !== "string" || typeof instruction?.kind !== "string") {
    return "invalid"
  }

  const pair = `${instruction?.source}\0${instruction?.kind}`
  const knownPair = versionOnePairs.has(pair) || versionTwoPairs.has(pair)
  if (Number.isSafeInteger(instruction?.render_version) &&
      instruction.render_version > 2 && knownPair) return "future"

  if (!validLegacyInstructionFields(instruction)) return "invalid"
  if (instruction.render_version === 1 && versionOnePairs.has(pair)) return "supported"
  if (instruction.render_version === 2 &&
      versionTwoPairs.has(pair) &&
      validVersionTwoInstructionFields(instruction) &&
      validVersionTwoMetrics(instruction.source, instruction.metrics)) return "supported"

  return "invalid"
}

function validLegacyInstructionFields(instruction) {
  return instruction &&
    Number.isSafeInteger(instruction.sequence) &&
    instruction.sequence > 0 &&
    boundedUnitNumber(instruction.lane) &&
    Number.isFinite(instruction.intensity) &&
    finiteVisual(instruction.visual)
}

function validVersionTwoInstructionFields(instruction) {
  return boundedUnitNumber(instruction.intensity) && boundedVisual(instruction.visual)
}

function validVersionTwoMetrics(source, metrics) {
  if (!metrics || typeof metrics !== "object" || Array.isArray(metrics)) return false

  switch (source) {
    case "bluesky":
      return validWindowMetrics(
        metrics,
        [
          "window_count",
          "window_span_seconds",
          "total_actions",
          "original_posts",
          "replies",
          "reposts",
          "creates",
          "updates",
          "deletes",
        ],
        ["truncated"],
      )
    case "ripe_ris":
      return validWindowMetrics(
        metrics,
        [
          "window_count",
          "window_span_seconds",
          "announced",
          "withdrawn",
          "ipv4",
          "ipv6",
          "collector_observations",
          "peer_observations",
        ],
        ["truncated"],
      )
    case "solana":
      return exactKeys(metrics, [
        "window_count",
        "window_span_seconds",
        "slot_count",
        "first_slot",
        "last_slot",
        "gap_count",
        "truncated",
      ]) &&
        uint32(metrics.window_count) && metrics.window_count > 0 &&
        uint32(metrics.window_span_seconds) &&
        metrics.window_span_seconds === metrics.window_count * 4 &&
        uint32(metrics.slot_count) && metrics.slot_count > 0 &&
        uint32(metrics.gap_count) &&
        nonNegativeSafeInteger(metrics.first_slot) &&
        nonNegativeSafeInteger(metrics.last_slot) &&
        metrics.first_slot <= metrics.last_slot &&
        ((metrics.slot_count === 1) === (metrics.first_slot === metrics.last_slot)) &&
        metrics.slot_count <= metrics.last_slot - metrics.first_slot + 1 &&
        typeof metrics.truncated === "boolean" &&
        (!metrics.truncated ||
          metrics.slot_count === uint32Maximum ||
          metrics.gap_count === uint32Maximum ||
          metrics.window_count === Math.floor(uint32Maximum / 4))
    case "drand":
      return exactKeys(metrics, ["round"]) &&
        nonNegativeSafeInteger(metrics.round) && metrics.round > 0
    default:
      return false
  }
}

function validWindowMetrics(metrics, numberKeys, booleanKeys = []) {
  return exactKeys(metrics, [...numberKeys, ...booleanKeys]) &&
    numberKeys.every(key => uint32(metrics[key])) &&
    booleanKeys.every(key => typeof metrics[key] === "boolean") &&
    metrics.window_count > 0 &&
    metrics.window_span_seconds === metrics.window_count * 4
}

function exactKeys(object, expectedKeys) {
  const actualKeys = Object.keys(object)
  return actualKeys.length === expectedKeys.length &&
    expectedKeys.every(key => Object.hasOwn(object, key))
}

function uint32(number) {
  return Number.isInteger(number) && number >= 0 && number <= uint32Maximum
}

function nonNegativeSafeInteger(number) {
  return Number.isSafeInteger(number) && number >= 0
}

function fallbackFor(instruction, semantic) {
  return {
    sequence: Number.isSafeInteger(instruction?.sequence) && instruction.sequence > 0
      ? instruction.sequence
      : 0,
    kind: semantic ? instruction.kind : "fallback",
    lane: clampNumber(instruction?.lane, 0, 1, 0.5),
    source: semantic ? instruction.source : "visitor",
    intensity: clampNumber(instruction?.intensity, 0, 1, 0.5),
    visual: {
      spread: clampNumber(instruction?.visual?.spread, 0, 1, 0.5),
      bend: clampNumber(instruction?.visual?.bend, -1, 1, 0),
      pulse: clampNumber(instruction?.visual?.pulse, 0, 1, 0.5),
    },
  }
}

function finiteVisual(visual) {
  return visual && [visual.spread, visual.bend, visual.pulse].every(Number.isFinite)
}

function boundedVisual(visual) {
  return visual &&
    boundedUnitNumber(visual.spread) &&
    Number.isFinite(visual.bend) && visual.bend >= -1 && visual.bend <= 1 &&
    boundedUnitNumber(visual.pulse)
}

function boundedUnitNumber(number) {
  return Number.isFinite(number) && number >= 0 && number <= 1
}

function clampNumber(number, minimum, maximum, fallback) {
  return Number.isFinite(number) ? Math.min(maximum, Math.max(minimum, number)) : fallback
}

function uniqueInstructions(instructions) {
  const bySequence = new Map()
  for (const instruction of Array.isArray(instructions) ? instructions : []) {
    if (Number.isSafeInteger(instruction?.sequence)) bySequence.set(instruction.sequence, instruction)
  }
  return [...bySequence.values()].sort((left, right) => left.sequence - right.sequence)
}
