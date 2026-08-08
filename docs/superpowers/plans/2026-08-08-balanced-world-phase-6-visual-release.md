# Balanced World Phase 6: Visual Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every real signal a recognizable material role, prove balanced composition and accessibility across responsive layouts, and verify the complete app with one hundred isolated browsers against instrumented fake upstreams.

**Architecture:** Pure topology converts v1/v2 instructions into source-specific structural roles; geometry applies the shared minute axis; renderer paints bounded materials without multiplying structural commands. LiveView owns semantic summaries and source health. A bounded ephemeral balance monitor measures eligible source cadence. Named fixtures, visual snapshots, and an instrumented fake upstream make the release deterministic and falsifiable.

**Tech Stack:** Phoenix LiveView, Canvas 2D, Tailwind CSS, browser-native JavaScript, Node test runner, Playwright, k6, Bandit/WebSock test upstream, Telemetry.

---

## Files

### Create

- `assets/js/worldloom/source_grammar.js`
- `assets/test/source_grammar.test.js`
- `assets/test/fixtures/balanced_snapshots.js`
- `lib/worldloom/signals/balance_monitor.ex`
- `test/worldloom/signals/balance_monitor_test.exs`
- `test/support/fake_upstream.ex`
- `test/worldloom/signals/fake_upstream_test.exs`
- `load/browser_100.mjs`
- `load/balanced_world.js`

### Modify

- `assets/js/worldloom/topology.js`, `geometry.js`, `renderer.js`, and tests
- `assets/js/worldloom/hook.js`
- `lib/worldloom_web/live/world_live.ex`
- `lib/worldloom_web/live/world_live.html.heex`
- `test/worldloom_web/live/world_live_test.exs`
- `assets/css/app.css`
- `e2e/worldloom.spec.js`
- `playwright.config.js`
- `load/worldloom.js`, `load/README.md`
- `README.md`, `docs/data-sources.md`, `docs/privacy.md`, `docs/operations.md`

## Task 1: Define named balanced-world fixtures

- [ ] **Step 1: Create one shared fixture builder**

Create `assets/test/fixtures/balanced_snapshots.js` exporting:

```javascript
export const balanced
export const wikimediaSurge
export const delayedRecovery
export const totalOutage
export const memoryExpiry
```

Build all timestamps from fixed ISO strings. In `balanced`, place one Wikimedia window at second 0, Bluesky at 1, RIPE at 2, Solana at 3, and real drand rounds at 0, 3, 6, and 9 for every ten-second interval. Include earthquake/weather/visitor context without counting them toward scheduled-source balance.

- [ ] **Step 2: Write fixture-contract tests**

In `assets/test/smoke.test.js`, assert every fixture has `window_end`, `commit_watermark`, display, memory, and ambient fields; every sequence is unique; every timestamp is UTC; every rolling ten-second balanced interval contains all five scheduled families; and no family exceeds 40 percent of durable primary anchors.

- [ ] **Step 3: Run and verify RED/GREEN**

```bash
rtk node --test assets/test/smoke.test.js
```

- [ ] **Step 4: Commit fixtures separately**

```bash
rtk git add assets/test/fixtures/balanced_snapshots.js assets/test/smoke.test.js
rtk git commit -m "Define deterministic balanced-world acceptance fixtures"
```

## Task 2: Encode source meaning before color

- [ ] **Step 1: Write the failing grammar tests**

Create `assets/test/source_grammar.test.js`. Assert exact role outputs:

```javascript
assert.equal(grammarFor(wikimedia).role, "backbone")
assert.equal(grammarFor(bluesky).role, "conversation-fan")
assert.equal(grammarFor(ripe).role, "route-fork")
assert.equal(grammarFor(solana).role, "slot-braid")
assert.equal(grammarFor(drand).role, "public-pulse")
assert.equal(grammarFor(earthquake).role, "rupture")
assert.equal(grammarFor(weather).role, "atmosphere")
assert.equal(grammarFor(visitor).role, "intervention")
```

For each grammar assert bounded counts/widths, finite parameters, stable output, and a unique combination of `pathStyle`, `markerStyle`, and `rhythm`. Unknown positive render versions return the neutral fallback.

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/source_grammar.test.js
```

- [ ] **Step 3: Implement the pure grammar table**

Create `assets/js/worldloom/source_grammar.js`. Rebuild metrics from an allow list and clamp every input. Implement:

- Wikimedia: continuous fine backbone; edit volume changes local thickness.
- Bluesky: violet-independent branching fan; replies diverge, reposts return, total action volume caps branch count at eight.
- RIPE: angular fork; announcements extend, withdrawals pinch, fork count caps at six.
- Solana: short braid with discrete bead markers and visible slot-gap breaks; bead count caps at twelve.
- drand: one pale-independent crystalline chevron/wave per round; never merge multiple rounds into one mark.
- earthquake: scar/ring rupture.
- weather: viewport atmosphere only.
- visitor: tug/knot/illumination intervention.

Do not put RGB values in this module; it defines structure and rhythm only.

- [ ] **Step 4: Verify and commit**

```bash
rtk node --test assets/test/source_grammar.test.js assets/test/smoke.test.js
rtk git add assets/js/worldloom/source_grammar.js assets/test/source_grammar.test.js
rtk git commit -m "Define a non-color grammar for every public signal"
```

## Task 3: Build bounded multi-source topology

- [ ] **Step 1: Add failing topology invariants**

In `assets/test/topology.test.js`, apply every named fixture and assert:

- Wikimedia remains the connective spine but not every anchor;
- Bluesky fans attach without displacing the spine;
- RIPE uses angular segments and inward withdrawal controls;
- Solana beads and explicit gap markers remain ordered by slot;
- drand pulses remain one-to-one with real rounds;
- current earthquake and visitor memory attach to quiet contextual bands;
- output is deterministic under input copy/reload;
- 600 display plus 4 memory instructions remain below existing topology limits.

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/topology.test.js
```

- [ ] **Step 3: Dispatch through the grammar**

Update `assets/js/worldloom/topology.js` to validate source-kind pairs, call `grammarFor`, and build bounded role-specific topology. Preserve sequence as identity and tie-breaker. Do not re-sort by source or fabricate missing source anchors.

Use aggregate metrics only to modify local structure. Under a Wikimedia surge, source round-robin selection has already happened on the server; topology must not reintroduce density bias.

- [ ] **Step 4: Verify and commit**

```bash
rtk node --test assets/test/topology.test.js assets/test/source_grammar.test.js
rtk git add assets/js/worldloom/topology.js assets/test/topology.test.js
rtk git commit -m "Compose distinct source structures on one living spine"
```

## Task 4: Project and paint bounded materials

- [ ] **Step 1: Write geometry and renderer tests first**

In `assets/test/geometry.test.js`, assert all source commands are finite, padded, and tied to event-time x columns. Assert equal-time source families separate vertically/structurally and history remains linear left.

In `assets/test/renderer.test.js`, use a recording canvas and assert each structural command paints bounded cosmetic layers without duplicating topology commands. Check source palette families:

```javascript
wikimedia: "cyan-verdigris"
bluesky: "violet"
ripe_ris: "electric"
solana: "amber"
drand: "crystalline"
usgs: "ember"
open_meteo: "moss-gold"
visitor: "ivory"
```

Also assert reduced motion paints the same settled command roles with no continuing pulse/growth scheduler.

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/geometry.test.js assets/test/renderer.test.js
```

- [ ] **Step 3: Add role-specific command projection**

Update `geometry.js` so role-specific points/segments remain on the shared event-time axis. Cap scene commands at the current global bound; cap each aggregate's branches, forks, beads, and crystals before command creation.

- [ ] **Step 4: Add the restrained palette and painters**

Update `renderer.js` with one palette entry and one painter per grammar role. Keep glow/body/core layers derived at paint time from one structural command. Use line caps, dash rhythm, marker silhouette, angularity, and negative space so meaning survives grayscale.

- [ ] **Step 5: Verify worst-case bounds and commit**

```bash
rtk node --test assets/test/geometry.test.js assets/test/renderer.test.js assets/test/topology.test.js
rtk npm test
rtk git add assets/js/worldloom/geometry.js assets/js/worldloom/renderer.js assets/test/geometry.test.js assets/test/renderer.test.js
rtk git commit -m "Paint bounded material responses for every world signal"
```

## Task 5: Add source health, legend, and semantic summaries

- [ ] **Step 1: Write failing LiveView semantics tests**

In `test/worldloom_web/live/world_live_test.exs`, assert the source legend names all eight source roles, uses text plus a non-color swatch shape, displays independent health, and links source attribution. Assert the semantic live region summarizes an accepted snapshot once per ten-second bucket rather than once per raw frame.

Representative accessible text:

```text
This minute: 15 Wikimedia windows, 15 Bluesky activity windows, 15 RIPE route windows, 20 drand rounds, 1 earthquake memory, and 3 visitor memories. Bluesky is quiet; the other enabled sources are live.
```

The exact numbers come from the snapshot; omit disabled/ineligible sources and never announce fabricated activity.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs
```

- [ ] **Step 3: Implement server-owned semantics**

Update `world_live.ex` with a pure `semantic_summary/2` over snapshot and health. Assign it only when the event-time ten-second bucket or health projection changes. Keep the trusted detail sheet source-owned and content-free.

Update `world_live.html.heex` with a compact legend/list using real links and plain-language material descriptions. Use HEEx attributes and components; do not inject HTML strings.

- [ ] **Step 4: Style the legend and responsive hierarchy**

Update `assets/css/app.css` using Tailwind utilities/custom selectors without `@apply`. Desktop can show the legend as a side rail; tablet and mobile collapse it into a readable disclosure without covering canvas controls. Preserve focus visibility, 44px touch targets, and readable contrast over worst-case weather atmosphere.

- [ ] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs
rtk npm test
rtk git add lib/worldloom_web/live/world_live.ex lib/worldloom_web/live/world_live.html.heex test/worldloom_web/live/world_live_test.exs assets/css/app.css
rtk git commit -m "Explain the balanced world without relying on canvas or color"
```

## Task 6: Measure the five-source balance target honestly

- [ ] **Step 1: Write pure rolling-window tests**

Create `test/worldloom/signals/balance_monitor_test.exs`. Feed events and health observations across five minutes of one-second boundaries. Assert:

- deterministic balanced input reports 100 percent per eligible source;
- one missing eligible occurrence reduces every affected rolling interval, not fabricated success;
- disabled, disconnected, or not-yet-enabled sources are excluded from that interval's denominator;
- only Wikimedia, Bluesky, RIPE, Solana, and drand enter the quota;
- memory, weather, earthquake, and visitor events never enter it;
- state retains at most 310 occurrence/eligibility seconds, enough to evaluate a five-minute horizon plus one ten-second window.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/balance_monitor_test.exs
```

- [ ] **Step 3: Implement bounded ephemeral measurement**

Create `lib/worldloom/signals/balance_monitor.ex`. Subscribe to the authoritative snapshot topic and health projection. Track a bounded set of occurrence seconds per scheduled source plus the eligible set for each observed second. At every one-second boundary, evaluate each ten-second interval ending in the rolling five-minute horizon; a source enters that interval's denominator only when its health is `:live` at the interval end, and passes only when it has a genuine occurrence inside the interval. Retain 310 seconds. Emit only aggregate ratios through:

```elixir
[:worldloom, :signals, :balance]
```

Measurements are integer observed/eligible interval counts; metadata contains only source atom. Do not persist, expose a dashboard, page a human, or call the metric an availability guarantee.

- [ ] **Step 4: Supervise and verify**

Start BalanceMonitor after Coordinator and HealthRegistry. Verify it restarts independently and an outage does not affect `/healthz`.

```bash
rtk mix test test/worldloom/signals/balance_monitor_test.exs test/worldloom_web/controllers/health_controller_test.exs
rtk git add lib/worldloom/application.ex lib/worldloom/signals/balance_monitor.ex test/worldloom/signals/balance_monitor_test.exs
rtk git commit -m "Measure eligible signal balance without fabricating marks"
```

## Task 7: Add responsive visual and accessibility snapshots

- [ ] **Step 1: Add deterministic route setup**

Extend the existing Playwright setup to seed named snapshots with feeds disabled. Do not make browser tests depend on public providers or current wall time.

- [ ] **Step 2: Add named screenshot cases**

In `e2e/worldloom.spec.js`, add `toHaveScreenshot` assertions for:

- `balanced-desktop.png` at 1440x1000;
- `balanced-tablet.png` at 900x1100;
- `balanced-mobile.png` at 390x844;
- `wikimedia-surge-desktop.png`;
- `delayed-recovery-desktop.png`;
- `total-outage-mobile.png`;
- `memory-selection-mobile.png`;
- `balanced-reduced-motion.png`.

Mask only volatile Phoenix debug/runtime fields, never the canvas or legend.

- [ ] **Step 3: Add non-visual browser assertions**

Verify keyboard selection, screen-reader summary, health changes, legend disclosure, source attribution, memory selection, same-time distinguishability, touch gestures, reduced motion, and zero console/page/WebSocket/request failures.

- [ ] **Step 4: Generate and review snapshots**

```bash
rtk npx playwright test e2e/worldloom.spec.js --update-snapshots
rtk npx playwright test e2e/worldloom.spec.js
```

Open every generated image at full size. Reject clipped controls, muddy density, indistinguishable grayscale structures, illegible text, or canvas/legend overlap.

- [ ] **Step 5: Commit reviewed snapshots**

```bash
rtk git add e2e/worldloom.spec.js e2e/worldloom.spec.js-snapshots playwright.config.js
rtk git commit -m "Lock responsive balanced-world visual acceptance"
```

## Task 8: Build an instrumented fake upstream

- [ ] **Step 1: Write fake-upstream tests**

Create `test/worldloom/signals/fake_upstream_test.exs`. Start `test/support/fake_upstream.ex` on an ephemeral port and assert it serves:

- Wikimedia SSE with cursor replay;
- USGS and Open-Meteo HTTP fixtures;
- Bluesky and RIPE WebSockets with subscription recording and deterministic windows;
- drand v2 round HTTP responses;
- Solana slot WebSocket only when explicitly requested;
- `/stats` with aggregate connection, subscription, request, and emitted-window counts only.

Assert `/stats` contains no visitor identity, cookie, IP, cursor, raw frame, source content, prefix, peer, or account.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/fake_upstream_test.exs
```

- [ ] **Step 3: Implement the test-only server**

Use Bandit plus WebSock callbacks from test dependencies already in the tree. Keep the module under `test/support` so production releases cannot start it. Accept a deterministic clock and cadence. Expose stats through an Agent using fixed source keys and integer counters only.

- [ ] **Step 4: Add the balanced load profile**

Create `load/balanced_world.js` to connect real LiveView clients, observe at least two increasing snapshot watermarks, and verify all enabled source names appear in snapshot pushes. Extend `load/README.md` with exact fake-upstream/test-server commands.

- [ ] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom/signals/fake_upstream_test.exs
rtk git add test/support/fake_upstream.ex test/worldloom/signals/fake_upstream_test.exs load/balanced_world.js load/README.md
rtk git commit -m "Instrument deterministic upstreams for whole-app load"
```

## Task 9: Prove one hundred isolated browsers do not multiply upstream work

- [ ] **Step 1: Create the real-browser runner**

Create `load/browser_100.mjs`. Launch one Chromium process with 100 isolated browser contexts, one page per context, distinct cookie jars, and no shared storage. Ramp 10 pages every two seconds, wait for `#loom-canvas[data-ready='true']`, require two watermark advances, hold sixty seconds, collect console/page/request/WebSocket failures, then close every context.

- [ ] **Step 2: Assert upstream and app evidence**

After the hold, fetch fake `/stats` and assert:

- exactly one concurrent Wikimedia stream, Bluesky socket, and RIPE socket;
- exactly one subscription set per enabled WebSocket source;
- drand request count matches bounded cadence rather than browser count;
- 100 LiveViews observed real summary broadcasts and snapshot reprojections;
- no browser requested an upstream host directly;
- all processes/connections return to baseline after close.

- [ ] **Step 3: Add an npm script and document resource expectations**

Add `"test:browser-100": "node load/browser_100.mjs"` to `package.json`. Document that this explicit local gate is heavier than pull-request CI and requires the instrumented test app.

- [ ] **Step 4: Run both protocol and real-browser profiles**

```bash
rtk k6 run -e WORLDLOOM_PROFILE=local-100 load/worldloom.js
rtk npm run test:browser-100
```

Expected: both gates pass; the real-browser report includes 100 ready pages, two or more snapshot advances per page, zero browser failures, and one server-side connection/subscription per enabled streaming source.

- [ ] **Step 5: Commit the load gate**

```bash
rtk git add load/browser_100.mjs load/README.md package.json package-lock.json
rtk git commit -m "Verify Worldloom with one hundred isolated browsers"
```

## Task 10: Finish the public release surface and evidence

- [ ] **Step 1: Update About and attribution**

Update the About panel, README, and source/privacy/operations docs. Name every source and link directly to official documentation. Explain the source's visual material and limits. State that Solana is qualified in fixtures but not production-enabled. Avoid endorsement language and uptime promises.

- [ ] **Step 2: Run the complete local release matrix**

```bash
rtk mix format --check-formatted
rtk mix compile --warning-as-errors
rtk mix test
rtk npm test
rtk npm run test:e2e
rtk npm run test:browser-100
rtk docker build --build-arg GIT_SHA=$(rtk git rev-parse HEAD) .
rtk git diff --check master...HEAD
rtk mix hex.audit
```

The Postgrex advisory must be upgraded away or handled through the explicitly approved verified mitigation gate in the roadmap. A known unapproved advisory blocks release.

- [ ] **Step 3: Review exact release-candidate diff**

Review:

```bash
rtk git status --short
rtk git log --oneline master..HEAD
rtk git diff --stat master...HEAD
rtk git diff --check master...HEAD
```

Audit the complete diff against all twelve acceptance criteria in the design specification. Confirm no generated secret, runtime URL query, raw provider fixture, screenshot of private data, or AI-attribution trailer exists.

- [ ] **Step 4: Commit the public surface**

```bash
rtk git add README.md docs/data-sources.md docs/privacy.md docs/operations.md lib/worldloom_web/live/world_live.html.heex
rtk git commit -m "Present Worldloom as a balanced living world"
```

- [ ] **Step 5: Push only after user authorization**

After all local gates and a fresh code review pass, report the exact commits and unresolved external gates. Do not merge, push, change production flags, or deploy unless the user explicitly authorizes those external actions.

## Phase 6 completion gate

- [ ] All eight signal roles remain recognizable without color and under reduced motion.
- [ ] Deterministic ten-second intervals contain all scheduled fixture families and no family exceeds 40 percent of primary anchors.
- [ ] Production balance measurement is honest, bounded, ephemeral, and does not fabricate events.
- [ ] Desktop, tablet, mobile, outage, recovery, memory, and reduced-motion screenshots were reviewed at full size.
- [ ] One hundred isolated browsers observe real server broadcasts while upstream connection/subscription count remains one per enabled streaming source.
- [ ] Accessibility, privacy, provider attribution, container build, dependency audit, and all test suites pass before integration.
