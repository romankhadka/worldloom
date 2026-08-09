import assert from "node:assert/strict"
import test from "node:test"

import {
  browserURLAllowed,
  capacityObservationErrors,
  postCloseInvariantErrors,
  safeDiagnosticText,
  safeNetworkURL,
  upstreamInvariantErrors,
  viewerCountFromHTML,
} from "../../load/browser_100.mjs"

const baseURL = "http://localhost:4002"

test("accepts one hundred isolated visitors with two real snapshot advances", () => {
  const observations = Array.from({length: 100}, (_unused, index) => {
    const token = `capacity-${String(index + 1).padStart(3, "0")}`

    return {
      index,
      token,
      ready: true,
      watermarks: [1_000 + index, 1_100 + index, 1_200 + index],
      cookieToken: token,
      storageToken: token,
      websocketOpens: 1,
      unexpectedWebsocketCloses: 0,
      failures: [],
      networkURLs: [
        `${baseURL}/`,
        `${baseURL}/assets/app.js`,
        "ws://localhost:4002/live/websocket?_csrf_token=synthetic",
      ],
    }
  })

  assert.deepEqual(
    capacityObservationErrors(observations, {
      baseURL,
      expectedVisitors: 100,
      minimumAdvances: 2,
    }),
    [],
  )
})

test("reports shared identity, stale projections, browser failures, and direct upstream access", () => {
  const observations = [
    {
      index: 0,
      token: "capacity-001",
      ready: true,
      watermarks: [10, 11, 12],
      cookieToken: "capacity-001",
      storageToken: "capacity-001",
      websocketOpens: 1,
      unexpectedWebsocketCloses: 0,
      failures: [],
      networkURLs: [`${baseURL}/`],
    },
    {
      index: 1,
      token: "capacity-001",
      ready: false,
      watermarks: [20, 20],
      cookieToken: "capacity-001",
      storageToken: "capacity-000",
      websocketOpens: 2,
      unexpectedWebsocketCloses: 1,
      failures: [
        "visitor 2 websocket: wss://visitor:secret@localhost:4002/live/websocket?_csrf_token=signed#private closed unexpectedly",
      ],
      networkURLs: ["wss://localhost:4443/bluesky/subscribe"],
    },
  ]

  const errors = capacityObservationErrors(observations, {
    baseURL,
    expectedVisitors: 2,
    minimumAdvances: 2,
  })

  assert.equal(
    errors.some((error) => error.includes("unique context tokens")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("visitor 2 was not ready")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("two snapshot advances")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("isolated storage")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("websocket")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("opened 2 LiveView WebSockets")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("closed 1 time before shutdown")),
    true,
  )
  assert.equal(
    errors.some((error) =>
      error.includes("wss://localhost:4002/live/websocket closed unexpectedly"),
    ),
    true,
  )
  assert.equal(
    errors.some((error) =>
      ["visitor:secret", "_csrf_token", "signed", "#private"].some(
        (privateValue) => error.includes(privateValue),
      ),
    ),
    false,
  )
  assert.equal(
    errors.some((error) => error.includes("direct non-app network")),
    true,
  )
})

test("allows only application HTTP and WebSocket URLs", () => {
  assert.equal(browserURLAllowed("http://localhost:4002/", baseURL), true)
  assert.equal(
    browserURLAllowed("ws://localhost:4002/live/websocket", baseURL),
    true,
  )
  assert.equal(browserURLAllowed("data:image/png;base64,AA==", baseURL), true)
  assert.equal(browserURLAllowed("about:blank", baseURL), true)
  assert.equal(
    browserURLAllowed("https://localhost:4443/stats", baseURL),
    false,
  )
  assert.equal(
    browserURLAllowed("wss://jetstream.example/subscribe", baseURL),
    false,
  )
  assert.equal(browserURLAllowed("not a url", baseURL), false)
})

test("keeps only network origin and path in diagnostics", () => {
  assert.equal(
    safeNetworkURL(
      "wss://visitor:secret@localhost:4002/live/websocket?_csrf_token=signed#private",
    ),
    "wss://localhost:4002/live/websocket",
  )
  assert.equal(
    safeNetworkURL("http://localhost:4002/live/longpoll?token=signed"),
    "http://localhost:4002/live/longpoll",
  )
  assert.equal(safeNetworkURL("about:blank"), "about:blank")
  assert.equal(safeNetworkURL("not a url"), "invalid-url")
})

test("scrubs embedded absolute and relative URLs from failure diagnostics", () => {
  const diagnostic =
    "socket wss://visitor:secret@localhost:4002/live/websocket?_csrf_token=signed#private failed; fallback /live/longpoll?token=signed#private"

  assert.equal(
    safeDiagnosticText(diagnostic),
    "socket wss://localhost:4002/live/websocket failed; fallback /live/longpoll",
  )
  assert.equal(diagnostic.includes("signed"), true)
  assert.equal(safeDiagnosticText(diagnostic).includes("signed"), false)
  assert.equal(
    safeDiagnosticText(new Error(diagnostic)),
    "Error: socket wss://localhost:4002/live/websocket failed; fallback /live/longpoll",
  )
})

test("reads a disconnected viewer baseline without creating a LiveView", () => {
  assert.equal(
    viewerCountFromHTML('<span id="viewer-count"><i></i> 7 viewing</span>'),
    7,
  )
  assert.equal(
    viewerCountFromHTML('<span id="viewer-count">0 viewing</span>'),
    0,
  )
  assert.equal(viewerCountFromHTML("<main>missing</main>"), null)
})

test("accepts one server-owned provider set and bounded polling cadence", () => {
  const before = providerStats({drandRequests: 10, pollingRequests: 20})
  const after = providerStats({drandRequests: 31, pollingRequests: 82})

  assert.deepEqual(
    upstreamInvariantErrors(before, after, {
      elapsedMs: 62_000,
      drandCadenceMs: 3_000,
      pollingCadenceMs: 1_000,
    }),
    [],
  )
})

test("allows load-delayed polling while retaining a single-worker upper bound", () => {
  const before = providerStats({drandRequests: 10, pollingRequests: 20})
  const after = providerStats({drandRequests: 31, pollingRequests: 21})

  assert.deepEqual(
    upstreamInvariantErrors(before, after, {
      elapsedMs: 62_000,
      drandCadenceMs: 3_000,
      pollingCadenceMs: 1_000,
    }),
    [],
  )
})

test("rejects browser-multiplied streams, subscriptions, and request cadence", () => {
  const before = providerStats({drandRequests: 10, pollingRequests: 20})
  const after = providerStats({drandRequests: 110, pollingRequests: 120})
  after.wikimedia.active_connections = 100
  after.wikimedia.connection_opens = 100
  after.wikimedia.peak_connections = 100
  after.ripe_ris.subscriptions = 200

  const errors = upstreamInvariantErrors(before, after, {
    elapsedMs: 60_000,
    drandCadenceMs: 3_000,
    pollingCadenceMs: 1_000,
  })

  assert.equal(
    errors.some((error) => error.includes("wikimedia active_connections")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("wikimedia connection_opens")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("ripe_ris subscriptions")),
    true,
  )
  assert.equal(
    errors.some((error) => error.includes("drand request cadence")),
    true,
  )
})

test("requires provider connections to remain at baseline after browser close", () => {
  const beforeClose = providerStats({drandRequests: 20, pollingRequests: 40})
  const afterClose = structuredClone(beforeClose)

  assert.deepEqual(postCloseInvariantErrors(beforeClose, afterClose), [])

  afterClose.bluesky.active_connections = 2
  afterClose.solana.connection_opens = 2

  assert.deepEqual(postCloseInvariantErrors(beforeClose, afterClose), [
    "bluesky active_connections changed after browser close: 1 -> 2",
    "solana connection_opens changed after browser close: 1 -> 2",
  ])
})

function providerStats({drandRequests, pollingRequests}) {
  const empty = {
    active_connections: 0,
    connection_opens: 0,
    emitted_windows: 0,
    peak_connections: 0,
    requests: 0,
    subscriptions: 0,
  }

  return {
    wikimedia: {
      ...empty,
      active_connections: 1,
      connection_opens: 1,
      peak_connections: 1,
      requests: 1,
    },
    bluesky: {
      ...empty,
      active_connections: 1,
      connection_opens: 1,
      peak_connections: 1,
      subscriptions: 1,
    },
    ripe_ris: {
      ...empty,
      active_connections: 1,
      connection_opens: 1,
      peak_connections: 1,
      subscriptions: 2,
    },
    solana: {
      ...empty,
      active_connections: 1,
      connection_opens: 1,
      peak_connections: 1,
      subscriptions: 1,
    },
    drand: {...empty, requests: drandRequests},
    usgs: {...empty, requests: pollingRequests},
    open_meteo: {...empty, requests: pollingRequests},
  }
}
