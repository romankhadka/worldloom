# Balanced World Phase 3: Provider Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove bounded, privacy-safe contracts for Bluesky Jetstream, RIPE RIS Live, Solana slot notifications, and drand Quicknet before any source can start in production.

**Architecture:** Each provider has a pure decoder/aggregator boundary that consumes one already-decoded frame and retains only approved aggregate state. Sanitized fixtures describe the minimum protocol surface. drand additionally has a bounded direct-Mint client with relay failover and an injected `Req.Response`-compatible test seam. Qualification code can be exercised against fake or development edges, but production configuration remains disabled.

**Tech Stack:** Elixir 1.20, Jason, Mint 1.9, Req 0.6 response structs, ExUnit, deterministic JSON fixtures.

---

## Files

### Create

- `lib/worldloom/signals/bounded_counter.ex`
- `lib/worldloom/signals/bluesky_window.ex`
- `lib/worldloom/signals/bluesky_recovery.ex`
- `lib/worldloom/signals/ripe_window.ex`
- `lib/worldloom/signals/solana_slot_adapter.ex`
- `lib/worldloom/signals/drand_client.ex`
- `lib/worldloom/signals/drand_transport.ex`
- matching tests under `test/worldloom/signals/`
- sanitized fixtures under `test/support/fixtures/feeds/`
- `docs/data-sources.md`

### Modify

- `test/support/fixtures/feeds/README.md`
- `lib/worldloom/signals/normalizer.ex`
- `test/worldloom/signals/normalizer_test.exs`
- `docs/privacy.md`

## Task 1: Centralize saturation and fixed-window arithmetic

- [x] **Step 1: Write failing boundary tests**

Create `test/worldloom/signals/bounded_counter_test.exs`. Assert:

```elixir
assert BoundedCounter.add(4_294_967_294, 1) == {4_294_967_295, false}
assert BoundedCounter.add(4_294_967_295, 1) == {4_294_967_295, true}
assert BoundedCounter.window_start(~U[2026-08-08 12:00:05Z], 4, 1) ==
         ~U[2026-08-08 12:00:05Z]
assert BoundedCounter.window_start(~U[2026-08-08 12:00:06Z], 4, 1) ==
         ~U[2026-08-08 12:00:05Z]
```

Reject negative increments, non-DateTimes, widths outside `1..60`, and offsets outside the window.

- [x] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/bounded_counter_test.exs
```

- [x] **Step 3: Implement the tiny pure helper**

Create `lib/worldloom/signals/bounded_counter.ex` with `@uint32_max 4_294_967_295`, `add/2`, and `window_start/3`. Keep it free of provider names and process state.

- [x] **Step 4: Verify and commit**

```bash
rtk mix test test/worldloom/signals/bounded_counter_test.exs
rtk git add lib/worldloom/signals/bounded_counter.ex test/worldloom/signals/bounded_counter_test.exs
rtk git commit -m "Bound signal counters and staggered windows"
```

## Task 2: Qualify the pinned legacy Bluesky Jetstream contract

- [x] **Step 1: Create sanitized protocol fixtures**

Create `test/support/fixtures/feeds/bluesky_frames.json` with only synthetic DIDs/keys and these representative decoded shapes:

```json
{
  "time_us": 1786204802000000,
  "kind": "commit",
  "commit": {
    "collection": "app.bsky.feed.post",
    "operation": "create",
    "record": {"reply": {"root": {}, "parent": {}}}
  }
}
```

Include original post create, reply create, repost create, post update, post delete, unknown collection, malformed timestamp, and one frame carrying synthetic text/identity fields that must disappear. Do not copy a real DID, handle, text, URI, CID, or cursor into the fixture.

- [x] **Step 2: Write failing aggregation tests**

Create `test/worldloom/signals/bluesky_window_test.exs`. Use four-second windows at offset one. Assert exact counts for `total_actions`, `original_posts`, `replies`, `reposts`, `creates`, `updates`, and `deletes`; provider occurrence time from `time_us`; one-second lateness; uint32 saturation; `:empty`; and `inspect(window)` containing none of `did`, `handle`, `text`, `uri`, `cid`, or cursor values.

Call `BlueskyWindow.add/3` with one injected, trusted server `receipt_at`. Assert the inclusive provider-time interval from exactly `receipt_at - 60_000_000` microseconds through exactly `receipt_at + 5_000_000` microseconds, both one-microsecond violations, a year-9999 future timestamp followed by a valid frame, replay after a long outage, and invalid receipt-time rejection. Assert record-less post deletes increment only `total_actions` and `deletes`, repost deletes remain reposts, and post creates/updates require a map-valued record.

Create `test/worldloom/signals/bluesky_recovery_test.exs` for the pure replay boundary. Assert that it:

- rewinds a valid fully committed cursor by exactly `5_000_000` microseconds and clamps the result at zero;
- rejects observations at or before the committed cursor before consulting overlap fingerprints;
- retains at most 4,096 fixed-size fingerprints for the open overlap window, rejects duplicates, and explicitly drops unseen observations after the bound is full;
- selects the live tail and reports a gap when the checkpoint is missing, ahead of server receipt time, or more than 60 seconds behind it; and
- never exposes raw cursor or identity material through `inspect/1`.

- [x] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/bluesky_recovery_test.exs
```

- [x] **Step 4: Implement a deny-by-default window**

Create `lib/worldloom/signals/bluesky_window.ex`. Accept only top-level `kind: "commit"`, collections `app.bsky.feed.post` and `app.bsky.feed.repost`, operations `create`, `update`, and `delete`, and integer `time_us`. `add/3` requires an explicit trusted server-receipt `DateTime` and accepts provider time only from `receipt_at - 60_000_000` microseconds through `receipt_at + 5_000_000` microseconds, inclusive; drop observations outside those bounds without changing the window. Explicitly drop the account and identity events that Jetstream sends regardless of collection filters. Creates and updates require a map-valued record. Determine reply only from presence of a map-valued `record.reply`; do not retain that map. A record-less post delete has no post category, while a repost delete remains a repost. Return one of:

```elixir
{:ok, window}
{:flush, completed_window, next_window}
{:drop, reason, window}
```

The struct may contain only window times, approved counters, and `truncated`. Do not store a cursor, identity, record, or raw frame in the struct.

Create `lib/worldloom/signals/bluesky_recovery.ex` as a pure boundary for the legacy service's Unix-microsecond cursor. Given the maximum fully committed cursor and current server receipt time, return either the exact five-second rewind or an explicit live-tail gap when the checkpoint is missing, future-dated, or older than the 60-second replay horizon. Track only fixed-size hashes for observations above the committed cursor in a 4,096-entry open-window set. Duplicate hashes are dropped; once full, previously unseen overlap observations are dropped with an explicit bounded-capacity reason instead of being accepted without deduplication. Phase 4 may call this boundary but must not reimplement its policy.

- [x] **Step 5: Normalize the aggregate**

Add `Normalizer.bluesky_window/1`, producing `:public_activity/:bluesky`, identity `bluesky-window:<unix-start>:4`, provider `occurred_at = window_start`, deterministic lane from the approved counters, and the exact allow-listed payload.

- [x] **Step 6: Verify privacy and commit**

```bash
rtk mix test test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/bluesky_recovery_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/loom/source_event_test.exs
rtk git add lib/worldloom/signals/bluesky_window.ex lib/worldloom/signals/bluesky_recovery.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/bluesky_recovery_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/bluesky_frames.json
rtk git commit -m "Qualify bounded Bluesky activity summaries"
```

## Task 3: Qualify a collector-bounded RIPE RIS Live contract

- [x] **Step 1: Create synthetic UPDATE fixtures**

Create `test/support/fixtures/feeds/ripe_frames.json` with `type: "ris_message"` and `data.type: "UPDATE"`. Model `announcements` as an array of `%{"next_hop" => string, "prefixes" => [CIDR strings]}` groups and `withdrawals` as a flat array of CIDR strings, matching the current RIS Live UPDATE schema. Include synthetic collectors, peers, IPv4 and IPv6 announcements and withdrawals, non-UPDATE messages, malformed times, and identifiers that must never survive aggregation. Keep the checked-in fixture reviewable; construct the greater-than-2,048 adversarial collections mechanically in the test.

- [x] **Step 2: Write the subscription and aggregation tests**

Create `test/worldloom/signals/ripe_window_test.exs`. Assert `request_rrc_list_message/0` returns exactly `%{"type" => "request_rrc_list", "data" => nil}`. Assert `subscription_messages/2` accepts one to four unique configured collectors matching `~r/\Arrc\d{2}\z/` and a `%{"type" => "ris_rrc_list", "data" => available_collectors}` response whose data is an array of strings. Validate the provider list in one bounded pass, halting on a duplicate, invalid entry, or an entry beyond the complete 100-name `rrc00` through `rrc99` namespace; retain only a `MapSet` for membership. Preserve configured allow-list order when intersecting and return one exact subscription per approved current collector because the protocol's `host` filter is a string, not an array:

```elixir
Enum.map(approved_current_collectors, fn collector ->
  %{
    "type" => "ris_subscribe",
    "data" => %{
      "type" => "UPDATE",
      "host" => collector,
      "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
    }
  }
end)
```

Reject malformed lists, duplicate or invalid configured collectors, a configured collector list larger than four, and an empty intersection with the `ris_rrc_list` response; never fall back to the full firehose or emit an unfiltered subscription. Aggregate four-second windows at offset two. Assert announced/withdrawn prefix-occurrence counts, IPv4/IPv6 counts, distinct collector/peer counts, a collector-hash cap of four, a peer-hash cap of 2,048, `truncated`, and no raw identifier in `inspect(window)`.

- [x] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/ripe_window_test.exs
```

- [x] **Step 4: Implement hashed ephemeral distinct sets**

Create `lib/worldloom/signals/ripe_window.ex`. `RipeWindow.new/2` accepts the initial `DateTime` and the approved one-to-four-collector allow-list, immediately replacing the raw collector strings with an `approved_collector_fingerprints` hash set. Keep a separate `observed_collector_fingerprints` set so `collector_count` measures collectors actually observed rather than collectors configured. `RipeWindow.add/3` requires one explicit trusted server `receipt_at`. Accept `data.timestamp` only as a non-negative finite JSON number representing Unix seconds, convert it deterministically to integer microseconds with `round(timestamp * 1_000_000)`, and accept the inclusive interval from `receipt_at - 20_000_000` through `receipt_at + 5_000_000` microseconds. Validate this before prefix traversal or state mutation. The twenty-second past bound is a transport-staleness limit aligned with RIPE's high-cadence quiet threshold, not replay.

The state keeps at most one sanitized immediate-successor aggregate: `pending.window_start` may only equal `current.window_start + 4 seconds`. Before `close_at`, current-window frames update current, immediate-successor frames update or create pending, earlier frames drop as `:late_event`, and later frames drop as `:window_ahead`; routing and validation drops preserve state exactly. A peer-capacity drop changes only the targeted current or pending aggregate's `truncated` flag, never its counters, hashes, sibling aggregate, or authorization. Seeing the first successor frame during grace must not flush current or cause a later current frame to be dropped. A valid zero-prefix UPDATE records contact outside this pure aggregate boundary but leaves state byte-for-byte unchanged in current, successor, and elapsed cases.

Add `close/2` with return contract `{:open, identical_state}` or `{:flush, public_aggregate_or_empty, next_state}`. Before `close_at` it is a no-op. At or after `close_at`, it flushes current exactly once, promotes pending and clears it, or—when no pending exists—creates an empty window at the later of the immediate successor and the receipt-time-aligned live window. The latter bounds no-replay recovery instead of walking or checkpointing every missed interval. Preserve only approved collector authorization across an empty promotion. `flush/1` remains a pure current-window projection.

For any non-empty frame received after `close_at`, `add/3` returns `{:close_required, identical_state}` without consuming the frame. The caller synchronously calls `close/2`, durably submits the returned transition, installs `next_state` only after success, and retries the same already-decoded complete frame with the same `receipt_at`; if a pending successor was promoted, at most one additional close may be required before the no-pending live jump. Do not queue, copy, or `send/2` the raw frame. Test multiple current and pending frames appearing exactly once, close immediately before and exactly at grace, repeated close calls, elapsed empty state with and without pending, a window two or more steps ahead, pending validation/capacity isolation and promotion, nested Inspect privacy, commit-failure retry state, and bounded long-outage live-edge recovery.

Accept only `UPDATE` messages from the configured collector allow list. Parse peer and next-hop addresses with `:inet.parse_strict_address/1`; reject permissive IPv4 shorthand. Hash peers immediately from their canonical packed address bytes so equivalent IPv6 spellings share one fingerprint. Retain only hashes in capped worker-local `MapSet`s. Count strict CIDR prefix occurrences by family, then discard them. Validate and discard every traversed announcement `next_hop`; reject a malformed traversed group or prefix without partially mutating the window.

Inspect at most 2,048 announcement group elements and at most 2,048 prefix entries total per complete frame. Flatten announcement prefixes in outer-array then inner-array wire order, followed by withdrawals in wire order. Stop immediately when either budget is exhausted, do not sort or enumerate the unvisited tail, count only visited valid prefixes, and set `truncated: true`. Cap retained collector hashes at four and peer hashes at 2,048; reject unseen values after capacity while continuing to recognize duplicates.

The struct may contain only UTC window time, counters, capped hash sets, `truncated`, and the single bounded sanitized pending aggregate; derive `Inspect` to omit every hash set and the pending internal state. Never retain or expose collector, peer, peer ASN, message ID, next hop, prefix, path, community, raw bytes, or the source frame in state, output, logs, telemetry, PubSub, or errors.

- [x] **Step 5: Normalize and commit**

Add `Normalizer.ripe_window/1`, producing `:route_change/:ripe_ris`, identity `ripe-window:<unix-start>:4`, and the exact public aggregate. Reject empty windows and every counter outside uint32. Require `collector_count` in `1..4`, `peer_count` in `1..2048`, and each distinct count to be no greater than both the direction total and the address-family total. Require positive totals and exact equality when `truncated` is false. When truncated totals differ, treat each two-counter partition as either an exact total when neither component is saturated or a lower-bounded total when either component equals uint32 max; accept only intersecting possible raw-total ranges. This preserves equality for traversal or set truncation without rejecting legitimate independent counter saturation. Require a boolean `truncated`, UTC-normalize `window_start`, and derive deterministic lane and intensity only from approved counters. Test zero activity, small truncated mismatch/equality, compatible and incompatible saturation ranges, impossible distinct counts, set-bound violations, ignored extra private inputs, and repeated deterministic normalization.

```bash
rtk mix test test/worldloom/signals/ripe_window_test.exs test/worldloom/signals/normalizer_test.exs
rtk git add lib/worldloom/signals/ripe_window.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/ripe_window_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/ripe_frames.json
rtk git commit -m "Qualify bounded RIPE route-change summaries"
```

## Task 4: Qualify Solana slots without approving a production endpoint

- [x] **Step 1: Write deterministic adapter tests**

Create `test/worldloom/signals/solana_slot_adapter_test.exs` with synthetic `slotSubscribe` notifications. Pin the exact request `%{"jsonrpc" => "2.0", "id" => 1, "method" => "slotSubscribe"}` with no `params`. Assert only `slotNotification` envelopes with a non-negative integer subscription id and integer `slot`, `parent`, and `root` positions in `0..9_007_199_254_740_991` are accepted. Require `root <= parent < slot`, except for `{slot: 0, parent: 0, root: 0}`. Extra fields may be ignored but can never be retained. Assert occurrence time is the once-injected server receipt time; duplicate and backward positions return distinct drop reasons and leave state unchanged; gaps derive from consecutive accepted slots across ordinary windows, an in-process socket reconnect, and process-restart continuity loaded from the committed checkpoint; counters saturate and set `truncated`; close commit failure is retryable without state advancement; and account, transaction, wallet, program, and token fields cannot appear in state, inspection, output, or errors.

- [x] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/solana_slot_adapter_test.exs
```

- [x] **Step 3: Implement the pure adapter**

Create `lib/worldloom/signals/solana_slot_adapter.ex` with:

```elixir
@spec add(t(), map(), DateTime.t()) ::
        {:ok, t()} | {:close_required, t()} | {:drop, atom(), t()}
```

Use four-second server-receipt windows at offset three with a one-second close grace and at most one bounded immediate-successor aggregate. Add deterministic `elapsed?/2`, `close/2`, and `flush/1` operations. An elapsed frame is not consumed: return `{:close_required, identical_state}`, let the caller synchronously commit `close/2`'s completed aggregate, install the promoted state only on success, and retry the same decoded frame with the same receipt time. A timer close with no pending successor advances to the later of the immediate successor and the receipt-aligned live window, retaining only the prior accepted slot for future gap detection; it does not manufacture empty windows.

Expose `subscription_message/0` and `new/2`, where the optional second argument is the last durably committed JSON-safe slot loaded by the future worker. Invalid prior slots are programming errors. Persist only slot count, first/last slot, gap count, `truncated`, window count/span, summary, lane, and intensity. Keep `slot_count` positive, require `(slot_count == 1) == (first_slot == last_slot)` and `slot_count <= last_slot - first_slot + 1`, and allow the gap count to include the transition from a prior window or reconnect. Validate `root` and `parent` as notification-shape fields and then discard them; this phase does not publish root-lag metrics. The struct may contain only its UTC window, bounded counters, first/last and previous accepted slot, a continuity anchor for the current window, `truncated`, and the single sanitized pending aggregate; omit pending state from `Inspect`. No production URL, child spec, runtime flag, or worker belongs in this phase.

- [x] **Step 4: Normalize and commit**

Add `Normalizer.solana_window/1` with `:slot/:solana` and `solana-window:<unix-start>:4` identity. Revalidate JSON-safe ordered slot positions, positive uint32 `slot_count`, uint32 `gap_count`, boolean `truncated`, endpoint cardinality, and `slot_count <= last_slot - first_slot + 1`. Use the sanitized internal continuity anchor, when present, to derive the exact logical span from the slot before the window's first accepted observation through `last_slot`; without an anchor the span begins at `first_slot`. For a saturated slot counter, bound its possible raw range above by the inclusive first/last span; for a saturated gap counter, use the logical span as its finite upper bound. Accept only when some raw slot count plus raw gap count equals the logical span. A true `truncated` flag additionally requires the logical span to be strictly greater than the bounded public counter sum, proving actual precision loss; a capped counter reached exactly is not truncation. Reject empty or impossible aggregates, derive lane and intensity only from approved numeric fields, and omit continuity, parent, root, subscription ID, and the source frame from the `SourceEvent`.

```bash
rtk mix test test/worldloom/signals/solana_slot_adapter_test.exs test/worldloom/signals/normalizer_test.exs
rtk git add lib/worldloom/signals/solana_slot_adapter.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/solana_slot_adapter_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/solana_slot_frames.json
rtk git commit -m "Qualify Solana slot cadence against fixtures"
```

## Task 5: Qualify drand Quicknet relay failover

- [x] **Step 1: Write failing client tests around injected response and transport edges**

Create `test/worldloom/signals/drand_client_test.exs`. Use the fixed Quicknet chain hash:

```elixir
@quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
```

Pin the three production relay origins to `https://api.drand.sh`, `https://api2.drand.sh`, and `https://api3.drand.sh`. Assert exact requests to `/v2/chains/<quicknet-hash>/info` and `/v2/chains/<quicknet-hash>/rounds/<requested-round>`; never use `rounds/latest`. Require HTTP 200, an `application/json` media type, and a body no larger than 4,096 streamed bytes before manual JSON decoding. Round bodies must contain exactly a matching round in `1..9_007_199_254_740_991` and one 96-character lowercase hexadecimal `signature`; reject `randomness`, `previous_signature`, unknown keys, malformed signature, wrong round, invalid JSON, timeout, oversized body, wrong content type, and HTTP failure.

Assert SHA-256 of the decoded 48 signature bytes becomes a 64-character lowercase render identity and that neither signature, render identity, response body, URL, chain metadata, nor external failure reason appears in client inspection, logs, telemetry, or public errors. Add a chain-info fixture and race it across the same relay list. An invalid HTTP success must not end the race. Require exactly the pinned lowercase Quicknet hash, `beacon_id == "quicknet"`, `period == 3`, `genesis_time` in `1..253_402_300_799`, a 64-character lowercase hexadecimal `genesis_seed`, a 192-character lowercase hexadecimal `public_key`, and `scheme == "bls-unchained-g1-rfc9380"`; retain only period and genesis time.

Inject the request edge and timeout configuration without weakening production origin validation. Assert first-valid rather than first-completed behavior, chain-info failover, at most three concurrent tasks, timeout without caller exit, and that halting the race terminates every losing task without delayed results. Raised or exiting request functions collapse to the same unavailable outcome. Live relay smoke tests remain scheduled outside deterministic CI.

- [x] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/drand_client_test.exs
```

- [x] **Step 3: Implement bounded concurrent direct-Mint calls**

Create `lib/worldloom/signals/drand_client.ex` and `lib/worldloom/signals/drand_transport.ex`. Accept one to three unique pinned relay origins, an injected `Req.Response`-compatible request function, and finite timeout configuration through `new/1`; invalid configuration is a programming error. Derive `Inspect` without relays, request functions, URLs, response bodies, signatures, or render identities. Use one shared race helper for chain info and exact rounds with `Task.async_stream/3`, `ordered: false`, `max_concurrency: 3`, finite `timeout`, and `on_timeout: :kill_task`. Reduce until the first validated result and halt the stream so enumerable cleanup terminates outstanding tasks. Treat `{:exit, _}`, request exceptions, transport errors, non-200 responses, and invalid bodies identically; never return or log their reasons.

The default edge uses a fresh passive-mode direct Mint HTTPS connection with system CA verification, a 16,384-byte response-header cap, finite connect, socket-send, receive, and task timeouts, and deterministic connection closure. It never retries, redirects, advertises compression, decompresses, or automatically decodes a body. This bypasses Finch's URL- and response-bearing request telemetry; attach to Finch request start/stop/exception events in a regression test and prove the default transport emits none. Stream into a 4,096-byte accumulator and halt immediately when the next chunk would cross the cap; do not trust `Content-Length`. This bounds retained response size even though the current transport chunk has already been allocated before the callback. Use one absolute monotonic receive deadline so partial or unexpected traffic cannot extend the timeout. Decode only a complete bounded body. Race `/info` during initialization and retain only validated `period` and `genesis_time`. Race exact requested rounds, decode the signature, derive `render_identity = SHA256(signature_bytes)` as lowercase hexadecimal, and discard the signature. Return only:

```elixir
{:ok, %{round: round, render_identity: render_identity}}
{:error, :unavailable}
```

This is HTTPS structural validation and first-valid-response failover, not BLS signature verification, chain-identity recomputation, or relay consensus. Coarse telemetry may contain outcome atoms, duration, and relay count only.

- [x] **Step 4: Normalize without persisting beacon output**

Add `Normalizer.drand_round/2`. Require validated `%{period: 3, genesis_time: genesis_time}` and `%{round: round, render_identity: identity}`. Compute `unix_second = genesis_time + (round - 1) * 3`, require it in `0..253_402_300_799`, and construct UTC time with `DateTime.from_unix/2`. Return `{:error, :invalid_round}` for an unsafe round, invalid identity, or out-of-range timestamp. Pass `render_identity` ephemerally to `SourceEvent`; durable payload remains exactly `%{"summary" => "drand Quicknet round #{round}", "round" => round}`. Identity is exactly `drand-round:<round>` and occurrence time never uses local receipt time. Update SourceEvent, InstructionMetrics, browser validation, and their fixtures/tests so drand rounds use the positive JSON-safe range rather than uint32. Add boundaries for round one, maximum JSON-safe input, timestamp overflow, mismatched requested round, and repeated deterministic normalization.

- [x] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom/signals/drand_client_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/loom/visual_parameters_test.exs
rtk git add mix.exs lib/worldloom/signals/drand_client.ex lib/worldloom/signals/drand_transport.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/drand_client_test.exs test/worldloom/signals/drand_transport_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/drand_rounds.json
rtk git commit -m "Qualify drand Quicknet relay failover"
```

## Task 6: Document the qualification boundary

- [x] **Step 1: Add source and privacy documentation**

Create `docs/data-sources.md` and update `docs/privacy.md` plus the fixture README. State:

- Bluesky uses the deployed legacy Jetstream protocol for informal visualization, only post/repost collections, and no content or identity;
- RIPE consumes only `UPDATE` from at most four configured collectors with `includeRaw: false` and no full-firehose fallback;
- Solana is fixture/development-qualified only and remains production-disabled pending a dedicated/self-hosted endpoint decision;
- drand uses API v2 Quicknet and structural response validation without a BLS verification claim;
- public endpoints are best-effort and can disconnect slow consumers.

- [x] **Step 2: Scan fixtures and code for forbidden retained fields**

```bash
rtk rg -n 'did|handle|text|uri|cid|prefix|peer|wallet|account|transaction|response_body' test/support/fixtures/feeds lib/worldloom/signals
```

Review every match. Synthetic input-only fixture keys are acceptable; output structs, stored payload expectations, logs, and telemetry are not.

- [x] **Step 3: Complete phase verification**

```bash
rtk mix precommit
rtk npm test
rtk git diff --check master...HEAD
rtk mix hex.audit
```

- [x] **Step 4: Commit documentation**

```bash
rtk git add docs/data-sources.md docs/privacy.md test/support/fixtures/feeds/README.md
rtk git commit -m "Document qualified public signal boundaries"
```

## Phase 3 completion gate

- [x] All four pure boundaries are deterministic, bounded, and deny-by-default.
- [x] Decoded counters and sets have explicit caps.
- [x] Provider time versus server receipt time matches the specification.
- [x] The SHA-256 digest of the decoded drand signature affects render seed; the signature and digest are not persisted.
- [x] No provider worker or production enablement exists.
- [x] Solana has no production URL decision hidden in code or configuration.
