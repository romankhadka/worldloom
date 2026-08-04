# Connected Living Weave Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Worldloom's short isolated marks with a deterministic connected spline network and make Tug, Knot, and Illuminate direct, visibly distinct actions.

**Architecture:** Add a pure viewport-independent topology builder, project that graph through centripetal Catmull–Rom splines, and let the renderer own only drawing, bounded transitions, and a detached-canvas cache. Keep the durable instruction contract unchanged; LiveView continues to persist before broadcasting and changes only the gesture-control boundary from select-then-confirm to direct form submission.

**Tech Stack:** Phoenix LiveView 1.2, Elixir 1.20, Canvas 2D, ECMAScript modules, Node 24 test runner, Playwright Chromium.

**Design:** `docs/superpowers/specs/2026-08-03-connected-living-weave-design.md`

---

## File structure

- Create `assets/js/worldloom/topology.js`: pure instruction-to-graph transformation; no DOM, canvas, viewport, or clock dependency.
- Create `assets/test/topology.test.js`: topology determinism, connectivity, gesture semantics, malformed input, and bounds.
- Modify `assets/js/worldloom/geometry.js`: graph projection, centripetal Catmull–Rom conversion, long connected commands, hit regions, seams, and fallbacks.
- Modify `assets/test/geometry.test.js`: smooth-join, long-span, resize, source-role, and fallback contracts.
- Modify `assets/js/worldloom/renderer.js`: settled-layer caching, bounded transition state, growth interpolation, breathing, and lifecycle cleanup.
- Modify `assets/test/renderer.test.js`: cache invalidation, no rebuild during ticks, transition cap, settled reconstruction, and reduced motion.
- Modify `lib/worldloom_web/live/world_live.ex`: remove gesture selection state, parse submitted lanes at the LiveView boundary, and commit direct actions.
- Modify `lib/worldloom_web/live/world_live.html.heex`: replace choice buttons plus Weave confirmation with one accessible three-action form.
- Modify `assets/css/app.css`: style direct action/loading/cooldown states and retain mobile target sizes.
- Modify `test/worldloom_web/live/world_live_test.exs`: direct submit, malformed lane, cooldown, historical, and accessible markup tests.
- Modify `e2e/worldloom.spec.js`: two-browser, keyboard, mobile, and reduced-motion flows using direct action buttons.
- Modify `ARCHITECTURE.md`: document the topology/projection/cache boundary and direct persisted gestures.

### Task 1: Build the viewport-independent topology graph

**Files:**

- Create: `assets/js/worldloom/topology.js`
- Create: `assets/test/topology.test.js`

- [ ] **Step 1: Write failing topology contract tests**

Create fixtures through a local helper and assert deterministic graph identities, connected Wikimedia branches, and three distinct visitor effects:

```javascript
import assert from "node:assert/strict"
import test from "node:test"

import {buildTopology} from "../js/worldloom/topology.js"

const sourceForKind = kind => {
  if (kind === "wikimedia") return "wikimedia"
  if (kind === "earthquake") return "usgs"
  if (kind === "weather") return "open_meteo"
  return "visitor"
}

const instruction = (sequence, kind = "wikimedia", overrides = {}) => ({
  sequence,
  kind,
  source: sourceForKind(kind),
  occurred_at: `2026-08-03T12:00:${String(sequence % 60).padStart(2, "0")}.000000Z`,
  render_version: 1,
  seed: sequence * 7919,
  lane: (sequence % 8) / 8,
  intensity: 0.6,
  visual: {spread: 0.5, bend: 0.25, pulse: 0.75},
  summary: `Formation ${sequence}`,
  ...overrides,
})

test("builds the same bounded topology regardless of input order and duplicates", () => {
  const ordered = Array.from({length: 24}, (_item, index) => instruction(index + 1))
  const first = buildTopology(ordered)
  const second = buildTopology([...ordered].reverse().concat(ordered[5]))

  assert.deepEqual(second, first)
  assert.equal(first.anchors.length, 24)
  assert.ok(first.edges.length > 0)
  assert.ok(first.edges.every(edge => first.anchors.some(anchor => anchor.id === edge.from)))
  assert.ok(first.edges.every(edge => first.anchors.some(anchor => anchor.id === edge.to)))
})

test("derives structural tug, knot, and illuminate effects", () => {
  const fibers = Array.from({length: 18}, (_item, index) => instruction(index + 1))
  const topology = buildTopology([
    ...fibers,
    instruction(19, "tug", {lane: 0.8}),
    instruction(20, "knot", {lane: 0.5}),
    instruction(21, "illuminate", {lane: 0.25}),
  ])

  const tug = topology.formations.find(item => item.kind === "tug")
  const knot = topology.formations.find(item => item.kind === "knot")
  const illuminate = topology.formations.find(item => item.kind === "illuminate")

  assert.ok(tug.affectedAnchorIds.length >= 1)
  assert.ok(tug.beforeLanes.some((lane, index) => lane !== tug.afterLanes[index]))
  assert.ok(knot.edgeId || knot.loopAnchorId)
  assert.ok(illuminate.anchorId)
})

test("keeps malformed and unsupported instructions as bounded fallbacks", () => {
  const topology = buildTopology([
    instruction(1),
    {...instruction(2), lane: Number.NaN},
    {...instruction(3), render_version: 99},
  ])

  assert.equal(topology.fallbacks.length, 2)
  assert.equal(topology.anchors.length, 1)
})
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
rtk proxy node --test assets/test/topology.test.js
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `topology.js`.

- [ ] **Step 3: Implement the pure graph builder**

Create `topology.js` with these exported and internal contracts:

```javascript
const supportedRenderVersion = 1
const maximumInstructions = 600
const laneReach = 0.34
const maximumSequenceGap = 12

export function buildTopology(instructions) {
  const ordered = uniqueInstructions(instructions).slice(-maximumInstructions)
  const topology = {anchors: [], edges: [], formations: [], fallbacks: [], ambient: null}

  for (const item of ordered) {
    if (!validInstruction(item)) {
      topology.fallbacks.push(fallbackFor(item))
      continue
    }

    switch (item.kind) {
      case "wikimedia":
        extendFiber(topology, item)
        break
      case "earthquake":
        attachEarthquake(topology, item)
        break
      case "weather":
        topology.ambient = item
        break
      case "tug":
        applyTug(topology, item)
        break
      case "knot":
        applyKnot(topology, item)
        break
      case "illuminate":
        applyIlluminate(topology, item)
        break
      default:
        topology.fallbacks.push(fallbackFor(item))
    }
  }

  return topology
}
```

Implement stable ids as `anchor:<sequence>`, `edge:<from>:<to>`, and `formation:<sequence>`. Fiber predecessor ranking must use normalized lane distance, sequence distance, then stable anchor id. A disconnected new branch must receive one connector to the nearest established anchor. Tug records before/after lanes for the chosen anchor and its same-branch neighbors. Knot stores either a cross-branch edge id or a loop anchor id. Illuminate and earthquakes attach to the nearest normalized anchor. Every nearest lookup returns a safe fallback formation when no anchor exists.

- [ ] **Step 4: Run topology tests and the complete Node unit suite**

Run:

```bash
rtk proxy node --test assets/test/topology.test.js
rtk npm test
```

Expected: topology tests PASS and the existing Node suite remains green.

- [ ] **Step 5: Commit the topology unit**

```bash
rtk git add assets/js/worldloom/topology.js assets/test/topology.test.js
rtk git commit -m "Build deterministic weave topology"
```

### Task 2: Project smooth connected spline commands

**Files:**

- Modify: `assets/js/worldloom/geometry.js`
- Modify: `assets/test/geometry.test.js`

- [ ] **Step 1: Add failing spline and long-run tests**

Import `buildTopology`, exercise a dense fixture, and add helpers that compare the outgoing tangent of one cubic segment with the incoming tangent of the next:

```javascript
test("projects long connected runs with continuous shared tangents", () => {
  const instructions = Array.from({length: 40}, (_item, index) => ({
    ...contract[0],
    sequence: index + 1,
    seed: index + 101,
    lane: 0.42 + Math.sin(index / 5) * 0.18,
  }))
  const commands = commandsForScene(instructions, viewport)
  const paths = commands.filter(command => command.type === "fiber-path")
  const segments = paths.flatMap(path => path.segments)

  assert.ok(segments.length >= 20)
  assert.ok(paths.slice(0, -1).every(path => path.width >= viewport.width * 0.35))
  assert.ok(paths.every(path => path.width <= viewport.width * 0.65))

  for (const [left, right] of adjacentConnectedSegments(segments)) {
    assert.deepEqual(left.to, right.from)
    assert.ok(tangentDifference(left, right) < 1e-6)
  }
})

test("projects visitor gestures as deformation, connector, and bloom commands", () => {
  const commands = commandsForScene(contract, viewport)

  assert.ok(commands.some(command => command.type === "tug-response"))
  assert.ok(commands.some(command => command.type === "knot-connector"))
  assert.ok(commands.some(command => command.type === "illuminate-bloom"))
})
```

Update the existing type assertions from `fiber`, `tug`, `knot`, and `glow` to the graph-based command types while retaining ambient, ripple, seam, hit, and fallback coverage.

- [ ] **Step 2: Run geometry tests and verify RED**

```bash
rtk proxy node --test assets/test/geometry.test.js
```

Expected: FAIL because connected spline commands do not yet exist.

- [ ] **Step 3: Implement graph projection and Catmull–Rom conversion**

Refactor `commandsForScene` to call `buildTopology(instructions)`, project normalized anchors through `sequenceToX` and `laneToY`, and produce stable commands. Add these pure helpers:

```javascript
export function catmullRomToBezier(previous, from, to, next) {
  const alpha = 0.5
  const t0 = 0
  const t1 = t0 + Math.max(distance(previous, from) ** alpha, 0.0001)
  const t2 = t1 + Math.max(distance(from, to) ** alpha, 0.0001)
  const t3 = t2 + Math.max(distance(to, next) ** alpha, 0.0001)
  const interval = t2 - t1
  const fromTangent = scaleVector(catmullTangent(previous, from, to, t0, t1, t2), interval)
  const toTangent = scaleVector(catmullTangent(from, to, next, t1, t2, t3), interval)

  return {
    from,
    control1: addVector(from, scaleVector(fromTangent, 1 / 3)),
    control2: addVector(to, scaleVector(toTangent, -1 / 3)),
    to,
  }
}

function catmullTangent(previous, current, next, t0, t1, t2) {
  return addVector(
    subtractVector(
      divideVector(subtractVector(current, previous), t1 - t0),
      divideVector(subtractVector(next, previous), t2 - t0),
    ),
    divideVector(subtractVector(next, current), t2 - t1),
  )
}

function addVector(left, right) {
  return {x: left.x + right.x, y: left.y + right.y}
}

function subtractVector(left, right) {
  return {x: left.x - right.x, y: left.y - right.y}
}

function scaleVector(vector, amount) {
  return {x: vector.x * amount, y: vector.y * amount}
}

function divideVector(vector, amount) {
  return scaleVector(vector, 1 / amount)
}

function distance(left, right) {
  return Math.hypot(right.x - left.x, right.y - left.y)
}

function interpolate(from, to, progress) {
  return {
    x: from.x + (to.x - from.x) * progress,
    y: from.y + (to.y - from.y) * progress,
  }
}

export function cubicPrefix(curve, progress) {
  const bounded = Math.min(1, Math.max(0, progress))
  const first = interpolate(curve.from, curve.control1, bounded)
  const second = interpolate(curve.control1, curve.control2, bounded)
  const third = interpolate(curve.control2, curve.to, bounded)
  const fourth = interpolate(first, second, bounded)
  const fifth = interpolate(second, third, bounded)
  return {from: curve.from, control1: first, control2: fourth, to: interpolate(fourth, fifth, bounded)}
}
```

Duplicate branch endpoints for missing boundary neighbors, clamp projected controls to vertical viewport padding while preserving offscreen timeline x coordinates, and group connected cubic segments into `fiber-path` commands spanning 35–65% of viewport width when history permits. Each path retains its per-edge segment ids, sequences, approximate lengths, curves, intensities, and transition sequences so animation remains local. Emit separate invisible `anchor-hit` commands so every durable formation retains keyboard, tap, detail, and permalink selection. Preserve chapter seams, ambient weather, and future-version fallbacks.

- [ ] **Step 4: Run geometry and Node tests**

```bash
rtk proxy node --test assets/test/geometry.test.js
rtk npm test
```

Expected: all geometry and Node tests PASS.

- [ ] **Step 5: Commit projection**

```bash
rtk git add assets/js/worldloom/geometry.js assets/test/geometry.test.js
rtk git commit -m "Project connected living fibers"
```

### Task 3: Add bounded growth, settled caching, and breathing

**Files:**

- Modify: `assets/js/worldloom/renderer.js`
- Modify: `assets/test/renderer.test.js`

- [ ] **Step 1: Write failing renderer lifecycle tests**

Make `projectScene`, `createCanvas`, and `requestFrame` injectable. Extend the fake context with `drawImage`, `translate`, and a call log, then add:

```javascript
import {commandsForScene} from "../js/worldloom/geometry.js"

test("rebuilds topology on scene changes but never during animation ticks", () => {
  let projections = 0
  const renderer = new Renderer(fakeCanvas(), {
    width: 800,
    height: 600,
    projectScene: (...arguments_) => {
      projections++
      return commandsForScene(...arguments_)
    },
    createCanvas: fakeCanvas,
  })

  renderer.setEvents([instruction(1), instruction(2)])
  const afterRebuild = projections
  renderer.step(16)
  renderer.step(32)

  assert.equal(projections, afterRebuild)
})

test("bounds active transitions and settles the oldest", () => {
  const renderer = new Renderer(fakeCanvas(), {width: 800, height: 600, createCanvas: fakeCanvas})
  renderer.setEvents([instruction(1)])
  for (let sequence = 2; sequence <= 11; sequence++) renderer.receiveEvent(instruction(sequence))

  assert.equal(renderer.activeTransitions.size, 8)
  assert.equal(renderer.activeTransitions.has(2), false)
})

test("reduced motion reconstructs directly into the settled cache", () => {
  let frameRequests = 0
  const renderer = new Renderer(fakeCanvas(), {
    reducedMotion: true,
    createCanvas: fakeCanvas,
    requestFrame: () => frameRequests++,
  })
  renderer.setEvents([instruction(1), instruction(2)])
  renderer.receiveEvent(instruction(3))
  renderer.start()

  assert.equal(renderer.activeTransitions.size, 0)
  assert.equal(frameRequests, 0)
  assert.equal(renderer.cacheDirty, false)
})

test("destroy cancels animation and releases cached and transient state", () => {
  let cancelledHandle
  const renderer = new Renderer(fakeCanvas(), {
    createCanvas: fakeCanvas,
    requestFrame: () => 17,
    cancelFrame: handle => (cancelledHandle = handle),
  })
  renderer.start()
  renderer.destroy()

  assert.equal(cancelledHandle, 17)
  assert.equal(renderer.frameHandle, null)
  assert.equal(renderer.activeTransitions.size, 0)
  assert.equal(renderer.cacheCanvas, null)
  assert.equal(renderer.cacheContext, null)
})
```

- [ ] **Step 2: Run renderer tests and verify RED**

```bash
rtk proxy node --test assets/test/renderer.test.js
```

Expected: FAIL for missing injection, transition, and cache behavior.

- [ ] **Step 3: Implement renderer lifecycle and drawing**

Add constructor defaults and bounded state:

```javascript
this.projectScene = options.projectScene ?? commandsForScene
this.createCanvas = options.createCanvas ?? (() => globalThis.document?.createElement?.("canvas") ?? null)
this.cacheCanvas = this.createCanvas()
this.cacheContext = this.cacheCanvas?.getContext?.("2d") ?? null
this.activeTransitions = new Map()
this.maximumTransitions = 8
this.cacheDirty = true
```

`rebuild()` calls `projectScene` once, marks the cache dirty, rebuilds the settled cache, and draws. Initial load, catch-up, reload, history, resize, and pan settle all transitions. `receiveEvent` alone records a transition for the committed sequence when full motion is enabled. Transition duration is `clamp(700, command.length * 1.8, 1300)` for fibers and the fixed Tug/Knot/Illuminate durations from the design.

During active transitions, draw settled commands normally except for the active command's transient treatment: use `cubicPrefix` for new fiber and connector growth, interpolate Tug's before/after curves, and scale bloom/ripple alpha and radius. Once a transition completes, delete it and refresh the settled cache. When more than eight are active, delete the oldest before adding the next.

When no transition is active, draw the detached settled canvas with a 12-second sinusoidal translation no larger than 1.25 CSS pixels and alpha variation no larger than 0.04. Continue drawing bounded viewer pulses above it. Cache dimensions track CSS size times DPR. `destroy()` cancels the frame, clears transitions, and nulls cache references.

- [ ] **Step 4: Run renderer and complete Node tests**

```bash
rtk proxy node --test assets/test/renderer.test.js
rtk npm test
```

Expected: all renderer and Node tests PASS.

- [ ] **Step 5: Commit renderer lifecycle**

```bash
rtk git add assets/js/worldloom/renderer.js assets/test/renderer.test.js
rtk git commit -m "Animate and cache the living weave"
```

### Task 4: Replace gesture selection with direct persisted actions

**Files:**

- Modify: `lib/worldloom_web/live/world_live.ex`
- Modify: `lib/worldloom_web/live/world_live.html.heex`
- Modify: `assets/css/app.css`
- Modify: `test/worldloom_web/live/world_live_test.exs`

- [ ] **Step 1: Replace selection tests with failing direct-action tests**

Add a test that submits each named button through the form and proves the clicked gesture and current numeric lane reach the committed broadcast without a Weave control:

```elixir
test "gesture buttons commit directly at the current lane", %{conn: conn} do
  {:ok, live_view, _html} = live(conn, "/")

  live_view
  |> form("#gesture-lane-form", %{"lane" => "0.7", "gesture" => "illuminate"})
  |> render_submit()

  assert_push_event live_view, "worldloom:event", %{
    "kind" => "illuminate",
    "source" => "visitor",
    "lane" => 0.7
  }

  refute has_element?(live_view, "#weave-gesture")
  refute has_element?(live_view, "[aria-pressed]")
  assert has_element?(live_view, "#gesture-illuminate[name='gesture'][value='illuminate']")
  assert has_element?(live_view, "#gesture-status", "Gesture joined the living edge")
end

test "direct gesture boundary rejects malformed lane text", %{conn: conn} do
  {:ok, live_view, _html} = live(conn, "/")

  live_view
  |> form("#gesture-lane-form", %{"gesture" => "tug", "lane" => "sideways"})
  |> render_submit()

  assert has_element?(live_view, "#gesture-status", "Choose a valid gesture and lane")
end
```

Update historical and cooldown tests to assert all three `.gesture-button` controls are disabled. Remove assertions for selected gesture state and the Weave button.

- [ ] **Step 2: Run LiveView tests and verify RED**

```bash
rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
```

Expected: FAIL because the old two-step controls still render.

- [ ] **Step 3: Implement the direct gesture form**

Remove `:selected_gesture`, `select-gesture`, and `weave-selected`. Add a strict form boundary:

```elixir
def handle_event(
      "weave-gesture",
      %{"gesture" => gesture, "lane" => encoded_lane},
      socket
    )
    when gesture in ["tug", "knot", "illuminate"] and is_binary(encoded_lane) do
  case Float.parse(encoded_lane) do
    {lane, ""} -> commit_gesture(%{"gesture" => gesture, "lane" => clamp_lane(lane)}, socket)
    _invalid -> {:noreply, assign(socket, :gesture_status, "Choose a valid gesture and lane.")}
  end
end

def handle_event("weave-gesture", _payload, socket) do
  {:noreply, assign(socket, :gesture_status, "Choose a valid gesture and lane.")}
end

def handle_info(:gesture_ready, socket) do
  {:noreply,
   assign(socket,
     cooldown_until: nil,
     gesture_status: "Choose an action for the live edge."
   )}
end
```

After a successful commit, schedule `Process.send_after(self(), :gesture_ready, 30_000)` and assign `cooldown_until`. Render one `phx-submit="weave-gesture"` form containing the range input and three submit buttons. Each button has `name="gesture"`, its allow-listed value, `phx-disable-with="Weaving…"`, a stable id, and no `aria-pressed`. Disable all three when the view is historical, panned away, or `cooldown_until` is present. Keep `aria-disabled`, lane label, and polite status. Remove the separate Weave button.

Update CSS so `.gesture-actions` and `.lane-control` remain legible in the single form, `.phx-submit-loading .gesture-button` communicates pending state, and all action buttons retain 44 CSS-pixel desktop and 48 CSS-pixel mobile heights. Remove `.weave-gesture` rules.

- [ ] **Step 4: Run focused Elixir and formatting gates**

```bash
rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
rtk proxy asdf exec mix format --check-formatted lib/worldloom_web/live/world_live.ex test/worldloom_web/live/world_live_test.exs
```

Expected: LiveView tests PASS and formatting is clean.

- [ ] **Step 5: Commit direct gesture controls**

```bash
rtk git add lib/worldloom_web/live/world_live.ex lib/worldloom_web/live/world_live.html.heex assets/css/app.css test/worldloom_web/live/world_live_test.exs
rtk git commit -m "Make visitor gestures direct actions"
```

### Task 5: Prove integrated browser behavior and document the renderer boundary

**Files:**

- Modify: `e2e/worldloom.spec.js`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Run the existing browser flows and verify the expected integration RED**

```bash
rtk proxy npx playwright test e2e/worldloom.spec.js --grep "two visitors|keyboard-only|touch visitors"
```

Expected: FAIL because the old scenarios still look for the removed Weave control and persistent `aria-pressed` selection.

- [ ] **Step 2: Update Playwright flows for direct actions**

Change the two-browser scenario to click Illuminate once and wait for both rendered sequences. Change the keyboard scenario to focus Knot, press Enter once, and observe the commit. Remove every Weave-button lookup. In mobile coverage assert each of the three direct buttons is at least 44 pixels tall. Extend reduced-motion coverage with a direct action and assert the canvas remains `data-motion="reduced"` after the committed sequence advances.

```javascript
await firstPage.getByRole("button", {name: "Illuminate", exact: true}).click()
await expect(firstPage.locator("#gesture-status")).toContainText(
  "Gesture joined the living edge",
)
await expect
  .poll(async () => renderedSequence(firstCanvas))
  .toBeGreaterThan(startingSequence)
```

- [ ] **Step 3: Document the architecture boundary**

Update `ARCHITECTURE.md` to describe:

- instruction → viewport-independent topology → spline projection → renderer;
- detached standard canvas cache and bounded transition overlay;
- topology rebuild triggers versus animation-only ticks;
- direct gesture form → validation → persistence → PubSub → animation;
- reduced-motion settled reconstruction and safe fallback behavior.

The existing hook already synchronizes `data-rendered-sequence`, `data-ready`, and `data-motion` after event, catch-up, history, reload, and return-live paths. Confirm that behavior through existing hook calls; do not add DOM attributes for instruction internals, identities, timestamps, or transient animation clocks.

- [ ] **Step 4: Run browser, Node, and LiveView integration gates**

```bash
rtk npm test
rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
rtk proxy npx playwright test e2e/worldloom.spec.js --grep "two visitors|keyboard-only|reduced-motion|touch visitors"
rtk proxy npm run test:e2e
```

Expected: Node, LiveView, and all Playwright tests PASS with no console or page errors.

- [ ] **Step 5: Commit integrated behavior and docs**

```bash
rtk git add e2e/worldloom.spec.js ARCHITECTURE.md
rtk git commit -m "Verify connected weave interactions"
```

### Task 6: Adversarial review, complete verification, and worktrunk merge

**Files:** none unless review demonstrates a defect.

- [ ] **Step 1: Review the complete change against the approved design**

Inspect for disconnected edges, spline overshoot, NaN controls, viewport-dependent topology, command growth, transition leaks, cache invalidation mistakes, optimistic gesture drawing, lost cooldown enforcement, inaccessible disabled states, and privacy leakage. Any demonstrated Critical or Important defect must first receive a focused failing regression test, then the smallest fix and the relevant focused gate.

- [ ] **Step 2: Run the clean release gate**

```bash
rtk proxy asdf exec mix precommit
rtk npm test
rtk proxy npm run test:e2e
rtk docker build -t worldloom:connected-weave .
rtk git diff --check
rtk git status --short
```

Expected: 0 failures, Docker build succeeds, diff check emits nothing, and status is clean.

- [ ] **Step 3: Manually verify the live experience**

At `http://localhost:4000`, verify a dense scene reads as connected long fibers; each direct action produces its approved visible semantic after the committed sequence advances; reload reconstructs the same settled topology; panning/history remain stable; mobile controls do not clip; reduced motion is static; and the server remains healthy at `/healthz`.

- [ ] **Step 4: Invoke branch-finishing and merge through worktrunk**

Invoke `superpowers:verification-before-completion`, then `superpowers:finishing-a-development-branch`. Confirm the task worktree is clean and merge with:

```bash
rtk wt merge --yes
```

Do not use `git checkout`, `git switch`, a branch-only merge, or destructive cleanup. After merge, verify the primary checkout's current branch and HEAD include the connected-weave commits.
