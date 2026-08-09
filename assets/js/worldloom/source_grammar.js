const uint32Maximum = 4_294_967_295
const jsonSafeMaximum = Number.MAX_SAFE_INTEGER

const metricSchemas = Object.freeze({
  bluesky: Object.freeze({
    integers: Object.freeze([
      "window_count",
      "window_span_seconds",
      "total_actions",
      "original_posts",
      "replies",
      "reposts",
      "creates",
      "updates",
      "deletes",
    ]),
    safeIntegers: Object.freeze([]),
    booleans: Object.freeze(["truncated"]),
  }),
  ripe_ris: Object.freeze({
    integers: Object.freeze([
      "window_count",
      "window_span_seconds",
      "announced",
      "withdrawn",
      "ipv4",
      "ipv6",
      "collector_observations",
      "peer_observations",
    ]),
    safeIntegers: Object.freeze([]),
    booleans: Object.freeze(["truncated"]),
  }),
  solana: Object.freeze({
    integers: Object.freeze([
      "window_count",
      "window_span_seconds",
      "slot_count",
      "gap_count",
    ]),
    safeIntegers: Object.freeze(["first_slot", "last_slot"]),
    booleans: Object.freeze(["truncated"]),
  }),
  drand: Object.freeze({
    integers: Object.freeze([]),
    safeIntegers: Object.freeze(["round"]),
    booleans: Object.freeze([]),
  }),
})

const grammarFactories = new Map([
  [contractKey("wikimedia", "wikimedia", 1), wikimediaGrammar],
  [contractKey("bluesky", "public_activity", 2), blueskyGrammar],
  [contractKey("ripe_ris", "route_change", 2), ripeGrammar],
  [contractKey("solana", "slot", 2), solanaGrammar],
  [contractKey("drand", "randomness", 2), drandGrammar],
  [contractKey("usgs", "earthquake", 1), earthquakeGrammar],
  [contractKey("open_meteo", "weather", 1), weatherGrammar],
  [contractKey("visitor", "tug", 1), visitorGrammar],
  [contractKey("visitor", "knot", 1), visitorGrammar],
  [contractKey("visitor", "illuminate", 1), visitorGrammar],
])

export function grammarFor(instruction) {
  const safeInstruction = rebuildInstruction(instruction)
  const factory = grammarFactory(safeInstruction)
  if (!factory) return neutralGrammar()

  const common = commonParameters(safeInstruction)
  return factory(safeInstruction, common)
}

function grammarFactory(instruction) {
  if (typeof instruction.source !== "string" || typeof instruction.kind !== "string") {
    return null
  }
  if (!Number.isSafeInteger(instruction.render_version) || instruction.render_version <= 0) {
    return null
  }

  return grammarFactories.get(
    contractKey(instruction.source, instruction.kind, instruction.render_version),
  ) ?? null
}

function rebuildInstruction(candidate) {
  const visual = ownDataValue(candidate, "visual")

  return {
    source: ownDataValue(candidate, "source"),
    kind: ownDataValue(candidate, "kind"),
    render_version: ownDataValue(candidate, "render_version"),
    lane: ownDataValue(candidate, "lane"),
    intensity: ownDataValue(candidate, "intensity"),
    visual: {
      spread: ownDataValue(visual, "spread"),
      bend: ownDataValue(visual, "bend"),
      pulse: ownDataValue(visual, "pulse"),
    },
    metrics: ownDataValue(candidate, "metrics"),
  }
}

function contractKey(source, kind, renderVersion) {
  return [source, kind, renderVersion].join("\0")
}

function wikimediaGrammar(_instruction, common) {
  return structuralGrammar({
    role: "backbone",
    pathStyle: "continuous-fine",
    markerStyle: "activity-ridge",
    rhythm: "flowing",
    count: 1,
    width: 0.75 + common.intensity * 2.25,
    common,
    metrics: {},
  })
}

function blueskyGrammar(instruction, common) {
  const metrics = rebuildMetrics("bluesky", instruction.metrics)
  const actionCount = metrics.total_actions
  const denominator = Math.max(1, actionCount)
  const branchCount = boundedInteger(Math.ceil(actionCount / 4), 1, 8, 1)

  return structuralGrammar({
    role: "conversation-fan",
    pathStyle: "branching-fan",
    markerStyle: "reply-tip",
    rhythm: "burst-return",
    count: branchCount,
    width: 0.8 + common.intensity * 1.8,
    common,
    metrics,
    branchCount,
    divergence: boundedNumber(metrics.replies / denominator + common.spread * 0.25, 0, 1, 0),
    returnStrength: boundedNumber(metrics.reposts / denominator, 0, 1, 0),
  })
}

function ripeGrammar(instruction, common) {
  const metrics = rebuildMetrics("ripe_ris", instruction.metrics)
  const routeChanges = metrics.announced + metrics.withdrawn
  const denominator = Math.max(1, routeChanges)
  const forkCount = boundedInteger(Math.ceil(routeChanges / 16), 1, 6, 1)

  return structuralGrammar({
    role: "route-fork",
    pathStyle: "angular-fork",
    markerStyle: "route-wedge",
    rhythm: "extend-pinch",
    count: forkCount,
    width: 0.9 + common.intensity * 2.1,
    common,
    metrics,
    forkCount,
    extension: boundedNumber(metrics.announced / denominator, 0, 1, 0),
    pinch: boundedNumber(metrics.withdrawn / denominator, 0, 1, 0),
  })
}

function solanaGrammar(instruction, common) {
  const metrics = rebuildMetrics("solana", instruction.metrics)
  const beadCount = boundedInteger(metrics.slot_count, 1, 12, 1)
  const maximumBreaks = Math.min(11, Math.max(0, beadCount - 1))
  const gapBreakCount = boundedInteger(metrics.gap_count, 0, maximumBreaks, 0)

  return structuralGrammar({
    role: "slot-braid",
    pathStyle: "short-braid",
    markerStyle: "slot-bead",
    rhythm: "stepped-gap",
    count: beadCount,
    width: 0.75 + common.intensity * 1.25,
    common,
    metrics,
    beadCount,
    gapBreakCount,
    braidTension: boundedNumber(0.35 + common.pulse * 0.5, 0, 1, 0.5),
  })
}

function drandGrammar(instruction, common) {
  const metrics = rebuildMetrics("drand", instruction.metrics)

  return structuralGrammar({
    role: "public-pulse",
    pathStyle: "crystalline-chevron",
    markerStyle: "round-crystal",
    rhythm: "single-round",
    count: 1,
    width: 1 + common.intensity * 2,
    common,
    metrics,
    pulseCount: 1,
    round: metrics.round,
  })
}

function earthquakeGrammar(_instruction, common) {
  const ringCount = boundedInteger(Math.ceil(common.intensity * 3), 1, 3, 1)

  return structuralGrammar({
    role: "rupture",
    pathStyle: "scar-ring",
    markerStyle: "rupture-notch",
    rhythm: "restrained-aftershock",
    count: ringCount,
    width: 1.2 + common.intensity * 3,
    common,
    metrics: {},
    ringCount,
    rupture: boundedNumber(0.25 + common.intensity * 0.75, 0, 1, 0.5),
  })
}

function weatherGrammar(_instruction, common) {
  return structuralGrammar({
    role: "atmosphere",
    pathStyle: "viewport-field",
    markerStyle: "atmosphere-band",
    rhythm: "slow-field",
    count: 1,
    width: 2 + common.intensity * 4,
    common,
    metrics: {},
    coverage: boundedNumber(0.2 + common.spread * 0.6, 0, 1, 0.5),
  })
}

function visitorGrammar(instruction, common) {
  const styles = visitorStyles(instruction.kind)

  return structuralGrammar({
    role: "intervention",
    ...styles,
    count: instruction.kind === "tug" ? 3 : 1,
    width: 1 + common.intensity * 2.5,
    common,
    metrics: {},
    displacement: instruction.kind === "tug"
      ? boundedNumber(0.2 + common.spread * 0.6, 0, 1, 0.5)
      : 0,
    cohesion: instruction.kind === "knot"
      ? boundedNumber(0.4 + common.intensity * 0.5, 0, 1, 0.5)
      : 0,
    illumination: instruction.kind === "illuminate"
      ? boundedNumber(0.3 + common.pulse * 0.7, 0, 1, 0.5)
      : 0,
  })
}

function visitorStyles(kind) {
  switch (kind) {
    case "tug":
      return {
        pathStyle: "tension-curve",
        markerStyle: "pull-hook",
        rhythm: "human-pull",
      }
    case "knot":
      return {
        pathStyle: "joining-loop",
        markerStyle: "join-knot",
        rhythm: "human-hold",
      }
    default:
      return {
        pathStyle: "traveling-wave",
        markerStyle: "illumination-knot",
        rhythm: "human-travel",
      }
  }
}

function structuralGrammar({
  role,
  pathStyle,
  markerStyle,
  rhythm,
  count,
  width,
  common,
  metrics,
  ...parameters
}) {
  return {
    role,
    pathStyle,
    markerStyle,
    rhythm,
    structureSignature: `${pathStyle}\0${markerStyle}\0${rhythm}`,
    count: boundedInteger(count, 1, 12, 1),
    width: boundedNumber(width, 0.5, 8, 1),
    ...common,
    metrics,
    ...parameters,
  }
}

function neutralGrammar() {
  const pathStyle = "neutral-line"
  const markerStyle = "neutral-mark"
  const rhythm = "steady"

  return {
    role: "neutral",
    pathStyle,
    markerStyle,
    rhythm,
    structureSignature: `${pathStyle}\0${markerStyle}\0${rhythm}`,
    count: 1,
    width: 1,
    lane: 0.5,
    intensity: 0.5,
    spread: 0.5,
    bend: 0,
    pulse: 0.5,
    metrics: {},
  }
}

function commonParameters(instruction) {
  return {
    lane: boundedNumber(instruction.lane, 0, 1, 0.5),
    intensity: boundedNumber(instruction.intensity, 0, 1, 0.5),
    spread: boundedNumber(instruction.visual?.spread, 0, 1, 0.5),
    bend: boundedNumber(instruction.visual?.bend, -1, 1, 0),
    pulse: boundedNumber(instruction.visual?.pulse, 0, 1, 0.5),
  }
}

function rebuildMetrics(source, candidate) {
  const schema = metricSchemas[source]
  const metrics = safeRecord(candidate)
  const rebuilt = {}

  for (const key of schema.integers) {
    rebuilt[key] = boundedInteger(ownDataValue(metrics, key), 0, uint32Maximum, 0)
  }
  for (const key of schema.safeIntegers) {
    rebuilt[key] = boundedInteger(ownDataValue(metrics, key), 0, jsonSafeMaximum, 0)
  }
  for (const key of schema.booleans) {
    const boolean = ownDataValue(metrics, key)
    rebuilt[key] = typeof boolean === "boolean" ? boolean : false
  }

  return rebuilt
}

function safeRecord(candidate) {
  if (candidate === null || typeof candidate !== "object") return {}

  try {
    return Array.isArray(candidate) ? {} : candidate
  } catch (_error) {
    return {}
  }
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

function boundedInteger(number, minimum, maximum, fallback) {
  if (!Number.isFinite(number)) return fallback
  return Math.min(maximum, Math.max(minimum, Math.trunc(number)))
}

function boundedNumber(number, minimum, maximum, fallback) {
  if (!Number.isFinite(number)) return fallback
  return Math.min(maximum, Math.max(minimum, number))
}
