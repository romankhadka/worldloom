# Balanced World Phase 2: Contract Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the four approved signal families and render-contract version 2 without rewriting or breaking existing Worldloom history.

**Architecture:** Expand source-kind allow lists in one additive migration and in every trusted construction boundary. Keep presentation role outside persistence. Version 2 instructions add an allow-listed `metrics` map; version 1 output remains byte-for-byte stable. Change Wikimedia from one-second buckets to stagger-ready four-second windows before adding another high-cadence source.

**Tech Stack:** Elixir 1.20, Ecto/PostgreSQL, Phoenix, Jason, ExUnit, browser-native JavaScript.

---

## Files

### Create

- `priv/repo/migrations/20260808180000_expand_loom_signal_contracts.exs`
- `lib/worldloom/loom/instruction_metrics.ex`
- `test/worldloom/loom/instruction_metrics_test.exs`
- `test/support/fixtures/render_contract_v2.json`

### Modify

- `lib/worldloom/loom/event.ex`
- `lib/worldloom/loom/source_event.ex`
- `lib/worldloom/loom/feed_checkpoint.ex`
- `lib/worldloom/loom/instruction.ex`
- `lib/worldloom/loom/visual_parameters.ex`
- `lib/worldloom/signals/wikimedia_bucket.ex`
- `lib/worldloom/signals/wikimedia_worker.ex`
- `lib/worldloom/signals/normalizer.ex`
- `lib/worldloom/signals/buffer.ex`
- their existing tests under `test/worldloom/loom/` and `test/worldloom/signals/`
- `assets/js/worldloom/topology.js` and `assets/test/topology.test.js`

## Task 1: Expand the database constraint without touching old rows

- [ ] **Step 1: Add failing database contract cases**

Extend `test/worldloom/loom/event_test.exs` to insert all ten approved pairs and to reject cross-pairing:

```elixir
@new_pairs [
  {"public_activity", "bluesky"},
  {"route_change", "ripe_ris"},
  {"slot", "solana"},
  {"randomness", "drand"}
]
```

Use `Repo.insert/1` for positive cases and `Repo.insert_all/3` inside `assert_raise Postgrex.Error` for a direct database mismatch. Insert a version 1 Wikimedia row before migrating and assert it remains unchanged after migration.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/loom/event_test.exs
```

Expected: the Ecto allow list and database constraint reject every new pair.

- [ ] **Step 3: Create the additive migration**

Create `priv/repo/migrations/20260808180000_expand_loom_signal_contracts.exs`. In `up/0`, drop only `loom_events_kind_source_pair`, then recreate the same constraint name with the original clauses plus:

```sql
(source = 'bluesky' AND kind = 'public_activity') OR
(source = 'ripe_ris' AND kind = 'route_change') OR
(source = 'solana' AND kind = 'slot') OR
(source = 'drand' AND kind = 'randomness')
```

Do not update `loom_events`. In `down/0`, first raise if any of the four new sources exists, then restore the original constraint. This makes rollback safe for a pre-enablement database and explicit once new durable rows exist.

- [ ] **Step 4: Exercise forward and backward compatibility**

```bash
rtk mix ecto.migrate
rtk mix test test/worldloom/loom/event_test.exs
rtk mix ecto.rollback --step 1
rtk mix ecto.migrate
rtk mix test test/worldloom/loom/event_test.exs
```

- [ ] **Step 5: Commit the database boundary**

```bash
rtk git add priv/repo/migrations/20260808180000_expand_loom_signal_contracts.exs test/worldloom/loom/event_test.exs
rtk git commit -m "Expand the durable signal pairing constraint"
```

## Task 2: Expand every trusted source allow list

- [ ] **Step 1: Add table-driven failing tests**

In `test/worldloom/loom/source_event_test.exs`, extend `@pairs` with:

```elixir
{:public_activity, :bluesky},
{:route_change, :ripe_ris},
{:slot, :solana},
{:randomness, :drand}
```

Add exact payload keys for each source and assert a forbidden identifier such as `"did"`, `"prefix"`, `"peer"`, `"account"`, or `"wallet"` returns `{:error, {:payload, :invalid_keys}}`.

Add an optional non-durable `render_identity` field to `SourceEvent`. Accept it only for drand as 64 lowercase hexadecimal characters; require `nil` for every other source. Assert `Map.from_struct(event).render_identity` never appears inside `event.payload`.

In `test/worldloom/loom/feed_checkpoint_test.exs`, accept `wikimedia`, `usgs`, `open_meteo`, `bluesky`, `ripe_ris`, `solana`, and `drand`, while still rejecting `visitor`.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/loom/source_event_test.exs test/worldloom/loom/feed_checkpoint_test.exs
```

- [ ] **Step 3: Add exact model and struct contracts**

Use these pair names consistently in `Event`, `SourceEvent`, `FeedCheckpoint`, and `Instruction`:

```elixir
bluesky: [:public_activity]
ripe_ris: [:route_change]
solana: [:slot]
drand: [:randomness]
```

Add these bounded public payload keys to `SourceEvent`:

```elixir
bluesky: ~w(summary window_count window_span_seconds total_actions original_posts replies reposts creates updates deletes truncated)
ripe_ris: ~w(summary window_count window_span_seconds announced withdrawn ipv4 ipv6 collector_count peer_count truncated)
solana: ~w(summary window_count window_span_seconds slot_count first_slot last_slot gap_count truncated)
drand: ~w(summary round)
```

Keep keys strings, values JSON-encodable, counters non-negative integers, and the existing 16 KiB total payload limit. Do not convert external strings to atoms.

`render_identity` is an ephemeral trusted-construction field. `Store.event_attributes/2` must pass it to `VisualParameters.for/2` and must never copy it into the durable row.

Add explicit `validate_payload_shape/2` clauses. Every v2 counter must be an integer in `0..4_294_967_295`, `window_count` must be positive, ordinary `window_span_seconds` must equal four, pressure spans must equal `window_count * 4`, boolean `truncated` must be a boolean, and drand round must be positive. Solana's `slot_count` and `gap_count` are counters, but `first_slot` and `last_slot` are ordered protocol positions and must instead be integers in the JSON-safe range `0..9_007_199_254_740_991`. Reject wrong types before persistence rather than relying on `InstructionMetrics` to fail later.

Split `Worldloom.Loom.Store`'s phase-1 source list into `@primary_sources ~w(wikimedia bluesky ripe_ris solana drand)` and `@context_sources ~w(usgs visitor)`. Query both for current display selection, but apply the scheduled-family balance/quota reporting only to primary sources; keep Open-Meteo ambient-only. New sources remain dormant because no worker is enabled in this phase.

- [ ] **Step 4: Verify and commit**

```bash
rtk mix test test/worldloom/loom/source_event_test.exs test/worldloom/loom/feed_checkpoint_test.exs test/worldloom/loom/instruction_test.exs
rtk git add lib/worldloom/loom/event.ex lib/worldloom/loom/source_event.ex lib/worldloom/loom/feed_checkpoint.ex lib/worldloom/loom/instruction.ex test/worldloom/loom/event_test.exs test/worldloom/loom/source_event_test.exs test/worldloom/loom/feed_checkpoint_test.exs test/worldloom/loom/instruction_test.exs
rtk git commit -m "Recognize the approved public signal families"
```

## Task 3: Add version 2 metrics while freezing version 1

- [ ] **Step 1: Preserve the v1 golden test**

Do not edit `test/support/fixtures/render_contract_v1.json`. Run its current golden test before changing code:

```bash
rtk mix test test/worldloom/loom/instruction_test.exs
```

Expected: PASS. Retain this as the compatibility baseline.

- [ ] **Step 2: Write failing v2 metrics tests**

Create `test/worldloom/loom/instruction_metrics_test.exs`. For every v2 source, assert the exact map. Representative RIPE expectation:

```elixir
assert InstructionMetrics.from_payload("ripe_ris", payload) == %{
         "announced" => 31,
         "collector_count" => 2,
         "ipv4" => 28,
         "ipv6" => 7,
         "peer_count" => 18,
         "truncated" => false,
         "window_count" => 2,
         "window_span_seconds" => 8,
         "withdrawn" => 4
       }
```

Assert unknown fields are discarded and bounded counters outside `0..4_294_967_295`, Solana slot positions outside `0..9_007_199_254_740_991`, non-finite floats, oversized collections, or wrong types return `:error`. Require Solana's projected `truncated` boolean alongside its counters and slot positions.

Add `Instruction` tests proving v1 has no `metrics` key and v2 includes it.

- [ ] **Step 3: Run and verify RED**

```bash
rtk mix test test/worldloom/loom/instruction_metrics_test.exs test/worldloom/loom/instruction_test.exs
```

- [ ] **Step 4: Implement deny-by-default metrics projection**

Create `lib/worldloom/loom/instruction_metrics.ex` with:

```elixir
@uint32_max 4_294_967_295
@spec from_payload(String.t(), map()) :: map() | :error
def from_payload(source, payload)
```

Use a literal source-to-key map and rebuild output from allowed keys; never use `Map.drop/2`. In `Instruction.from_event/1`, add `"metrics"` only when `event.render_version == 2` and the projection succeeds. Keep the exact v1 map unchanged.

- [ ] **Step 5: Add and verify the v2 golden fixture**

Create `test/support/fixtures/render_contract_v2.json` containing one event for each new source. Assert `Instruction.from_event/1` reproduces it exactly.

```bash
rtk mix test test/worldloom/loom/instruction_metrics_test.exs test/worldloom/loom/instruction_test.exs
rtk git add lib/worldloom/loom/instruction_metrics.ex lib/worldloom/loom/instruction.ex test/worldloom/loom/instruction_metrics_test.exs test/worldloom/loom/instruction_test.exs test/support/fixtures/render_contract_v2.json
rtk git commit -m "Add bounded metrics to render contract version two"
```

## Task 4: Derive version 2 visual parameters deterministically

- [ ] **Step 1: Write failing visual-parameter cases**

In `test/worldloom/loom/visual_parameters_test.exs`, assert every new source returns `render_version: 2`, stable seed and finite `spread`, `bend`, and `pulse`. For drand assert two events with the same beacon output derive the same seed and two different outputs differ.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/loom/visual_parameters_test.exs
```

- [ ] **Step 3: Add source-aware visual identities**

In `lib/worldloom/loom/visual_parameters.ex`, keep the v1 path untouched for the six original kinds. Return version 2 for the four new sources. Derive drand identity from `SourceEvent.render_identity`, validated as a 64-character lowercase hexadecimal beacon output; persisted v2 payload retains only `round` and the derived numeric seed.

Do not use beacon round alone as the visual identity. Do not claim BLS verification.

- [ ] **Step 4: Verify and commit**

```bash
rtk mix test test/worldloom/loom/visual_parameters_test.exs test/worldloom/loom/instruction_test.exs
rtk git add lib/worldloom/loom/visual_parameters.ex test/worldloom/loom/visual_parameters_test.exs
rtk git commit -m "Derive deterministic visuals for version two signals"
```

## Task 5: Change Wikimedia to its staggered four-second window

- [ ] **Step 1: Rewrite bucket tests before implementation**

In `test/worldloom/signals/wikimedia_bucket_test.exs`, replace second-boundary expectations with UTC windows `[00..03]`, `[04..07]`, and so on. Prove one-second lateness is accepted into the just-closed window, older frames are dropped, counters saturate at `4_294_967_295`, and an empty elapsed window returns `:empty` while its checkpoint can still advance.

In `test/worldloom/signals/buffer_test.exs`, submit `[]` with a valid Wikimedia checkpoint and assert the coordinator receives one checkpoint-only commit, the caller receives `:ok`, and no loom event/snapshot is broadcast.

Expected normalized identity:

```elixir
assert event.external_id == "wikimedia-window:1785758400:4"
assert event.occurred_at == ~U[2026-08-03 12:00:00.000000Z]
assert event.payload["window_count"] == 1
assert event.payload["window_span_seconds"] == 4
```

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/wikimedia_bucket_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/signals/wikimedia_worker_test.exs test/worldloom/signals/buffer_test.exs
```

- [ ] **Step 3: Implement fixed-window semantics**

Keep the existing module name to minimize churn, but replace `second` with `window_start`, `@window_seconds 4`, and `@offset_seconds 0`. Calculate start as:

```elixir
unix_second = DateTime.to_unix(occurred_at, :second)
window_start = unix_second - Integer.mod(unix_second - @offset_seconds, @window_seconds)
```

Flush at the first observed/timer time past `window_start + 4 + 1 second lateness`. A zero-count window produces no `SourceEvent`; the worker still submits `[]` with the latest checkpoint. Extend `Buffer.submit/2` to accept an empty event list only when the checkpoint source is allow-listed, enqueue one checkpoint-only entry, and never pass it through `Merger`. Include `window_count: 1` and `window_span_seconds: 4` in non-empty payloads. Saturate every counter at uint32 max.

- [ ] **Step 4: Update the worker timer and normalizer**

Rename normalizer input fields to `window_start`, and change the identity prefix from `wikimedia-second` to `wikimedia-window`. The worker timer may tick each second, but it closes only elapsed four-second windows. Preserve Last-Event-ID cursor handling for phase 4 replay work.

- [ ] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom/signals/wikimedia_bucket_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/signals/wikimedia_worker_test.exs test/worldloom/signals/buffer_test.exs
rtk git add lib/worldloom/signals/wikimedia_bucket.ex lib/worldloom/signals/wikimedia_worker.ex lib/worldloom/signals/normalizer.ex lib/worldloom/signals/buffer.ex test/worldloom/signals/wikimedia_bucket_test.exs test/worldloom/signals/wikimedia_worker_test.exs test/worldloom/signals/normalizer_test.exs test/worldloom/signals/buffer_test.exs
rtk git commit -m "Aggregate Wikimedia into staggered four-second windows"
```

## Task 6: Teach the browser the expanded but still dormant contract

- [ ] **Step 1: Add topology fallback tests**

In `assets/test/topology.test.js`, load every v2 fixture instruction and assert it yields finite bounded topology even before custom visual grammar lands. Assert an unsupported positive render version still creates a finite semantic fallback.

- [ ] **Step 2: Run and verify RED**

```bash
rtk node --test assets/test/topology.test.js assets/test/smoke.test.js
```

- [ ] **Step 3: Add source-kind validation without final styling**

Update `assets/js/worldloom/topology.js` to recognize the four pairs and accept bounded v2 metrics. Use the existing neutral fiber fallback for now. Presentation role remains in the snapshot arrays; do not add a `memory` field to durable events or instructions.

- [ ] **Step 4: Complete phase verification**

```bash
rtk mix precommit
rtk npm test
rtk mix ecto.rollback --step 1
rtk mix ecto.migrate
rtk mix precommit
rtk git diff --check master...HEAD
rtk mix hex.audit
```

- [ ] **Step 5: Commit browser compatibility**

```bash
rtk git add assets/js/worldloom/topology.js assets/test/topology.test.js assets/test/smoke.test.js
rtk git commit -m "Keep dormant version two signals renderable"
```

## Phase 2 completion gate

- [ ] Old rows were not rewritten.
- [ ] The additive constraint accepts only ten approved kind-source pairs.
- [ ] Version 1 golden output is unchanged.
- [ ] Version 2 exposes only bounded source-specific metrics.
- [ ] `memory_events` remains a snapshot role, never a durable event field.
- [ ] Wikimedia emits non-overlapping four-second windows at offset zero.
- [ ] Empty windows produce no durable row and can advance a checkpoint.
- [ ] All new production source flags remain absent or false.
