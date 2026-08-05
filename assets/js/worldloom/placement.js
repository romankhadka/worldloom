const canvasPadding = 40
const liveEdgeTargetWidth = 64

export function laneFromClientY(clientY, bounds) {
  const usableHeight = Math.max(1, bounds.height - canvasPadding * 2)
  const relativeY = clientY - bounds.top - canvasPadding
  return roundLane(relativeY / usableHeight)
}

export function clientYForLane(lane, bounds) {
  const usableHeight = Math.max(1, bounds.height - canvasPadding * 2)
  return bounds.top + canvasPadding + roundLane(lane) * usableHeight
}

export function withinLiveEdgeTarget(clientX, bounds) {
  return clientX >= bounds.left + bounds.width - liveEdgeTargetWidth &&
    clientX <= bounds.left + bounds.width
}

function roundLane(lane) {
  return Math.min(1, Math.max(0, Math.round(Number(lane) * 20) / 20))
}
