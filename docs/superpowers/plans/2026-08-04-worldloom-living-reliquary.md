# Worldloom Living Reliquary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Worldloom into an immersive Living Reliquary whose layered organism, meaningful gestures, and truthful public presentation match the quality of its Phoenix/OTP foundation.

**Architecture:** Preserve the existing persist-before-broadcast server and render contract. Strengthen the pure topology with a deterministic smoothed spine, project material metadata in geometry, paint bounded layered strokes from each structural command, and keep local placement/selection affordances in the renderer and hook. LiveView continues to own trusted detail, gesture policy, semantic UI, and public navigation.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, Phoenix LiveView 1.2, PostgreSQL, Canvas 2D, browser-native JavaScript modules, Node test runner, Playwright, k6, Docker, GitHub Actions.

---

## File responsibility map

### Existing files to modify

- `test/worldloom_web/live/world_live_test.exs` — LiveView semantics, privacy structure, gestures, selection, and curatorial UI.
- `lib/worldloom_web/live/world_live.ex` — trusted selection dismissal and cooldown presentation assigns.
- `lib/worldloom_web/live/world_live.html.heex` — opening statement, gesture language, contextual detail, lane seed semantics, and About content.
- `lib/worldloom_web/components/layouts/root.html.heex` — public document and social metadata.
- `assets/js/worldloom/topology.js` — deterministic primary spine and structural gesture relationships.
- `assets/js/worldloom/geometry.js` — spine/capillary projection and bounded material metadata.
- `assets/js/worldloom/renderer.js` — layered painting, lane seed, selection halo, and cached rendering.
- `assets/js/worldloom/hook.js` — pointer/touch lane placement, local control synchronization, copy feedback, and renderer selection.
- `assets/css/app.css` — Living Reliquary composition, material atmosphere, responsive hierarchy, and motion behavior.
- `assets/test/topology.test.js` — primary-spine invariants.
- `assets/test/geometry.test.js` — smooth projection and one-command material invariants.
- `assets/test/renderer.test.js` — layered drawing, seed, selection, bounds, and lifecycle.
- `assets/test/smoke.test.js` — stable public module surface.
- `e2e/worldloom.spec.js` — real desktop, mobile, keyboard, touch, reduced-motion, and two-browser experience.
- `load/phoenix_live_view.js` — correct LiveView form encoding and abnormal-close classification.
- `load/live_view_protocol.js` — pure event-value encoding shared by k6 and Node tests.
- `load/worldloom.js` — truthful 100-viewer profile and gesture evidence.
- `README.md` — current artwork-first public presentation with no false demo URL.
- `docs/operations.md` and `load/README.md` — corrected load commands and evidence boundaries.

### Files to create

- `assets/js/worldloom/placement.js` — pure mapping between pointer coordinates and normalized live-edge lanes.
- `assets/test/placement.test.js` — boundary and inverse-mapping tests.
- `assets/test/live_view_protocol.test.js` — Node-runnable tests for pure LiveView form-value encoding.
- `test/worldloom_web/controllers/page_metadata_test.exs` — LazyHTML assertions for public metadata.
- `priv/static/images/worldloom-social-preview.png` — screenshot captured from the verified deterministic app.

No new dependency, database migration, durable payload field, or render-contract version is planned.

## Task 1: Make the privacy contract deterministic

**Files:**
- Modify: `test/worldloom_web/live/world_live_test.exs:278-300`

- [ ] **Step 1: Reproduce and preserve the observed red baseline**

Run the untouched suite once and retain the observed failure in the execution notes:

```bash
rtk mix precommit
```

Expected: the audit run may fail at `world_live_test.exs:295` because a public visual float contains the digits `127`. The captured audit example is `"pulse" => 0.127611`; the stored map contains only `summary` and `visual`.

- [ ] **Step 2: Replace incidental substring checks with exact structure**

Replace the existing summary assertion and two serialized-string refutations after `Store.fetch/1` with:

```elixir
assert stored_event.payload["summary"] == "A visitor illuminated a thread"

assert stored_event.payload
       |> Map.keys()
       |> Enum.sort() == ["summary", "visual"]

assert stored_event.payload["visual"]
       |> Map.keys()
       |> Enum.sort() == ["bend", "pulse", "spread"]

refute Map.has_key?(stored_event.payload, "visitor_identity")
refute Map.has_key?(stored_event.payload, "peer_address")
```

This asserts the privacy boundary itself and cannot collide with numeric rendering values.

- [ ] **Step 3: Prove the test is stable across randomized nonces**

Run:

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs:278 --repeat-until-failure 100 --max-failures 1
```

Expected: 100 passes and no privacy false positive.

- [ ] **Step 4: Commit the isolated correction**

```bash
rtk git add test/worldloom_web/live/world_live_test.exs
rtk git commit -m "Stabilize the visitor payload privacy contract"
```

## Task 2: Repair real LiveView gesture load testing

**Files:**
- Create: `assets/test/live_view_protocol.test.js`
- Create: `load/live_view_protocol.js`
- Modify: `load/phoenix_live_view.js:1-110`
- Modify: `load/worldloom.js:1-250`
- Modify: `load/README.md`

- [ ] **Step 1: Write the failing protocol tests**

Create `assets/test/live_view_protocol.test.js`:

```javascript
import assert from "node:assert/strict"
import test from "node:test"

import {liveViewEventValue, socketCloseError} from "../../load/live_view_protocol.js"

test("encodes LiveView form values like a browser form submission", () => {
  assert.equal(
    liveViewEventValue({gesture: "tug", lane: "0.5"}, "form"),
    "gesture=tug&lane=0.5",
  )
  assert.equal(
    liveViewEventValue({note: "warm light", lane: 0.75}, "form"),
    "note=warm%20light&lane=0.75",
  )
})

test("preserves click values and already encoded form text", () => {
  const click = {sequence: 42}
  assert.equal(liveViewEventValue(click, "click"), click)
  assert.equal(liveViewEventValue("gesture=knot&lane=0.25", "form"), "gesture=knot&lane=0.25")
})

test("classifies only a close before client leave as unexpected", () => {
  assert.equal(socketCloseError(true), null)
  assert.equal(socketCloseError(false), "websocket closed before the LiveView client left")
})
```

- [ ] **Step 2: Run the test and verify RED**

```bash
rtk npm test
```

Expected: FAIL because `liveViewEventValue` is not exported.

- [ ] **Step 3: Implement browser-equivalent form encoding**

Create `load/live_view_protocol.js`:

```javascript
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
```

Import it at the top of `load/phoenix_live_view.js`:

```javascript
import {liveViewEventValue, socketCloseError} from "./live_view_protocol.js"
```

Then use it inside `pushLiveViewEvent`:

```javascript

export function pushLiveViewEvent(client, event, value = {}, type = "click") {
  return push(client, client.topic, "event", {
    type,
    event,
    value: liveViewEventValue(value, type),
    cid: null,
  })
}
```

Inside `connectLiveView`, register close classification after the existing error handler:

```javascript
socket.on("close", () => {
  const safeError = socketCloseError(client.leaving)
  if (!safeError) return
  outcome.errors.push(safeError)
  onError(safeError, outcome)
})
```

This follows the official k6 `k6/ws` event model: normal client shutdown calls `leave(client)` first; a remote or abnormal close before that is evidence, not success.

- [ ] **Step 4: Add an explicit 100-viewer profile**

Add to `optionsFor` in `load/worldloom.js`:

```javascript
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
```

Document these exact commands in `load/README.md`:

```bash
WORLDLOOM_PROFILE=gesture-smoke rtk k6 run load/worldloom.js
WORLDLOOM_PROFILE=local-100 rtk k6 run load/worldloom.js
```

- [ ] **Step 5: Verify GREEN and the real server boundary**

```bash
rtk npm test
WORLDLOOM_PROFILE=gesture-smoke rtk k6 run load/worldloom.js
```

Expected: Node tests pass; k6 reports one classified committed gesture, one observed sequence, zero protocol errors, and zero unclassified gestures.

- [ ] **Step 6: Commit the protocol repair**

```bash
rtk git add assets/test/live_view_protocol.test.js load/live_view_protocol.js load/phoenix_live_view.js load/worldloom.js load/README.md
rtk git commit -m "Repair real LiveView gesture load testing"
```

## Task 3: Define pure live-edge placement

**Files:**
- Create: `assets/js/worldloom/placement.js`
- Create: `assets/test/placement.test.js`

- [ ] **Step 1: Write failing coordinate tests**

Create `assets/test/placement.test.js`:

```javascript
import assert from "node:assert/strict"
import test from "node:test"

import {
  clientYForLane,
  laneFromClientY,
  withinLiveEdgeTarget,
} from "../js/worldloom/placement.js"

const bounds = {left: 20, top: 100, width: 1000, height: 600}

test("maps pointer height to the padded normalized lane", () => {
  assert.equal(laneFromClientY(140, bounds), 0)
  assert.equal(laneFromClientY(400, bounds), 0.5)
  assert.equal(laneFromClientY(660, bounds), 1)
  assert.equal(laneFromClientY(-100, bounds), 0)
  assert.equal(laneFromClientY(900, bounds), 1)
})

test("reverses a lane into the same live-edge height", () => {
  for (const lane of [0, 0.25, 0.5, 0.75, 1]) {
    const clientY = clientYForLane(lane, bounds)
    assert.equal(laneFromClientY(clientY, bounds), lane)
  }
})

test("limits direct placement to the live-edge target", () => {
  assert.equal(withinLiveEdgeTarget(990, bounds), true)
  assert.equal(withinLiveEdgeTarget(930, bounds), false)
})
```

- [ ] **Step 2: Run and verify RED**

```bash
rtk npm test
```

Expected: FAIL because `placement.js` does not exist.

- [ ] **Step 3: Implement the pure mapping**

Create `assets/js/worldloom/placement.js`:

```javascript
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
```

- [ ] **Step 4: Verify GREEN and commit**

```bash
rtk npm test
rtk git add assets/js/worldloom/placement.js assets/test/placement.test.js
rtk git commit -m "Define live-edge gesture placement"
```

## Task 4: Build a coherent deterministic spine

**Files:**
- Modify: `assets/test/topology.test.js`
- Modify: `assets/js/worldloom/topology.js`

- [ ] **Step 1: Write failing spine invariants**

Add to `assets/test/topology.test.js`:

```javascript
test("derives one calm primary spine through a busy public window", () => {
  const instructions = Array.from({length: 48}, (_item, index) =>
    instruction(index + 1, "wikimedia", {
      lane: index % 2 === 0 ? 0.08 : 0.92,
      visual: {spread: 0.5, bend: index % 3 === 0 ? 0.8 : -0.8, pulse: 0.75},
    }),
  )

  const topology = buildTopology(instructions)

  assert.equal(topology.spine.length, 48)
  assert.deepEqual(topology.spine.map(point => point.sequence), instructions.map(item => item.sequence))
  for (let index = 1; index < topology.spine.length; index++) {
    assert.ok(Math.abs(topology.spine[index].lane - topology.spine[index - 1].lane) <= 0.25)
  }
})

test("keeps spine derivation deterministic, bounded, and viewport independent", () => {
  const instructions = Array.from({length: 700}, (_item, index) => instruction(index + 1))
  const first = buildTopology(instructions)
  const second = buildTopology([...instructions].reverse().concat(instructions[500]))

  assert.deepEqual(second.spine, first.spine)
  assert.equal(first.spine.length, 600)
  assert.equal(first.spine[0].sequence, 101)
})
```

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/topology.test.js
```

Expected: FAIL because `topology.spine` is undefined.

- [ ] **Step 3: Add the bounded smoothed spine**

Initialize `spine: []` in `buildTopology` and call `extendSpine` before `extendFiber` for valid Wikimedia instructions:

```javascript
function extendSpine(topology, instruction) {
  const previous = topology.spine.at(-1)
  const lane = previous
    ? clampLane(
        previous.lane * 0.76 +
        instruction.lane * 0.24 +
        instruction.visual.bend * 0.012,
      )
    : instruction.lane

  topology.spine.push({
    id: `spine:${instruction.sequence}`,
    sequence: instruction.sequence,
    lane,
    source: instruction.source,
    intensity: instruction.intensity,
    visual: instruction.visual,
  })
}
```

Keep `spine` separate from interactive anchors so existing anchor and event limits retain their meaning. The ordered spine itself is bounded by the already sliced 600-instruction input.

- [ ] **Step 4: Make Tug alter the nearby settled spine**

When applying Tug, find the nearest spine point by normalized sequence/lane distance, modify that point and its immediate neighbors with the same bounded weighting used for branch anchors, and add these fields to the formation:

```javascript
function tugSpine(topology, instruction) {
  const target = nearestAnchor(topology.spine, instruction)
  if (!target) {
    return {affectedSpineIds: [], beforeSpineLanes: [], afterSpineLanes: []}
  }

  const targetIndex = topology.spine.findIndex(point => point.id === target.id)
  const affected = topology.spine.slice(Math.max(0, targetIndex - 1), targetIndex + 2)
  const beforeSpineLanes = affected.map(point => point.lane)

  for (const point of affected) {
    const neighborWeight = point.id === target.id ? 1 : 0.45
    const strength = (0.16 + instruction.intensity * 0.28) * neighborWeight
    point.lane = clampLane(
      point.lane + (instruction.lane - point.lane) * strength,
    )
  }

  return {
    affectedSpineIds: affected.map(point => point.id),
    beforeSpineLanes,
    afterSpineLanes: affected.map(point => point.lane),
  }
}
```

Spread `...tugSpine(topology, instruction)` into the Tug formation before returning from `applyTug`.

Add to the existing structural-gesture test:

```javascript
assert.ok(tug.affectedSpineIds.length >= 1)
assert.ok(tug.beforeSpineLanes.some((lane, index) => lane !== tug.afterSpineLanes[index]))
```

- [ ] **Step 5: Verify all topology tests and commit**

```bash
rtk node --test assets/test/topology.test.js
rtk npm test
rtk git add assets/js/worldloom/topology.js assets/test/topology.test.js
rtk git commit -m "Give the living weave a coherent primary spine"
```

## Task 5: Project layered fiber material without command inflation

**Files:**
- Modify: `assets/test/geometry.test.js`
- Modify: `assets/js/worldloom/geometry.js`

- [ ] **Step 1: Write failing material and composition tests**

Add to `assets/test/geometry.test.js`:

```javascript
test("projects a viewport-spanning primary spine with bounded material", () => {
  const instructions = Array.from({length: 40}, (_item, index) => ({
    ...contract[0],
    sequence: index + 1,
    lane: index % 2 === 0 ? 0.1 : 0.9,
  }))
  const scene = commandsForScene(instructions, {...viewport, maxSequence: 40})
  const spine = scene.find(command => command.type === "fiber-path" && command.role === "spine")

  assert.ok(spine)
  assert.ok(spine.segments.length > 20)
  assert.deepEqual(Object.keys(spine.material), ["glow", "body", "core"])
  assert.ok(spine.material.glow.width > spine.material.body.width)
  assert.ok(spine.material.body.width > spine.material.core.width)
  assert.ok(spine.material.glow.alpha <= 0.18)
})

test("derives cosmetic fiber layers from one structural command", () => {
  const instructions = Array.from({length: 60}, (_item, index) => ({
    ...contract[0],
    sequence: index + 1,
    lane: 0.5 + Math.sin(index / 8) * 0.2,
  }))
  const scene = commandsForScene(instructions, {...viewport, maxSequence: 60})
  const structuralPaths = scene.filter(command => command.type === "fiber-path")

  assert.ok(structuralPaths.every(command => command.material))
  assert.ok(scene.length <= 4000)
  assert.equal(scene.some(command => command.type === "fiber-glow-copy"), false)
})
```

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/geometry.test.js
```

Expected: FAIL because there is no `spine` path or material metadata.

- [ ] **Step 3: Add material metadata and spine projection**

Add:

```javascript
function materialFor(role, intensity) {
  const strength = Math.min(1, Math.max(0, intensity))
  const scale = role === "spine" ? 1.45 : role === "capillary" ? 0.58 : 1

  return {
    glow: {width: (7 + strength * 8) * scale, alpha: 0.08 + strength * 0.08},
    body: {width: (2.6 + strength * 2.8) * scale, alpha: 0.28 + strength * 0.22},
    core: {width: (0.7 + strength * 0.9) * scale, alpha: 0.72 + strength * 0.2},
  }
}
```

Project `topology.spine` through the existing Catmull-Rom function as one ordered `fiber-path` with `role: "spine"`. Project a bounded capillary only when an event anchor differs from its same-sequence spine point by at least `0.06` normalized lane. Add `material: materialFor(role, intensity)` to every `fiber-path`, including existing branches and connectors.

Use these focused helpers:

```javascript
function spineCommands(topology, viewport) {
  if (topology.spine.length < 2) return []

  const points = topology.spine.map(point => projectAnchor(point, viewport))
  const segments = topology.spine.slice(1).map((point, index) => {
    const previous = points[Math.max(0, index - 1)]
    const from = points[index]
    const to = points[index + 1]
    const next = points[Math.min(points.length - 1, index + 2)]
    const curve = clampCurve(catmullRomToBezier(previous, from, to, next), viewport)

    return {
      id: `spine-edge:${point.sequence}`,
      sequence: point.sequence,
      transitionSequence: point.sequence,
      curve,
      length: approximateCurveLength(curve),
      intensity: point.intensity,
      visual: point.visual,
    }
  })
  const intensity = average(segments.map(segment => segment.intensity))

  return [{
    type: "fiber-path",
    id: `path:spine:${topology.spine[0].sequence}:${topology.spine.at(-1).sequence}`,
    role: "spine",
    sequence: topology.spine.at(-1).sequence,
    segments,
    stroke: signalPalette.wikimedia.stroke,
    glow: signalPalette.wikimedia.glow,
    intensity,
    material: materialFor("spine", intensity),
  }]
}

function capillaryCommands(topology, viewport) {
  const spineBySequence = new Map(topology.spine.map(point => [point.sequence, point]))

  return topology.anchors.flatMap(anchor => {
    const spinePoint = spineBySequence.get(anchor.sequence)
    if (!spinePoint || Math.abs(anchor.lane - spinePoint.lane) < 0.06) return []

    const curve = connectorCurve(
      projectAnchor(spinePoint, viewport),
      projectAnchor(anchor, viewport),
      anchor.visual,
      viewport,
    )
    const segment = {
      id: `capillary:${anchor.sequence}`,
      sequence: anchor.sequence,
      transitionSequence: anchor.sequence,
      curve,
      length: approximateCurveLength(curve),
      intensity: anchor.intensity,
      visual: anchor.visual,
    }

    return [{
      type: "fiber-path",
      id: `path:capillary:${anchor.sequence}`,
      role: "capillary",
      sequence: anchor.sequence,
      segments: [segment],
      stroke: signalPalette.wikimedia.stroke,
      glow: signalPalette.wikimedia.glow,
      intensity: anchor.intensity,
      material: materialFor("capillary", anchor.intensity),
    }]
  })
}
```

Return ordering must paint atmosphere, chapter seams, spine, secondary paths, formations, fallbacks, then hit regions.

- [ ] **Step 4: Verify smoothness and bounded output**

```bash
rtk node --test assets/test/geometry.test.js
rtk npm test
```

Expected: all geometry and JavaScript tests pass; no scene exceeds 4,000 commands.

- [ ] **Step 5: Commit**

```bash
rtk git add assets/js/worldloom/geometry.js assets/test/geometry.test.js
rtk git commit -m "Project layered material across the living weave"
```

## Task 6: Paint the Living Reliquary and local affordances

**Files:**
- Modify: `assets/test/renderer.test.js`
- Modify: `assets/js/worldloom/renderer.js`

- [ ] **Step 1: Write failing renderer tests**

Add to `assets/test/renderer.test.js`:

```javascript
test("paints each fiber as glow, body, and luminous core", () => {
  const calls = cachedCallsFor({
    type: "fiber-path",
    sequence: 2,
    intensity: 0.7,
    stroke: "#63d7d1",
    glow: "#b6fff8",
    material: {
      glow: {width: 12, alpha: 0.12},
      body: {width: 4, alpha: 0.42},
      core: {width: 1.2, alpha: 0.86},
    },
    segments: [{
      sequence: 2,
      transitionSequence: 2,
      length: 100,
      curve: {
        from: {x: 10, y: 30},
        control1: {x: 35, y: 10},
        control2: {x: 65, y: 50},
        to: {x: 90, y: 30},
      },
    }],
  })

  assert.deepEqual(
    calls.filter(([name]) => name === "lineWidth").map(([_name, width]) => width),
    [12, 4, 1.2],
  )
  assert.equal(calls.filter(([name]) => name === "stroke").length, 3)
})

test("draws a bounded lane seed and selected-formation halo", () => {
  const canvas = fakeCanvas()
  const renderer = new Renderer(canvas, {width: 800, height: 600, reducedMotion: true})
  renderer.setEvents([instruction(1), instruction(2)])
  renderer.setTargetLane(0.25)
  renderer.setSelection(2)
  canvas.calls.length = 0

  renderer.draw()

  const arcs = canvas.calls.filter(([name]) => name === "arc")
  assert.ok(arcs.some(([_name, x, y]) => x === 786 && y === 170))
  assert.ok(arcs.length >= 2)
  assert.equal(renderer.targetLane, 0.25)
  assert.equal(renderer.selectedSequence, 2)
})
```

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/renderer.test.js
```

Expected: FAIL because layered widths and selection/target APIs do not exist.

- [ ] **Step 3: Paint material in three passes**

Replace the `fiber-path` branch in `drawCommand` with a helper that traces the same segments three times:

```javascript
function drawFiberPath(context, command) {
  const material = command.material ?? {
    glow: {width: 5, alpha: 0.08},
    body: {width: 2, alpha: 0.42},
    core: {width: 1, alpha: 0.82},
  }

  for (const [layer, style] of Object.entries(material)) {
    context.beginPath()
    context.lineWidth = style.width
    context.globalAlpha = style.alpha
    context.strokeStyle = layer === "glow" ? command.glow : command.stroke
    traceFiberSegments(context, command.segments)
    context.stroke()
  }
}

function traceFiberSegments(context, segments) {
  for (const segment of segments) {
    context.moveTo(segment.curve.from.x, segment.curve.from.y)
    context.bezierCurveTo(
      segment.curve.control1.x,
      segment.curve.control1.y,
      segment.curve.control2.x,
      segment.curve.control2.y,
      segment.curve.to.x,
      segment.curve.to.y,
    )
  }
}
```

Handle `fiber-path` before assigning the generic one-pass line width in `drawCommand`, restore the context, and return. This ensures its only width assignments are the three material passes. Do not use `shadowBlur`; the explicit passes are predictable and cached.

- [ ] **Step 4: Add bounded local target and selection state**

Initialize:

```javascript
this.targetLane = 0.5
this.selectedSequence = null
```

Add public methods:

```javascript
setTargetLane(lane) {
  this.targetLane = Math.min(1, Math.max(0, Number(lane) || 0))
  this.draw()
}

setSelection(sequence) {
  this.selectedSequence = Number.isSafeInteger(sequence) ? sequence : null
  this.draw()
}

clearSelection() {
  this.selectedSequence = null
  this.draw()
}
```

After cached scene and active transitions, draw the target seed at `width - 14` and `laneToY(targetLane, viewport())`, then draw a restrained halo around the selected command's hit-region center. Skip seed drawing away from the live edge and skip all pulsing in reduced motion.

Import `laneToY` with the existing geometry imports and add:

```javascript
function drawTargetSeed(context, lane, viewport, visible) {
  if (!visible) return

  const x = viewport.width - 14
  const y = laneToY(lane, viewport)
  context.save()
  context.fillStyle = "#f5ecd8"
  context.globalAlpha = 0.92
  context.beginPath()
  context.arc(x, y, 3.5, 0, Math.PI * 2)
  context.fill()
  context.restore()
}

function drawSelectionHalo(context, commands, sequence) {
  if (!Number.isSafeInteger(sequence)) return
  const selected = commands.find(command => command.sequence === sequence && command.hit)
  if (!selected) return

  const x = selected.hit.x + selected.hit.width / 2
  const y = selected.hit.y + selected.hit.height / 2
  context.save()
  context.strokeStyle = "#f5ecd8"
  context.globalAlpha = 0.54
  context.lineWidth = 1
  context.beginPath()
  context.arc(x, y, Math.max(selected.hit.width, selected.hit.height) * 0.62, 0, Math.PI * 2)
  context.stroke()
  context.restore()
}
```

Call them from `draw()` after translated scene drawing:

```javascript
drawTargetSeed(context, this.targetLane, this.viewport(), this.atLiveEdge())
drawTranslated(context, translationX, () =>
  drawSelectionHalo(context, this.commands, this.selectedSequence),
)
```

- [ ] **Step 5: Verify no animation-time topology rebuild**

```bash
rtk node --test assets/test/renderer.test.js
rtk npm test
```

Expected: all renderer lifecycle, cache, transition, and new material tests pass.

- [ ] **Step 6: Commit**

```bash
rtk git add assets/js/worldloom/renderer.js assets/test/renderer.test.js
rtk git commit -m "Render the weave as a layered living material"
```

## Task 7: Stage the semantic artwork and curatorial interface

**Files:**
- Modify: `test/worldloom_web/live/world_live_test.exs`
- Create: `test/worldloom_web/controllers/page_metadata_test.exs`
- Modify: `lib/worldloom_web/live/world_live.ex`
- Modify: `lib/worldloom_web/live/world_live.html.heex`
- Modify: `lib/worldloom_web/components/layouts/root.html.heex`

- [ ] **Step 1: Write failing LiveView experience tests**

Replace the expectation that the empty detail sheet always exists and add:

```elixir
test "stages the artwork without rendering empty detail chrome", %{conn: conn} do
  {:ok, live_view, _html} = live(conn, "/")

  assert has_element?(live_view, "#worldloom-introduction h1", "The world is weaving itself")
  assert has_element?(live_view, "#worldloom-introduction", "Public signals")
  assert has_element?(live_view, "#gesture-dock", "Touch the loom")
  refute has_element?(live_view, "#signal-detail")
end

test "dismisses trusted formation detail without changing its permalink", %{conn: conn} do
  [event] = seed_events(1, ~U[2026-08-03 15:00:00.000000Z])
  {:ok, live_view, _html} = live(conn, "/")

  render_hook(live_view, "select-formation", %{"sequence" => event.id})
  assert has_element?(live_view, "#signal-detail", "Public formation 1")

  live_view |> element("#signal-detail") |> render_keydown(%{"key" => "Escape"})
  refute has_element?(live_view, "#signal-detail")
end
```

Add assertions that each gesture button has exact `aria-label` and visible explanatory text, and that an active cooldown renders `#gesture-cooldown-ring[data-seconds]`.

Also assert `#mobile-worldloom-menu` contains Archive and About links so responsive CSS cannot make core navigation unreachable.

- [ ] **Step 2: Write failing metadata tests with LazyHTML**

Create `test/worldloom_web/controllers/page_metadata_test.exs`:

```elixir
defmodule WorldloomWeb.PageMetadataTest do
  use WorldloomWeb.ConnCase

  test "publishes complete truthful artwork metadata", %{conn: conn} do
    document =
      conn
      |> get("/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.filter("meta[name='description']") |> Enum.count() == 1
    assert document |> LazyHTML.filter("meta[property='og:title'][content*='Worldloom']") |> Enum.count() == 1
    assert document |> LazyHTML.filter("meta[property='og:image'][content$='/images/worldloom-social-preview.png']") |> Enum.count() == 1
    assert document |> LazyHTML.filter("meta[name='twitter:card'][content='summary_large_image']") |> Enum.count() == 1
    assert document |> LazyHTML.filter("meta[name='theme-color'][content='#07110f']") |> Enum.count() == 1
    assert document |> LazyHTML.filter("a[href*='WORLDLOOM_PUBLIC_URL']") |> Enum.empty?()
  end
end
```

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs test/worldloom_web/controllers/page_metadata_test.exs
```

Expected: FAIL because the introduction, conditional detail, cooldown ring, and metadata do not exist.

- [ ] **Step 4: Add trusted detail dismissal and cooldown duration**

In `WorldLive.mount/3`, assign `:cooldown_seconds` to `nil`. Set it in `begin_gesture_cooldown/3`, clear it in `clear_gesture_cooldown/1`, and add:

```elixir
def handle_event("clear-selection", _payload, socket) do
  {:noreply, assign(socket, selected_event: nil, selected_detail: nil)}
end
```

Do not clear the permalink or historical mode; dismissal hides the card without falsifying navigation state.

- [ ] **Step 5: Replace default UI sections with semantic Living Reliquary markup**

Add before the header:

```heex
<section id="worldloom-introduction" class="worldloom-introduction" aria-labelledby="worldloom-title">
  <p class="eyebrow">A living public record</p>
  <h1 id="worldloom-title">The world is weaving itself.</h1>
  <p>Public signals, becoming one persistent fabric.</p>
  <span aria-hidden="true">Move left through earlier hours.</span>
</section>
```

Give the dock a visible `Touch the loom` heading. Render action content as:

```heex
<span class="gesture-copy">
  <strong>{label}</strong>
  <small>{gesture_description(gesture)}</small>
</span>
```

Keep `aria-label={label}` so existing exact accessible names remain stable. Add a decorative lane seed to `#live-edge` and this cooldown element when active:

```heex
<span
  :if={@cooldown_seconds}
  id="gesture-cooldown-ring"
  class="gesture-cooldown-ring"
  data-seconds={@cooldown_seconds}
  style={"--cooldown-duration: #{@cooldown_seconds}s"}
  aria-hidden="true"
></span>
```

Define the visible descriptions in `WorldLive` so the template never derives arbitrary text:

```elixir
defp gesture_description("tug"), do: "Bend a strand"
defp gesture_description("knot"), do: "Join two paths"
defp gesture_description("illuminate"), do: "Awaken a junction"
```

Render `#signal-detail` only when `@selected_detail` is present. Add `phx-click-away="clear-selection"`, `phx-window-keydown="clear-selection"`, and `phx-key="Escape"` to that conditional aside.

Add a persistent semantic share-status target near the Share controls:

```heex
<p id="share-status" class="sr-only" aria-live="polite"></p>
```

Add a mobile-only native disclosure next to the viewer count so Archive and About are not removed on small screens:

```heex
<details id="mobile-worldloom-menu" class="mobile-worldloom-menu">
  <summary aria-label="Open Worldloom navigation">
    <.icon name="hero-ellipsis-horizontal" class="size-5" />
  </summary>
  <nav aria-label="Worldloom mobile navigation">
    <.link navigate={~p"/chapters"}>Archive</.link>
    <.link navigate={~p"/about"}>About</.link>
    <button type="button" phx-click="share">Share</button>
  </nav>
</details>
```

Keep this disclosure hidden at desktop widths. Replace the existing noscript copy with: `Worldloom needs JavaScript to draw the living fabric. Its public source, privacy contract, and data-source documentation remain available in the repository.`

Rewrite the About panel in the order specified by the design using this content structure:

```heex
<p class="about-lede">
  Worldloom is one living public record. Activity from across the world enters as
  fiber, tension, atmosphere, and light—then remains part of the same shared fabric.
</p>
<div class="about-sections">
  <section>
    <p class="eyebrow">The material</p>
    <h2>Public change, given form</h2>
    <p>Wikimedia edits extend connective threads. Earthquakes tighten ember knots.
      Weather changes the surrounding field. The work is interpretive, not an alerting tool.</p>
  </section>
  <section>
    <p class="eyebrow">Your touch</p>
    <h2>Shape the present, never rewrite the past</h2>
    <p>Tug bends a strand, Knot joins two paths, and Illuminate awakens a junction.
      Every gesture appears only after it becomes part of the persistent record.</p>
  </section>
  <section>
    <p class="eyebrow">A shared memory</p>
    <h2>The weave survives the room</h2>
    <p>Committed formations live in PostgreSQL and reopen through stable UTC chapter links.
      Connected browsers receive the same ordered artifact.</p>
  </section>
  <section>
    <p class="eyebrow">Privacy</p>
    <h2>No identity enters the artwork</h2>
    <p>There are no accounts, names, chat messages, uploads, profiles, or public cursors.
      Anonymous browser and network values exist only long enough to enforce contribution limits.</p>
  </section>
  <section>
    <p class="eyebrow">Access</p>
    <h2>The canvas is not the only way in</h2>
    <p>Keyboard, pointer, and touch controls share the same actions. Reduced motion,
      visible focus, structural signal shapes, and textual formation summaries remain available.</p>
  </section>
</div>
<div id="source-attribution" class="source-attribution">
  <h2>Public sources</h2>
  <a href="https://stream.wikimedia.org/" rel="noreferrer">Wikimedia EventStreams</a>
  <a href="https://earthquake.usgs.gov/" rel="noreferrer">USGS Earthquake Hazards</a>
  <a href="https://open-meteo.com/" rel="noreferrer">Open-Meteo</a>
</div>
<p class="about-technology">
  Worldloom is built with Phoenix LiveView, OTP, PubSub, Presence, PostgreSQL, and a
  deterministic Canvas 2D renderer.
  <a href="https://github.com/romankhadka/worldloom" rel="noreferrer">Read the public source</a>.
</p>
```

- [ ] **Step 6: Add public document metadata**

Add to `root.html.heex` before static assets:

```heex
<meta name="description" content="A persistent living tapestry woven from public signals and anonymous visitor gestures." />
<meta name="theme-color" content="#07110f" />
<meta property="og:type" content="website" />
<meta property="og:title" content="Worldloom · The world is weaving itself" />
<meta property="og:description" content="A persistent living tapestry woven from public signals and anonymous visitor gestures." />
<meta property="og:image" content={WorldloomWeb.Endpoint.url() <> "/images/worldloom-social-preview.png"} />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:title" content="Worldloom · The world is weaving itself" />
<meta name="twitter:description" content="Public signals, becoming one persistent fabric." />
<meta name="twitter:image" content={WorldloomWeb.Endpoint.url() <> "/images/worldloom-social-preview.png"} />
<link rel="icon" type="image/svg+xml" href={~p"/images/logo.svg"} />
```

Do not add a canonical URL before a hosted public origin exists.

- [ ] **Step 7: Verify GREEN and commit**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs test/worldloom_web/controllers/page_metadata_test.exs
rtk git add test/worldloom_web/live/world_live_test.exs test/worldloom_web/controllers/page_metadata_test.exs lib/worldloom_web/live/world_live.ex lib/worldloom_web/live/world_live.html.heex lib/worldloom_web/components/layouts/root.html.heex
rtk git commit -m "Stage Worldloom as an immersive public artwork"
```

## Task 8: Connect live-edge placement and local selection

**Files:**
- Modify: `assets/js/worldloom/hook.js`
- Modify: `assets/test/smoke.test.js`
- Modify: `lib/worldloom_web/live/world_live.html.heex`

- [ ] **Step 1: Add failing public-surface assertions**

Extend `assets/test/smoke.test.js`:

```javascript
import {laneFromClientY, withinLiveEdgeTarget} from "../js/worldloom/placement.js"

test("the live-edge placement surface remains importable without a DOM", () => {
  const bounds = {left: 0, top: 0, width: 800, height: 600}
  assert.equal(withinLiveEdgeTarget(790, bounds), true)
  assert.equal(laneFromClientY(300, bounds), 0.5)
})
```

Add `data-gesture-lane={@gesture_lane}` to `#loom-canvas` and a LiveView assertion for that attribute.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs
```

Expected: FAIL until the canvas exposes the lane contract.

- [ ] **Step 3: Synchronize range input and direct live-edge input**

Import placement helpers in `hook.js`:

```javascript
import {laneFromClientY, withinLiveEdgeTarget} from "./placement.js"
```

During `mounted`, initialize renderer target lane from the canvas dataset, find `#gesture-lane`, and listen for local input:

```javascript
this.laneInput = document.querySelector("#gesture-lane")
this.renderer.setTargetLane(Number(this.el.dataset.gestureLane ?? 0.5))

if (this.laneInput) {
  this.listen(this.laneInput, "input", event => {
    this.renderer.setTargetLane(Number(event.target.value))
  })
}
```

Capture the introduction and share-status targets and define local helpers:

```javascript
this.introduction = document.querySelector("#worldloom-introduction")
this.shareStatus = document.querySelector("#share-status")

this.dismissIntroduction = () => {
  if (this.introduction) this.introduction.dataset.dismissed = "true"
}

this.announceShare = message => {
  if (this.shareStatus) this.shareStatus.textContent = message
}
```

Call `dismissIntroduction()` on the first wheel, pointer-down, touch-start, range input, keyboard traversal, or gesture-button interaction. Update `copyLink` to announce `Link copied.` after clipboard success and `Select and copy this permanent link.` after focusing/selecting the fallback input.

Before normal pointer panning, detect the rightmost target zone:

```javascript
const placeLane = event => {
  const bounds = this.el.getBoundingClientRect()
  const lane = laneFromClientY(event.clientY, bounds)
  this.renderer.setTargetLane(lane)
  if (this.laneInput) this.laneInput.value = String(lane)
  this.pushEvent("lane-change", {lane: String(lane)})
  this.placedLane = true
}
```

Use `withinLiveEdgeTarget` on pointer down to enter placement mode, update while moving, and exit on pointer up/cancel. If `placedLane` is set, suppress the following formation-selection click. Retain the existing pan behavior outside the live-edge zone.

Implement the pointer listeners in this order:

```javascript
this.listen(this.el, "pointerdown", event => {
  if (event.pointerType === "touch") return
  const bounds = this.el.getBoundingClientRect()
  if (withinLiveEdgeTarget(event.clientX, bounds) && this.renderer.atLiveEdge()) {
    this.placingLane = true
    placeLane(event)
    return
  }
  this.renderer.pointerDown(event)
})

this.listen(this.el, "pointermove", event => {
  if (event.pointerType === "touch") return
  if (this.placingLane) {
    placeLane(event)
    return
  }
  this.renderer.pointerMove(event)
})

this.listen(this.el, "pointerup", () => {
  this.placingLane = false
  this.renderer.pointerUp()
})

this.listen(this.el, "pointercancel", () => {
  this.placingLane = false
  this.renderer.pointerUp()
})
```

Retain the dedicated one-finger touch path and replace its listeners with:

```javascript
this.listen(this.el, "touchstart", event => {
  const touch = event.touches?.length === 1 ? event.touches[0] : null
  if (!touch) return
  const bounds = this.el.getBoundingClientRect()
  if (withinLiveEdgeTarget(touch.clientX, bounds) && this.renderer.atLiveEdge()) {
    this.placingLane = true
    placeLane(touch)
    return
  }
  this.renderer.touchStart(event)
}, {passive: true})

this.listen(this.el, "touchmove", event => {
  if (this.placingLane && event.touches?.length === 1) {
    event.preventDefault()
    placeLane(event.touches[0])
    return
  }
  this.renderer.touchMove(event)
}, {passive: false})

this.listen(this.el, "touchend", () => {
  this.placingLane = false
  this.renderer.touchEnd()
})
```

This avoids processing the same touch through both Pointer Events and Touch Events.

At the start of the click listener:

```javascript
if (this.placedLane) {
  this.placedLane = false
  return
}
```

On successful hit testing and keyboard activation, call `renderer.setSelection(sequence)` before pushing trusted selection to LiveView. Listen for Escape to call `renderer.clearSelection()` while the server's `phx-window-keydown` clears trusted detail.

- [ ] **Step 4: Verify unit and LiveView contracts**

```bash
rtk npm test
rtk mix test test/worldloom_web/live/world_live_test.exs
```

- [ ] **Step 5: Commit**

```bash
rtk git add assets/js/worldloom/hook.js assets/test/smoke.test.js lib/worldloom_web/live/world_live.html.heex test/worldloom_web/live/world_live_test.exs
rtk git commit -m "Tie visitor gestures to the live membrane"
```

## Task 9: Apply the Living Reliquary art direction

**Files:**
- Modify: `e2e/worldloom.spec.js`
- Modify: `assets/css/app.css`

- [ ] **Step 1: Write failing composition assertions**

Add a Playwright test before changing CSS:

```javascript
test("the opening composition prioritizes unobstructed artwork", async ({page}) => {
  const canvas = await openWorldloom(page)
  const introduction = page.locator("#worldloom-introduction")

  await expect(introduction).toBeVisible()
  await expect(page.locator("#signal-detail")).toHaveCount(0)
  await expect(page.locator("#gesture-dock")).toContainText("Touch the loom")

  const headerStyle = await page.locator(".worldloom-header").evaluate(element => {
    const style = getComputedStyle(element)
    return {position: style.position, border: style.borderBottomWidth}
  })
  expect(headerStyle.position).toBe("absolute")
  expect(headerStyle.border).toBe("0px")

  const canvasBounds = await canvas.boundingBox()
  const dockBounds = await page.locator("#gesture-dock").boundingBox()
  expect(dockBounds.y + dockBounds.height).toBeLessThanOrEqual(canvasBounds.height)
})
```

- [ ] **Step 2: Run and verify RED**

```bash
rtk npm run test:e2e -- --grep "opening composition"
```

Expected: FAIL because the current header is relative with a border and the new composition is not styled.

- [ ] **Step 3: Establish the reliquary atmosphere**

Update root variables and shell layers:

```css
:root {
  --loom-ink: #07110f;
  --loom-deep: #030806;
  --loom-cyan: #69ded5;
  --loom-ember: #f0925e;
  --loom-moss: #849d68;
  --loom-gold: #d5bd78;
  --loom-ivory: #f5ecd8;
  --loom-muted: #a3aea7;
  --loom-panel: rgb(5 14 12 / 84%);
  --loom-border: rgb(245 236 216 / 17%);
}

.worldloom-shell {
  background:
    radial-gradient(ellipse at 74% 42%, rgb(105 222 213 / 8%), transparent 34%),
    radial-gradient(ellipse at 20% 76%, rgb(132 157 104 / 10%), transparent 40%),
    radial-gradient(ellipse at 52% 110%, rgb(213 189 120 / 7%), transparent 44%),
    linear-gradient(150deg, var(--loom-deep), var(--loom-ink) 46%, #0a1511);
}
```

Replace the hard grid texture and header/live-edge rules with:

```css
.worldloom-shell::before {
  position: absolute;
  inset: 0;
  z-index: -1;
  content: "";
  pointer-events: none;
  opacity: .22;
  background-image:
    repeating-linear-gradient(7deg, transparent 0 38px, rgb(105 222 213 / 2.8%) 39px 40px),
    repeating-linear-gradient(-11deg, transparent 0 61px, rgb(213 189 120 / 2%) 62px 63px);
  mask-image: radial-gradient(ellipse at center, black 20%, transparent 88%);
}

.worldloom-header {
  position: absolute;
  z-index: 20;
  top: 0;
  right: 0;
  left: 0;
  display: flex;
  min-height: 76px;
  padding: 16px clamp(18px, 3vw, 48px);
  border: 0;
  background: linear-gradient(to bottom, rgb(3 8 6 / 72%), transparent);
}

.live-edge {
  top: 76px;
  width: 18px;
  background: radial-gradient(ellipse at center, rgb(245 236 216 / 16%), transparent 68%);
  box-shadow: none;
}

.live-edge::after {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 50%;
  width: 1px;
  content: "";
  background: linear-gradient(transparent, rgb(245 236 216 / 76%) 28%, rgb(245 236 216 / 76%) 72%, transparent);
  box-shadow: 0 0 14px rgb(245 236 216 / 28%);
}

.worldloom-panel,
#mobile-detail-sheet,
.gesture-dock {
  border: 1px solid var(--loom-border);
  background: var(--loom-panel);
  box-shadow: 0 24px 80px rgb(0 0 0 / 34%);
  backdrop-filter: blur(18px);
}
```

Keep panel radii small and varied by purpose: the gesture dock may remain softly rounded, while curatorial and detail surfaces use restrained 2-6px corners.

- [ ] **Step 4: Stage introduction, gestures, detail, and cooldown**

Add complete rules for the new selectors:

```css
.worldloom-introduction {
  position: absolute;
  z-index: 9;
  top: clamp(112px, 18vh, 180px);
  left: clamp(22px, 7vw, 112px);
  max-width: min(34rem, calc(100vw - 44px));
  pointer-events: none;
  animation: reliquary-introduction 7s ease both;
}

.worldloom-introduction h1 {
  max-width: 12ch;
  margin: 0;
  font-family: var(--font-display);
  font-size: clamp(2.7rem, 7vw, 6.4rem);
  font-weight: 400;
  line-height: .92;
  letter-spacing: -.035em;
}

.worldloom-introduction > p:last-of-type,
.worldloom-introduction > span {
  display: block;
  margin-top: 18px;
  color: var(--loom-muted);
  font-size: .72rem;
  letter-spacing: .12em;
}

.worldloom-introduction[data-dismissed="true"] {
  opacity: 0;
  transform: translateY(-12px);
  visibility: hidden;
}

@keyframes reliquary-introduction {
  0%, 55% { opacity: 1; transform: translateY(0); }
  100% { opacity: 0; transform: translateY(-12px); visibility: hidden; }
}

.gesture-cooldown-ring {
  --cooldown-progress: 1;
  width: 16px;
  height: 16px;
  border: 1px solid rgb(245 236 216 / 24%);
  border-radius: 50%;
  background: conic-gradient(
    var(--loom-gold) calc(var(--cooldown-progress) * 1turn),
    transparent 0
  );
  animation: cooldown-unwind var(--cooldown-duration) linear forwards;
}

@property --cooldown-progress {
  syntax: "<number>";
  inherits: false;
  initial-value: 1;
}

@keyframes cooldown-unwind {
  to { --cooldown-progress: 0; opacity: .25; }
}
```

Style gesture subtitles, active seed, selected card, curatorial prose, legend, and timeline as one material system. Keep all targets at least 44px.

For `prefers-reduced-motion`, set the introduction directly to its quiet resting composition, remove cooldown rotation while retaining the ring, and preserve the existing renderer restrictions.

- [ ] **Step 5: Complete mobile composition**

At `max-width: 760px`, keep the introduction below the 60px header, reduce it to at most `3.2rem`, place selected detail above the dock, retain all three action labels, and ensure the lane control remains reachable. Hide the desktop navigation and show `#mobile-worldloom-menu`; its expanded surface must remain above the canvas and outside the gesture dock. Add restrained styles for the existing disconnected LiveView flash so the last committed artwork remains visually dominant while reconnecting.

- [ ] **Step 6: Verify GREEN and commit**

```bash
rtk npm run test:e2e -- --grep "opening composition"
rtk git add assets/css/app.css e2e/worldloom.spec.js
rtk git commit -m "Refine the Living Reliquary art direction"
```

## Task 10: Prove the complete interaction in browsers

**Files:**
- Modify: `e2e/worldloom.spec.js`
- Modify as failures require: `assets/js/worldloom/hook.js`, `assets/js/worldloom/renderer.js`, `assets/css/app.css`, `lib/worldloom_web/live/world_live.html.heex`

- [ ] **Step 1: Add failing direct-placement coverage**

Add:

```javascript
test("pointer visitors place a seed on the live membrane before weaving", async ({page}) => {
  const canvas = await openWorldloom(page)
  const bounds = await canvas.boundingBox()

  await canvas.dispatchEvent("pointerdown", {clientX: bounds.x + 100, clientY: bounds.y + 200})
  await canvas.dispatchEvent("pointerup")
  await expect(page.locator("#worldloom-introduction")).toBeHidden()

  await canvas.click({position: {x: bounds.width - 12, y: bounds.height * 0.25}})
  await expect(page.getByRole("slider", {name: "Gesture vertical lane"})).toHaveValue("0.2")

  const startingSequence = await renderedSequence(canvas)
  await page.getByRole("button", {name: "Tug", exact: true}).click()
  await expect.poll(async () => renderedSequence(canvas)).toBeGreaterThan(startingSequence)
})
```

The padded inverse mapping makes the expected snapped lane `0.2` at one-quarter of total canvas height.

- [ ] **Step 2: Add failing contextual-detail dismissal coverage**

After keyboard-selecting a formation:

```javascript
await expect(page.locator("#signal-detail")).toBeVisible()
await page.keyboard.press("Escape")
await expect(page.locator("#signal-detail")).toHaveCount(0)
```

Add an equivalent outside-click assertion and retain the permalink round-trip in its own selection.

- [ ] **Step 3: Add visible gesture-distinction coverage**

For each gesture in a fresh browser context, commit the action, wait for its sequence, and assert the canvas remains ready with no console/page/network/WebSocket failures. Use the accessible formation summary to assert the committed kind:

```javascript
const expectations = [
  ["Tug", /tugged the living edge/i],
  ["Knot", /tied a knot/i],
  ["Illuminate", /illuminated a thread/i],
]

for (const [label, summary] of expectations) {
  const context = await browser.newContext({
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
  })
  const gesturePage = await context.newPage()
  const failures = monitorPage(gesturePage, label)
  const gestureCanvas = await openWorldloom(gesturePage)
  const startingSequence = await renderedSequence(gestureCanvas)

  await gesturePage.getByRole("button", {name: label, exact: true}).click()
  await expect.poll(async () => renderedSequence(gestureCanvas)).toBeGreaterThan(startingSequence)
  await expect(gesturePage.locator("#accessible-formations button").last()).toContainText(summary)
  expect(failures).toEqual([])
  await context.close()
}
```

Do not inspect pixels for semantic correctness; pure topology/geometry tests already prove structural distinction.

- [ ] **Step 4: Add clipboard fallback coverage**

Open a fresh context with the clipboard API unavailable, select a formation, click Share, and assert the permanent-link field becomes focused and selected:

```javascript
await page.addInitScript(() => {
  Object.defineProperty(navigator, "clipboard", {value: undefined, configurable: true})
})

const canvas = await openWorldloom(page)
await canvas.focus()
await page.keyboard.press("ArrowRight")
await page.keyboard.press("Enter")
await page.getByRole("button", {name: "Share", exact: true}).click()

await expect(page.locator("#share-link")).toBeFocused()
await expect(page.locator("#share-status")).toHaveText("Select and copy this permanent link.")
expect(await page.locator("#share-link").evaluate(input => input.selectionStart)).toBe(0)
```

Extend the existing successful clipboard round trip with:

```javascript
await expect(page.locator("#share-status")).toHaveText("Link copied.")
```

- [ ] **Step 5: Run the focused tests and implement only observed gaps**

```bash
rtk npm run test:e2e -- --grep "place a seed|contextual-detail|gesture distinction|clipboard fallback"
```

Expected RED causes must be missing interaction behavior, not selector or timing mistakes. Implement the minimum hook/template/style corrections, then rerun until GREEN.

- [ ] **Step 6: Run the entire browser suite**

```bash
rtk npm run test:e2e
```

Expected: desktop, two-browser, keyboard, permalink, archive, reduced-motion, mobile touch, placement, dismissal, and all gesture paths pass with no browser failures.

- [ ] **Step 7: Commit**

```bash
rtk git add e2e/worldloom.spec.js assets/js/worldloom/hook.js assets/js/worldloom/renderer.js assets/css/app.css lib/worldloom_web/live/world_live.html.heex
rtk git commit -m "Prove the complete reliquary interaction"
```

## Task 11: Finish the public repository presentation

**Files:**
- Modify: `README.md`
- Modify: `docs/release-notes/v1.0.0.md`
- Create: `priv/static/images/worldloom-social-preview.png`

- [ ] **Step 1: Remove the false demo claim before adding a preview**

Change the README opening to:

```markdown
# Worldloom

> **The world is weaving itself.**

Worldloom is a persistent living tapestry woven in real time from Wikimedia edits,
earthquakes, global weather, and three small anonymous visitor gestures. The present
lives at the luminous right edge; move left to revisit earlier UTC chapters.

![Worldloom's Living Reliquary](priv/static/images/worldloom-social-preview.png)

Worldloom is currently available as public source and a local experience. A hosted
demo link will appear here only after public infrastructure is configured and verified.
```

Keep the architecture, setup, data, privacy, and operations sections below it. Remove every `WORLDLOOM_PUBLIC_URL` occurrence.

- [ ] **Step 2: Update release notes truthfully**

Add this release-note subsection:

```markdown
## Living Reliquary

- A deterministic primary spine and bounded capillaries make the canvas read as one
  layered organism rather than isolated plots.
- Glow, translucent body, and luminous core are painted from each structural command
  without expanding the durable event contract.
- Visitors place a warm seed directly on the live membrane before using Tug, Knot, or
  Illuminate; the visible weave still changes only after durable commit.
- Formation detail now appears only after selection, and About reads as a curatorial
  explanation before exposing the Phoenix/OTP machinery.
- The k6 client now sends real URL-encoded LiveView forms and rejects unexpected socket
  closure, replacing invalid gesture-load evidence.

Persist-before-broadcast, deterministic reconstruction, bounded browser work,
anonymous rate limits, stable permalinks, and reduced-motion behavior are unchanged.
```

- [ ] **Step 3: Build deterministic preview data**

Run the feed-disabled demo on an unused port:

```bash
WORLDLOOM_FEEDS_ENABLED=false rtk mix worldloom.seed_demo
PORT=4003 WORLDLOOM_FEEDS_ENABLED=false rtk mix phx.server
```

Keep the server in its managed long-running session for the capture and visual-review steps.

- [ ] **Step 4: Capture the verified artwork itself**

After confirming `#loom-canvas[data-ready='true']`, capture:

```bash
rtk npx playwright screenshot --browser chromium --viewport-size "1600,900" --wait-for-timeout 4000 http://localhost:4003 priv/static/images/worldloom-social-preview.png
```

Inspect the generated image at original resolution. Reject and correct the build if it shows chart-like geometry, empty panels, clipped controls, weak contrast, or indistinct depth. Recapture only after correcting the implementation and rerunning affected tests.

- [ ] **Step 5: Verify public text and commit**

```bash
rtk rg -n "WORLDLOOM_PUBLIC_URL|hello_phoenix|HelloPhoenix" . -g '!deps/**' -g '!_build/**' -g '!assets/node_modules/**'
rtk git add README.md docs/release-notes/v1.0.0.md priv/static/images/worldloom-social-preview.png
rtk git commit -m "Polish Worldloom's public presentation"
```

Expected: `rg` returns no matches; the commit contains the current verified screenshot, not a concept image.

## Task 12: Verify, integrate, and publish the completed pass

**Files:**
- Modify only if verification exposes a defect; every defect begins with a failing regression test.
- External metadata: `romankhadka/worldloom` GitHub repository.

- [ ] **Step 1: Run the complete local release gate**

Run independent suites in parallel where practical:

```bash
rtk mix precommit
rtk npm test
rtk npm run test:e2e
rtk docker build .
```

Expected: 134 or more Elixir tests pass, all Node tests pass, all Playwright tests pass, and the production image builds without errors. Dependency compile warnings already present upstream are not new project warnings; project compilation must remain warnings-as-errors clean.

- [ ] **Step 2: Run corrected interaction load evidence**

Against the verified local server:

```bash
WORLDLOOM_PROFILE=gesture-smoke WORLDLOOM_BASE_URL=http://localhost:4003 rtk k6 run load/worldloom.js
WORLDLOOM_PROFILE=local-100 WORLDLOOM_BASE_URL=http://localhost:4003 rtk k6 run load/worldloom.js
```

Expected thresholds:

- checks above 99%;
- HTTP failure rate below 1%;
- LiveView join failure below 1%;
- zero protocol errors;
- at least one committed gesture;
- unclassified and missed-observation rates below 1%;
- p95 committed-gesture observation below 300 milliseconds;
- process and memory return toward baseline after the test.

Do not claim the 200-viewer launch target until the exact hosted VM size exists and the unchanged launch profile passes there.

- [ ] **Step 3: Perform original-resolution visual review**

Capture desktop `1440x900`, mobile `390x844`, and reduced-motion desktop screenshots. Inspect each for:

- one coherent organism;
- glow/body/core depth;
- calm negative space;
- no empty detail panel;
- no dock, detail, or header overlap;
- visible live membrane and lane seed;
- legible focus and controls;
- no horizontal page overflow.

Record the screenshot paths and findings in the execution notes.

- [ ] **Step 4: Run final diff and history review**

```bash
rtk git diff master...HEAD --check
rtk git diff master...HEAD --stat
rtk git log --oneline master..HEAD
rtk git status --short --branch
```

Expected: clean whitespace, focused files, meaningful commits, and no uncommitted changes.

- [ ] **Step 5: Use the branch-finishing workflow**

Invoke `superpowers:verification-before-completion`, then `superpowers:finishing-a-development-branch`. Integrate with the repository-required command:

```bash
rtk wt merge --yes
```

Resolve no conflict by guessing. If the public `master` moved, inspect and re-run the complete affected verification after integration.

- [ ] **Step 6: Push the verified public master**

From the primary checkout:

```bash
rtk git push origin master
```

No force push is authorized.

- [ ] **Step 7: Complete GitHub About metadata**

After the verified revision is public:

```bash
rtk gh repo edit romankhadka/worldloom \
  --description "A persistent living tapestry woven from public signals and anonymous visitor gestures, built with Phoenix LiveView and OTP." \
  --add-topic elixir \
  --add-topic phoenix \
  --add-topic liveview \
  --add-topic creative-coding \
  --add-topic generative-art \
  --add-topic canvas \
  --add-topic real-time
```

Do not set a homepage until a real hosted URL is reachable.

- [ ] **Step 8: Verify GitHub CI and public state**

```bash
rtk gh run list --branch master --limit 1
rtk gh run watch --exit-status
rtk gh repo view romankhadka/worldloom
```

Expected: Elixir, JavaScript, Browser, and Container jobs pass; deployment remains truthfully skipped without Fly configuration; description and topics are populated; `master` is the default public branch.

If CI exposes a failure, reproduce it locally, use systematic debugging, add a failing regression test, fix only the root cause, rerun the release gate, and push a new meaningful commit.
