export function liveViewEventValue(value, type) {
  if (type !== "form" || typeof value === "string") return value

  return Object.entries(value)
    .map(([key, fieldValue]) =>
      `${encodeURIComponent(key)}=${encodeURIComponent(String(fieldValue))}`,
    )
    .join("&")
}

export function socketCloseError(leaving) {
  return leaving ? null : "websocket closed before the LiveView client left"
}
