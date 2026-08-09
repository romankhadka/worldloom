import {grammarFor} from "./source_grammar.js"

const maximumInstructions = 600
const maximumMemoryInstructions = 4
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

function contextualMemoryFor(instructions) {
  const eligible = uniqueInstructions(instructions)
    .filter(instruction =>
      instructionSupport(instruction) === "supported" &&
      (instruction.kind === "earthquake" || instruction.source === "visitor")
    )
  const earthquake = eligible
    .filter(instruction => instruction.kind === "earthquake" && instruction.source === "usgs")
    .sort(newerInstructionFirst)[0]
  const visitors = eligible
    .filter(instruction => instruction.source === "visitor")
    .sort(newerInstructionFirst)
    .slice(0, maximumMemoryInstructions - 1)

  return [...(earthquake ? [earthquake] : []), ...visitors]
    .map(instruction => {
      const grammar = grammarFor(instruction)

      return {
        ...formationFor(instruction, grammar),
        band: "quiet-context",
        anchorId: null,
      }
    })
}

export function buildTopology(instructions, options = {}) {
  const memoryInstructions = ownDataValue(options, "memoryInstructions") ?? []
  const topology = {
    spine: [],
    anchors: [],
    edges: [],
    formations: [],
    fallbacks: [],
    memory: contextualMemoryFor(memoryInstructions),
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

    const grammar = grammarFor(instruction)
    if (grammar.role === "neutral") {
      topology.fallbacks.push(fallbackFor(instruction, false))
      continue
    }

    switch (grammar.role) {
      case "backbone":
        extendSpine(topology, instruction, grammar)
        extendFiber(topology, instruction, grammar)
        break
      case "rupture":
        attachEarthquake(topology, instruction, grammar)
        break
      case "atmosphere":
        topology.ambient = instruction
        break
      case "intervention":
        applyIntervention(topology, instruction, grammar)
        break
      case "conversation-fan":
        attachBlueskyFan(topology, instruction, grammar)
        break
      case "route-fork":
        attachRipeFork(topology, instruction, grammar)
        break
      case "slot-braid":
        attachSolanaBraid(topology, instruction, grammar)
        break
      case "public-pulse":
        attachDrandPulse(topology, instruction, grammar)
        break
      default:
        topology.fallbacks.push(fallbackFor(instruction, false))
    }
  }

  return topology
}

function applyIntervention(topology, instruction, grammar) {
  switch (instruction.kind) {
    case "tug":
      applyTug(topology, instruction, grammar)
      break
    case "knot":
      applyKnot(topology, instruction, grammar)
      break
    case "illuminate":
      applyIlluminate(topology, instruction, grammar)
      break
  }
}

function attachEarthquake(topology, instruction, grammar) {
  const anchor = nearestAnchor(topology.anchors, instruction)
  topology.formations.push({
    ...formationFor(instruction, grammar),
    anchorId: anchor?.id ?? null,
  })
}

function applyTug(topology, instruction, grammar) {
  const spineTug = tugSpine(topology, instruction)
  const target = nearestAnchor(topology.anchors, instruction)
  if (!target) {
    topology.formations.push({
      ...formationFor(instruction, grammar),
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
    ...formationFor(instruction, grammar),
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

function applyKnot(topology, instruction, grammar) {
  const branchAnchors = nearestDistinctBranches(topology.anchors, instruction)
  const formation = formationFor(instruction, grammar)

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

function applyIlluminate(topology, instruction, grammar) {
  const anchor = nearestJunction(topology, instruction) ?? nearestAnchor(topology.anchors, instruction)
  topology.formations.push({
    ...formationFor(instruction, grammar),
    anchorId: anchor?.id ?? null,
  })
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

function attachBlueskyFan(topology, instruction, grammar) {
  const anchor = appendSourceAnchor(topology, instruction, grammar)
  const attachment = nearestAnchor(topology.spine, instruction)
  const branchDivisor = Math.max(1, grammar.branchCount - 1)
  const branches = Array.from({length: grammar.branchCount}, (_entry, index) => {
    const normalizedOffset = grammar.branchCount === 1 ? 0 : index / branchDivisor - 0.5

    return {
      id: `fan:${instruction.sequence}:${index}`,
      order: index,
      lane: clampLane(instruction.lane + normalizedOffset * grammar.divergence * 0.36),
      pathStyle: grammar.pathStyle,
      returns: index < Math.round(grammar.branchCount * grammar.returnStrength),
    }
  })

  topology.formations.push({
    ...formationFor(instruction, grammar),
    anchorId: anchor.id,
    attachmentSpineId: attachment?.id ?? null,
    branches,
  })
}

function attachRipeFork(topology, instruction, grammar) {
  const anchor = appendSourceAnchor(topology, instruction, grammar)
  const attachment = nearestAnchor(topology.spine, instruction)
  const forkDivisor = Math.max(1, grammar.forkCount - 1)
  const segments = Array.from({length: grammar.forkCount}, (_entry, index) => ({
    id: `fork:${instruction.sequence}:${index}`,
    order: index,
    angle: grammar.forkCount === 1
      ? 0
      : (index / forkDivisor - 0.5) * (0.5 + grammar.extension),
    extension: grammar.extension,
    pathStyle: grammar.pathStyle,
    withdrawalControl: {direction: "inward", amount: grammar.pinch},
  }))

  topology.formations.push({
    ...formationFor(instruction, grammar),
    anchorId: anchor.id,
    attachmentSpineId: attachment?.id ?? null,
    segments,
  })
}

function attachSolanaBraid(topology, instruction, grammar) {
  const anchor = appendSourceAnchor(topology, instruction, grammar)
  const attachment = nearestAnchor(topology.spine, instruction)
  const beads = Array.from({length: grammar.beadCount}, (_entry, index) => ({
    id: `bead:${instruction.sequence}:${index}`,
    slotOrder: index,
    position: grammar.beadCount === 1 ? 0.5 : index / (grammar.beadCount - 1),
  }))
  const gapMarkers = Array.from({length: grammar.gapBreakCount}, (_entry, index) => ({
    id: `gap:${instruction.sequence}:${index}`,
    afterSlotOrder: Math.min(
      grammar.beadCount - 2,
      Math.floor(((index + 1) * grammar.beadCount) / (grammar.gapBreakCount + 1)) - 1,
    ),
  }))

  topology.formations.push({
    ...formationFor(instruction, grammar),
    anchorId: anchor.id,
    attachmentSpineId: attachment?.id ?? null,
    slotRange: {
      first: grammar.metrics.first_slot,
      last: grammar.metrics.last_slot,
    },
    beads,
    gapMarkers,
  })
}

function attachDrandPulse(topology, instruction, grammar) {
  const attachment = nearestAnchor(topology.spine, instruction)

  topology.formations.push({
    ...formationFor(instruction, grammar),
    attachmentSpineId: attachment?.id ?? null,
    pulses: [{
      id: `pulse:${instruction.sequence}`,
      order: 0,
      round: grammar.round,
    }],
  })
}

function appendSourceAnchor(topology, instruction, grammar) {
  const anchor = anchorFor(
    instruction,
    `source:${instruction.source}:${instruction.sequence}`,
    grammar,
  )
  topology.anchors.push(anchor)
  return anchor
}

function formationFor(instruction, grammar) {
  return {
    id: `formation:${instruction.sequence}`,
    sequence: instruction.sequence,
    kind: instruction.kind,
    source: instruction.source,
    role: grammar.role,
    grammar,
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

function extendSpine(topology, instruction, grammar) {
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
    grammar,
    intensity: instruction.intensity,
    visual: instruction.visual,
  })
}

function extendFiber(topology, instruction, grammar) {
  const backboneAnchors = topology.anchors.filter(anchor => anchor.source === "wikimedia")
  const predecessor = eligiblePredecessor(backboneAnchors, instruction)
  const nearest = predecessor ?? nearestAnchor(backboneAnchors, instruction)
  const branchId = predecessor?.branchId ?? `branch:${instruction.sequence}`
  const anchor = anchorFor(instruction, branchId, grammar)

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

function anchorFor(instruction, branchId, grammar) {
  return {
    id: `anchor:${instruction.sequence}`,
    sequence: instruction.sequence,
    branchId,
    lane: instruction.lane,
    source: instruction.source,
    kind: instruction.kind,
    grammar,
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
  for (const candidate of ownArrayValues(instructions)) {
    const instruction = rebuildInstruction(candidate)
    if (Number.isSafeInteger(instruction.sequence)) {
      bySequence.set(instruction.sequence, instruction)
    }
  }
  return [...bySequence.values()].sort((left, right) => left.sequence - right.sequence)
}

function rebuildInstruction(candidate) {
  const visual = ownDataValue(candidate, "visual")

  return {
    sequence: ownDataValue(candidate, "sequence"),
    kind: ownDataValue(candidate, "kind"),
    source: ownDataValue(candidate, "source"),
    occurred_at: ownDataValue(candidate, "occurred_at"),
    render_version: ownDataValue(candidate, "render_version"),
    seed: ownDataValue(candidate, "seed"),
    lane: ownDataValue(candidate, "lane"),
    intensity: ownDataValue(candidate, "intensity"),
    visual: {
      spread: ownDataValue(visual, "spread"),
      bend: ownDataValue(visual, "bend"),
      pulse: ownDataValue(visual, "pulse"),
    },
    summary: ownDataValue(candidate, "summary"),
    metrics: rebuildMetricRecord(ownDataValue(candidate, "metrics")),
  }
}

function rebuildMetricRecord(candidate) {
  if (candidate === undefined || candidate === null || typeof candidate !== "object") {
    return candidate
  }

  try {
    if (Array.isArray(candidate)) return []
    const rebuilt = {}

    for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(candidate))) {
      if (!Object.hasOwn(descriptor, "value")) return null
      Object.defineProperty(rebuilt, key, {
        value: descriptor.value,
        enumerable: true,
        configurable: true,
        writable: true,
      })
    }

    return rebuilt
  } catch (_error) {
    return null
  }
}

function ownArrayValues(candidate) {
  try {
    if (!Array.isArray(candidate)) return []

    return Object.entries(Object.getOwnPropertyDescriptors(candidate))
      .filter(([key, descriptor]) => arrayIndex(key) && Object.hasOwn(descriptor, "value"))
      .sort(([left], [right]) => Number(left) - Number(right))
      .map(([_key, descriptor]) => descriptor.value)
  } catch (_error) {
    return []
  }
}

function arrayIndex(key) {
  if (!/^(0|[1-9]\d*)$/.test(key)) return false
  const index = Number(key)
  return Number.isSafeInteger(index) && index >= 0
}

function ownDataValue(candidate, key) {
  if (candidate === null || (typeof candidate !== "object" && typeof candidate !== "function")) {
    return undefined
  }

  try {
    const descriptor = Object.getOwnPropertyDescriptor(candidate, key)
    return descriptor && Object.hasOwn(descriptor, "value") ? descriptor.value : undefined
  } catch (_error) {
    return undefined
  }
}

function newerInstructionFirst(left, right) {
  const leftTime = parsedTime(left.occurred_at)
  const rightTime = parsedTime(right.occurred_at)
  return rightTime - leftTime || right.sequence - left.sequence
}

function parsedTime(timestamp) {
  if (typeof timestamp !== "string") return Number.NEGATIVE_INFINITY
  const milliseconds = Date.parse(timestamp)
  return Number.isFinite(milliseconds) ? milliseconds : Number.NEGATIVE_INFINITY
}
