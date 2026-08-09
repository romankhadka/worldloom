# Balanced World Phase 3: Provider Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove bounded, privacy-safe contracts for Bluesky Jetstream, RIPE RIS Live, Solana slot notifications, and drand Quicknet before any source can start in production.

**Architecture:** Each provider has a pure decoder/aggregator boundary that consumes one already-decoded frame and retains only approved aggregate state. Sanitized fixtures describe the minimum protocol surface. drand additionally has a bounded Req client with relay failover. Qualification code can be exercised against fake or development edges, but production configuration remains disabled.

**Tech Stack:** Elixir 1.20, Jason, Req 0.6, ExUnit, deterministic JSON fixtures.

---

## Files

### Create

- `lib/worldloom/signals/bounded_counter.ex`
- `lib/worldloom/signals/bluesky_window.ex`
- `lib/worldloom/signals/bluesky_recovery.ex`
- `lib/worldloom/signals/ripe_window.ex`
- `lib/worldloom/signals/solana_slot_adapter.ex`
- `lib/worldloom/signals/drand_client.ex`
- matching tests under `test/worldloom/signals/`
- sanitized fixtures under `test/support/fixtures/feeds/`
- `docs/data-sources.md`

### Modify

- `test/support/fixtures/feeds/README.md`
- `lib/worldloom/signals/normalizer.ex`
- `test/worldloom/signals/normalizer_test.exs`
- `docs/privacy.md`

## Task 1: Centralize saturation and fixed-window arithmetic

- [ ] **Step 1: Write failing boundary tests**

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

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/bounded_counter_test.exs
```

- [ ] **Step 3: Implement the tiny pure helper**

Create `lib/worldloom/signals/bounded_counter.ex` with `@uint32_max 4_294_967_295`, `add/2`, and `window_start/3`. Keep it free of provider names and process state.

- [ ] **Step 4: Verify and commit**

```bash
rtk mix test test/worldloom/signals/bounded_counter_test.exs
rtk git add lib/worldloom/signals/bounded_counter.ex test/worldloom/signals/bounded_counter_test.exs
rtk git commit -m "Bound signal counters and staggered windows"
```

## Task 2: Qualify the pinned legacy Bluesky Jetstream contract

- [ ] **Step 1: Create sanitized protocol fixtures**

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

- [ ] **Step 2: Write failing aggregation tests**

Create `test/worldloom/signals/bluesky_window_test.exs`. Use four-second windows at offset one. Assert exact counts for `total_actions`, `original_posts`, `replies`, `reposts`, `creates`, `updates`, and `deletes`; provider occurrence time from `time_us`; one-second lateness; uint32 saturation; `:empty`; and `inspect(window)` containing none of `did`, `handle`, `text`, `uri`, `cid`, or cursor values.

Call `BlueskyWindow.add/3` with one injected, trusted server `receipt_at`. Assert the inclusive provider-time interval from exactly `receipt_at - 60_000_000` microseconds through exactly `receipt_at + 5_000_000` microseconds, both one-microsecond violations, a year-9999 future timestamp followed by a valid frame, replay after a long outage, and invalid receipt-time rejection. Assert record-less post deletes increment only `total_actions` and `deletes`, repost deletes remain reposts, and post creates/updates require a map-valued record.

Create `test/worldloom/signals/bluesky_recovery_test.exs` for the pure replay boundary. Assert that it:

- rewinds a valid fully committed cursor by exactly `5_000_000` microseconds and clamps the result at zero;
- rejects observations at or before the committed cursor before consulting overlap fingerprints;
- retains at most 4,096 fixed-size fingerprints for the open overlap window, rejects duplicates, and explicitly drops unseen observations after the bound is full;
- selects the live tail and reports a gap when the checkpoint is missing, ahead of server receipt time, or more than 60 seconds behind it; and
- never exposes raw cursor or identity material through `inspect/1`.

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/bluesky_recovery_test.exs
```

- [ ] **Step 4: Implement a deny-by-default window**

Create `lib/worldloom/signals/bluesky_window.ex`. Accept only top-level `kind: "commit"`, collections `app.bsky.feed.post` and `app.bsky.feed.repost`, operations `create`, `update`, and `delete`, and integer `time_us`. `add/3` requires an explicit trusted server-receipt `DateTime` and accepts provider time only from `receipt_at - 60_000_000` microseconds through `receipt_at + 5_000_000` microseconds, inclusive; drop observations outside those bounds without changing the window. Explicitly drop the account and identity events that Jetstream sends regardless of collection filters. Creates and updates require a map-valued record. Determine reply only from presence of a map-valued `record.reply`; do not retain that map. A record-less post delete has no post category, while a repost delete remains a repost. Return one of:

```elixir
{:ok, window}
{:flush, completed_window, next_window}
{:drop, reason, window}
```

The struct may contain only window times, approved counters, and `truncated`. Do not store a cursor, identity, record, or raw frame in the struct.

Create `lib/worldloom/signals/bluesky_recovery.ex` as a pure boundary for the legacy service's Unix-microsecond cursor. Given the maximum fully committed cursor and current server receipt time, return either the exact five-second rewind or an explicit live-tail gap when the checkpoint is missing, future-dated, or older than the 60-second replay horizon. Track only fixed-size hashes for observations above the committed cursor in a 4,096-entry open-window set. Duplicate hashes are dropped; once full, previously unseen overlap observations are dropped with an explicit bounded-capacity reason instead of being accepted without deduplication. Phase 4 may call this boundary but must not reimplement its policy.

- [ ] **Step 5: Normalize the aggregate**

Add `Normalizer.bluesky_window/1`, producing `:public_activity/:bluesky`, identity `bluesky-window:<unix-start>:4`, provider `occurred_at = window_start`, deterministic lane from the approved counters, and the exact allow-listed payload.

- [ ] **Step 6: Verify privacy and commit**

```bash
rtk mix test test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/bluesky_recovery_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/loom/source_event_test.exs
rtk git add lib/worldloom/signals/bluesky_window.ex lib/worldloom/signals/bluesky_recovery.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/bluesky_recovery_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/bluesky_frames.json
rtk git commit -m "Qualify bounded Bluesky activity summaries"
```

## Task 3: Qualify a collector-bounded RIPE RIS Live contract

- [ ] **Step 1: Create synthetic UPDATE fixtures**

Create `test/support/fixtures/feeds/ripe_frames.json` with `type: "ris_message"` and `data.type: "UPDATE"`. Model `announcements` as an array of `%{"next_hop" => string, "prefixes" => [CIDR strings]}` groups and `withdrawals` as a flat array of CIDR strings, matching the current RIS Live UPDATE schema. Include synthetic collectors, peers, IPv4 and IPv6 announcements and withdrawals, non-UPDATE messages, malformed times, and identifiers that must never survive aggregation. Keep the checked-in fixture reviewable; construct the greater-than-2,048 adversarial collections mechanically in the test.

- [ ] **Step 2: Write the subscription and aggregation tests**

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

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/ripe_window_test.exs
```

- [ ] **Step 4: Implement hashed ephemeral distinct sets**

Create `lib/worldloom/signals/ripe_window.ex`. `RipeWindow.new/2` accepts the initial `DateTime` and the approved one-to-four-collector allow-list, immediately replacing the raw collector strings with an `approved_collector_fingerprints` hash set. Keep a separate `observed_collector_fingerprints` set so `collector_count` measures collectors actually observed rather than collectors configured. `RipeWindow.add/3` requires one explicit trusted server `receipt_at`. Accept `data.timestamp` only as a non-negative finite JSON number representing Unix seconds, convert it deterministically to integer microseconds with `round(timestamp * 1_000_000)`, and accept the inclusive interval from `receipt_at - 20_000_000` through `receipt_at + 5_000_000` microseconds. Validate this before prefix traversal or state mutation. The twenty-second past bound is a transport-staleness limit aligned with RIPE's high-cadence quiet threshold, not replay.

The state keeps at most one sanitized next-window aggregate while the current four-second window remains inside its one-second late-arrival grace. Seeing the first next-window frame during grace must not flush the current window or cause a later current-window frame to be dropped. Add `close/2` with return contract `{:open, state}` or `{:flush, public_aggregate_or_empty, next_state}`. It promotes the pending aggregate, or an empty immediate next window, only once grace has elapsed. A non-empty frame after grace may perform the same flush-and-promote transition from `add/3`. A valid zero-prefix UPDATE records contact outside this pure aggregate boundary but never advances, flushes, or creates pending aggregate state. Reject provider windows beyond the single pending successor while the current window is still open. Test the realistic receipt-time sequence, timer close/promotion, zero-prefix crossing, and the one-pending-window bound.

Accept only `UPDATE` messages from the configured collector allow list. Parse peer and next-hop addresses with `:inet.parse_strict_address/1`; reject permissive IPv4 shorthand. Hash peers immediately from their canonical packed address bytes so equivalent IPv6 spellings share one fingerprint. Retain only hashes in capped worker-local `MapSet`s. Count strict CIDR prefix occurrences by family, then discard them. Validate and discard every traversed announcement `next_hop`; reject a malformed traversed group or prefix without partially mutating the window.

Inspect at most 2,048 announcement group elements and at most 2,048 prefix entries total per complete frame. Flatten announcement prefixes in outer-array then inner-array wire order, followed by withdrawals in wire order. Stop immediately when either budget is exhausted, do not sort or enumerate the unvisited tail, count only visited valid prefixes, and set `truncated: true`. Cap retained collector hashes at four and peer hashes at 2,048; reject unseen values after capacity while continuing to recognize duplicates.

The struct may contain only UTC window time, counters, capped hash sets, `truncated`, and the single bounded sanitized pending aggregate; derive `Inspect` to omit every hash set and the pending internal state. Never retain or expose collector, peer, peer ASN, message ID, next hop, prefix, path, community, raw bytes, or the source frame in state, output, logs, telemetry, PubSub, or errors.

- [ ] **Step 5: Normalize and commit**

Add `Normalizer.ripe_window/1`, producing `:route_change/:ripe_ris`, identity `ripe-window:<unix-start>:4`, and the exact public aggregate. Reject empty windows and every counter outside uint32. Require `collector_count` in `1..4`, `peer_count` in `1..2048`, and each distinct count to be no greater than both the direction total and the address-family total. Require positive totals and exact equality when `truncated` is false. When truncated totals differ, treat each two-counter partition as either an exact total when neither component is saturated or a lower-bounded total when either component equals uint32 max; accept only intersecting possible raw-total ranges. This preserves equality for traversal or set truncation without rejecting legitimate independent counter saturation. Require a boolean `truncated`, UTC-normalize `window_start`, and derive deterministic lane and intensity only from approved counters. Test zero activity, small truncated mismatch/equality, compatible and incompatible saturation ranges, impossible distinct counts, set-bound violations, ignored extra private inputs, and repeated deterministic normalization.

```bash
rtk mix test test/worldloom/signals/ripe_window_test.exs test/worldloom/signals/normalizer_test.exs
rtk git add lib/worldloom/signals/ripe_window.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/ripe_window_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/ripe_frames.json
rtk git commit -m "Qualify bounded RIPE route-change summaries"
```

## Task 4: Qualify Solana slots without approving a production endpoint

- [ ] **Step 1: Write deterministic adapter tests**

Create `test/worldloom/signals/solana_slot_adapter_test.exs` with synthetic `slotSubscribe` notifications. Assert only JSON-RPC notifications with integer `slot`, `parent`, and `root` are accepted; occurrence time is injected server receipt time; gaps derive from slot discontinuity; counters saturate; and account, transaction, wallet, and program fields are rejected or ignored without retention.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/solana_slot_adapter_test.exs
```

- [ ] **Step 3: Implement the pure adapter**

Create `lib/worldloom/signals/solana_slot_adapter.ex` with:

```elixir
@spec add(t(), map(), DateTime.t()) ::
        {:ok, t()} | {:flush, t(), t()} | {:drop, atom(), t()}
```

Use four-second server-receipt windows at offset three. Persist only slot count, first/last slot, gap count, window count/span, summary, lane, and intensity. Validate `root` and `parent` as notification-shape fields and then discard them; this phase does not publish root-lag metrics. No production URL, child spec, runtime flag, or worker belongs in this phase.

- [ ] **Step 4: Normalize and commit**

Add `Normalizer.solana_window/1` with `:slot/:solana` and `solana-window:<unix-start>:4` identity.

```bash
rtk mix test test/worldloom/signals/solana_slot_adapter_test.exs test/worldloom/signals/normalizer_test.exs
rtk git add lib/worldloom/signals/solana_slot_adapter.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/solana_slot_adapter_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/solana_slot_frames.json
rtk git commit -m "Qualify Solana slot cadence against fixtures"
```

## Task 5: Qualify drand Quicknet relay failover

- [ ] **Step 1: Write failing client tests around injected Req edges**

Create `test/worldloom/signals/drand_client_test.exs`. Use the fixed Quicknet chain hash:

```elixir
@quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
```

Assert concurrent requests to the bounded v2-capable relay list return the first structurally valid response containing the requested positive round and exactly one 96-character lowercase hexadecimal `signature`. Reject a `randomness`-only response, malformed signature, wrong round, invalid JSON, timeout, and HTTP failure. Assert SHA-256 of the decoded 48 signature bytes becomes a 64-character lowercase render identity and that neither the signature, response body, nor URL appears in payloads, inspection, logs, or telemetry. Add a chain-info fixture and require the exact Quicknet hash, `beacon_id == "quicknet"`, `period == 3`, a positive integer `genesis_time`, a 64-character hexadecimal `genesis_seed`, a 192-character hexadecimal `public_key`, and `scheme == "bls-unchained-g1-rfc9380"` before accepting round scheduling.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/drand_client_test.exs
```

- [ ] **Step 3: Implement bounded concurrent Req calls**

Create `lib/worldloom/signals/drand_client.ex`. Accept `relays`, `request`, and timeout through the initializer/options, rejecting more than three relay bases. Production defaults are exactly the three current v2-capable bases `https://api.drand.sh`, `https://api2.drand.sh`, and `https://api3.drand.sh`; tests may inject bounded local relay URLs. Use `Task.async_stream/3` with `ordered: false`, `max_concurrency: 3`, and a finite timeout to race `/v2/chains/<quicknet-hash>/...` requests, halting after the first valid `%{"round" => positive_integer, "signature" => signature_96_hex}`. Decode the signature, derive `render_identity = SHA256(signature_bytes)` as lowercase hexadecimal, and discard the signature. Fetch `/v2/chains/<quicknet-hash>/info` at initialization and retain only validated `period` and `genesis_time`. Return only:

```elixir
{:ok, %{round: round, render_identity: render_identity}}
{:error, :unavailable}
```

This is HTTPS structural validation and first-valid-response failover, not BLS signature verification or relay consensus.

- [ ] **Step 4: Normalize without persisting beacon output**

Add `Normalizer.drand_round/2`. Pass `render_identity` ephemerally to `SourceEvent`; durable payload remains exactly `%{"summary" => "drand Quicknet round #{round}", "round" => round}`. Identity is `drand-round:<round>` and occurrence time is `genesis_time + (round - 1) * period`, not local receipt time.

- [ ] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom/signals/drand_client_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/loom/visual_parameters_test.exs
rtk git add lib/worldloom/signals/drand_client.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/drand_client_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/drand_rounds.json
rtk git commit -m "Qualify drand Quicknet relay failover"
```

## Task 6: Document the qualification boundary

- [ ] **Step 1: Add source and privacy documentation**

Create `docs/data-sources.md` and update `docs/privacy.md` plus the fixture README. State:

- Bluesky uses the deployed legacy Jetstream protocol for informal visualization, only post/repost collections, and no content or identity;
- RIPE consumes only `UPDATE` from at most four configured collectors with `includeRaw: false` and no full-firehose fallback;
- Solana is fixture/development-qualified only and remains production-disabled pending a dedicated/self-hosted endpoint decision;
- drand uses API v2 Quicknet and structural response validation without a BLS verification claim;
- public endpoints are best-effort and can disconnect slow consumers.

- [ ] **Step 2: Scan fixtures and code for forbidden retained fields**

```bash
rtk rg -n 'did|handle|text|uri|cid|prefix|peer|wallet|account|transaction|response_body' test/support/fixtures/feeds lib/worldloom/signals
```

Review every match. Synthetic input-only fixture keys are acceptable; output structs, stored payload expectations, logs, and telemetry are not.

- [ ] **Step 3: Complete phase verification**

```bash
rtk mix precommit
rtk npm test
rtk git diff --check master...HEAD
rtk mix hex.audit
```

- [ ] **Step 4: Commit documentation**

```bash
rtk git add docs/data-sources.md docs/privacy.md test/support/fixtures/feeds/README.md
rtk git commit -m "Document qualified public signal boundaries"
```

## Phase 3 completion gate

- [ ] All four pure boundaries are deterministic, bounded, and deny-by-default.
- [ ] Decoded counters and sets have explicit caps.
- [ ] Provider time versus server receipt time matches the specification.
- [ ] The SHA-256 digest of the decoded drand signature affects render seed; the signature and digest are not persisted.
- [ ] No provider worker or production enablement exists.
- [ ] Solana has no production URL decision hidden in code or configuration.
