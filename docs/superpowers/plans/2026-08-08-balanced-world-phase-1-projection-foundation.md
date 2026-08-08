# Balanced World Phase 1: Projection Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Worldloom's sequence-spaced `latest(400)` live view with one authoritative, deterministic, event-time snapshot while adding no provider.

**Architecture:** A pure `LiveProjection` selects display, memory, and ambient roles from persisted events. `Store` supplies bounded source queues; `Coordinator` owns the monotonic `window_end`, computes one snapshot per commit, and broadcasts that snapshot to all LiveViews. The browser replaces its current live projection atomically and uses database sequence only as the commit watermark and selection identity.

**Tech Stack:** Elixir 1.20, Phoenix LiveView 1.2, Ecto/PostgreSQL, Canvas 2D, browser-native JavaScript, Node test runner, Playwright.

---

## File responsibility map

### Create

- `lib/worldloom/loom/live_snapshot.ex` — immutable snapshot envelope and validation.
- `lib/worldloom/loom/live_projection.ex` — pure window, quota, memory, and ambient selection.
- `test/worldloom/loom/live_projection_test.exs` — deterministic selection invariants.
- `test/support/fixtures/live_snapshots/balanced_v1.json` — fixed browser contract with real timestamps.

### Modify

- `lib/worldloom/loom/store.ex` and `test/worldloom/loom/store_test.exs` — bounded source/window queries.
- `lib/worldloom/loom/coordinator.ex` and `test/worldloom/loom/coordinator_test.exs` — one monotonic snapshot per committed batch.
- `lib/worldloom_web/live/world_live.ex` and `test/worldloom_web/live/world_live_test.exs` — mount and broadcast the snapshot envelope.
- `assets/js/worldloom/hook.js` and `assets/test/hook.test.js` — atomic snapshot events.
- `assets/js/worldloom/renderer.js` and `assets/test/renderer.test.js` — separate display, memory, ambient, and watermark state.
- `assets/js/worldloom/geometry.js` and `assets/test/geometry.test.js` — exact sixty-second event-time projection.
- `e2e/worldloom.spec.js` — reload determinism, memory selection, and live-axis behavior.

## Task 1: Define the snapshot value and pure selection rules

- [ ] **Step 1: Write the failing projection tests**

Create `test/worldloom/loom/live_projection_test.exs` with focused tests for:

```elixir
assert snapshot.window_end == ~U[2026-08-08 12:01:00Z]
assert snapshot.snapshot_version == 1
assert snapshot.commit_watermark == 906
assert length(snapshot.display_events) == 600
assert Enum.frequencies_by(snapshot.display_events, & &1.source)["wikimedia"] == 240
assert snapshot.display_events == Enum.sort_by(snapshot.display_events, &{&1.occurred_at, &1.id})
assert Enum.map(snapshot.memory_events, & &1.id) == [earthquake.id | visitor_ids]
assert snapshot.ambient.id == weather.id
```

Add independent tests proving:

- `window_end` is the later of the previous monotonic value and latest eligible primary occurrence, truncated to a second;
- events outside `[window_end - 60 seconds, window_end]` do not enter `display_events`;
- source queues are consumed newest-first in round-robin order, capped at 240, then returned in stable `(occurred_at, id)` order;
- the most recent earthquake and latest three visitor events appear as memory only when absent from the minute and at most 24 hours old;
- weather is ambient only;
- an empty candidate set preserves the previous `window_end` and advances only the supplied watermark.

- [ ] **Step 2: Run the new test and verify RED**

```bash
rtk mix test test/worldloom/loom/live_projection_test.exs
```

Expected: compilation fails because `Worldloom.Loom.LiveProjection` does not exist.

- [ ] **Step 3: Create the explicit envelope**

Create `lib/worldloom/loom/live_snapshot.ex`:

```elixir
defmodule Worldloom.Loom.LiveSnapshot do
  @enforce_keys [:window_end, :commit_watermark, :display_events, :memory_events, :ambient]
  defstruct snapshot_version: 1,
            window_end: nil,
            commit_watermark: 0,
            display_events: [],
            memory_events: [],
            ambient: nil

  @type t :: %__MODULE__{
          snapshot_version: 1,
          window_end: DateTime.t() | nil,
          commit_watermark: non_neg_integer(),
          display_events: [Worldloom.Loom.Event.t()],
          memory_events: [Worldloom.Loom.Event.t()],
          ambient: Worldloom.Loom.Event.t() | nil
        }
end
```

- [ ] **Step 4: Implement bounded pure projection**

Create `lib/worldloom/loom/live_projection.ex` with these public constants and API:

```elixir
@window_seconds 60
@display_limit 600
@per_source_limit 240
@memory_seconds 24 * 60 * 60

@spec build([Event.t()], Event.t() | nil, non_neg_integer(), DateTime.t() | nil) ::
        LiveSnapshot.t()
def build(candidates, ambient, commit_watermark, previous_window_end \\ nil)
```

Use `DateTime.compare/2`, not struct comparison. Partition weather before deriving `window_end`; use current earthquake and visitor rows in the display pool; then derive contextual memory only from eligible rows omitted by time. Implement round robin over `source => newest-first queue`, take at most one item per source per pass, and stop at 600 or exhaustion. Finish with:

```elixir
selected
|> Enum.sort_by(&{DateTime.to_unix(&1.occurred_at, :microsecond), &1.id})
```

Keep the selector pure: no Repo access, wall clock, process state, or random values.

- [ ] **Step 5: Verify GREEN and commit**

```bash
rtk mix test test/worldloom/loom/live_projection_test.exs
rtk git add lib/worldloom/loom/live_snapshot.ex lib/worldloom/loom/live_projection.ex test/worldloom/loom/live_projection_test.exs
rtk git commit -m "Define the authoritative live snapshot projection"
```

## Task 2: Supply bounded candidates from durable storage

- [ ] **Step 1: Add failing Store tests**

In `test/worldloom/loom/store_test.exs`, insert more than 240 rows for one source plus current earthquake, visitor, and weather rows. Assert:

```elixir
snapshot = Store.live_snapshot(nil)

assert snapshot.commit_watermark == Store.highest_sequence()
assert snapshot.window_end == ~U[2026-08-08 12:01:00Z]
assert Enum.count(snapshot.display_events, &(&1.source == "wikimedia")) == 240
assert Enum.any?(snapshot.display_events, &(&1.source == "usgs"))
assert Enum.any?(snapshot.display_events, &(&1.source == "visitor"))
assert snapshot.ambient.source == "open_meteo"
```

Attach a test handler to `Worldloom.Repo.config()[:telemetry_prefix] ++ [:query]`, count query events during `Store.live_snapshot/1`, and assert the count stays constant when Wikimedia row volume grows from 240 to 2,400. The implementation must stay bounded by the number of allow-listed sources, not row volume.

- [ ] **Step 2: Run the test and verify RED**

```bash
rtk mix test test/worldloom/loom/store_test.exs
```

Expected: failure because `Store.live_snapshot/1` is undefined.

- [ ] **Step 3: Add source-window queries**

In `lib/worldloom/loom/store.ex`, add:

```elixir
@live_sources ~w(wikimedia usgs visitor)
@live_source_limit 240
@memory_lookback_seconds 24 * 60 * 60

@spec live_snapshot(DateTime.t() | nil) :: LiveSnapshot.t()
def live_snapshot(previous_window_end \\ nil)
```

Resolve the candidate `window_end` from the latest non-weather `occurred_at`, keep the previous value if it is later, then issue one bounded query per `@live_sources` for current-window rows and memory candidates. Query newest-first with `limit(^@live_source_limit)` and reverse only inside `LiveProjection`. Fetch ambient with the existing indexed `ambient_before/1` semantics, and use `highest_sequence/0` as the watermark even when the highest row is not displayed.

Handle an empty database without calling `ambient_before/1` with sequence zero; return snapshot version 1, `window_end: nil`, watermark zero, empty display/memory, and nil ambient.

Do not call `Store.latest/1` from the live route after this task.

- [ ] **Step 4: Verify query and projection tests, then commit**

```bash
rtk mix test test/worldloom/loom/store_test.exs test/worldloom/loom/live_projection_test.exs
rtk git add lib/worldloom/loom/store.ex test/worldloom/loom/store_test.exs
rtk git commit -m "Load bounded live candidates by event time"
```

## Task 3: Compute and broadcast one snapshot per commit

- [ ] **Step 1: Write failing Coordinator tests**

Extend `test/worldloom/loom/coordinator_test.exs` so the test store records calls to `live_snapshot/1`. Assert:

```elixir
assert_receive {:loom_snapshot, %LiveSnapshot{commit_watermark: sequence}}, 500
refute_receive {:loom_event, _instruction}, 50
assert Coordinator.current_snapshot(coordinator).commit_watermark == sequence
```

Add cases for a late recovery row that advances `commit_watermark` without moving `window_end`, and a duplicate/checkpoint-only commit that emits no snapshot.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/loom/coordinator_test.exs
```

- [ ] **Step 3: Make the Coordinator authoritative**

In `lib/worldloom/loom/coordinator.ex`:

```elixir
@spec current_snapshot(GenServer.server()) :: LiveSnapshot.t()
def current_snapshot(server \\ __MODULE__), do: GenServer.call(server, :current_snapshot)
```

Initialize `state.snapshot = state.store.live_snapshot(nil)`. After a non-empty successful commit, call `state.store.live_snapshot(state.snapshot.window_end)` exactly once and broadcast `{:loom_snapshot, snapshot}` exactly once. Keep `highest_sequence` synchronized with `snapshot.commit_watermark`. A successful empty insert updates no live projection and broadcasts nothing.

- [ ] **Step 4: Verify ordering, durability, and one-projection behavior**

```bash
rtk mix test test/worldloom/loom/coordinator_test.exs
rtk git add lib/worldloom/loom/coordinator.ex test/worldloom/loom/coordinator_test.exs
rtk git commit -m "Broadcast one durable snapshot per committed batch"
```

## Task 4: Move LiveView to the snapshot contract

- [ ] **Step 1: Write LiveView contract tests**

In `test/worldloom_web/live/world_live_test.exs`, assert the root canvas receives separate serialized fields:

```elixir
assert has_element?(view, "#loom-canvas[data-window-end='2026-08-08T12:01:00Z']")
assert has_element?(view, "#loom-canvas[data-commit-watermark='906']")
assert render(view) =~ "data-display-events"
assert render(view) =~ "data-memory-events"
```

Send `{:loom_snapshot, snapshot}` and assert one `worldloom:snapshot` push contains `window_end`, `commit_watermark`, `display_events`, `memory_events`, and `ambient`. Assert both display and memory rows are in `trusted_events`. Delete expectations for `worldloom:event`, `worldloom:catch-up`, and `sequence-gap` on the live route.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs
```

- [ ] **Step 3: Replace the live-route data flow**

In `lib/worldloom_web/live/world_live.ex`:

- replace `Store.latest(@initial_history_limit)` in live entry and return-live with `Coordinator.current_snapshot()`;
- serialize every snapshot event through `Instruction.from_event/1` while preserving the five envelope keys;
- rebuild `trusted_events` from `display_events ++ memory_events`;
- rebuild the accessible stream from the same ordered set;
- handle only `{:loom_snapshot, snapshot}` for live updates;
- remove live gap fetch/append behavior while preserving bounded history queries and chapter reconstruction.

Push this exact public shape:

```elixir
%{
  snapshot_version: snapshot.snapshot_version,
  window_end: encoded_window_end,
  commit_watermark: snapshot.commit_watermark,
  display_events: Enum.map(snapshot.display_events, &Instruction.from_event/1),
  memory_events: Enum.map(snapshot.memory_events, &Instruction.from_event/1),
  ambient: snapshot.ambient && Instruction.from_event(snapshot.ambient)
}
```

- [ ] **Step 4: Verify trusted selection and history compatibility**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs
rtk git add lib/worldloom_web/live/world_live.ex test/worldloom_web/live/world_live_test.exs
rtk git commit -m "Separate live display membership from commit ordering"
```

## Task 5: Make the browser replace snapshots atomically

- [ ] **Step 1: Add a fixed snapshot fixture**

Create `test/support/fixtures/live_snapshots/balanced_v1.json` with at least two Wikimedia events, one current earthquake, one visitor memory, and weather ambient. Every instruction needs an explicit ISO-8601 timestamp; do not generate fixture timestamps from `Date.now()`.

- [ ] **Step 2: Write failing hook and renderer tests**

In `assets/test/hook.test.js`, assert `worldloom:snapshot` calls `renderer.setSnapshot(envelope)` once and never emits `sequence-gap` for legal display omissions.

In `assets/test/renderer.test.js`, assert:

```javascript
renderer.setSnapshot(snapshot)
assert.equal(renderer.commitWatermark, snapshot.commit_watermark)
assert.equal(renderer.snapshotVersion, 1)
assert.deepEqual(renderer.instructions, snapshot.display_events)
assert.deepEqual(renderer.memoryInstructions, snapshot.memory_events)
assert.equal(renderer.windowEnd, snapshot.window_end)
```

Apply a second envelope with a skipped visible sequence but consecutive `commit_watermark`; assert full replacement and no catch-up request.

- [ ] **Step 3: Run and verify RED**

```bash
rtk node --test assets/test/hook.test.js assets/test/renderer.test.js
```

- [ ] **Step 4: Implement `setSnapshot`**

In `assets/js/worldloom/renderer.js`, make `setSnapshot` require `snapshot_version === 1`, validate finite safe sequences and a parseable UTC `window_end`, cap display at 600, cap memory at 4, and replace all live arrays in one synchronous method. Keep history in a separate collection. Set the DOM diagnostics from the accepted envelope, not from the last visible sequence.

In `assets/js/worldloom/hook.js`, decode the initial data attributes into the same envelope and route `worldloom:snapshot` and `worldloom:return-live` through `setSnapshot`. Remove client-originated live `sequence-gap` repair.

- [ ] **Step 5: Verify and commit**

```bash
rtk node --test assets/test/hook.test.js assets/test/renderer.test.js
rtk npm test
rtk git add assets/js/worldloom/hook.js assets/js/worldloom/renderer.js assets/test/hook.test.js assets/test/renderer.test.js test/support/fixtures/live_snapshots/balanced_v1.json
rtk git commit -m "Replace live browser state from complete snapshots"
```

## Task 6: Project exactly sixty seconds of event time

- [ ] **Step 1: Write failing geometry tests**

In `assets/test/geometry.test.js`, load the fixed snapshot and assert:

```javascript
assert.equal(xFor("2026-08-08T12:00:00Z"), viewport.padding)
assert.equal(xFor("2026-08-08T12:00:30Z"), viewport.width / 2)
assert.equal(xFor("2026-08-08T12:01:00Z"), viewport.width - viewport.padding)
```

Also prove:

- equal timestamps share an x column but remain distinguishable by lane/topology;
- 600 dense Wikimedia rows remain inside the viewport;
- an event older than the minute is absent from primary geometry;
- memory uses a labeled quiet band and its real timestamp is retained for selection;
- historical pages extend left at the same pixels-per-second scale;
- no `minimumPublicDisplayStep`, scaffold spacing, or sequence delta changes a live x position.

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/geometry.test.js
```

- [ ] **Step 3: Replace sequence spacing with event-time normalization**

In `assets/js/worldloom/geometry.js`, remove `minimumPublicDisplayStep` and derive live x from:

```javascript
const windowEndMs = Date.parse(snapshot.window_end)
const windowStartMs = windowEndMs - 60_000
const ratio = clamp((Date.parse(instruction.occurred_at) - windowStartMs) / 60_000, 0, 1)
const x = padding + ratio * (width - padding * 2)
```

Sequence may break deterministic ties but may not alter x. Pass `window_end`, display, memory, ambient, and history as explicit scene inputs; do not hide them in module globals.

- [ ] **Step 4: Verify geometry and full JavaScript suite**

```bash
rtk node --test assets/test/geometry.test.js assets/test/topology.test.js assets/test/renderer.test.js
rtk npm test
rtk git add assets/js/worldloom/geometry.js assets/test/geometry.test.js
rtk git commit -m "Project the live loom across sixty seconds of event time"
```

## Task 7: Verify reload, selection, and outage behavior

- [ ] **Step 1: Add browser acceptance cases**

In `e2e/worldloom.spec.js`, add tests that:

- capture `data-window-end`, `data-commit-watermark`, and painted command diagnostics;
- reload and compare the complete settled scene diagnostics;
- select a contextual memory and verify its original occurrence time and permalink;
- commit a late event and verify the watermark advances without the x-axis moving backward;
- stop fake activity and verify the axis freezes instead of following the browser clock.

- [ ] **Step 2: Run targeted and full verification**

```bash
rtk mix precommit
rtk npm test
rtk npm run test:e2e
rtk git diff --check master...HEAD
rtk mix hex.audit
```

Expected: all application suites pass. If `mix hex.audit` still reports `EEF-CVE-2026-66838`, record it as the known release blocker from the roadmap; do not represent the advisory as resolved.

- [ ] **Step 3: Review and commit the acceptance coverage**

Review the phase diff against the projection, live-window, temporal-layout, and compatibility sections of the specification. Then:

```bash
rtk git add e2e/worldloom.spec.js
rtk git commit -m "Verify deterministic live snapshots across reload and outage"
```

## Phase 1 completion gate

- [ ] No new provider dependency, source, or production flag exists.
- [ ] `Store.latest/1` is absent from the live route.
- [ ] One committed batch performs one authoritative reprojection, independent of browser count.
- [ ] The visible set and `commit_watermark` are independently tested.
- [ ] Current and memory events remain selectable from trusted server state.
- [ ] Chapters and permalinks remain sequence-authoritative.
- [ ] The live x-axis spans exactly sixty seconds of persisted event time.
- [ ] `rtk mix precommit`, `rtk npm test`, and `rtk npm run test:e2e` pass.
