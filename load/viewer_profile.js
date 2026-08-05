export function viewerHoldMsFor(profile) {
  if (profile === "launch") return 35 * 60 * 1_000
  if (profile === "local") return 6 * 60 * 1_000
  if (profile === "local-100") return 3 * 60 * 1_000

  return 2_000
}
