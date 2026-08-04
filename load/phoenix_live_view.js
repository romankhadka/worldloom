import http from "k6/http"
import ws from "k6/ws"

import {liveViewEventValue, socketCloseError} from "./live_view_protocol.js"

const phoenixProtocolVersion = "2.0.0"
const heartbeatIntervalMs = 25_000

export function connectLiveView({
  baseURL,
  path = "/",
  holdForMs = 2_000,
  onJoined = () => {},
  onMessage = () => {},
  onError = () => {},
  tags = {},
}) {
  const bootstrap = fetchLiveView(baseURL, path, tags)
  const outcome = {
    bootstrapStatus: bootstrap.status,
    socketStatus: 0,
    joined: false,
    highestSequence: bootstrap.highestSequence,
    errors: [...bootstrap.errors],
  }

  if (bootstrap.errors.length > 0) return outcome

  const websocketURL = socketURL(baseURL, bootstrap.csrfToken)
  const response = ws.connect(
    websocketURL,
    {jar: http.cookieJar(), tags: {...tags, name: "WorldLive websocket"}},
    (socket) => {
      const client = liveViewClient(socket, bootstrap)

      socket.on("open", () => {
        client.join()
        client.heartbeatTimer = socket.setInterval(
          () => heartbeat(client),
          heartbeatIntervalMs,
        )
        socket.setTimeout(() => leave(client), holdForMs)
        socket.setTimeout(() => socket.close(), holdForMs + 1_000)
      })

      socket.on("message", (encodedMessage) => {
        const message = decodeMessage(encodedMessage, outcome, onError)
        if (!message) return

        outcome.highestSequence = Math.max(
          outcome.highestSequence,
          observeSequence(message) ?? 0,
        )

        if (joinSucceeded(message, client)) {
          outcome.joined = true
          onJoined(client, outcome)
        }

        if (leaveSucceeded(message, client)) socket.close()
        onMessage(message, client, outcome)
      })

      socket.on("error", (error) => {
        const safeError = `websocket: ${String(error)}`
        outcome.errors.push(safeError)
        onError(safeError, outcome)
      })

      socket.on("close", () => {
        const safeError = socketCloseError(client.leaving)
        if (!safeError) return
        outcome.errors.push(safeError)
        onError(safeError, outcome)
      })
    },
  )

  outcome.socketStatus = response?.status ?? 0
  return outcome
}

export function fetchLiveView(baseURL, path = "/", tags = {}) {
  const pageURL = joinURL(baseURL, path)
  const response = http.get(pageURL, {
    tags: {...tags, name: "WorldLive bootstrap"},
  })
  const document = response.html()
  const root = document.find("[data-phx-main]").first()
  const canvas = root.find("#loom-canvas").first()
  const errors = []
  const csrfToken = document
    .find('meta[name="csrf-token"]')
    .first()
    .attr("content")
  const viewId = root.attr("id")
  const session = root.attr("data-phx-session")
  const staticToken = root.attr("data-phx-static")

  if (response.status !== 200)
    errors.push(`bootstrap status ${response.status}`)
  if (!csrfToken) errors.push("missing CSRF token")
  if (!viewId) errors.push("missing LiveView id")
  if (!session) errors.push("missing LiveView session")
  if (!staticToken) errors.push("missing LiveView static token")

  return {
    status: response.status,
    url: pageURL,
    csrfToken,
    viewId,
    session,
    staticToken,
    highestSequence: highestBootstrapSequence(canvas.attr("data-instructions")),
    errors,
  }
}

export function heartbeat(client) {
  return push(client, "phoenix", "heartbeat", {})
}

export function pushLiveViewEvent(client, event, value = {}, type = "click") {
  return push(client, client.topic, "event", {
    type,
    event,
    value: liveViewEventValue(value, type),
    cid: null,
  })
}

export function observeSequence(message) {
  return highestNestedSequence(message)
}

export function liveViewPushes(message, eventName) {
  const payloads = []
  collectLiveViewPushes(message, eventName, payloads)
  return payloads
}

export function liveViewReply(message, ref) {
  const [_joinRef, messageRef, _topic, event, payload] = message
  return messageRef === ref && event === "phx_reply" ? payload : null
}

export function leave(client) {
  if (client.leaving) return client.leaveRef

  client.leaving = true
  client.leaveRef = push(client, client.topic, "phx_leave", {})
  return client.leaveRef
}

function liveViewClient(socket, bootstrap) {
  const client = {
    socket,
    topic: `lv:${bootstrap.viewId}`,
    joinRef: "1",
    nextRef: 1,
    leaveRef: null,
    leaving: false,
    heartbeatTimer: null,
  }

  client.join = () => {
    client.nextRef = 1
    socket.send(
      encodeMessage(client.joinRef, "1", client.topic, "phx_join", {
        url: bootstrap.url,
        params: {
          _csrf_token: bootstrap.csrfToken,
          _mounts: 0,
          _mount_attempts: 0,
        },
        session: bootstrap.session,
        static: bootstrap.staticToken,
        sticky: false,
      }),
    )
  }

  return client
}

function push(client, topic, event, payload) {
  client.nextRef += 1
  const ref = String(client.nextRef)
  client.socket.send(encodeMessage(client.joinRef, ref, topic, event, payload))
  return ref
}

function encodeMessage(joinRef, ref, topic, event, payload) {
  return JSON.stringify([joinRef, ref, topic, event, payload])
}

function decodeMessage(encodedMessage, outcome, onError) {
  try {
    const decoded = JSON.parse(encodedMessage)
    if (!Array.isArray(decoded) || decoded.length !== 5)
      throw new Error("invalid envelope")
    return decoded
  } catch (error) {
    const safeError = `decode: ${String(error)}`
    outcome.errors.push(safeError)
    onError(safeError, outcome)
    return null
  }
}

function joinSucceeded([joinRef, ref, _topic, event, payload], client) {
  return (
    joinRef === client.joinRef &&
    ref === client.joinRef &&
    event === "phx_reply" &&
    payload?.status === "ok"
  )
}

function leaveSucceeded([_joinRef, ref, _topic, event, payload], client) {
  return (
    ref === client.leaveRef && event === "phx_reply" && payload?.status === "ok"
  )
}

function socketURL(baseURL, csrfToken) {
  const websocketBase = baseURL
    .replace(/^http:/, "ws:")
    .replace(/^https:/, "wss:")
  return `${joinURL(websocketBase, "/live/websocket")}?_csrf_token=${encodeURIComponent(csrfToken)}&vsn=${phoenixProtocolVersion}`
}

function joinURL(baseURL, path) {
  return `${baseURL.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`
}

function highestBootstrapSequence(encodedInstructions) {
  try {
    return JSON.parse(encodedInstructions ?? "[]").reduce(
      (highest, instruction) =>
        Math.max(highest, Number(instruction?.sequence) || 0),
      0,
    )
  } catch (_error) {
    return 0
  }
}

function highestNestedSequence(subject, depth = 0) {
  if (depth > 14 || subject === null || typeof subject !== "object") return null

  let highest = Number.isSafeInteger(subject.sequence) ? subject.sequence : null
  for (const nested of Object.values(subject)) {
    const candidate = highestNestedSequence(nested, depth + 1)
    if (candidate !== null && (highest === null || candidate > highest))
      highest = candidate
  }
  return highest
}

function collectLiveViewPushes(subject, eventName, payloads, depth = 0) {
  if (depth > 14 || subject === null || typeof subject !== "object") return

  if (
    Array.isArray(subject) &&
    subject.length === 2 &&
    subject[0] === eventName &&
    subject[1] !== null &&
    typeof subject[1] === "object"
  ) {
    payloads.push(subject[1])
  }

  for (const nested of Object.values(subject)) {
    collectLiveViewPushes(nested, eventName, payloads, depth + 1)
  }
}
