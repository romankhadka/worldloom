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

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/bluesky_window_test.exs
```

- [ ] **Step 4: Implement a deny-by-default window**

Create `lib/worldloom/signals/bluesky_window.ex`. Accept only top-level `kind: "commit"`, collections `app.bsky.feed.post` and `app.bsky.feed.repost`, operations `create`, `update`, and `delete`, and integer `time_us`. Explicitly drop the account and identity events that Jetstream sends regardless of collection filters. Determine reply only from presence of a map-valued `record.reply`; do not retain that map. Return one of:

```elixir
{:ok, window}
{:flush, completed_window, next_window}
{:drop, reason, window}
```

The struct may contain only window times, approved counters, and `truncated`. Do not store a cursor, identity, record, or raw frame in the struct.

- [ ] **Step 5: Normalize the aggregate**

Add `Normalizer.bluesky_window/1`, producing `:public_activity/:bluesky`, identity `bluesky-window:<unix-start>:4`, provider `occurred_at = window_start`, deterministic lane from the approved counters, and the exact allow-listed payload.

- [ ] **Step 6: Verify privacy and commit**

```bash
rtk mix test test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/loom/source_event_test.exs
rtk git add lib/worldloom/signals/bluesky_window.ex lib/worldloom/signals/normalizer.ex test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds/bluesky_frames.json
rtk git commit -m "Qualify bounded Bluesky activity summaries"
```

## Task 3: Qualify a collector-bounded RIPE RIS Live contract

- [ ] **Step 1: Create synthetic UPDATE fixtures**

Create `test/support/fixtures/feeds/ripe_frames.json` with `type: "ris_message"` and `data.type: "UPDATE"`. Include synthetic collectors, peers, IPv4 and IPv6 announcements and withdrawals, non-UPDATE messages, more than 2,048 distinct synthetic values, malformed times, and identifiers that must never survive aggregation.

- [ ] **Step 2: Write the subscription and aggregation tests**

Create `test/worldloom/signals/ripe_window_test.exs`. Assert `subscription_messages/2` returns one exact subscription per approved current collector because the protocol's `host` filter is a string, not an array:

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

Reject a configured collector list larger than four and reject an empty intersection with the `ris_rrc_list` response; never fall back to the full firehose. Aggregate four-second windows at offset two. Assert announced/withdrawn prefix counts, IPv4/IPv6 counts, distinct collector/peer counts, 2,048-set caps, `truncated`, and no raw identifier in `inspect(window)`.

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/ripe_window_test.exs
```

- [ ] **Step 4: Implement hashed ephemeral distinct sets**

Create `lib/worldloom/signals/ripe_window.ex`. Hash collector and peer identifiers immediately with `:crypto.hash(:sha256, identifier)` and retain only hashes in capped `MapSet`s. Count prefix strings by family, then discard them; never store prefixes or identifiers in the struct. Accept only `UPDATE` messages from the configured collector allow list and provider timestamps inside the one-second lateness bound.

Traverse at most 2,048 announcement/withdrawal groups and 2,048 prefixes per complete frame. If either bound is exceeded, count only the bounded prefix and set `truncated: true`; never enumerate the remaining decoded collection.

- [ ] **Step 5: Normalize and commit**

Add `Normalizer.ripe_window/1`, producing `:route_change/:ripe_ris`, identity `ripe-window:<unix-start>:4`, and the exact public aggregate.

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

Use four-second server-receipt windows at offset three. Persist only slot count, first/last slot, gap count, window count/span, summary, lane, and intensity. No production URL, child spec, runtime flag, or worker belongs in this phase.

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

Assert concurrent requests to a bounded official relay list return the first structurally valid response; invalid JSON, wrong round, wrong chain path, non-64-character hex randomness, timeout, and HTTP failure are ignored; all failures return `{:error, :unavailable}`; response bodies and URLs never appear in telemetry/log captures. Add a chain-info fixture and require hash equality, `period == 3`, and a positive integer `genesis_time` before accepting round scheduling.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/drand_client_test.exs
```

- [ ] **Step 3: Implement bounded concurrent Req calls**

Create `lib/worldloom/signals/drand_client.ex`. Accept `relays`, `request`, and timeout through the initializer/options. Limit relays to three, use `Task.async_stream/3` with `ordered: false`, `max_concurrency: 3`, and a finite timeout, halt after the first valid `%{"round" => positive_integer, "randomness" => 64_hex}`. Fetch `/v2/chains/<quicknet-hash>/info` at initialization and retain only validated `period` and `genesis_time`. Return only:

```elixir
{:ok, %{round: round, randomness: String.downcase(randomness)}}
{:error, :unavailable}
```

This is structural validation and relay agreement-by-first-valid-response, not BLS signature verification.

- [ ] **Step 4: Normalize without persisting beacon output**

Add `Normalizer.drand_round/2`. Pass the validated randomness as the ephemeral `SourceEvent.render_identity`; durable payload is exactly `%{"summary" => "drand Quicknet round #{round}", "round" => round}`. Identity is `drand-round:<round>` and occurrence time is `genesis_time + (round - 1) * 3` seconds, not local receipt time.

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
- [ ] drand randomness affects render seed but is not persisted.
- [ ] No provider worker or production enablement exists.
- [ ] Solana has no production URL decision hidden in code or configuration.
