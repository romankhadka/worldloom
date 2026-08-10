# Timeline Zoom and Touch Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship bounded 1m/5m/15m live and historical timeline scales, a reliable two-step mobile touch path, renderer-authoritative formation taps, and accurate public documentation.

**Architecture:** PostgreSQL selects at most 100 time-bucket representatives per non-weather source before loading records, then a pure Elixir projection balances genuine events to the existing 600-event ceiling and force-includes a trusted chapter anchor. The browser owns only ephemeral duration and lag, projects every painted and hit-tested command through one explicit UTC axis, and obtains wider windows through an acknowledged, throttled LiveView request/reply contract.

**Tech Stack:** Elixir 1.20, Phoenix LiveView 1.2, Ecto/PostgreSQL window queries, browser-native ES modules and Canvas 2D, Node test runner, Playwright Chromium, Tailwind input CSS.

---

## File map

- Create `lib/worldloom/loom/timeline_window.ex`: immutable value returned by bounded timeline queries.
- Create `lib/worldloom/loom/timeline_projection.ex`: pure per-source temporal spreading and balanced 600-event selection.
- Create `test/worldloom/loom/timeline_projection_test.exs`: high-density, sparse-source, determinism, weather, and anchor tests.
- Modify `lib/worldloom/loom/store.ex`: indexed interval sampling, ambient-at-time, and archive-boundary loading.
- Modify `test/worldloom/loom/store_test.exs`: query bounds, endpoints, validation, and index-plan coverage.
- Modify `lib/worldloom_web/live/world_live.ex`: `timeline-window` request/reply, throttle acknowledgement, authorization replacement, and chapter anchor payload.
- Modify `test/worldloom_web/live/world_live_test.exs`: range contract, throttle, authorization, and chapter anchor tests.
- Modify `assets/js/worldloom/geometry.js`: explicit axis input for all event-time geometry.
- Modify `assets/test/geometry.test.js`: 1m/5m/15m endpoint, off-axis, seam, and hit-coordinate tests.
- Modify `assets/js/worldloom/renderer.js`: duration, route mode, time lag, center preservation, range intent, diagnostics, and Return-live behavior.
- Modify `assets/test/renderer.test.js`: scale, pan, snapshot stability, request coalescing, throttle, archive, resize, and diagnostics tests.
- Modify `assets/js/worldloom/hook.js`: scale bindings, persistent range text, LiveView reply bridge, generation guards, and existing touch state integration.
- Modify `assets/test/hook.test.js`: idempotent controls, reply lifecycle, range text, and touch/pan isolation tests.
- Modify `lib/worldloom_web/live/world_live.html.heex`: one semantic timeline-control wrapper with stable IDs.
- Modify `assets/css/app.css`: Lacquered Gallery scale control, responsive placement, focus/forced-colors states, and `touch-action: none`.
- Modify `assets/test/fixtures/balanced_snapshots.js`: deterministic quarter-hour historical records.
- Modify `test/support/worldloom/e2e_scene_loader.ex`: acceptance-only insertion of validated prior records.
- Modify `test/support/worldloom_web/e2e_controller.ex`: pass optional prior records to the loader without broadening production routes.
- Modify `test/worldloom_web/e2e_controller_test.exs`: prior-record allow-list, bounds, and durability tests.
- Modify `e2e/worldloom.spec.js`: zoom behavior, mobile touch submissions, diagnostics-based formation tapping, overlay scrolling, and visual baselines.
- Create two 15m desktop/mobile baseline PNGs and update the existing 1m desktop/mobile baselines under `e2e/worldloom.spec.js-snapshots/`.
- Modify `README.md`: shipped zoom, anchor, two-step touch, accessibility, and verification language.

### Task 1: Pure bounded timeline projection

**Files:**
- Create: `lib/worldloom/loom/timeline_window.ex`
- Create: `lib/worldloom/loom/timeline_projection.ex`
- Create: `test/worldloom/loom/timeline_projection_test.exs`

- [ ] **Step 1: Write failing projection tests**

Define class-style ExUnit tests that construct stored `%Event{}` structs directly and assert these exact contracts:

```elixir
test "spreads dense sources across the interval and balances the final projection" do
  events =
    for source <- ~w(wikimedia bluesky ripe_ris solana drand visitor usgs),
        offset <- 0..149 do
      event(source, offset, offset)
    end

  projected = TimelineProjection.select(events)

  assert length(projected) == 600
  assert projected == Enum.sort_by(projected, &{&1.occurred_at, &1.id})
  assert MapSet.new(projected, & &1.source) ==
           MapSet.new(~w(wikimedia bluesky ripe_ris solana drand visitor usgs))

  for source <- ~w(wikimedia bluesky ripe_ris solana drand visitor usgs) do
    source_events = Enum.filter(projected, &(&1.source == source))
    assert Enum.min_by(source_events, & &1.occurred_at).occurred_at ==
             ~U[2026-08-09 12:00:00.000000Z]
    assert Enum.max_by(source_events, & &1.occurred_at).occurred_at ==
             ~U[2026-08-09 12:02:29.000000Z]
  end
end

test "keeps sparse sources and force-includes the trusted anchor" do
  dense = for offset <- 0..999, do: event("wikimedia", offset, offset)
  earthquake = event("usgs", 2_000, 450)
  anchor = event("visitor", 2_001, 451)

  projected = TimelineProjection.select(dense ++ [earthquake, anchor], anchor)

  assert length(projected) <= 600
  assert earthquake in projected
  assert anchor in projected
end

test "weather is ambient rather than projected topology" do
  weather = event("open_meteo", 9_000, 10)
  assert TimelineProjection.select([weather]) == []
end
```

Use a private `event/3` helper that fills every required `Event` field with deterministic values and assigns legal kind/render-version pairs per source.

- [ ] **Step 2: Run the projection test and observe RED**

Run:

```bash
rtk mix test test/worldloom/loom/timeline_projection_test.exs
```

Expected: compilation fails because `TimelineProjection` and `TimelineWindow` do not exist.

- [ ] **Step 3: Implement the pure projection and value object**

Create an enforced `TimelineWindow` struct:

```elixir
defmodule Worldloom.Loom.TimelineWindow do
  alias Worldloom.Loom.Event

  @enforce_keys [:start_at, :end_at, :duration_seconds, :events, :ambient, :archive_start_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          start_at: DateTime.t(),
          end_at: DateTime.t(),
          duration_seconds: 60 | 300 | 900,
          events: [Event.t()],
          ambient: Event.t() | nil,
          archive_start_at: DateTime.t() | nil
        }
end
```

Implement `TimelineProjection.select/2` with these concrete invariants:

```elixir
defmodule Worldloom.Loom.TimelineProjection do
  alias Worldloom.Loom.Event

  @maximum_events 600
  @per_source_candidates 100

  @spec select([Event.t()], Event.t() | nil) :: [Event.t()]
  def select(events, anchor \\ nil) when is_list(events) do
    events
    |> Enum.filter(&topology_event?/1)
    |> maybe_add_anchor(anchor)
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(& &1.source)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {source, source_events} ->
      ordered = Enum.sort_by(source_events, &{&1.occurred_at, &1.id})
      spread = ordered |> evenly_spaced(@per_source_candidates) |> temporal_priority(anchor)
      {source, spread}
    end)
    |> round_robin(@maximum_events)
    |> Enum.sort_by(&{&1.occurred_at, &1.id})
  end

  defp topology_event?(%Event{source: source}), do: source != "open_meteo"
  defp topology_event?(_event), do: false

  defp maybe_add_anchor(events, %Event{source: source} = anchor)
       when source != "open_meteo",
       do: [anchor | events]

  defp maybe_add_anchor(events, _anchor), do: events

  defp evenly_spaced(events, limit) when length(events) <= limit, do: events

  defp evenly_spaced(events, limit) do
    last_index = length(events) - 1

    0..(limit - 1)
    |> Enum.map(&round(&1 * last_index / (limit - 1)))
    |> Enum.uniq()
    |> Enum.map(&Enum.at(events, &1))
  end

  defp temporal_priority([], _anchor), do: []

  defp temporal_priority(events, anchor) do
    last_index = length(events) - 1
    anchor_index =
      if is_struct(anchor, Event), do: Enum.find_index(events, &(&1.id == anchor.id))

    [0, last_index, anchor_index | midpoint_indices(1, last_index - 1)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&Enum.at(events, &1))
  end

  defp midpoint_indices(first, last) when first > last, do: []

  defp midpoint_indices(first, last) do
    midpoint = div(first + last, 2)

    [midpoint | interleave(
      midpoint_indices(first, midpoint - 1),
      midpoint_indices(midpoint + 1, last)
    )]
  end

  defp interleave([], right), do: right
  defp interleave(left, []), do: left
  defp interleave([left | left_rest], [right | right_rest]),
    do: [left, right | interleave(left_rest, right_rest)]

  defp round_robin(source_queues, limit), do: take_round(source_queues, [], limit)

  defp take_round(_source_queues, selected, 0), do: selected

  defp take_round(source_queues, selected, remaining) do
    {next_queues, next_selected, next_remaining, taken} =
      Enum.reduce_while(source_queues, {[], selected, remaining, 0}, fn
        _queue, state = {_queues, _selected, 0, _taken} ->
          {:halt, state}

        {source, [event | events]}, {queues, chosen, available, count} ->
          {:cont, {[{source, events} | queues], [event | chosen], available - 1, count + 1}}

        {source, []}, {queues, chosen, available, count} ->
          {:cont, {[{source, []} | queues], chosen, available, count}}
      end)

    if taken == 0 do
      next_selected
    else
      take_round(Enum.reverse(next_queues), next_selected, next_remaining)
    end
  end
end
```

- [ ] **Step 4: Run projection tests and the formatter**

Run:

```bash
rtk mix format lib/worldloom/loom/timeline_window.ex lib/worldloom/loom/timeline_projection.ex test/worldloom/loom/timeline_projection_test.exs
rtk mix test test/worldloom/loom/timeline_projection_test.exs
```

Expected: all projection tests pass with no compiler warnings.

- [ ] **Step 5: Commit the pure projection**

```bash
rtk git add lib/worldloom/loom/timeline_window.ex lib/worldloom/loom/timeline_projection.ex test/worldloom/loom/timeline_projection_test.exs
rtk git commit -m "Add bounded balanced timeline projection"
```

### Task 2: Indexed bounded Store window

**Files:**
- Modify: `lib/worldloom/loom/store.ex`
- Modify: `test/worldloom/loom/store_test.exs`

- [ ] **Step 1: Write failing Store tests**

Add tests that insert more than 1,000 events over fifteen minutes and assert the Store returns a `TimelineWindow` with exact inclusive start/end semantics, no weather in topology, historical ambient at the interval end, every source represented, exact source endpoints, and no more than 600 events. Add validation tests for unsupported durations, naive datetimes, and a non-Event anchor.

```elixir
window = Store.timeline_window(~U[2026-08-09 12:15:00.000000Z], 900, anchor)

assert window.start_at == ~U[2026-08-09 12:00:00.000000Z]
assert window.end_at == ~U[2026-08-09 12:15:00.000000Z]
assert window.duration_seconds == 900
assert length(window.events) <= 600
assert anchor in window.events
refute Enum.any?(window.events, &(&1.source == "open_meteo"))
assert window.ambient.id == historical_weather.id
assert window.archive_start_at == earliest_event.occurred_at

assert_raise ArgumentError, fn -> Store.timeline_window(window.end_at, 120) end
assert_raise ArgumentError, fn -> Store.timeline_window(~N[2026-08-09 12:15:00], 900) end
assert_raise ArgumentError, fn -> Store.timeline_window(window.end_at, 900, 42) end
```

Add an `EXPLAIN (FORMAT JSON)` assertion that the interval query can use `loom_events_primary_occurred_at_id_index` or `loom_events_source_occurred_at_id_index`; keep the existing index-definition assertions green.

- [ ] **Step 2: Run Store tests and observe RED**

```bash
rtk mix test test/worldloom/loom/store_test.exs
```

Expected: failures report undefined `Store.timeline_window/2` and `/3`.

- [ ] **Step 3: Implement the bounded indexed query**

Add `@timeline_durations [60, 300, 900]`, `@timeline_sources @primary_sources ++ @context_sources`, and `@timeline_source_buckets 100` to `Store`.

Implement:

```elixir
@spec timeline_window(DateTime.t(), 60 | 300 | 900, Event.t() | nil) ::
        TimelineWindow.t()
def timeline_window(end_at, duration_seconds, anchor \\ nil)

def timeline_window(%DateTime{} = end_at, duration_seconds, anchor)
    when duration_seconds in @timeline_durations and
           (is_nil(anchor) or is_struct(anchor, Event)) do
  start_at = DateTime.add(end_at, -duration_seconds, :second)
  candidates = timeline_candidates(start_at, end_at)

  %TimelineWindow{
    start_at: start_at,
    end_at: end_at,
    duration_seconds: duration_seconds,
    events: TimelineProjection.select(candidates, anchor_in_window(anchor, start_at, end_at)),
    ambient: ambient_at(end_at),
    archive_start_at: archive_start_at()
  }
end

def timeline_window(_end_at, _duration_seconds, _anchor),
  do: raise(ArgumentError, "timeline end, duration, or anchor is invalid")

defp timeline_candidates(start_at, end_at) do
  last_bucket = @timeline_source_buckets - 1

  ranked =
    Event
    |> where(
      [event],
      event.source in ^@timeline_sources and event.occurred_at >= ^start_at and
        event.occurred_at <= ^end_at
    )
    |> windows(
      [event],
      source_order: [
        partition_by: event.source,
        order_by: [asc: event.occurred_at, asc: event.id]
      ],
      source_count: [partition_by: event.source]
    )
    |> select([event], %{
      id: event.id,
      source: event.source,
      occurred_at: event.occurred_at,
      ordinal: over(row_number(), :source_order),
      source_count: over(count(event.id), :source_count)
    })

  bucketed =
    from candidate in subquery(ranked),
      select: %{
        id: candidate.id,
        source: candidate.source,
        occurred_at: candidate.occurred_at,
        bucket:
          fragment(
            "floor(((? - 1) * ?::numeric) / greatest(? - 1, 1))::integer",
            candidate.ordinal,
            ^last_bucket,
            candidate.source_count
          )
      }

  sampled_ids =
    from candidate in subquery(bucketed),
      distinct: [candidate.source, candidate.bucket],
      order_by: [
        asc: candidate.source,
        asc: candidate.bucket,
        asc: candidate.occurred_at,
        asc: candidate.id
      ],
      select: candidate.id

  Event
  |> where([event], event.id in subquery(sampled_ids))
  |> order_by([event], asc: event.occurred_at, asc: event.id)
  |> Repo.all()
end

defp ambient_at(end_at) do
  Event
  |> where([event], event.source == "open_meteo" and event.occurred_at <= ^end_at)
  |> order_by([event], desc: event.occurred_at, desc: event.id)
  |> limit(1)
  |> Repo.one()
end

defp archive_start_at do
  Event
  |> where([event], event.source != "open_meteo")
  |> select([event], min(event.occurred_at))
  |> Repo.one()
end

defp anchor_in_window(nil, _start_at, _end_at), do: nil

defp anchor_in_window(%Event{} = anchor, start_at, end_at) do
  if DateTime.compare(anchor.occurred_at, start_at) != :lt and
       DateTime.compare(anchor.occurred_at, end_at) != :gt,
     do: anchor
end
```

- [ ] **Step 4: Run Store and projection tests**

```bash
rtk mix format lib/worldloom/loom/store.ex test/worldloom/loom/store_test.exs
rtk mix test test/worldloom/loom/timeline_projection_test.exs test/worldloom/loom/store_test.exs
```

Expected: both files pass; the dense window never loads or returns an unbounded result.

- [ ] **Step 5: Commit the Store window**

```bash
rtk git add lib/worldloom/loom/store.ex test/worldloom/loom/store_test.exs
rtk git commit -m "Load indexed timeline windows with bounded level of detail"
```

### Task 3: Acknowledged LiveView range contract and trusted chapter anchor

**Files:**
- Modify: `lib/worldloom_web/live/world_live.ex`
- Modify: `lib/worldloom_web/live/world_live.html.heex`
- Modify: `test/worldloom_web/live/world_live_test.exs`

- [ ] **Step 1: Write failing LiveView tests**

Add tests for accepted, invalid, and throttled replies. Exercise the actual LiveView handler with `render_hook/3` and assert reply payloads, not only assigns.

```elixir
render_hook(live_view, "timeline-window", %{
  "duration_seconds" => 900,
  "end_at" => "2026-08-09T12:15:00.000000Z"
})

assert_reply live_view, %{
  status: "accepted",
  axis: %{duration_seconds: 900},
  instructions: instructions
}

assert length(instructions) <= 600
assert map_size(live_assign(live_view, :trusted_history_events)) ==
         length(instructions)

render_hook(live_view, "timeline-window", %{
  "duration_seconds" => 901,
  "end_at" => "not-utc"
})
assert_reply live_view, %{status: "invalid"}

render_hook(live_view, "timeline-window", valid_payload)
assert_reply live_view, %{status: "throttled", retry_after_ms: retry_after_ms}
assert retry_after_ms in 1..500
```

On a chapter route, assert the initial HTML dataset and `worldloom:reload` event contain `anchor_at` equal to the selected event occurrence, and that the accepted window includes and authorizes the selected sequence.

- [ ] **Step 2: Run LiveView tests and observe RED**

```bash
rtk mix test test/worldloom_web/live/world_live_test.exs
```

Expected: `timeline-window` currently has no handler and chapter payloads have no `anchor_at`.

- [ ] **Step 3: Implement strict request/reply handling**

Mount `:timeline_requested_at` as `nil`. Add a handler that validates exact integer durations and strict UTC ISO-8601 strings before calling Store. Accepted replies use this shape:

```elixir
%{
  status: "accepted",
  axis: %{
    start_at: DateTime.to_iso8601(window.start_at),
    end_at: DateTime.to_iso8601(window.end_at),
    duration_seconds: window.duration_seconds
  },
  instructions: Enum.map(window.events, &Instruction.from_event/1),
  scaffold: public_scaffold(window.events, socket.assigns.selected_event),
  ambient: encode_ambient(window.ambient),
  archive_start_at: encode_datetime(window.archive_start_at)
}
```

On acceptance, replace `:trusted_history_events` with `trusted_event_map(window.events)` and record the monotonic request time. If the 500 ms guard is active, return `%{status: "throttled", retry_after_ms: remaining}` without querying or changing authorization. Invalid requests reply `%{status: "invalid"}`. Mount `:anchor_at` as `nil`, assign it from `selected_event.occurred_at` only on chapter routes, render `data-anchor-at={@anchor_at}` on `#loom-canvas`, and include the same trusted `anchor_at` in chapter reload payloads.

- [ ] **Step 4: Run focused server tests**

```bash
rtk mix format lib/worldloom_web/live/world_live.ex lib/worldloom_web/live/world_live.html.heex test/worldloom_web/live/world_live_test.exs
rtk mix test test/worldloom/loom/timeline_projection_test.exs test/worldloom/loom/store_test.exs test/worldloom_web/live/world_live_test.exs
```

Expected: accepted, invalid, throttled, authorization, and chapter-anchor tests pass; existing cursor tests remain green.

- [ ] **Step 5: Commit the LiveView contract**

```bash
rtk git add lib/worldloom_web/live/world_live.ex lib/worldloom_web/live/world_live.html.heex test/worldloom_web/live/world_live_test.exs
rtk git commit -m "Add acknowledged authorized timeline window requests"
```

### Task 4: One explicit event-time axis in geometry

**Files:**
- Modify: `assets/js/worldloom/geometry.js`
- Modify: `assets/test/geometry.test.js`

- [ ] **Step 1: Write failing axis tests**

Add exact-edge tests for all durations and an unclamped off-axis assertion:

```javascript
for (const durationMilliseconds of [60_000, 300_000, 900_000]) {
  const axis = {
    end: "2026-08-09T12:15:00.000Z",
    durationMilliseconds,
  }
  const start = new Date(Date.parse(axis.end) - durationMilliseconds).toISOString()

  assert.equal(eventTimeToX(start, axis, viewport), 40)
  assert.equal(eventTimeToX(axis.end, axis, viewport), 760)
}

assert.ok(eventTimeToX("2026-08-09T11:59:59.000Z", axis, viewport, {
  clampToWindow: false,
}) < 40)
```

Add a scene test proving `anchor-hit`, formation paint, scaffold, and seam commands for one sequence share the same x coordinate under a 15m axis.

- [ ] **Step 2: Run geometry tests and observe RED**

```bash
rtk node --test assets/test/geometry.test.js
```

Expected: the current function accepts a fixed `windowEnd` and always projects 60 seconds.

- [ ] **Step 3: Replace the fixed minute with an explicit axis**

Change `eventTimeToX` to accept `{end, durationMilliseconds}` and validate both values. Pass the same axis into `commandsForScene`, `withinTimeAxis`, and `eventTimePositionsFor`. Remove `liveWindowMilliseconds` and remove pixel pan from timed positions; retain sequence/pixel fallback only when no valid axis exists.

```javascript
export function eventTimeToX(occurredAt, axis, viewport, {clampToWindow = true} = {}) {
  const padding = viewport.padding ?? 40
  const usableWidth = Math.max(0, viewport.width - padding * 2)
  const endMilliseconds = Date.parse(axis?.end)
  const durationMilliseconds = Number(axis?.durationMilliseconds)
  const occurredAtMilliseconds = Date.parse(occurredAt)
  if (![endMilliseconds, durationMilliseconds, occurredAtMilliseconds].every(Number.isFinite) ||
      durationMilliseconds <= 0) return padding

  const rawRatio =
    (occurredAtMilliseconds - (endMilliseconds - durationMilliseconds)) /
    durationMilliseconds
  const ratio = clampToWindow ? Math.min(1, Math.max(0, rawRatio)) : rawRatio
  return padding + ratio * usableWidth
}
```

- [ ] **Step 4: Run all Node geometry consumers**

```bash
rtk npm test
```

Expected: all Node tests pass after updating existing geometry expectations to supply the default one-minute axis explicitly.

- [ ] **Step 5: Commit the axis**

```bash
rtk git add assets/js/worldloom/geometry.js assets/test/geometry.test.js
rtk git commit -m "Project every formation through one timeline axis"
```

### Task 5: Renderer duration, lag, and latest-intent state machine

**Files:**
- Modify: `assets/js/worldloom/renderer.js`
- Modify: `assets/test/renderer.test.js`

- [ ] **Step 1: Write failing renderer state tests**

Cover the exact public contract:

```javascript
assert.equal(renderer.timelineDurationMilliseconds, 60_000)
assert.equal(renderer.setTimelineDuration(300_000), true)
assert.equal(renderer.timelineDurationMilliseconds, 300_000)
assert.equal(renderer.atLiveEdge(), true)
assert.equal(renderer.setTimelineDuration(120_000), false)

renderer.panBy(180)
const centerBefore = renderer.timelineAxis().centerMilliseconds
renderer.setTimelineDuration(900_000)
assert.equal(renderer.timelineAxis().centerMilliseconds, centerBefore)

renderer.setSnapshot(laterSnapshot)
assert.equal(renderer.timelineAxis().centerMilliseconds, centerBefore)
```

Add request tests where 5m is requested, 15m becomes the latest queued intent, the first accepted reply is discarded, a throttled reply schedules exactly one retry, and an archive boundary prevents further earlier requests. Inject `scheduleTimeout`, `cancelTimeout`, and `onTimelineRequest` so tests are deterministic.

- [ ] **Step 2: Run renderer tests and observe RED**

```bash
rtk node --test assets/test/renderer.test.js
```

Expected: missing duration/axis/range methods and pixel-based pan assertions fail.

- [ ] **Step 3: Implement duration and time-lag state**

Add supported duration constants, `liveMode`, `timelineDurationMilliseconds`, `viewLagMilliseconds`, `chapterAnchorMilliseconds`, `timelineRequestInFlight`, `latestTimelineIntent`, and `archiveStartMilliseconds`.

Implement these public methods with finite guards:

```javascript
setTimelineDuration(durationMilliseconds)
timelineAxis()
setTimelineWindow(payload)
completeTimelineRequest(reply)
setChapterAnchor(anchorAt)
returnLive()
```

At live Now, `timelineAxis().end` is canonical snapshot `windowEnd`. In panned live history, scale changes apply:

```javascript
newLag = oldLag + (oldDuration - newDuration) / 2
```

and clamp only to zero or the archive boundary. In chapter mode, `viewLagMilliseconds` offsets the selected center and duration changes leave that center unchanged. Convert pan pixels with:

```javascript
elapsedMilliseconds = deltaPixels * timelineDurationMilliseconds / usableWidth
```

New live snapshots advance Now but preserve the historical visible axis. `timelineAxis()` is the sole axis passed to geometry and diagnostics. Remove timed uses of `panOffset`, `projectedPanOffset`, and `viewTranslationX`; keep sequence fallback compatibility tests for untimed scenes.

- [ ] **Step 4: Run renderer and full Node tests**

```bash
rtk node --test assets/test/renderer.test.js
rtk npm test
```

Expected: scale, center, snapshot, request, Return-live, resize, reduced-motion, and all pre-existing renderer tests pass.

- [ ] **Step 5: Commit renderer state**

```bash
rtk git add assets/js/worldloom/renderer.js assets/test/renderer.test.js
rtk git commit -m "Add stable timeline scale and range intent state"
```

### Task 6: Semantic controls, reply bridge, and responsive Lacquered Gallery styling

**Files:**
- Modify: `assets/js/worldloom/hook.js`
- Modify: `assets/test/hook.test.js`
- Modify: `lib/worldloom_web/live/world_live.html.heex`
- Modify: `assets/css/app.css`
- Modify: `test/worldloom_web/live/world_live_test.exs`

- [ ] **Step 1: Write failing hook and template tests**

Extend the hook harness with three `.timeline-scale-button` nodes and `#timeline-range`. Assert repeated `updated()` calls bind each button once, 15m activation updates `aria-pressed`, and range text is explicit UTC text. Assert callback replies are forwarded only for the active hook generation.

```javascript
harness.scaleButtons[2].dispatch("click")
assert.deepEqual(harness.renderer.timelineDurations, [900_000])
assert.equal(harness.scaleButtons[2].getAttribute("aria-pressed"), "true")
assert.match(harness.timelineRange.textContent, /15 minutes · .* UTC–.* UTC/)

harness.hook.updated()
harness.hook.updated()
assert.equal(harness.scaleButtons[2].listeners.get("click").length, 1)
```

In LiveView tests, assert one `role="group"`, stable button IDs, 44px-target classes/data, `aria-describedby="timeline-range"`, and scale availability on chapter routes while gesture buttons remain disabled.

- [ ] **Step 2: Run hook and LiveView tests and observe RED**

```bash
rtk node --test assets/test/hook.test.js
rtk mix test test/worldloom_web/live/world_live_test.exs
```

Expected: no scale nodes, bindings, or reply bridge exist.

- [ ] **Step 3: Render and bind one control group**

Render this stable structure outside the `phx-update="ignore"` canvas subtree:

```heex
<div id="timeline-controls" class="timeline-controls">
  <div id="timeline" class="timeline" aria-hidden="true">
    <span>Earlier</span><i></i><span>Now</span>
  </div>
  <div class="timeline-scale" role="group" aria-label="Timeline scale" aria-describedby="timeline-range">
    <button :for={{label, seconds} <- [{"1m", 60}, {"5m", 300}, {"15m", 900}]}
            id={"timeline-scale-#{seconds}"}
            type="button"
            class="timeline-scale-button"
            data-duration-seconds={seconds}
            aria-pressed={seconds == 60}>{label}</button>
  </div>
  <p id="timeline-range" class="timeline-range">1 minute · UTC range unavailable</p>
</div>
```

Bind buttons through a `WeakSet`, call `renderer.setTimelineDuration(seconds * 1000)`, and use `pushEvent("timeline-window", payload, callback)` for renderer intents. Increment a hook generation on route/reload lifecycle changes; discard callbacks whose generation no longer matches or whose hook is destroyed. Accepted/throttled replies call the renderer completion method and refresh controls/diagnostics.

- [ ] **Step 4: Add responsive visual and accessibility states**

Position `.timeline-controls` above `.gesture-dock`; stack the decorative rule and scale group on desktop; hide only `.timeline` at `max-width: 760px`. Give every button `min-width` and `min-height: 44px`, native borders, saffron/wine active state, visible `:focus-visible`, and explicit forced-colors current-state treatment. Keep the range text readable but subordinate and non-live.

- [ ] **Step 5: Run focused and complete component tests**

```bash
rtk mix format lib/worldloom_web/live/world_live.html.heex
rtk node --test assets/test/hook.test.js
rtk mix test test/worldloom_web/live/world_live_test.exs
rtk npm test
```

Expected: bindings are idempotent, all scale semantics render on every route, and existing gesture controls remain server-authoritative.

- [ ] **Step 6: Commit the controls**

```bash
rtk git add assets/js/worldloom/hook.js assets/test/hook.test.js lib/worldloom_web/live/world_live.html.heex assets/css/app.css test/worldloom_web/live/world_live_test.exs
rtk git commit -m "Add accessible Lacquered Gallery timeline controls"
```

### Task 7: Mobile touch ownership and renderer-authoritative formation taps

**Files:**
- Modify: `assets/css/app.css`
- Modify: `assets/test/hook.test.js`
- Modify: `e2e/worldloom.spec.js`

- [ ] **Step 1: Add failing mobile acceptance assertions**

Move formation inspection before the current-time gesture. Replace sequence-coordinate reconstruction with `liveSceneDiagnostics(canvas).scene.paintCommands` filtered to visible `anchor-hit` commands. For each candidate, convert canvas-local center to viewport coordinates and require `document.elementFromPoint` to resolve to the canvas before tapping.

Convert the three-gesture test contexts to:

```javascript
{
  baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
  viewport: {width: 390, height: 844},
  hasTouch: true,
  isMobile: true,
}
```

and submit each action with `.tap()`. Add a real touch drag on the live membrane, assert one final slider lane, then tap the action and observe one new durable formation. Add a compact legend/panel touch-scroll assertion.

- [ ] **Step 2: Run the focused mobile tests and observe RED**

```bash
rtk npx playwright test e2e/worldloom.spec.js --grep "touch visitors|Tug, Knot, and Illuminate|overlay remains touch-scrollable"
```

Expected: the obsolete coordinate helper fails, and the stage still reports `touch-action: pan-y`.

- [ ] **Step 3: Give the fixed canvas full touch ownership**

Change only the canvas stage declaration:

```css
.loom-stage {
  touch-action: none;
}
```

Retain the existing placement state machine and its cancellation/exactly-once unit tests. Do not add a canvas gesture submission path.

- [ ] **Step 4: Run unit and focused browser verification**

```bash
rtk node --test assets/test/hook.test.js
rtk npx playwright test e2e/worldloom.spec.js --grep "touch visitors|Tug, Knot, and Illuminate|overlay remains touch-scrollable"
```

Expected: inspection, direct placement, all three native taps, cancellation semantics, and overlay scrolling pass without browser-monitor failures.

- [ ] **Step 5: Commit touch reliability**

```bash
rtk git add assets/css/app.css assets/test/hook.test.js e2e/worldloom.spec.js
rtk git commit -m "Prove reliable mobile touch placement and formation taps"
```

### Task 8: Representative quarter-hour acceptance scene and visual baselines

**Files:**
- Modify: `assets/test/fixtures/balanced_snapshots.js`
- Modify: `test/support/worldloom/e2e_scene_loader.ex`
- Modify: `test/support/worldloom_web/e2e_controller.ex`
- Modify: `test/worldloom_web/e2e_controller_test.exs`
- Modify: `e2e/worldloom.spec.js`
- Modify/Create: `e2e/worldloom.spec.js-snapshots/*.png`

- [ ] **Step 1: Write failing fixture-loader and browser assertions**

Export deterministic prior events spanning `2026-08-08T11:46:00Z` through `12:00:00Z` at the real source cadences used by the app. Give prior records sequences below 10,000 and build the live snapshot from sequence 10,000 upward so IDs cannot collide. Pass them as `prior_events` only for the known `balanced-quarter-hour` test scene. Set a test-only `@prior_limit 1_200`; controller tests reject unknown fields, invalid source/kind pairs, 1,201 prior records, or a prior event at/after the live minute.

Add desktop/mobile browser tests that press 15m and assert diagnostics report:

```javascript
expect(diagnostics.axis.durationSeconds).toBe(900)
expect(Date.parse(diagnostics.axis.end) - Date.parse(diagnostics.axis.start)).toBe(900_000)
const paintedSources = new Set(
  diagnostics.scene.paintCommands.map(command => command.source),
)
for (const source of ["wikimedia", "bluesky", "ripe_ris", "solana", "drand"]) {
  expect(paintedSources.has(source)).toBe(true)
}
```

Also assert Now remains pinned, all scale targets are at least 44px, and the historical center survives 5m→15m.

- [ ] **Step 2: Run loader and quarter-hour tests and observe RED**

```bash
rtk mix test test/worldloom_web/e2e_controller_test.exs
rtk npx playwright test e2e/worldloom.spec.js --grep "quarter-hour|timeline scale"
```

Expected: the new scene and prior-record contract do not exist.

- [ ] **Step 3: Extend only the acceptance harness**

Validate `prior_events` with the same instruction key allow-list and source/kind/render contracts as live fixture events. Insert live, memory, ambient, and prior rows in the existing exclusive test transaction before restarting the coordinator. Keep production routes and configuration unchanged.

- [ ] **Step 4: Generate and inspect exact baselines**

Run:

```bash
rtk npx playwright test e2e/worldloom.spec.js --grep "balanced desktop|balanced mobile|quarter-hour" --update-snapshots
rtk npx playwright test e2e/worldloom.spec.js --grep "balanced desktop|balanced mobile|quarter-hour"
```

Expected: updated 1m desktop/mobile controls and new 15m desktop/mobile baselines pass at the existing `0.08` threshold. Inspect all four PNGs for dock/control overlap, source diversity, live-right alignment, mobile width, and readable active state before keeping them.

- [ ] **Step 5: Commit representative visual coverage**

```bash
rtk git add assets/test/fixtures/balanced_snapshots.js test/support/worldloom/e2e_scene_loader.ex test/support/worldloom_web/e2e_controller.ex test/worldloom_web/e2e_controller_test.exs e2e/worldloom.spec.js e2e/worldloom.spec.js-snapshots
rtk git commit -m "Add representative quarter-hour visual coverage"
```

### Task 9: Public README and full release verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update only shipped public behavior**

Add a **What you can do** bullet for 1m/5m/15m scales. State that Now stays pinned live and panned/chapter centers remain stable. Replace the gesture bullet with the exact two-step flow: touch/adjust the lane, then press Tug, Knot, or Illuminate. Expand the verification paragraph to mention bounded timeline projection, anchor preservation, real mobile tap submission, and overlay scrolling. Do not alter source posture, privacy, versions, hosting, or deployment requirements.

- [ ] **Step 2: Run documentation and diff checks**

```bash
rtk rg -n "1m|5m|15m|position.*lane|mobile.*tap|timeline" README.md
rtk git diff --check
```

Expected: all shipped behaviors are named, no unrelated claim changed, and the diff has no whitespace errors.

- [ ] **Step 3: Commit documentation**

```bash
rtk git add README.md
rtk git commit -m "Document timeline scale and two-step touch controls"
```

- [ ] **Step 4: Run the complete verification matrix**

```bash
rtk npm test
rtk mix precommit
rtk npm run test:e2e
rtk docker build -t worldloom:timeline-zoom-touch .
rtk git status --short
```

Expected: Node, compile/format/Phoenix, all Playwright functional and visual tests, and the production container build pass; the worktree is clean.

- [ ] **Step 5: Inspect localhost at desktop and mobile sizes**

Run the feature worktree on an unused port with feeds disabled, inspect 1m/5m/15m live and a chapter at 1440×1000 and 390×844, exercise lane placement plus every action, and confirm zero console/page/request/response/WebSocket failures. Stop that temporary server after inspection.

- [ ] **Step 6: Review the final branch against the spec**

Check the final diff for: no fixed 60-second geometry assumption; no pixel-coordinate duplication in E2E; no zoom persistence; exact 600/4,000 bounds; one range request in flight; strict server validation; chapter read-only state; test-only diagnostics/fixtures; and no AI-attribution commit trailers.

- [ ] **Step 7: Integrate and publish only after exact-head verification**

Use the repository's established merge workflow, push the intended branch, require GitHub CI for the exact commit, then restart the primary localhost server from the merged checkout. Do not merge or push a head that differs from the locally verified commit.
