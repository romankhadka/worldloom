import {check} from "k6"
import http from "k6/http"
import {Counter, Rate, Trend} from "k6/metrics"

import {
  connectLiveView,
  leave,
  liveViewPushes,
  liveViewReply,
  pushLiveViewEvent,
} from "./phoenix_live_view.js"
import {viewerHoldMsFor} from "./viewer_profile.js"

const baseURL = __ENV.WORLDLOOM_BASE_URL ?? "http://localhost:4000"
const profile = __ENV.WORLDLOOM_PROFILE ?? "smoke"
const viewerHoldMs = viewerHoldMsFor(profile)

const liveViewJoinFailed = new Rate("worldloom_live_view_join_failed")
const protocolErrors = new Counter("worldloom_protocol_errors")
const gestureAttempts = new Counter("worldloom_gesture_attempts")
const gestureCommitted = new Counter("worldloom_gesture_committed")
const gesturePolicyRejected = new Counter("worldloom_gesture_policy_rejected")
const gestureUnclassified = new Rate("worldloom_gesture_unclassified")
const gestureObservationMissed = new Rate(
  "worldloom_gesture_observation_missed",
)
const gestureObservation = new Trend("worldloom_gesture_observation_ms", true)

export const options = optionsFor(profile)

export default function () {
  viewer()
}

export function viewer() {
  let joinRecorded = false
  const outcome = connectLiveView({
    baseURL,
    path: "/",
    holdForMs: viewerHoldMs,
    tags: {journey: "viewer"},
    onJoined: (_client, joinedOutcome) => {
      joinRecorded = true
      liveViewJoinFailed.add(false, {journey: "viewer"})
      check(joinedOutcome, {
        "joined the real WorldLive process": (current) => current.joined,
      })
    },
    onError: (_error) => protocolErrors.add(1, {journey: "viewer"}),
  })

  if (!joinRecorded) {
    liveViewJoinFailed.add(true, {journey: "viewer"})
    check(outcome, {
      "joined the real WorldLive process": (current) => current.joined,
    })
  }
}

export function gesture() {
  http.cookieJar().clear(`${baseURL}/`)
  gestureAttempts.add(1)

  const state = {
    eventRef: null,
    startedAt: null,
    committedSequence: null,
    rejection: null,
    observedAt: {},
    observationRecorded: false,
  }

  const outcome = connectLiveView({
    baseURL,
    path: "/",
    holdForMs: 5_000,
    tags: {journey: "gesture"},
    onJoined: (client, joinedOutcome) => {
      liveViewJoinFailed.add(false, {journey: "gesture"})
      state.startedAt = Date.now()
      state.eventRef = pushLiveViewEvent(
        client,
        "weave-gesture",
        {gesture: "tug", lane: "0.5"},
        "form",
      )
      check(joinedOutcome, {
        "gesture visitor joined WorldLive": (current) => current.joined,
      })
    },
    onMessage: (message, client) => {
      for (const event of liveViewPushes(message, "worldloom:event")) {
        if (Number.isSafeInteger(event.sequence))
          state.observedAt[event.sequence] = Date.now()
      }

      for (const acknowledgement of liveViewPushes(
        message,
        "worldloom:gesture-accepted",
      )) {
        if (Number.isSafeInteger(acknowledgement.sequence)) {
          state.committedSequence = acknowledgement.sequence
        }
      }

      const reply = state.eventRef && liveViewReply(message, state.eventRef)
      if (reply && !state.committedSequence) {
        state.rejection = policyRejection(reply)
        if (state.rejection) leave(client)
      }

      recordObservation(state, client)
    },
    onError: (_error) => protocolErrors.add(1, {journey: "gesture"}),
  })

  if (!outcome.joined) liveViewJoinFailed.add(true, {journey: "gesture"})

  const classified =
    state.committedSequence !== null || state.rejection !== null
  gestureUnclassified.add(!classified)
  gestureObservationMissed.add(
    state.committedSequence !== null && !state.observationRecorded,
  )

  if (state.committedSequence !== null) gestureCommitted.add(1)
  if (state.rejection !== null)
    gesturePolicyRejected.add(1, {reason: state.rejection})

  check(state, {
    "gesture became durable or met an expected policy limit": (current) =>
      current.committedSequence !== null || current.rejection !== null,
    "durable gesture was observed on the live sequence": (current) =>
      current.committedSequence === null || current.observationRecorded,
  })
}

function recordObservation(state, client) {
  if (
    state.observationRecorded ||
    state.committedSequence === null ||
    state.observedAt[state.committedSequence] === undefined
  ) {
    return
  }

  gestureObservation.add(
    state.observedAt[state.committedSequence] - state.startedAt,
  )
  state.observationRecorded = true
  leave(client)
}

function policyRejection(reply) {
  const encodedReply = JSON.stringify(reply)
  const expectedMessages = {
    cooldown: "Try again in",
    rate_limited: "The loom is busy",
    not_live: "Return to the live edge",
    invalid: "Choose a valid gesture and lane",
    unavailable: "The gesture is unavailable",
  }

  return (
    Object.entries(expectedMessages).find(([_reason, message]) =>
      encodedReply.includes(message),
    )?.[0] ?? null
  )
}

function optionsFor(selectedProfile) {
  if (selectedProfile === "launch") return launchOptions()
  if (selectedProfile === "local") return localCapacityOptions()

  if (selectedProfile === "gesture-smoke") {
    return {
      scenarios: {
        gesture_smoke: {
          executor: "shared-iterations",
          exec: "gesture",
          vus: 1,
          iterations: Number(__ENV.WORLDLOOM_GESTURE_ITERATIONS ?? "1"),
          maxDuration: "15s",
        },
      },
      thresholds: smokeThresholds(),
    }
  }

  if (selectedProfile === "local-100") {
    return {
      scenarios: {
        viewers: {
          executor: "ramping-vus",
          exec: "viewer",
          startVUs: 0,
          stages: [
            {duration: "20s", target: 100},
            {duration: "2m", target: 100},
            {duration: "20s", target: 0},
          ],
          gracefulRampDown: "15s",
        },
        gestures: {
          executor: "constant-arrival-rate",
          exec: "gesture",
          startTime: "20s",
          duration: "60s",
          rate: 10,
          timeUnit: "1s",
          preAllocatedVUs: 50,
          maxVUs: 100,
        },
      },
      thresholds: launchOptions().thresholds,
    }
  }

  return {
    vus: 1,
    duration: __ENV.WORLDLOOM_DURATION ?? "10s",
    thresholds: smokeThresholds(),
  }
}

function launchOptions() {
  return {
    scenarios: {
      viewers: {
        executor: "ramping-vus",
        exec: "viewer",
        startVUs: 0,
        stages: [
          {duration: "2m", target: 200},
          {duration: "30m", target: 200},
          {duration: "2m", target: 0},
        ],
        gracefulRampDown: "15s",
      },
      gesture_burst: {
        executor: "constant-arrival-rate",
        exec: "gesture",
        startTime: "2m",
        duration: "60s",
        rate: 20,
        timeUnit: "1s",
        preAllocatedVUs: 100,
        maxVUs: 200,
      },
    },
    thresholds: {
      checks: ["rate>0.99"],
      http_req_failed: ["rate<0.01"],
      worldloom_live_view_join_failed: ["rate<0.01"],
      worldloom_protocol_errors: ["count==0"],
      worldloom_gesture_committed: ["count>0"],
      worldloom_gesture_unclassified: ["rate<0.01"],
      worldloom_gesture_observation_missed: ["rate<0.01"],
      worldloom_gesture_observation_ms: ["p(95)<300"],
    },
  }
}

function localCapacityOptions() {
  return {
    scenarios: {
      viewers: {
        executor: "ramping-vus",
        exec: "viewer",
        startVUs: 0,
        stages: [
          {duration: "30s", target: 200},
          {duration: "4m", target: 200},
          {duration: "30s", target: 0},
        ],
        gracefulRampDown: "15s",
      },
      gesture_burst: {
        executor: "constant-arrival-rate",
        exec: "gesture",
        startTime: "30s",
        duration: "60s",
        rate: 20,
        timeUnit: "1s",
        preAllocatedVUs: 100,
        maxVUs: 200,
      },
    },
    thresholds: launchOptions().thresholds,
  }
}

function smokeThresholds() {
  return {
    checks: ["rate==1"],
    http_req_failed: ["rate<0.01"],
    worldloom_live_view_join_failed: ["rate==0"],
    worldloom_protocol_errors: ["count==0"],
  }
}
