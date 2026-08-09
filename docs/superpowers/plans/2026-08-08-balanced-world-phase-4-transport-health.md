# Balanced World Phase 4: Transport and Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Isolate every feed behind a supervised, bounded transport; drain persisted work fairly; and report ephemeral feed truth without confusing checkpoints with liveness.

**Architecture:** WebSocket sources use one source-specific WebSockex process each and synchronously reduce complete frames into bounded aggregate state. A health registry records coarse lifecycle observations. Buffer partitions isolate source pressure and drain round-robin. Source-specific associative reducers collapse scheduled summaries; drand preserves up to twenty ordered rounds and never merges.

**Tech Stack:** Elixir 1.20, OTP supervisors, WebSockex 0.5.1, Req, Ecto, Phoenix PubSub, Telemetry, ExUnit.

---

## Files

### Create

- `lib/worldloom/signals/health_registry.ex`
- `lib/worldloom/signals/safe_endpoint.ex`
- `lib/worldloom/signals/bluesky_socket.ex`
- `lib/worldloom/signals/ripe_socket.ex`
- `lib/worldloom/signals/solana_socket.ex`
- `lib/worldloom/signals/drand_worker.ex`
- `test/support/websocket_fixture_server.ex`
- corresponding tests under `test/worldloom/signals/`

### Modify

- `mix.exs` and `mix.lock`
- `lib/worldloom/application.ex`
- `lib/worldloom/signals/supervisor.ex`
- `lib/worldloom/signals/buffer.ex`
- `lib/worldloom/signals/merger.ex`
- `lib/worldloom/signals/feed_health.ex`
- `lib/worldloom/signals/health_monitor.ex`
- `lib/worldloom/signals/wikimedia_worker.ex`
- existing signal tests and telemetry tests

## Task 1: Add WebSockex with an explicit raw-frame telemetry prohibition

- [ ] **Step 1: Add the dependency and inspect its exact lock**

Add to `mix.exs`:

```elixir
{:websockex, "~> 0.5.1"}
```

Then:

```bash
rtk mix deps.get
rtk mix deps.compile websockex
rtk mix hex.audit
```

Review `mix.lock`; do not change unrelated dependency constraints.

- [ ] **Step 2: Write the telemetry attachment guard**

In `test/worldloom/signals/supervisor_test.exs`, inspect these documented events:

```elixir
for event <- [
  [:websockex, :frame, :received],
  [:websockex, :frame, :sent]
], do: assert(:telemetry.list_handlers(event) == [])
```

Also assert `WorldloomWeb.Telemetry.metrics/0` contains no WebSockex frame event. Connection/disconnection events may be observed only through Worldloom's own coarse callbacks, never by attaching to raw library events.

- [ ] **Step 3: Run and verify the guard**

```bash
rtk mix test test/worldloom/signals/supervisor_test.exs test/worldloom_web/telemetry_test.exs
```

- [ ] **Step 4: Commit dependency and policy together**

```bash
rtk git add mix.exs mix.lock test/worldloom/signals/supervisor_test.exs test/worldloom_web/telemetry_test.exs
rtk git commit -m "Add WebSocket transport without raw-frame telemetry"
```

## Task 2: Record ephemeral feed lifecycle truth

- [ ] **Step 1: Write failing registry tests**

Create `test/worldloom/signals/health_registry_test.exs`. With an injected clock, record and assert distinct observations for:

```elixir
HealthRegistry.record(registry, :bluesky, :connected)
HealthRegistry.record(registry, :bluesky, :contact)
HealthRegistry.record(registry, :bluesky, {:activity, 12})
HealthRegistry.record(registry, :bluesky, {:drop, :oversized})
HealthRegistry.record(registry, :bluesky, {:merge, 3})
HealthRegistry.record(registry, :bluesky, {:recovery, 2})
HealthRegistry.record(registry, :bluesky, {:retry, 4})
HealthRegistry.record(registry, :bluesky, :disconnected)
```

Assert no raw reason, cursor, URL, frame, prefix, identity, or response body is retained. Unknown source/event tuples return `{:error, :invalid_observation}` without atom creation.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/health_registry_test.exs
```

- [ ] **Step 3: Implement the bounded registry**

Create `lib/worldloom/signals/health_registry.ex` as a named GenServer. Store for each allow-listed source only connection state, last contact/activity times, and saturating aggregate counts for drops, merges, recovered windows, retries, and last coarse reason atom from a fixed allow list.

Expose:

```elixir
@spec record(GenServer.server(), atom(), observation()) :: :ok | {:error, :invalid_observation}
@spec current(GenServer.server()) :: map()
```

Publish `{:feed_health, projection}` only when the public projection changes.

- [ ] **Step 4: Replace checkpoint-derived high-cadence health**

Update `FeedHealth.project/2` and `HealthMonitor` to use registry observations for Wikimedia, Bluesky, RIPE, Solana, and drand. Rules:

- a closed socket is `:disconnected` immediately;
- connected high-cadence feeds become `:quiet` after 20 seconds without valid activity;
- drand becomes `:stale` after 12 seconds without a new valid round;
- USGS and Open-Meteo retain their existing thresholds;
- checkpoints remain durability/replay state only.

- [ ] **Step 5: Supervise and verify**

Start `HealthRegistry` before Buffer and Signals Supervisor in `lib/worldloom/application.ex`. Keep `/healthz` unchanged.

```bash
rtk mix test test/worldloom/signals/health_registry_test.exs test/worldloom/signals/feed_health_test.exs test/worldloom/signals/health_monitor_test.exs test/worldloom_web/controllers/health_controller_test.exs
rtk git add lib/worldloom/application.ex lib/worldloom/signals/health_registry.ex lib/worldloom/signals/feed_health.ex lib/worldloom/signals/health_monitor.ex test/worldloom/signals/health_registry_test.exs test/worldloom/signals/feed_health_test.exs test/worldloom/signals/health_monitor_test.exs
rtk git commit -m "Report ephemeral feed connection and activity health"
```

## Task 3: Redesign Buffer as fair source partitions

- [ ] **Step 1: Replace FIFO expectations with fairness tests**

In `test/worldloom/signals/buffer_test.exs`, create a blocked Wikimedia partition followed by Bluesky, RIPE, drand, and USGS submissions. Assert successful drains rotate sources and no source drains twice while another ready partition waits. Assert retry delay blocks only the failing source.

Add pressure cases proving:

- total depth and per-source depth remain bounded;
- a source partition merges only its own mergeable scheduled rows;
- drand queues at most 20 ordered rounds and never calls `Merger.merge/1`;
- all waiters receive success only after their merged durable commit succeeds;
- exhausting one source's persistence retries fails only that partition.
- checkpoint-only empty windows retain their source partition, advance durability, and never enter a reducer.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/buffer_test.exs
```

- [ ] **Step 3: Implement partition and rotation state**

Replace `queue: []` with:

```elixir
%{
  partitions: %{optional(source()) => :queue.queue(entry())},
  rotation: :queue.queue(source()),
  blocked_until: %{optional(source()) => integer()},
  depth: 0,
  timer_ref: nil
}
```

Insert a source into `rotation` only when its partition transitions empty-to-non-empty. On each drain, take the next ready source, pop one entry, and rotate a still-non-empty source to the tail. Preserve synchronous `Buffer.submit/2` acknowledgment semantics.

- [ ] **Step 4: Emit privacy-safe per-source pressure metrics**

Emit total depth plus source atom and bounded counts. Never attach event, checkpoint, cursor, or URL. Record `{:merge, count}` and `{:retry, attempt}` through `HealthRegistry`.

- [ ] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom/signals/buffer_test.exs test/worldloom/loom/coordinator_test.exs
rtk git add lib/worldloom/signals/buffer.ex test/worldloom/signals/buffer_test.exs
rtk git commit -m "Drain signal persistence fairly by source"
```

## Task 4: Make pressure reducers associative and source-specific

- [ ] **Step 1: Write grouping-invariance tests**

Extend `test/worldloom/signals/merger_test.exs` for Wikimedia, Bluesky, RIPE, and Solana. For each fixture list, assert:

```elixir
{:ok, direct} = Merger.merge(events)
{:ok, left} = Merger.merge(Enum.take(events, 2))
{:ok, right} = Merger.merge(Enum.drop(events, 2))
{:ok, regrouped} = Merger.merge([left, right])
assert regrouped == direct
```

Assert merged payload has `window_count = sum`, `window_span_seconds = sum`, saturation/truncation propagation, deterministic external identity, and source-appropriate weighted lane/intensity. Assert `Merger.merge(drand_events) == {:error, :unsupported_source}`.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/merger_test.exs
```

- [ ] **Step 3: Implement reducers using sufficient statistics**

Do not merge averages without their weights. Carry counts required to recompute lane/intensity exactly. Merge external IDs through the existing order-independent checksum. Label summaries as pressure summaries and disclose both `window_count` and `window_span_seconds`.

- [ ] **Step 4: Verify randomized grouping and commit**

Run each deterministic grouping case with shuffled input 100 times; output must be identical.

```bash
rtk mix test test/worldloom/signals/merger_test.exs --repeat-until-failure 100 --max-failures 1
rtk git add lib/worldloom/signals/merger.ex test/worldloom/signals/merger_test.exs
rtk git commit -m "Merge source pressure with associative summaries"
```

## Task 5: Implement bounded source-specific WebSocket processes

- [ ] **Step 1: Create safe endpoint tests**

Create `test/worldloom/signals/safe_endpoint_test.exs`. Assert `SafeEndpoint.label/1` preserves scheme, host, port, and path but strips query, fragment, userinfo, and cursor. Reject non-`wss` production endpoints.

- [ ] **Step 2: Build fake WebSocket edge tests first**

Create `test/support/websocket_fixture_server.ex` as a local Bandit/WebSock test server and use it in all three socket tests. For Bluesky, RIPE, and Solana, prove:

- one complete text frame is decoded and reduced synchronously in `handle_frame/2`;
- frames above 262,144 decoded bytes close/drop before JSON decoding;
- fragmented messages are tested at the complete-frame callback boundary and the documented post-allocation limitation is explicit;
- malformed JSON records one coarse drop and keeps the sibling processes alive;
- process `max_heap_size` is set to 2,000,000 words with `kill: true` and `error_logger: false`;
- a mailbox above 100 messages closes the process before more application work;
- logs and Worldloom telemetry contain no frame, cursor, URL query, or response body.

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/safe_endpoint_test.exs test/worldloom/signals/bluesky_socket_test.exs test/worldloom/signals/ripe_socket_test.exs test/worldloom/signals/solana_socket_test.exs
```

- [ ] **Step 4: Implement three explicit WebSockex modules**

Create `BlueskySocket`, `RipeSocket`, and `SolanaSocket`; do not hide provider behavior behind one generic callback module.

Bluesky URL parameters must be exactly two repeated `wantedCollections` values, `maxMessageSizeBytes=262144`, `compress=false`, and an optional replay cursor. Account and identity events are dropped. On reconnect, subtract five seconds from the last committed `time_us`, cap replay to sixty seconds, and deduplicate a bounded 4,096-entry hash set.

RIPE first sends `request_rrc_list`, intersects the response with at most four configured collectors, then sends one `ris_subscribe` message per collector with `type: UPDATE`, `includeRaw: false`, and `acknowledge: true`. It has no replay.

Solana sends only JSON-RPC `slotSubscribe`; it has no replay and remains production-disabled.

Each process records connected/contact/activity/drop/retry/disconnected observations directly through `HealthRegistry`. Do not `send(self(), decoded_frame)` or queue ordinary frame work.

At the start of each Bluesky complete-frame callback, call the injected server clock exactly once, bind that value as `receipt_at`, use it for every temporal decision in that callback, and pass it unchanged to `BlueskyWindow.add/3`.

For Bluesky overlap deduplication, the canonical fingerprint material is the JSON encoding of the ordered array `[time_us, "commit", did, collection, operation, rkey]`. Hash that material immediately through `BlueskyRecovery`; never retain or expose the encoded array, DID, record key, cursor, CID, record, or content.

One source-local timer may call `handle_info(:flush_window, state)` once per second. It closes only windows past the one-second lateness grace; a non-empty window submits its one sanitized event and checkpoint, while an empty elapsed window submits `[]` and the checkpoint. Timer messages are lifecycle control, not deferred raw-frame work.

- [ ] **Step 5: Verify isolation and commit**

```bash
rtk mix test test/worldloom/signals/safe_endpoint_test.exs test/worldloom/signals/bluesky_socket_test.exs test/worldloom/signals/ripe_socket_test.exs test/worldloom/signals/solana_socket_test.exs test/worldloom/signals/supervisor_test.exs
rtk git add lib/worldloom/signals/safe_endpoint.ex lib/worldloom/signals/bluesky_socket.ex lib/worldloom/signals/ripe_socket.ex lib/worldloom/signals/solana_socket.ex test/support/websocket_fixture_server.ex test/worldloom/signals/safe_endpoint_test.exs test/worldloom/signals/bluesky_socket_test.exs test/worldloom/signals/ripe_socket_test.exs test/worldloom/signals/solana_socket_test.exs test/worldloom/signals/supervisor_test.exs
rtk git commit -m "Isolate bounded public WebSocket transports"
```

## Task 6: Implement bounded drand polling and recovery

- [ ] **Step 1: Write worker recovery tests**

Create `test/worldloom/signals/drand_worker_test.exs`. With injected client, clock, timer, and buffer, assert one poll per expected three-second round, ordered catch-up, maximum 20 missed rounds, duplicate round idempotence, no merge, independent backoff, and stale health after 12 seconds.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/drand_worker_test.exs
```

- [ ] **Step 3: Implement the poll worker**

Create `lib/worldloom/signals/drand_worker.ex`. On each scheduled tick, derive expected round, ask `DrandClient` for exact rounds, normalize, and submit in ascending order. Stop catch-up after twenty rounds and record the remaining interval as a gap. Use its own capped backoff state; never block or restart a WebSocket sibling.

- [ ] **Step 4: Verify and commit**

```bash
rtk mix test test/worldloom/signals/drand_worker_test.exs test/worldloom/signals/drand_client_test.exs
rtk git add lib/worldloom/signals/drand_worker.ex test/worldloom/signals/drand_worker_test.exs
rtk git commit -m "Recover bounded drand rounds in order"
```

## Task 7: Bring Wikimedia and existing polling feeds into health/replay rules

- [ ] **Step 1: Add recovery and health tests**

Extend `wikimedia_worker_test.exs`, `earthquake_worker_test.exs`, and `weather_worker_test.exs`. Prove Wikimedia resumes with Last-Event-ID for at most sixty seconds, late recovery rows persist as history-only through the snapshot projection, and every worker records lifecycle health without putting checkpoint metadata into public health.

- [ ] **Step 2: Implement source-local backoff and observations**

Update workers to record through `HealthRegistry`. Preserve their independent `Backoff` states. Do not change `/healthz` or turn feed degradation into application unready status.

- [ ] **Step 3: Complete transport verification**

```bash
rtk mix precommit
rtk npm test
rtk mix test test/worldloom/signals --include stress
rtk git diff --check master...HEAD
rtk mix hex.audit
```

- [ ] **Step 4: Commit existing-feed integration**

```bash
rtk git add lib/worldloom/signals/wikimedia_worker.ex lib/worldloom/signals/earthquake_worker.ex lib/worldloom/signals/weather_worker.ex test/worldloom/signals/wikimedia_worker_test.exs test/worldloom/signals/earthquake_worker_test.exs test/worldloom/signals/weather_worker_test.exs
rtk git commit -m "Track bounded recovery across existing feeds"
```

## Phase 4 completion gate

- [ ] Each source process can crash without restarting a sibling; supervision remains `:one_for_one`.
- [ ] No app handler attaches to WebSockex frame telemetry.
- [ ] Complete-frame, process-heap, mailbox, replay, dedupe, distinct-set, counter, and queue bounds are tested.
- [ ] Fair draining prevents one source from monopolizing persistence.
- [ ] Scheduled pressure reducers are associative; drand never merges.
- [ ] Health comes from ephemeral connection/contact/activity observations, not immediate checkpoint state.
- [ ] New transports exist but production enablement remains false.
