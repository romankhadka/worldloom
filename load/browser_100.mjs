import {readFile} from "node:fs/promises"
import {request as httpRequest} from "node:http"
import {request as httpsRequest} from "node:https"
import {resolve} from "node:path"
import {pathToFileURL} from "node:url"

import {chromium} from "@playwright/test"

const streamingSources = ["wikimedia", "bluesky", "ripe_ris", "solana"]
const connectionCounters = [
  "active_connections",
  "connection_opens",
  "peak_connections",
]
const expectedSubscriptions = {
  wikimedia: 0,
  bluesky: 1,
  ripe_ris: 2,
  solana: 1,
}

export function capacityObservationErrors(
  observations,
  {baseURL, expectedVisitors = 100, minimumAdvances = 2},
) {
  const errors = []

  if (
    !Array.isArray(observations) ||
    observations.length !== expectedVisitors
  ) {
    errors.push(
      `expected ${expectedVisitors} visitor observations, received ${Array.isArray(observations) ? observations.length : "invalid"}`,
    )
    return errors
  }

  const tokens = observations.map((observation) => observation?.token)
  if (new Set(tokens).size !== expectedVisitors) {
    errors.push(`expected ${expectedVisitors} unique context tokens`)
  }

  for (const [index, observation] of observations.entries()) {
    const label = `visitor ${index + 1}`

    if (observation?.ready !== true) errors.push(`${label} was not ready`)

    const watermarks = Array.isArray(observation?.watermarks)
      ? observation.watermarks
      : []
    const increasing = watermarks.every(
      (watermark, watermarkIndex) =>
        Number.isSafeInteger(watermark) &&
        watermark > 0 &&
        (watermarkIndex === 0 || watermark > watermarks[watermarkIndex - 1]),
    )

    if (!increasing || watermarks.length < minimumAdvances + 1) {
      const required = minimumAdvances === 2 ? "two" : minimumAdvances
      errors.push(`${label} did not observe ${required} snapshot advances`)
    }

    if (
      typeof observation?.token !== "string" ||
      observation.cookieToken !== observation.token ||
      observation.storageToken !== observation.token
    ) {
      errors.push(`${label} did not retain isolated storage`)
    }

    if (observation?.websocketOpens !== 1) {
      errors.push(
        `${label} opened ${observation?.websocketOpens ?? "an unknown number of"} LiveView WebSockets`,
      )
    }

    if (observation?.unexpectedWebsocketCloses !== 0) {
      errors.push(
        `${label} WebSocket closed ${observation?.unexpectedWebsocketCloses ?? "an unknown number of"} time before shutdown`,
      )
    }

    for (const failure of observation?.failures ?? []) {
      errors.push(safeDiagnosticText(failure))
    }

    for (const url of observation?.networkURLs ?? []) {
      if (!browserURLAllowed(url, baseURL)) {
        errors.push(`${label} made direct non-app network request: ${url}`)
      }
    }
  }

  return errors
}

export function browserURLAllowed(candidate, baseURL) {
  try {
    const url = new URL(candidate)
    if (["about:", "blob:", "data:"].includes(url.protocol)) return true

    const application = new URL(baseURL)
    const networkProtocol = ["http:", "https:", "ws:", "wss:"].includes(
      url.protocol,
    )

    return networkProtocol && url.host === application.host
  } catch (_invalidURL) {
    return false
  }
}

export function safeNetworkURL(candidate) {
  try {
    const url = new URL(candidate)

    if (url.protocol === "about:") return `about:${url.pathname}`
    if (["blob:", "data:"].includes(url.protocol)) return url.protocol

    return `${url.protocol}//${url.host}${url.pathname}`
  } catch (_invalidURL) {
    return "invalid-url"
  }
}

export function safeDiagnosticText(candidate) {
  const diagnostic = String(candidate)
  const withoutAbsoluteSecrets = diagnostic.replace(
    /\b(?:https?|wss?):\/\/[^\s"'<>]+|\b(?:about|blob|data):[^\s"'<>]+/giu,
    (url) => safeNetworkURL(url),
  )

  return withoutAbsoluteSecrets.replace(
    /(^|[\s([{=:])((?:\/{1,2}|\.\.?\/)[^\s"'<>?#]*)(?:\?[^\s"'<>#]*)?(?:#[^\s"'<>]*)?/gu,
    (_url, prefix, pathname) => `${prefix}${pathname}`,
  )
}

export function viewerCountFromHTML(html) {
  if (typeof html !== "string") return null

  const count = html.match(
    /<[^>]*id=["']viewer-count["'][^>]*>[\s\S]{0,500}?\b(\d+)\s+viewing\b/i,
  )
  if (!count) return null

  const parsed = Number(count[1])
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null
}

export function upstreamInvariantErrors(
  before,
  after,
  {elapsedMs, drandCadenceMs = 3_000, pollingCadenceMs = 1_000},
) {
  const errors = []

  errors.push(...providerBaselineErrors(before, "before browser ramp"))
  errors.push(...providerBaselineErrors(after, "after browser hold"))
  errors.push(...unchangedStreamingCounterErrors(before, after))
  errors.push(
    ...cadenceErrors(
      "drand",
      counter(before, "drand", "requests"),
      counter(after, "drand", "requests"),
      elapsedMs,
      drandCadenceMs,
    ),
  )

  for (const source of ["usgs", "open_meteo"]) {
    errors.push(
      ...pollingUpperBoundErrors(
        source,
        counter(before, source, "requests"),
        counter(after, source, "requests"),
        elapsedMs,
        pollingCadenceMs,
      ),
    )
  }

  return errors
}

export function postCloseInvariantErrors(beforeClose, afterClose) {
  const errors = []

  for (const source of streamingSources) {
    for (const field of [...connectionCounters, "subscriptions"]) {
      const before = counter(beforeClose, source, field)
      const after = counter(afterClose, source, field)
      if (before !== after) {
        errors.push(
          `${source} ${field} changed after browser close: ${before} -> ${after}`,
        )
      }
    }
  }

  return errors
}

async function main() {
  const settings = loadSettings()
  const certificateAuthority = await readFile(settings.caFile)
  const viewerBaseline = await requestViewerCount(settings.baseURL)
  const baseline = await waitForProviderBaseline(
    settings.statsURL,
    certificateAuthority,
    settings.readyTimeoutMs,
  )
  const baselineAt = Date.now()
  const browser = await chromium.launch({headless: true})
  const visitors = []

  try {
    const launchPromises = await rampVisitors(browser, visitors, settings)
    await Promise.all(launchPromises)

    assertNoErrors(
      visitors.flatMap((visitor) => visitor.failures),
      "browser ramp failed",
    )
    await waitForViewerCount(
      visitors[0].page,
      viewerBaseline + settings.visitorCount,
      settings.readyTimeoutMs,
    )

    await Promise.all(
      visitors.map((visitor) =>
        waitForSnapshotAdvances(
          visitor,
          settings.minimumAdvances,
          settings.advanceTimeoutMs,
        ),
      ),
    )

    await sleep(settings.holdMs)

    const observations = await Promise.all(
      visitors.map((visitor) => collectObservation(visitor)),
    )
    assertNoErrors(
      capacityObservationErrors(observations, {
        baseURL: settings.baseURL,
        expectedVisitors: settings.visitorCount,
        minimumAdvances: settings.minimumAdvances,
      }),
      "browser isolation or snapshot evidence failed",
    )

    const afterHold = await requestJSON(settings.statsURL, certificateAuthority)
    assertNoErrors(
      upstreamInvariantErrors(baseline, afterHold, {
        elapsedMs: Date.now() - baselineAt,
        drandCadenceMs: settings.drandCadenceMs,
        pollingCadenceMs: settings.pollingCadenceMs,
      }),
      "upstream work multiplied or missed cadence",
    )

    await Promise.all(visitors.slice(1).map((visitor) => closeVisitor(visitor)))
    await waitForViewerCount(
      visitors[0].page,
      viewerBaseline + 1,
      settings.closeTimeoutMs,
    )
    await closeVisitor(visitors[0])
    await waitForDisconnectedViewerBaseline(
      settings.baseURL,
      viewerBaseline,
      settings.closeTimeoutMs,
    )

    const afterClose = await requestJSON(
      settings.statsURL,
      certificateAuthority,
    )
    assertNoErrors(
      postCloseInvariantErrors(afterHold, afterClose),
      "provider baseline changed after browser close",
    )

    if (visitors.some((visitor) => visitor.closed !== true)) {
      throw new Error("one or more browser contexts remained open")
    }

    await browser.close()
    if (browser.isConnected())
      throw new Error("Chromium remained connected after close")

    const summary = {
      visitors: observations.length,
      ready: observations.filter((observation) => observation.ready).length,
      viewer_baseline: viewerBaseline,
      minimum_snapshot_advances: Math.min(
        ...observations.map((observation) => observation.watermarks.length - 1),
      ),
      browser_failures: observations.reduce(
        (total, observation) => total + observation.failures.length,
        0,
      ),
      direct_upstream_requests: observations.reduce(
        (total, observation) =>
          total +
          observation.networkURLs.filter(
            (url) => !browserURLAllowed(url, settings.baseURL),
          ).length,
        0,
      ),
      provider_connections: Object.fromEntries(
        streamingSources.map((source) => [
          source,
          {
            opens: afterClose[source].connection_opens,
            active: afterClose[source].active_connections,
            peak: afterClose[source].peak_connections,
            subscriptions: afterClose[source].subscriptions,
          },
        ]),
      ),
    }

    process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`)
  } finally {
    await Promise.allSettled(visitors.map((visitor) => closeVisitor(visitor)))
    if (browser.isConnected()) await browser.close()
  }
}

async function rampVisitors(browser, visitors, settings) {
  const promises = []
  const startedAt = Date.now()

  for (
    let offset = 0;
    offset < settings.visitorCount;
    offset += settings.batchSize
  ) {
    const batchIndex = Math.floor(offset / settings.batchSize)
    const scheduledAt = startedAt + batchIndex * settings.rampIntervalMs
    await sleep(Math.max(0, scheduledAt - Date.now()))

    const batchEnd = Math.min(
      offset + settings.batchSize,
      settings.visitorCount,
    )
    for (let index = offset; index < batchEnd; index += 1) {
      const visitor = visitorRecord(index)
      visitors.push(visitor)
      promises.push(openVisitor(browser, visitor, settings))
    }
  }

  return promises
}

function visitorRecord(index) {
  return {
    index,
    token: `capacity-${String(index + 1).padStart(3, "0")}`,
    context: null,
    page: null,
    failures: [],
    networkURLs: [],
    websocketOpens: 0,
    unexpectedWebsocketCloses: 0,
    closing: false,
    closed: false,
  }
}

async function openVisitor(browser, visitor, settings) {
  try {
    visitor.context = await browser.newContext({
      reducedMotion: "reduce",
      viewport: {width: 800, height: 600},
    })
    await visitor.context.addCookies([
      {
        name: "worldloom_capacity_context",
        value: visitor.token,
        url: settings.baseURL,
        sameSite: "Strict",
      },
    ])
    await visitor.context.addInitScript(installCapacityObserver, visitor.token)

    visitor.page = await visitor.context.newPage()
    monitorPage(visitor, settings.baseURL)
    await visitor.page.goto(new URL("/", settings.baseURL).toString(), {
      waitUntil: "domcontentloaded",
      timeout: settings.readyTimeoutMs,
    })
    await visitor.page.waitForFunction(
      () => globalThis.__worldloomCapacity?.ready === true,
      undefined,
      {timeout: settings.readyTimeoutMs},
    )
  } catch (error) {
    recordVisitorFailure(
      visitor,
      `visitor ${visitor.index + 1} startup: ${error.message}`,
    )
  }
}

function installCapacityObserver(token) {
  globalThis.__worldloomCapacity = {
    token,
    ready: false,
    watermarks: [],
  }

  const record = () => {
    const canvas = document.querySelector("#loom-canvas")
    if (!canvas) return

    if (canvas.dataset.ready === "true") {
      globalThis.__worldloomCapacity.ready = true
    }

    const watermark = Number(canvas.dataset.commitWatermark)
    const watermarks = globalThis.__worldloomCapacity.watermarks
    const latest = watermarks.at(-1) ?? 0
    if (Number.isSafeInteger(watermark) && watermark > latest) {
      watermarks.push(watermark)
    }
  }

  const start = () => {
    const observer = new MutationObserver(record)
    observer.observe(document, {
      attributes: true,
      childList: true,
      subtree: true,
      attributeFilter: ["data-commit-watermark", "data-ready"],
    })
    record()
    localStorage.setItem("worldloom-capacity-context", token)
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, {once: true})
  } else {
    start()
  }
}

function monitorPage(visitor, baseURL) {
  const {page} = visitor
  const recordFailure = (message) => {
    if (!visitor.closing) recordVisitorFailure(visitor, message)
  }

  page.on("console", (message) => {
    if (message.type() === "error") {
      recordFailure(`visitor ${visitor.index + 1} console: ${message.text()}`)
    }
  })
  page.on("pageerror", (error) =>
    recordFailure(`visitor ${visitor.index + 1} page: ${error.message}`),
  )
  page.on("crash", () =>
    recordFailure(`visitor ${visitor.index + 1} page crashed`),
  )
  page.on("request", (request) =>
    visitor.networkURLs.push(safeNetworkURL(request.url())),
  )
  page.on("requestfailed", (request) =>
    recordFailure(
      `visitor ${visitor.index + 1} request: ${request.method()} ${safeNetworkURL(request.url())} ${request.failure()?.errorText}`,
    ),
  )
  page.on("response", (response) => {
    if (response.status() >= 400) {
      recordFailure(
        `visitor ${visitor.index + 1} response: ${response.status()} ${safeNetworkURL(response.url())}`,
      )
    }
  })
  page.on("websocket", (socket) => {
    visitor.websocketOpens += 1
    visitor.networkURLs.push(safeNetworkURL(socket.url()))
    socket.on("socketerror", (error) =>
      recordFailure(`visitor ${visitor.index + 1} websocket: ${error}`),
    )
    socket.on("close", () => {
      if (!visitor.closing) visitor.unexpectedWebsocketCloses += 1
    })
  })

  if (!browserURLAllowed(baseURL, baseURL)) {
    recordFailure(
      `visitor ${visitor.index + 1} invalid application URL: ${baseURL}`,
    )
  }
}

async function waitForSnapshotAdvances(visitor, minimumAdvances, timeout) {
  if (!visitor.page || visitor.page.isClosed()) return

  try {
    await visitor.page.waitForFunction(
      (requiredWatermarks) =>
        (globalThis.__worldloomCapacity?.watermarks?.length ?? 0) >=
        requiredWatermarks,
      minimumAdvances + 1,
      {timeout},
    )
  } catch (error) {
    recordVisitorFailure(
      visitor,
      `visitor ${visitor.index + 1} snapshot observation: ${error.message}`,
    )
  }
}

async function collectObservation(visitor) {
  if (!visitor.page || visitor.page.isClosed()) {
    return {
      index: visitor.index,
      token: visitor.token,
      ready: false,
      watermarks: [],
      cookieToken: null,
      storageToken: null,
      websocketOpens: visitor.websocketOpens,
      unexpectedWebsocketCloses: visitor.unexpectedWebsocketCloses,
      failures: [...visitor.failures],
      networkURLs: [...visitor.networkURLs],
    }
  }

  try {
    const state = await visitor.page.evaluate(() => {
      const cookies = Object.fromEntries(
        document.cookie
          .split(";")
          .map((entry) => entry.trim())
          .filter(Boolean)
          .map((entry) => {
            const separator = entry.indexOf("=")
            return [entry.slice(0, separator), entry.slice(separator + 1)]
          }),
      )

      return {
        ready: globalThis.__worldloomCapacity?.ready === true,
        watermarks: [...(globalThis.__worldloomCapacity?.watermarks ?? [])],
        cookieToken: cookies.worldloom_capacity_context ?? null,
        storageToken: localStorage.getItem("worldloom-capacity-context"),
      }
    })

    return {
      index: visitor.index,
      token: visitor.token,
      ...state,
      websocketOpens: visitor.websocketOpens,
      unexpectedWebsocketCloses: visitor.unexpectedWebsocketCloses,
      failures: [...visitor.failures],
      networkURLs: [...visitor.networkURLs],
    }
  } catch (error) {
    recordVisitorFailure(
      visitor,
      `visitor ${visitor.index + 1} evidence: ${error.message}`,
    )
    return collectObservation({...visitor, page: null})
  }
}

async function waitForViewerCount(page, expected, timeout) {
  try {
    await page.waitForFunction(
      (viewerCount) => {
        const text = document.querySelector("#viewer-count")?.textContent ?? ""
        return Number.parseInt(text, 10) === viewerCount
      },
      expected,
      {timeout},
    )
  } catch (error) {
    const text = await page
      .locator("#viewer-count")
      .textContent()
      .catch(() => "missing")
    throw new Error(
      `viewer count did not reach ${expected}; observed ${JSON.stringify(text?.trim())}: ${error.message}`,
    )
  }
}

async function closeVisitor(visitor) {
  if (!visitor || visitor.closed) return
  visitor.closing = true

  try {
    await visitor.context?.close()
  } finally {
    visitor.closed = true
  }
}

function recordVisitorFailure(visitor, message) {
  visitor.failures.push(safeDiagnosticText(message))
}

function providerBaselineErrors(stats, phase) {
  const errors = []

  for (const source of streamingSources) {
    for (const field of connectionCounters) {
      const actual = counter(stats, source, field)
      if (actual !== 1)
        errors.push(
          `${source} ${field} ${phase}: expected 1, received ${actual}`,
        )
    }

    const subscriptions = counter(stats, source, "subscriptions")
    if (subscriptions !== expectedSubscriptions[source]) {
      errors.push(
        `${source} subscriptions ${phase}: expected ${expectedSubscriptions[source]}, received ${subscriptions}`,
      )
    }
  }

  return errors
}

function unchangedStreamingCounterErrors(before, after) {
  const errors = []

  for (const source of streamingSources) {
    for (const field of [
      "connection_opens",
      "peak_connections",
      "subscriptions",
    ]) {
      const baseline = counter(before, source, field)
      const observed = counter(after, source, field)
      if (baseline !== observed) {
        errors.push(
          `${source} ${field} changed during browser hold: ${baseline} -> ${observed}`,
        )
      }
    }
  }

  return errors
}

function cadenceErrors(source, before, after, elapsedMs, cadenceMs) {
  if (![before, after, elapsedMs, cadenceMs].every(Number.isFinite)) {
    return [`${source} request cadence could not be measured`]
  }

  const requests = after - before
  const expected = elapsedMs / cadenceMs
  const minimum = Math.max(0, Math.floor(expected) - 2)
  const maximum = Math.ceil(expected) + 3

  return requests >= minimum && requests <= maximum
    ? []
    : [
        `${source} request cadence outside ${minimum}-${maximum}: observed ${requests} over ${elapsedMs}ms`,
      ]
}

function pollingUpperBoundErrors(source, before, after, elapsedMs, cadenceMs) {
  if (![before, after, elapsedMs, cadenceMs].every(Number.isFinite)) {
    return [`${source} request upper bound could not be measured`]
  }

  const requests = after - before
  const maximum = Math.ceil(elapsedMs / cadenceMs) + 3

  return requests > 0 && requests <= maximum
    ? []
    : [
        `${source} request upper bound outside 1-${maximum}: observed ${requests} over ${elapsedMs}ms`,
      ]
}

function counter(stats, source, field) {
  const candidate = stats?.[source]?.[field]
  return Number.isSafeInteger(candidate) && candidate >= 0
    ? candidate
    : "missing"
}

async function waitForProviderBaseline(
  statsURL,
  certificateAuthority,
  timeout,
) {
  const deadline = Date.now() + timeout
  let latestErrors = []

  while (Date.now() < deadline) {
    const stats = await requestJSON(statsURL, certificateAuthority)
    latestErrors = providerBaselineErrors(stats, "at baseline")
    if (latestErrors.length === 0) return stats
    await sleep(250)
  }

  throw new Error(
    `provider baseline was not ready:\n${latestErrors.join("\n")}`,
  )
}

async function waitForDisconnectedViewerBaseline(baseURL, expected, timeout) {
  const deadline = Date.now() + timeout
  let observed = null

  while (Date.now() < deadline) {
    observed = await requestViewerCount(baseURL)
    if (observed === expected) return
    await sleep(100)
  }

  throw new Error(
    `viewer count did not return to disconnected baseline ${expected}; observed ${observed}`,
  )
}

async function requestViewerCount(baseURL) {
  const response = await fetch(new URL("/", baseURL), {
    headers: {accept: "text/html"},
    redirect: "error",
    signal: AbortSignal.timeout(5_000),
  })
  if (!response.ok)
    throw new Error(`viewer baseline returned ${response.status}`)

  const viewerCount = viewerCountFromHTML(await response.text())
  if (viewerCount === null)
    throw new Error("viewer baseline was absent from application HTML")
  return viewerCount
}

function requestJSON(url, certificateAuthority) {
  return new Promise((resolveRequest, rejectRequest) => {
    const parsed = new URL(url)
    const request = parsed.protocol === "https:" ? httpsRequest : httpRequest
    const options =
      parsed.protocol === "https:"
        ? {ca: certificateAuthority, rejectUnauthorized: true}
        : undefined

    const outgoing = request(parsed, options, (response) => {
      const chunks = []
      let bytes = 0

      response.on("data", (chunk) => {
        bytes += chunk.length
        if (bytes > 1_000_000) {
          outgoing.destroy(new Error("stats response exceeded one megabyte"))
          return
        }
        chunks.push(chunk)
      })
      response.on("end", () => {
        if (response.statusCode !== 200) {
          rejectRequest(
            new Error(`stats response returned ${response.statusCode}`),
          )
          return
        }

        try {
          resolveRequest(JSON.parse(Buffer.concat(chunks).toString("utf8")))
        } catch (error) {
          rejectRequest(
            new Error(`stats response was not JSON: ${error.message}`),
          )
        }
      })
    })

    outgoing.setTimeout(5_000, () =>
      outgoing.destroy(new Error("stats request timed out")),
    )
    outgoing.on("error", rejectRequest)
    outgoing.end()
  })
}

function loadSettings() {
  return {
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
    statsURL:
      process.env.WORLDLOOM_UPSTREAM_STATS_URL ??
      "https://localhost:4443/stats",
    caFile:
      process.env.WORLDLOOM_UPSTREAM_CA_FILE ??
      resolve("test/support/fixtures/tls/localhost_ca.pem"),
    visitorCount: positiveInteger(process.env.WORLDLOOM_BROWSER_VISITORS, 100),
    batchSize: positiveInteger(process.env.WORLDLOOM_BROWSER_BATCH_SIZE, 10),
    rampIntervalMs: positiveInteger(
      process.env.WORLDLOOM_BROWSER_RAMP_MS,
      2_000,
    ),
    holdMs: positiveInteger(process.env.WORLDLOOM_BROWSER_HOLD_MS, 60_000),
    readyTimeoutMs: positiveInteger(
      process.env.WORLDLOOM_BROWSER_READY_MS,
      45_000,
    ),
    advanceTimeoutMs: positiveInteger(
      process.env.WORLDLOOM_BROWSER_ADVANCE_MS,
      30_000,
    ),
    closeTimeoutMs: positiveInteger(
      process.env.WORLDLOOM_BROWSER_CLOSE_MS,
      30_000,
    ),
    minimumAdvances: positiveInteger(process.env.WORLDLOOM_BROWSER_ADVANCES, 2),
    drandCadenceMs: positiveInteger(
      process.env.WORLDLOOM_DRAND_CADENCE_MS,
      3_000,
    ),
    pollingCadenceMs: positiveInteger(
      process.env.WORLDLOOM_POLL_CADENCE_MS,
      1_000,
    ),
  }
}

function positiveInteger(candidate, fallback) {
  const parsed = Number(candidate)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback
}

function assertNoErrors(errors, heading) {
  if (errors.length > 0)
    throw new Error(`${heading}:\n- ${errors.join("\n- ")}`)
}

function sleep(milliseconds) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds))
}

const invokedModule = process.argv[1]
  ? pathToFileURL(resolve(process.argv[1])).href
  : null

if (import.meta.url === invokedModule) {
  main().catch((error) => {
    process.stderr.write(`${safeDiagnosticText(error.stack ?? error.message)}\n`)
    process.exitCode = 1
  })
}
