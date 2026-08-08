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

function isRecord(candidate) {
  return candidate !== null && typeof candidate === "object" && !Array.isArray(candidate)
}
