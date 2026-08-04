const supportedRenderVersion = 1
const maximumInstructions = 600
const laneReach = 0.34
const maximumSequenceGap = 12

export function buildTopology(instructions) {
  const topology = {
    anchors: [],
    edges: [],
    formations: [],
    fallbacks: [],
    ambient: null,
  }

  for (const instruction of uniqueInstructions(instructions).slice(-maximumInstructions)) {
    if (!validInstruction(instruction)) {
      topology.fallbacks.push(fallbackFor(instruction))
      continue
    }

    switch (instruction.kind) {
      case "wikimedia":
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
      default:
        topology.fallbacks.push(fallbackFor(instruction))
    }
  }

  return topology
}

function attachEarthquake(topology, instruction) {
  const anchor = nearestAnchor(topology.anchors, instruction)
  topology.formations.push({...formationFor(instruction), anchorId: anchor?.id ?? null})
}

function applyTug(topology, instruction) {
  const target = nearestAnchor(topology.anchors, instruction)
  if (!target) {
    topology.formations.push({...formationFor(instruction), affectedAnchorIds: [], beforeLanes: [], afterLanes: []})
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
  })
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
    lane: instruction.lane,
    intensity: instruction.intensity,
    visual: instruction.visual,
  }
}

function clampLane(lane) {
  return Math.min(1, Math.max(0, Number(lane.toFixed(6))))
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

function validInstruction(instruction) {
  return instruction &&
    instruction.render_version === supportedRenderVersion &&
    Number.isSafeInteger(instruction.sequence) &&
    instruction.sequence > 0 &&
    Number.isFinite(instruction.lane) &&
    instruction.lane >= 0 &&
    instruction.lane <= 1 &&
    Number.isFinite(instruction.intensity) &&
    instruction.visual &&
    [instruction.visual.spread, instruction.visual.bend, instruction.visual.pulse].every(Number.isFinite)
}

function fallbackFor(instruction) {
  return {
    sequence: Number.isSafeInteger(instruction?.sequence) ? instruction.sequence : 0,
    lane: Number.isFinite(instruction?.lane) ? instruction.lane : 0.5,
    source: instruction?.source ?? "visitor",
    intensity: Number.isFinite(instruction?.intensity) ? instruction.intensity : 0.5,
    visual: validVisual(instruction?.visual)
      ? instruction.visual
      : {spread: 0.5, bend: 0, pulse: 0.5},
  }
}

function validVisual(visual) {
  return visual && [visual.spread, visual.bend, visual.pulse].every(Number.isFinite)
}

function uniqueInstructions(instructions) {
  const bySequence = new Map()
  for (const instruction of Array.isArray(instructions) ? instructions : []) {
    if (Number.isSafeInteger(instruction?.sequence)) bySequence.set(instruction.sequence, instruction)
  }
  return [...bySequence.values()].sort((left, right) => left.sequence - right.sequence)
}
