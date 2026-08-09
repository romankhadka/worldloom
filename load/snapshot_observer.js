const observableRoles = ["display_events", "memory_events"]

export function mergeSnapshotObservations(observedAt, envelope, observationTime) {
  const merged = isRecord(observedAt) ? {...observedAt} : {}
  if (!isRecord(envelope)) return merged

  for (const role of observableRoles) {
    const instructions = envelope[role]
    if (!Array.isArray(instructions)) continue

    for (const instruction of instructions) {
      const sequence = instruction?.sequence
      if (!Number.isSafeInteger(sequence) || sequence <= 0) continue
      if (Object.prototype.hasOwnProperty.call(merged, sequence)) continue
      merged[sequence] = observationTime
    }
  }

  return merged
}

export function mergeBalancedSnapshotObservation(observation, envelope) {
  const merged = normalizedBalancedObservation(observation)
  if (!isRecord(envelope)) return merged

  const watermark = envelope.commit_watermark
  if (!Number.isSafeInteger(watermark) || watermark <= 0) return merged

  const latestWatermark = merged.watermarks.at(-1) ?? 0
  if (watermark <= latestWatermark) return merged

  for (const role of observableRoles) {
    const instructions = envelope[role]
    if (!Array.isArray(instructions)) continue

    for (const instruction of instructions) {
      addSource(merged.sources, instruction?.source)
    }
  }
  addSource(merged.sources, envelope.ambient?.source)
  merged.watermarks.push(watermark)

  return merged
}

export function balancedSnapshotComplete(observation, expectedSources) {
  const normalized = normalizedBalancedObservation(observation)
  if (!strictlyIncreasing(normalized.watermarks)) return false
  if (!Array.isArray(expectedSources) || expectedSources.length === 0)
    return false
  if (
    !expectedSources.every(
      (source) => typeof source === "string" && source.length > 0,
    )
  ) {
    return false
  }

  return expectedSources.every((source) => normalized.sources.includes(source))
}

function normalizedBalancedObservation(observation) {
  if (!isRecord(observation)) return {watermarks: [], sources: []}

  const watermarks = Array.isArray(observation.watermarks)
    ? observation.watermarks.filter(
        (watermark) => Number.isSafeInteger(watermark) && watermark > 0,
      )
    : []
  const sources = Array.isArray(observation.sources)
    ? observation.sources.filter(
        (source, index, allSources) =>
          typeof source === "string" &&
          source.length > 0 &&
          allSources.indexOf(source) === index,
      )
    : []

  return {watermarks, sources}
}

function strictlyIncreasing(watermarks) {
  return (
    watermarks.length >= 2 &&
    watermarks.every(
      (watermark, index) => index === 0 || watermark > watermarks[index - 1],
    )
  )
}

function addSource(sources, source) {
  if (typeof source !== "string" || source.length === 0) return
  if (!sources.includes(source)) sources.push(source)
}

function isRecord(candidate) {
  return candidate !== null && typeof candidate === "object" && !Array.isArray(candidate)
}
