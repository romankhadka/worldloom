import {check} from "k6"
import {Counter, Rate} from "k6/metrics"

import {
  connectLiveView,
  leave,
  liveViewPushes,
} from "./phoenix_live_view.js"
import {
  balancedSnapshotComplete,
  mergeBalancedSnapshotObservation,
} from "./snapshot_observer.js"

const baseURL = __ENV.WORLDLOOM_BASE_URL ?? "http://localhost:4002"
const expectedSources = expectedSourceNames(
  __ENV.WORLDLOOM_EXPECTED_SOURCES ??
    "wikimedia,bluesky,ripe_ris,solana,drand,usgs,open_meteo",
)
const observationMs = positiveInteger(
  __ENV.WORLDLOOM_BALANCED_OBSERVATION_MS,
  30_000,
)

const liveViewJoinFailed = new Rate("worldloom_balanced_live_view_join_failed")
const protocolErrors = new Counter("worldloom_balanced_protocol_errors")

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    checks: ["rate==1"],
    worldloom_balanced_live_view_join_failed: ["rate==0"],
    worldloom_balanced_protocol_errors: ["count==0"],
  },
}

export default function () {
  const observation = {watermarks: [], sources: []}
  let joined = false

  const outcome = connectLiveView({
    baseURL,
    path: "/",
    holdForMs: observationMs,
    tags: {journey: "balanced-world"},
    onJoined: () => {
      joined = true
      liveViewJoinFailed.add(false)
    },
    onMessage: (message, client) => {
      for (const snapshot of liveViewPushes(message, "worldloom:snapshot")) {
        const updated = mergeBalancedSnapshotObservation(observation, snapshot)
        observation.watermarks = updated.watermarks
        observation.sources = updated.sources
      }

      if (balancedSnapshotComplete(observation, expectedSources)) leave(client)
    },
    onError: () => protocolErrors.add(1),
  })

  if (!joined) liveViewJoinFailed.add(true)

  check(
    {joined, outcome, observation, expectedSources},
    {
      "joined the real WorldLive process": (state) => state.joined,
      "observed two increasing committed snapshot watermarks": (state) =>
        state.observation.watermarks.length >= 2,
      "observed every enabled source in public snapshot roles": (state) =>
        balancedSnapshotComplete(state.observation, state.expectedSources),
      "completed without Phoenix protocol errors": (state) =>
        state.outcome.errors.length === 0,
    },
  )
}

function expectedSourceNames(encodedSources) {
  return [...new Set(encodedSources.split(",").map((source) => source.trim()))]
    .filter((source) => source.length > 0)
}

function positiveInteger(candidate, fallback) {
  const parsed = Number(candidate)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback
}
