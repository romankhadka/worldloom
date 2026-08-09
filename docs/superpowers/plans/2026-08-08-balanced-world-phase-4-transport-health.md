# Balanced World Phase 4: Transport and Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Isolate every feed behind a supervised, bounded transport; drain persisted work fairly; and report ephemeral feed truth without confusing checkpoints with liveness.

**Architecture:** Each WebSocket source uses one source-specific GenServer that owns its Mint connection, upgrade reference, `Mint.WebSocket` decoder, subscription, reconnect timer, and bounded aggregate state. A processless helper centralizes only secure transport mechanics and coarse failures; provider behavior stays explicit. A health registry records coarse lifecycle observations. Buffer partitions isolate source pressure and drain round-robin. Source-specific associative reducers collapse scheduled summaries; drand preserves up to twenty ordered rounds and never merges.

**Tech Stack:** Elixir 1.20, OTP supervisors, Mint WebSocket 1.0.5 plus its pinned official Elixir 1.20 compatibility commit, Mint 1.9, Req, Ecto, Phoenix PubSub, Telemetry, ExUnit.

---

## Files

### Create

- `lib/worldloom/signals/health_registry.ex`
- `lib/worldloom/signals/safe_endpoint.ex`
- `lib/worldloom/signals/websocket_transport.ex`
- `lib/worldloom/signals/bluesky_socket.ex`
- `lib/worldloom/signals/ripe_socket.ex`
- `lib/worldloom/signals/solana_socket.ex`
- `lib/worldloom/signals/drand_worker.ex`
- `test/support/websocket_fixture_server.ex`
- `test/support/fixtures/tls/localhost_ca.pem`
- `test/support/fixtures/tls/localhost_certificate.pem`
- `test/support/fixtures/tls/localhost_key.pem`
- `test/worldloom/signals/websocket_transport_test.exs`
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

## Task 1: Add Mint WebSocket with a verified transport contract

- [x] **Step 1: Add the dependency and inspect its exact lock**

Add to `mix.exs`:

```elixir
{:mint_web_socket,
 git: "https://github.com/elixir-mint/mint_web_socket.git",
 ref: "0c630f75d0a0f27ee337d7e1208abe15e8f20b22"}
```

Then:

```bash
rtk mix deps.get
rtk mix deps.compile mint_web_socket
rtk mix hex.audit
```

Review `mix.lock`; do not change unrelated dependency constraints. The full immutable ref is temporary: return to a checksummed Hex release as soon as one contains `0c630f75`, diff that release against this pin, and restore ordinary Hex advisory coverage for the package.

- [x] **Step 2: Audit the exact dependency boundary**

Inspect the locked `mint_web_socket` source and changelog. Confirm it delegates network I/O to Mint, emits no raw-frame telemetry or logs, and supports active/passive connections without replacing Mint's TLS configuration. Record the evidence in this plan before closing the task. Do not infer safety from package naming.

Audit evidence, 2026-08-08:

- The official v1.0.5 source delegates network I/O to Mint, keeps the API processless, returns decoded frames to its caller, and contains no Telemetry or Logger calls.
- The immutable official commit `0c630f75d0a0f27ee337d7e1208abe15e8f20b22` is exactly two commits ahead of v1.0.5: one README badge fix and the Elixir 1.20 pin-operator/type-warning fix. Its source delta is four additions and three deletions in `frame.ex`, one one-line fix in `per_message_deflate.ex`, and the minimum Elixir version update.
- The first Hex v1.0.5 compile exposed two Elixir 1.20 warnings. The pinned commit compiles without them and retains Mint 1.9.3 with no new transitive dependency.
- `mix hex.audit` covers every locked Hex package but cannot cover this Git dependency. Until the removal condition above is met, release review must check both the official repository's security advisories and Hex v1.0.5 retirement/advisory state explicitly.
- The official repository currently reports no public security advisories, Hex v1.0.5 is not retired, the exact lock re-fetches cleanly, and the warning-as-error full suite passes 326 tests.

- [x] **Step 3: Verify the existing observability boundary**

Assert `WorldloomWeb.Telemetry.metrics/0` contains no Mint or Mint WebSocket transport metric, and that Worldloom source metrics contain only coarse source, status, and operation fields. The provider edge tests in Task 5 will attach marker collectors and exercise the real helper; the locked-source audit in Step 2 proves the dependency introduces no second observability path.

```bash
rtk mix test test/worldloom/signals/supervisor_test.exs test/worldloom_web/telemetry_test.exs
rtk mix deps.tree
rtk mix deps.unlock --check-unused
rtk mix hex.audit
rtk mix deps.get --check-locked
```

- [x] **Step 4: Commit dependency and policy together**

```bash
rtk git add mix.exs mix.lock test/worldloom/signals/supervisor_test.exs test/worldloom_web/telemetry_test.exs docs/superpowers/plans/2026-08-08-balanced-world-phase-4-transport-health.md
rtk git commit -m "Select a private peer-verified WebSocket transport"
```

## Task 2: Record ephemeral feed lifecycle truth

- [x] **Step 1: Write failing registry tests**

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

- [x] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/health_registry_test.exs
```

- [x] **Step 3: Implement the bounded registry**

Create `lib/worldloom/signals/health_registry.ex` as a named GenServer. Store for each allow-listed source only connection state, last contact/activity times, and saturating aggregate counts for drops, merges, recovered windows, retries, and last coarse reason atom from a fixed allow list.

Expose:

```elixir
@spec record(GenServer.server(), atom(), observation()) :: :ok | {:error, :invalid_observation}
@spec current(GenServer.server()) :: map()
```

The registry never publishes public health. On a connection-state transition, it sends `HealthMonitor` only the payload-free message `:health_registry_changed`, so a disconnect projects immediately without copying registry state through a mailbox. Periodic monitor refreshes age quiet/stale activity. `HealthMonitor` remains the sole owner of public health telemetry, cache, PubSub topic, and broadcasts.

- [x] **Step 4: Replace checkpoint-derived high-cadence health**

Update `FeedHealth.project/2` and `HealthMonitor` to use this explicit input contract:

```elixir
FeedHealth.project(
  %{
    observations: %{
      optional(:wikimedia | :bluesky | :ripe_ris | :solana | :drand) => %{
        connection: :connected | :disconnected,
        last_contact_at: DateTime.t() | nil,
        last_activity_at: DateTime.t() | nil
      }
    },
    checkpoints: [map()]
  },
  now
)
```

Registry counters and coarse reasons remain internal and are never part of `FeedHealth` input or public output. `HealthMonitor` loads both inputs, owns the public projection, and broadcasts `{:feed_health, projection}` only when that projection changes. Rules:

- a closed socket is `:disconnected` immediately;
- connected high-cadence feeds become `:quiet` after 20 seconds without valid activity;
- drand becomes `:stale` after 12 seconds without a new valid round;
- USGS and Open-Meteo retain their existing thresholds;
- checkpoints remain durability/replay state only; and
- public `observed_at` is the last activity time for high-cadence sources and the checkpoint success time for polling sources.

Wire the existing Wikimedia worker's connection, valid-frame contact, durable activity, retry, and disconnect transitions into `HealthRegistry` in this task. A started stream task is not proof of a connected transport: record `:connected` only when the worker receives a valid SSE event or heartbeat. Record activity only after a non-empty window is durably accepted by Buffer. This prevents today's active source from regressing to public `:disconnected` while Task 7 remains focused on replay and the two polling workers.

- [x] **Step 5: Supervise and verify**

Start `HealthRegistry`, then `HealthMonitor`, before Buffer and Signals Supervisor in `lib/worldloom/application.ex`, so no worker can notify a missing monitor. `HealthMonitor` handles `:health_registry_changed` with an immediate projection refresh but does not schedule an additional periodic timer. Keep `/healthz` unchanged.

```bash
rtk mix test test/worldloom/signals/health_registry_test.exs test/worldloom/signals/feed_health_test.exs test/worldloom/signals/health_monitor_test.exs test/worldloom/signals/wikimedia_worker_test.exs test/worldloom_web/controllers/health_controller_test.exs
rtk git add lib/worldloom/application.ex lib/worldloom/signals/health_registry.ex lib/worldloom/signals/feed_health.ex lib/worldloom/signals/health_monitor.ex lib/worldloom/signals/wikimedia_worker.ex test/worldloom/signals/health_registry_test.exs test/worldloom/signals/feed_health_test.exs test/worldloom/signals/health_monitor_test.exs test/worldloom/signals/wikimedia_worker_test.exs
rtk git commit -m "Report ephemeral feed connection and activity health"
```

## Task 3: Redesign Buffer as fair source partitions

- [x] **Step 1: Replace FIFO expectations with fairness tests**

In `test/worldloom/signals/buffer_test.exs`, create a blocked Wikimedia partition followed by Bluesky, RIPE, drand, and USGS submissions. Assert successful drains rotate sources and no source drains twice while another ready partition waits. Assert retry delay blocks only the failing source.

Add pressure cases proving:

- total depth and per-source depth remain bounded;
- a source partition merges only its own mergeable scheduled rows;
- drand queues at most 20 ordered rounds and never calls `Merger.merge/1`;
- all waiters receive success only after their merged durable commit succeeds;
- exhausting one source's persistence retries fails only that partition.
- checkpoint-only empty windows retain their source partition, advance durability, and never enter a reducer.

Use explicit queue limits: 64 entries globally, 16 entries per ordinary source, and 20 entries for drand. Depth counts every queued entry, including checkpoint-only entries. Admission is all-or-nothing: compact eligible entries first; if the complete submission still cannot fit, preserve existing state and checkpoints, store no waiter, record one `{:drop, :capacity}`, and return `{:error, :capacity}` immediately. An empty Buffer accepts exactly 20 ordered drand rounds; a twenty-first round fails atomically.

Compact only adjacent, unattempted entries within one source. Never merge a blocked or retrying entry. Drand never reaches `Merger`. Checkpoint-only entries never reach a reducer and may coalesce only with adjacent checkpoint-only entries, retaining the newest checkpoint and every waiter. Task 3 uses the existing Wikimedia, USGS, and Open-Meteo reducers; Task 4 adds Bluesky, RIPE, and Solana eligibility. A reducer error means the run is not compactable, never a Buffer crash.

- [x] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/buffer_test.exs
```

- [x] **Step 3: Implement partition and rotation state**

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

On persistence failure, put the entry back at the front of its source partition and set that source's monotonic `blocked_until`; continue draining other ready sources every 250 milliseconds. If only blocked sources remain, schedule the earliest unblock. Timer messages carry a generation token so an earlier replacement timer cannot later cause an extra drain. Exhausting retries removes and fails only the affected partition.

- [x] **Step 4: Emit privacy-safe per-source pressure metrics**

Emit `[:worldloom, :signals, :buffer, :depth]` after every affected partition mutation, including source depth zero, with measurements `%{depth: total_depth, source_depth: source_depth, observed_at: monotonic_milliseconds}` and metadata `%{source: fixed_source_atom}`. Never attach event, checkpoint, cursor, URL, or provider failure. Record `{:merge, count}` using queue slots eliminated (`inputs - 1`) and `{:retry, 1}` for each scheduled retry through `HealthRegistry`; retry telemetry separately retains the attempt ordinal from one through three.

- [x] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom/signals/buffer_test.exs test/worldloom/loom/coordinator_test.exs test/worldloom_web/telemetry_test.exs
rtk git add lib/worldloom/signals/buffer.ex lib/worldloom_web/telemetry.ex test/worldloom/signals/buffer_test.exs test/worldloom_web/telemetry_test.exs
rtk git commit -m "Drain signal persistence fairly by source"
```

## Task 4: Make pressure reducers associative and source-specific

- [x] **Step 1: Define the bounded merge algebra at ingestion and projection boundaries**

Wikimedia's current top-five language projection and dominant-edit label are not
sufficient statistics: a child merge can discard a language or edit type that
would win after a later regrouping. Replace arbitrary language keys at ingestion
with five fixed, deterministic, SHA-256-partitioned `language_buckets`, retain all
five fixed edit-type counters, derive `dominant_edit_type`, and propagate an
explicit `truncated` flag. This also bounds the worker's previously open-ended
language map before normalization.

RIPE `collector_count` and `peer_count` are distinct only inside one window and
cannot be combined into cross-window distinct counts. Rename the durable metrics
to `collector_observations` and `peer_observations`; a pressure summary sums those
per-window observations and never claims global distinctness. Keep Solana's leaf
invariants strict, but validate a multi-window pressure summary as an aggregate:
sum its already-accounted `gap_count`, take the minimum and maximum slot endpoints,
and never fabricate a boundary gap.

The payload's bounded integers are the monoid. Every derived lane and intensity is
recomputed through shared `Normalizer` formulas from the final integer statistics;
never average an earlier event's floating-point lane or intensity. Saturating
addition returns both the capped value and overflow state. `truncated` is true when
any input was truncated or any counter/window total overflowed. Cap `window_count`
at `floor(uint32_max / 4)` so `window_span_seconds = window_count * 4` remains valid.

- [x] **Step 2: Write grouping-invariance tests**

Extend `test/worldloom/signals/merger_test.exs` for Wikimedia, Bluesky, RIPE, and Solana. For each fixture list, assert:

```elixir
{:ok, direct} = Merger.merge(events)
{:ok, left} = Merger.merge(Enum.take(events, 2))
{:ok, right} = Merger.merge(Enum.drop(events, 2))
{:ok, regrouped} = Merger.merge([left, right])
assert regrouped == direct
```

Assert merged payload has `window_count = sum`, `window_span_seconds = sum`, saturation/truncation propagation, deterministic external identity, and source-appropriate lane/intensity derived from the final integer statistics. Assert `Merger.merge(drand_events) == {:error, :unsupported_source}`.

Compare the entire `SourceEvent`, not selected fields. Exercise every binary split,
input permutation, and adversarial Wikimedia fixtures proving that complete fixed
current and edit-type counters preserve totals and dominance. Cover saturation for every
counter and the window cap, repeated RIPE peers/collectors as observations, and
nonconsecutive Solana windows whose gaps were already charged at ingestion.

- [x] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/merger_test.exs
```

- [x] **Step 4: Implement reducers using sufficient statistics**

Merge external IDs through the existing order-independent checksum and use the
latest `occurred_at`. Label summaries as pressure summaries and disclose both
`window_count` and `window_span_seconds`. Wikimedia, Bluesky, RIPE, and Solana each
get an explicit reducer; drand remains unsupported.

- [x] **Step 5: Verify randomized grouping and commit**

Run each deterministic grouping case with shuffled input 100 times; output must be identical.

```bash
rtk mix test test/worldloom/signals/merger_test.exs --repeat-until-failure 100 --max-failures 1
rtk git add assets/js/worldloom/topology.js assets/test/topology.test.js docs/data-sources.md docs/superpowers/plans/2026-08-08-balanced-world-phase-4-transport-health.md docs/superpowers/specs/2026-08-08-balanced-world-signals-design.md lib/mix/tasks/worldloom.seed_demo.ex lib/worldloom/loom/instruction_metrics.ex lib/worldloom/loom/source_event.ex lib/worldloom/signals/merger.ex lib/worldloom/signals/normalizer.ex lib/worldloom/signals/wikimedia_bucket.ex test/support/fixtures/feeds/README.md test/support/fixtures/render_contract_v2.json test/support/worldloom_web/e2e_controller.ex test/worldloom/loom/instruction_metrics_test.exs test/worldloom/loom/instruction_test.exs test/worldloom/loom/source_event_test.exs test/worldloom/loom/visual_parameters_test.exs test/worldloom/signals/buffer_test.exs test/worldloom/signals/merger_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/signals/wikimedia_bucket_test.exs
rtk git commit -m "Merge source pressure with associative summaries"
```

## Task 5: Implement bounded source-specific WebSocket processes

- [ ] **Step 1: Create safe endpoint tests**

Create `test/worldloom/signals/safe_endpoint_test.exs`. Assert `SafeEndpoint.label/1` preserves scheme, host, port, and path but strips query, fragment, userinfo, and cursor. Reject non-`wss` production endpoints.

- [ ] **Step 2: Build fake WebSocket edge tests first**

Create `test/support/websocket_fixture_server.ex` as a local Bandit/WebSock server. Put shared transport coverage in `websocket_transport_test.exs` so provider tests remain focused on subscriptions, aggregation, recovery, and end-to-end privacy markers. Prove:

- trusted local WSS succeeds while an untrusted certificate and hostname mismatch fail;
- upgrade status, headers, and completion split across transport messages still establish exactly once;
- TCP chunking and WebSocket fragmentation produce exactly one complete application frame;
- ping payloads are echoed in pong frames, including during fragmentation, and close is acknowledged before state is cleared;
- one complete text frame is decoded and reduced synchronously in the owning GenServer;
- frames above 262,144 decoded bytes close/drop before JSON decoding;
- fragmented messages are tested at the complete-frame boundary and the documented post-allocation limitation is explicit;
- a socket message decoding to more than 100 application frames drops the whole batch and disconnects before provider parsing;
- malformed JSON records one coarse drop and keeps the sibling processes alive;
- process `max_heap_size` is set to 2,000,000 words with `kill: true` and `error_logger: false`;
- a mailbox above 100 messages closes the process before more application work;
- reconnect closes old state and ignores messages and request references from stale connections; and
- errors containing frame, cursor, URL query, header, body, or provider-reason markers collapse to fixed atoms before logs, Worldloom telemetry, or health output.

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/safe_endpoint_test.exs test/worldloom/signals/websocket_transport_test.exs test/worldloom/signals/bluesky_socket_test.exs test/worldloom/signals/ripe_socket_test.exs test/worldloom/signals/solana_socket_test.exs
```

- [ ] **Step 4: Implement the processless helper and three explicit source GenServers**

Create `WebSocketTransport` for connect, upgrade, stream/decode, encode/send, close, and fixed coarse error mapping. It owns no process or provider policy. Force HTTP/1 active mode (`active: :once` inside Mint), `log: false`, a 16 KiB response-header cap, finite connect/send/upgrade timeouts, peer verification, hostname/SNI, and operating-system certificate authorities. Never accept caller options that disable verification, enable logging, or weaken the caps.

Create `BlueskySocket`, `RipeSocket`, and `SolanaSocket` as explicit GenServers; do not hide provider behavior behind one generic callback module. Each owns its Mint connection, upgrade reference, WebSocket decoder, reconnect timer, and aggregate state. It matches every socket message to the current connection, rejects stale request references, manually echoes ping payloads in pong frames, acknowledges close, closes old state before reconnect, and disconnects before provider parsing when one socket message decodes to more than 100 application frames.

Bluesky URL parameters must be exactly two repeated `wantedCollections` values, `maxMessageSizeBytes=262144`, `compress=false`, and an optional replay cursor. Account and identity events are dropped. On reconnect, subtract five seconds from the last committed `time_us`, cap replay to sixty seconds, and deduplicate a bounded 4,096-entry hash set.

RIPE first sends `request_rrc_list`, intersects the response with at most four configured collectors, then sends one `ris_subscribe` message per collector with `type: UPDATE`, `includeRaw: false`, and `acknowledge: true`. It has no replay.

Solana sends only the exact parameterless JSON-RPC `slotSubscribe` request. It accepts the exact acknowledgement for request ID `1`, retains its non-negative subscription ID only in socket state, and rejects any notification whose subscription ID does not match before calling the pure adapter. It has no replay and remains production-disabled.

Each process records connected/contact/activity/drop/retry/disconnected observations directly through `HealthRegistry`. Do not `send(self(), decoded_frame)` or queue ordinary frame work.

At the start of each Bluesky or Solana complete-frame reduction, call the injected server clock exactly once, bind that value as `receipt_at`, use it for every temporal decision in that reduction, and pass it unchanged to the source reducer.

For Bluesky overlap deduplication, the canonical fingerprint material is the JSON encoding of the ordered array `[time_us, "commit", did, collection, operation, rkey]`. Hash that material immediately through `BlueskyRecovery`; never retain or expose the encoded array, DID, record key, cursor, CID, record, or content.

One source-local timer may call `handle_info(:flush_window, state)` once per second. It closes only windows past the one-second lateness grace; a non-empty window submits its one sanitized event and checkpoint, while an empty elapsed window submits `[]` and the checkpoint. RIPE and Solana call their explicit `close/2`, submit the completed aggregate and checkpoint synchronously, and install the returned next state only after successful durability. The Solana checkpoint is the last accepted slot represented by the completed transition, never a merely received slot. When either reducer's `add/3` returns `{:close_required, state}`, the same complete frame remains on the handler stack while this close/submit transition succeeds and is then retried with the same receipt time; it is never put in a process message. Timer messages are lifecycle control, not deferred raw-frame work.

- [ ] **Step 5: Verify isolation and commit**

```bash
rtk mix test test/worldloom/signals/safe_endpoint_test.exs test/worldloom/signals/websocket_transport_test.exs test/worldloom/signals/bluesky_socket_test.exs test/worldloom/signals/ripe_socket_test.exs test/worldloom/signals/solana_socket_test.exs test/worldloom/signals/supervisor_test.exs
rtk git add lib/worldloom/signals/safe_endpoint.ex lib/worldloom/signals/websocket_transport.ex lib/worldloom/signals/bluesky_socket.ex lib/worldloom/signals/ripe_socket.ex lib/worldloom/signals/solana_socket.ex test/support/websocket_fixture_server.ex test/support/fixtures/tls/localhost_ca.pem test/support/fixtures/tls/localhost_certificate.pem test/support/fixtures/tls/localhost_key.pem test/worldloom/signals/safe_endpoint_test.exs test/worldloom/signals/websocket_transport_test.exs test/worldloom/signals/bluesky_socket_test.exs test/worldloom/signals/ripe_socket_test.exs test/worldloom/signals/solana_socket_test.exs test/worldloom/signals/supervisor_test.exs
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

Extend `wikimedia_worker_test.exs`, `earthquake_worker_test.exs`, and `weather_worker_test.exs`. Prove Wikimedia resumes with Last-Event-ID for at most sixty seconds, late recovery rows persist as history-only through the snapshot projection, and the polling workers record lifecycle health without putting checkpoint metadata into public health. Preserve the Wikimedia lifecycle observations introduced in Task 2.

- [ ] **Step 2: Implement source-local backoff and observations**

Extend Wikimedia recovery observations and update the polling workers to record through `HealthRegistry`. Preserve their independent `Backoff` states. Do not change `/healthz` or turn feed degradation into application unready status.

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
- [ ] Source-owned Mint WebSocket transports retain peer and hostname verification; untrusted WSS fails closed.
- [ ] No raw frame, cursor, query, header, body, or detailed transport failure reaches Worldloom logs, telemetry, or health output.
- [ ] Complete-frame, frames-per-message, process-heap, mailbox, replay, dedupe, distinct-set, counter, and queue bounds are tested.
- [ ] Ping/pong, close acknowledgement, split upgrade, fragmentation, stale-reference rejection, and reconnect cleanup are tested.
- [ ] Fair draining prevents one source from monopolizing persistence.
- [ ] Scheduled pressure reducers are associative; drand never merges.
- [ ] Health comes from ephemeral connection/contact/activity observations, not immediate checkpoint state.
- [ ] New transports exist but production enablement remains false.
