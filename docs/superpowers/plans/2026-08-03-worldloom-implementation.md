# Worldloom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publicly launch Worldloom, a persistent Phoenix/LiveView tapestry woven from Wikimedia, USGS, Open-Meteo, and constrained anonymous visitor gestures.

**Architecture:** PostgreSQL is the durable source of truth. Supervised feed workers normalize public signals and pass bounded batches through a four-per-second buffer to a single coordinator. The coordinator persists before broadcasting through PubSub. LiveViews load bounded history, use Presence for an aggregate viewer count, and send deterministic drawing instructions to a Canvas 2D hook. The browser owns frames; the server owns identity, policy, sequence, durability, and recovery.

**Tech Stack:** Elixir 1.20.2 on Erlang/OTP 29.0.4, Node.js 24.18.0 LTS, Phoenix 1.8.x, LiveView 1.2.x, Ecto/PostgreSQL, Req 0.6.x, Canvas 2D, Tailwind CSS 4, Node's built-in test runner, Playwright 1.61.1, k6 2.0.0, GitHub Actions, Fly.io, and Fly Managed Postgres.

---

## Execution rules

- Work only in `/Users/roman/code/hello_live.roman-worldloom` on `roman/worldloom` until the final merge.
- Use `rtk` for every shell command. Use `rtk proxy` for commands without a dedicated RTK adapter.
- Invoke `superpowers:test-driven-development` before Task 1 and keep red/green/refactor discipline for every behavior change.
- Invoke `superpowers:systematic-debugging` for any unexpected failure; do not patch symptoms.
- Invoke `superpowers:verification-before-completion` before claiming any phase or the launch complete.
- Do not add AI attribution to commits.
- Keep source commits small enough to revert independently. Never combine a structural rename with new behavior.
- Use official upstream docs and captured fixtures at HTTP boundaries. Never hit live feeds from the test suite.
- Never log raw Wikimedia frames, visitor identities, cookies, peer addresses, or IP-derived rate-limit keys.
- Run the focused test after each implementation step and `rtk proxy asdf exec mix precommit` before each phase boundary.

## File and responsibility map

```text
lib/worldloom/
  application.ex                  supervision tree
  repo.ex                         Ecto repository
  loom/event.ex                   append-only event schema
  loom/feed_checkpoint.ex         durable source cursor/health schema
  loom/source_event.ex            validated internal source representation
  loom/visual_parameters.ex       deterministic render contract
  loom/instruction.ex             allow-listed server-to-canvas projection
  loom/store.ex                   transactions and bounded history queries
  loom/coordinator.ex             serialize, persist, then broadcast
  loom/rate_limiter.ex            anonymous cooldown and coarse IP bucket
  loom/gesture_policy.ex          allow-list and live-edge authorization
  signals/buffer.ex               bounded external signal queue, four/second
  signals/merger.ex               pure overload aggregation
  signals/backoff.ex              pure capped retry calculation
  signals/sse_parser.ex           pure chunk-safe SSE decoding
  signals/wikimedia_bucket.ex     one-second privacy-preserving edit buckets
  signals/client.ex               only Req HTTP boundary
  signals/normalizer.ex           pure upstream-to-source-event conversion
  signals/feed_health.ex          quiet/stale status projection
  signals/health_monitor.ex       one shared freshness poll/cache/broadcast
  signals/wikimedia_worker.ex     SSE lifecycle and cursor recovery
  signals/earthquake_worker.ex    USGS polling, ETag, and deduplication
  signals/weather_worker.ex       fixed-anchor Open-Meteo polling
  signals/supervisor.ex           independent feed supervision
lib/worldloom_web/
  plugs/anonymous_identity.ex     random signed session identity
  presence.ex                     aggregate live viewer presence
  live/world_live.ex              bounded history, gestures, PubSub, details
  live/world_live.html.heex       Living Fiber application shell
  controllers/health_controller.ex public liveness/readiness response
assets/js/worldloom/
  random.js                       seeded PRNG
  geometry.js                     pure projection and drawing commands
  renderer.js                     Canvas state and draw loop
  hook.js                         LiveView bridge and user input
assets/test/                      pure renderer tests
test/support/fixtures/feeds/      scrubbed upstream response fixtures
test/worldloom/                   unit and integration tests
test/worldloom_web/               ConnCase and LiveView tests
e2e/                              Playwright two-browser/accessibility smoke
load/                             k6 launch-capacity scenario
```

The source-event contract is fixed for all tasks:

```elixir
%Worldloom.Loom.SourceEvent{
  kind: :wikimedia | :earthquake | :weather | :tug | :knot | :illuminate,
  source: :wikimedia | :usgs | :open_meteo | :visitor,
  external_id: String.t() | nil,
  occurred_at: DateTime.t(),
  lane: float(),
  intensity: float(),
  payload: map()
}
```

The client instruction contract is versioned and fixed:

```json
{
  "sequence": 42,
  "kind": "earthquake",
  "source": "usgs",
  "occurred_at": "2026-08-03T12:00:00Z",
  "render_version": 1,
  "seed": 173881294,
  "lane": 0.61,
  "intensity": 0.78,
  "visual": {"spread": 0.42, "bend": -0.18, "pulse": 0.73},
  "summary": "Magnitude 5.2 near South Sandwich Islands"
}
```

Unknown render versions must produce a static fallback marker and readable detail, never a JavaScript exception.

## Phase 1: Establish a clean Worldloom foundation

### Task 1: Pin the toolchain and rename the generated application

**Files:**

- Create: `.tool-versions`
- Modify: `mix.exs`, `.gitignore`, `README.md`
- Rename: `lib/hello_live.ex` → `lib/worldloom.ex`
- Rename: `lib/hello_live/` → `lib/worldloom/`
- Rename: `lib/hello_live_web.ex` → `lib/worldloom_web.ex`
- Rename: `lib/hello_live_web/` → `lib/worldloom_web/`
- Rename: `test/hello_live/` → `test/worldloom/`
- Rename: `test/hello_live_web/` → `test/worldloom_web/`
- Modify: `config/*.exs`, `test/support/*.ex`, `test/test_helper.exs`, `priv/repo/seeds.exs`, `assets/js/app.js`

- [ ] Confirm isolation before writes:

  ```bash
  rtk git rev-parse --abbrev-ref HEAD
  rtk wt list
  rtk git status --short
  ```

  Expected: branch `roman/worldloom`, current worktree path ends in `hello_live.roman-worldloom`, and status is clean.

- [ ] Add the exact toolchain:

  ```text
  erlang 29.0.4
  elixir 1.20.2-otp-29
  nodejs 24.18.0
  ```

- [ ] Install it and bootstrap Hex/Rebar:

  ```bash
  rtk proxy zsh -c 'asdf plugin list | rg -qx nodejs || asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git'
  rtk proxy asdf install
  rtk proxy asdf exec mix local.hex --force
  rtk proxy asdf exec mix local.rebar --force
  rtk proxy asdf exec elixir --version
  ```

  Expected: Elixir 1.20.2, Erlang/OTP 29, and Node.js 24.18.0.

- [ ] Perform only the mechanical rename. Replace `HelloLive` with `Worldloom`, `HelloLiveWeb` with `WorldloomWeb`, `:hello_live` with `:worldloom`, `hello_live` paths/asset profile names with `worldloom`, database names with `worldloom_dev`/`worldloom_test`, the session key with `_worldloom_key`, and release command examples with `bin/worldloom`.

- [ ] Set dependency constraints to the current stable release lines without pinning transitive patch versions by hand:

  ```elixir
  {:phoenix, "~> 1.8.9"},
  {:phoenix_live_view, "~> 1.2.8"},
  {:req, "~> 0.6.3"},
  ```

  Set `elixir: "~> 1.20"`, change all esbuild/tailwind profile keys and aliases to `worldloom`, and change the colocated-hook manifest import to `phoenix-colocated/worldloom`.

- [ ] Fetch dependencies and prove the pure rename compiles before changing behavior:

  ```bash
  rtk proxy asdf exec mix deps.get
  rtk proxy asdf exec mix compile --warnings-as-errors
  rtk proxy asdf exec mix test
  ```

  Expected: compilation succeeds and the two generated controller tests pass.

- [ ] Commit the structural change:

  ```bash
  rtk git add .tool-versions mix.exs mix.lock .gitignore README.md assets config lib priv test
  rtk git commit -m "Rename application to Worldloom"
  ```

### Task 2: Remove generated demo UI and establish asset tests

**Files:**

- Delete: `lib/worldloom_web/controllers/page_controller.ex`
- Delete: `lib/worldloom_web/controllers/page_html.ex`
- Delete: `lib/worldloom_web/controllers/page_html/home.html.heex`
- Delete: `test/worldloom_web/controllers/page_controller_test.exs`
- Delete: `assets/vendor/daisyui.js`, `assets/vendor/daisyui-theme.js`
- Modify: `assets/css/app.css`, `assets/js/app.js`, `lib/worldloom_web/components/core_components.ex`, `lib/worldloom_web/components/layouts/root.html.heex`, `lib/worldloom_web/components/layouts.ex`, `lib/worldloom_web/router.ex`
- Create: `package.json`, `package-lock.json`, `assets/test/smoke.test.js`

- [ ] Add an intentionally failing asset smoke test:

  ```javascript
  import assert from "node:assert/strict"
  import test from "node:test"

  import {signalPalette} from "../js/worldloom/geometry.js"

  test("the four signal families have fixed accessible palette roles", () => {
    assert.deepEqual(Object.keys(signalPalette), ["wikimedia", "usgs", "open_meteo", "visitor"])
  })
  ```

- [ ] Add `package.json` with no runtime framework dependency:

  ```json
  {
    "name": "worldloom-assets",
    "private": true,
    "type": "module",
    "engines": {"node": "24.18.0"},
    "scripts": {
      "test": "node --test assets/test/**/*.test.js",
      "test:e2e": "playwright test"
    },
    "devDependencies": {
      "@playwright/test": "1.61.1"
    }
  }
  ```

- [ ] Run it and confirm RED because the geometry module does not exist:

  ```bash
  rtk npm install
  rtk npm test
  ```

- [ ] Create `assets/js/worldloom/geometry.js` with the stable palette export:

  ```javascript
  export const signalPalette = Object.freeze({
    wikimedia: {stroke: "#63d7d1", glow: "#b6fff8"},
    usgs: {stroke: "#ec8d55", glow: "#ffc08e"},
    open_meteo: {stroke: "#8ba66d", glow: "#d3bb70"},
    visitor: {stroke: "#f3ead4", glow: "#fff9e9"},
  })
  ```

- [ ] Remove DaisyUI imports and the generated theme toggle/inline theme script. Rewrite every retained `CoreComponents` class to plain Tailwind so no `btn`, `alert`, `badge`, `input`, or other DaisyUI token remains. Rewrite `Layouts.app/1` as the neutral Worldloom wrapper plus flash group and remove `theme_toggle/1`. Keep Tailwind v4 and Heroicons. Replace the root title with `Worldloom · A living public tapestry`, set `class="worldloom-root"` on `<html>`, and leave the router temporarily without a `/` route so no generated product UI survives.

- [ ] Run the focused checks:

  ```bash
  rtk npm test
  rtk proxy asdf exec mix format
  rtk proxy asdf exec mix compile --warnings-as-errors
  ```

- [ ] Commit:

  ```bash
  rtk git add assets lib package.json package-lock.json
  rtk git commit -m "Remove generated demo interface"
  ```

## Phase 2: Build the durable loom engine

### Task 3: Create the append-only schemas and database constraints

**Files:**

- Create: `priv/repo/migrations/*_create_loom_events.exs`
- Create: `priv/repo/migrations/*_create_feed_checkpoints.exs`
- Create: `lib/worldloom/loom/event.ex`
- Create: `lib/worldloom/loom/feed_checkpoint.ex`
- Create: `test/worldloom/loom/event_test.exs`
- Create: `test/worldloom/loom/feed_checkpoint_test.exs`

- [ ] Generate timestamped migrations:

  ```bash
  rtk proxy asdf exec mix ecto.gen.migration create_loom_events
  rtk proxy asdf exec mix ecto.gen.migration create_feed_checkpoints
  ```

- [ ] Write failing schema tests for required fields, bounds, the visitor-only nullable `external_id`, and the partial uniqueness guarantee. Use `Worldloom.DataCase`, inline setup, and no global test fixture.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/event_test.exs test/worldloom/loom/feed_checkpoint_test.exs
  ```

- [ ] Implement the `loom_events` migration exactly:

  ```elixir
  create table(:loom_events, primary_key: false) do
    add :id, :bigserial, primary_key: true
    add :kind, :string, null: false
    add :source, :string, null: false
    add :external_id, :string
    add :occurred_at, :utc_datetime_usec, null: false
    add :render_version, :integer, null: false
    add :render_seed, :bigint, null: false
    add :lane, :float, null: false
    add :intensity, :float, null: false
    add :payload, :map, null: false, default: %{}
    add :inserted_at, :utc_datetime_usec, null: false
  end

  create constraint(:loom_events, :loom_events_lane_bounds,
           check: "lane >= 0.0 AND lane <= 1.0"
         )

  create constraint(:loom_events, :loom_events_intensity_bounds,
           check: "intensity >= 0.0 AND intensity <= 1.0"
         )

  create constraint(:loom_events, :loom_events_kind_source_pair,
           check: "(source = 'wikimedia' AND kind = 'wikimedia') OR (source = 'usgs' AND kind = 'earthquake') OR (source = 'open_meteo' AND kind = 'weather') OR (source = 'visitor' AND kind IN ('tug', 'knot', 'illuminate'))"
         )

  create constraint(:loom_events, :loom_events_render_contract,
           check: "render_version > 0 AND render_seed >= 0 AND render_seed < 2147483647"
         )

  create constraint(:loom_events, :loom_events_external_identity,
           check: "(source = 'visitor' AND external_id IS NULL) OR (source <> 'visitor' AND external_id IS NOT NULL)"
         )

  create constraint(:loom_events, :loom_events_payload_size,
           check: "octet_length(payload::text) <= 16384 AND char_length(COALESCE(payload->>'summary', '')) <= 160"
         )

  create unique_index(:loom_events, [:source, :external_id],
           where: "external_id IS NOT NULL",
           name: :loom_events_source_external_id_index
         )

  create index(:loom_events, [:occurred_at, :id])
  ```

  Do not add `updated_at`; the table is append-only.

- [ ] Implement `feed_checkpoints` with `source` as the primary key string, nullable text `cursor`, nullable `etag`, non-null `last_successful_at`, non-null `metadata` defaulting to `%{}`, and microsecond timestamps. Add checks limiting cursor to 8 KB, ETag to 512 bytes, and metadata JSON text to 8 KB.

- [ ] Implement both Ecto schemas with `@timestamps_opts [type: :utc_datetime_usec]`, string inclusion/length validations, bounds validations, and every named database constraint above. `Worldloom.Loom.Event.changeset/2` is private to the persistence layer; no business orchestration belongs in either schema.

- [ ] Migrate and prove GREEN:

  ```bash
  rtk proxy asdf exec mix ecto.create
  rtk proxy asdf exec mix ecto.migrate
  rtk proxy asdf exec mix test test/worldloom/loom/event_test.exs test/worldloom/loom/feed_checkpoint_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add priv/repo/migrations lib/worldloom/loom test/worldloom/loom
  rtk git commit -m "Add durable loom event storage"
  ```

### Task 4: Define validated source events and deterministic visuals

**Files:**

- Create: `lib/worldloom/loom/source_event.ex`
- Create: `lib/worldloom/loom/visual_parameters.ex`
- Create: `lib/worldloom/loom/instruction.ex`
- Create: `test/worldloom/loom/source_event_test.exs`
- Create: `test/worldloom/loom/visual_parameters_test.exs`
- Create: `test/worldloom/loom/instruction_test.exs`
- Create: `test/support/fixtures/render_contract_v1.json`

- [ ] Write failing tests that cover every kind/source pairing, invalid types, UTC normalization, lane/intensity bounds, payload allow-listing, stable seed/visual output for identical inputs, different output for distinct ids, 32-bit JavaScript-safe seeds, and the exact string-keyed client instruction contract. Add one hand-reviewed v1 golden fixture containing all six kinds and exact stored instructions; Elixir tests must reproduce its decoded structure exactly.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/source_event_test.exs test/worldloom/loom/visual_parameters_test.exs test/worldloom/loom/instruction_test.exs
  ```

- [ ] Implement `SourceEvent` as a `defstruct` with `@enforce_keys`, a `new/1` constructor returning `{:ok, event}` or `{:error, reason}`, and a `new!/1` constructor reserved for trusted test/build code. Enforce the exact contract at the top of this plan. Convert no arbitrary strings to atoms.

- [ ] Implement `VisualParameters.for/2` as a pure function. Version 1 derives a non-negative seed with `:erlang.phash2({source, external_id || nonce, occurred_at, kind}, 2_147_483_647)` and derives `spread`, `bend`, and `pulse` from a local xorshift32 sequence. It returns:

  ```elixir
  %{
    render_version: 1,
    render_seed: seed,
    visual: %{
      "spread" => spread,
      "bend" => bend,
      "pulse" => pulse
    }
  }
  ```

  The caller must supply a random request nonce for visitor gestures; that nonce is used only to derive the stored visual parameters and is never persisted itself.

- [ ] Implement `Instruction.from_event/1` as the only Event-to-client projection. It emits the exact JSON-compatible contract at the top of this plan, ISO-8601 UTC timestamps, and only `visual` plus `summary` from the stored payload. It rejects unknown database kinds/sources and preserves unknown positive `render_version` values for the renderer's fallback path.

- [ ] Prove GREEN and deterministic behavior across 1,000 generated inputs:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/source_event_test.exs test/worldloom/loom/visual_parameters_test.exs test/worldloom/loom/instruction_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/loom test/worldloom/loom
  rtk git commit -m "Define deterministic loom event contract"
  ```

### Task 5: Implement transactional persistence and bounded history

**Files:**

- Create: `lib/worldloom/loom/store.ex`
- Create: `test/worldloom/loom/store_test.exs`

- [ ] Write failing integration tests for:

  - inserting a source batch and returning rows in sequence order;
  - deduplicating `(source, external_id)` without error;
  - updating `last_successful_at` even for an empty successful batch;
  - committing cursor/ETag and accepted events atomically;
  - rolling back checkpoint movement when an event is invalid;
  - latest history capped at 600;
  - `around/2`, `after/3`, `before/2`, held ambient weather, and UTC chapter boundaries;
  - chapter-day listing with counts and first/last sequence.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/store_test.exs
  ```

- [ ] Implement `Worldloom.Loom.Store` with this public API:

  ```elixir
  @spec commit_external([SourceEvent.t()], map()) :: {:ok, [Event.t()]} | {:error, term()}
  def commit_external(events, checkpoint)

  @spec commit_visitor(SourceEvent.t(), String.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def commit_visitor(event, request_nonce)

  @spec latest(pos_integer()) :: [Event.t()]
  def latest(limit \\ 400)

  @spec fetch(pos_integer()) :: {:ok, Event.t()} | :error
  def fetch(sequence)

  @spec around(pos_integer(), pos_integer()) :: [Event.t()]
  def around(sequence, limit \\ 500)

  @spec after(non_neg_integer(), non_neg_integer(), pos_integer()) :: [Event.t()]
  def after(sequence, through_sequence, limit \\ 600)

  @spec before(pos_integer(), pos_integer()) :: [Event.t()]
  def before(sequence, limit \\ 400)

  @spec ambient_before(pos_integer()) :: Event.t() | nil
  def ambient_before(sequence)

  @spec chapter(Date.t(), pos_integer()) :: [Event.t()]
  def chapter(date, limit \\ 600)

  @spec chapters(pos_integer()) :: [map()]
  def chapters(limit \\ 30)

  @spec highest_sequence() :: non_neg_integer()
  def highest_sequence
  ```

  `commit_external/2` must use one `Repo.transaction/1` and `Repo.insert_all/3` with `on_conflict: :nothing` and `returning: true`. Do not pass a conflict target: PostgreSQL then treats any unique violation—including the partial `(source, external_id)` index—as the duplicate guard. Convert each validated source event to allow-listed insert attributes and derive/store visual parameters before insertion. Upsert the checkpoint only after all event insert operations have succeeded, but within the same transaction. Visitor writes use `Event.changeset/2`, derive visuals from the request nonce, and never write a checkpoint.

- [ ] Keep history queries bounded in their function heads; reject limits outside `1..600` with `ArgumentError`. `fetch/1` never raises for an absent sequence. `before/2` returns the preceding rows back in ascending display order. `ambient_before/1` returns the most recent Open-Meteo event at or before the sequence so weather state survives windows shorter than ten minutes. All database ordering is explicit by `id`.

- [ ] Prove GREEN:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/store_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/loom/store.ex test/worldloom/loom/store_test.exs
  rtk git commit -m "Add transactional loom store"
  ```

### Task 6: Persist before broadcasting with the coordinator

**Files:**

- Create: `lib/worldloom/loom/coordinator.ex`
- Create: `test/worldloom/loom/coordinator_test.exs`
- Modify: `lib/worldloom/application.ex`

- [ ] Write failing non-async `DataCase` tests for serialized sequence order, post-commit PubSub delivery, no broadcast on rollback, duplicate source silence, visitor persistence/broadcast, and recovery of `highest_sequence` after process restart. The generated sandbox owner runs shared for these process-backed tests so the supervised coordinator uses the same transaction safely.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/coordinator_test.exs
  ```

- [ ] Implement `start_link/1` options for `:name`, `:store`, `:pubsub`, and `:topic` so isolated tests can start the real coordinator under unique names without mutating global application configuration. Defaults remain the production modules/names. Implement the public API:

  ```elixir
  @topic "loom:events"

  def topic, do: @topic
  def commit_external(server \\ __MODULE__, events, checkpoint), do: GenServer.call(server, {:external, events, checkpoint}, 15_000)
  def commit_visitor(server \\ __MODULE__, event, request_nonce), do: GenServer.call(server, {:visitor, event, request_nonce}, 15_000)
  def highest_sequence(server \\ __MODULE__), do: GenServer.call(server, :highest_sequence)
  ```

  On init, load `Store.highest_sequence/0`. For each call, invoke the store, update the in-memory high-water mark from returned rows, emit telemetry, and only then broadcast `{:loom_event, instruction}` once per inserted row. Return persisted records to callers. A duplicate external batch returns `{:ok, []}` and produces no broadcast.

- [ ] Add the coordinator after Repo and PubSub in the application supervision tree.

- [ ] Prove GREEN, including an explicit test that sees the row in a separate sandbox owner before receiving PubSub:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/coordinator_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/loom/coordinator.ex lib/worldloom/application.ex test/worldloom/loom/coordinator_test.exs
  rtk git commit -m "Broadcast only committed loom events"
  ```

### Task 7: Add bounded external-signal backpressure

**Files:**

- Create: `lib/worldloom/signals/merger.ex`
- Create: `lib/worldloom/signals/buffer.ex`
- Create: `test/worldloom/signals/merger_test.exs`
- Create: `test/worldloom/signals/buffer_test.exs`
- Modify: `lib/worldloom/application.ex`

- [ ] Write failing pure tests showing that same-source overflow merges counts, intensity, summaries, and external ids without mixing visual families. Write non-async shared-sandbox process tests with the real Store and Coordinator proving no more than four external commits per second, visitor commits bypass this buffer, the queue never exceeds 16 entries, a checkpoint is attached only to the final durable representation of its submission, callers receive no success reply before that commit, and a buffer crash exits waiting calls without allowing a later checkpoint to skip their events.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/merger_test.exs test/worldloom/signals/buffer_test.exs
  ```

- [ ] Implement `Merger.merge/1` as a pure source-specific aggregation. For Wikimedia, sum edit/byte counts and language counts. For USGS, retain the strongest quake plus an `additional_count` and bounded place list. For weather, retain the newest ambient state. Refuse mixed-source input.

- [ ] Implement `Signals.Buffer` as a GenServer with an injected clock/timer for tests. `submit(events, checkpoint)` is a deferred-reply `GenServer.call`: append individual events while the queue is under 16; above the cap merge same-source pending entries and retain every affected caller waiter. Every 250 milliseconds attempt at most one `Coordinator.commit_external/2`. Only the last durable representation of a submission carries its checkpoint. Reply `:ok` to all represented callers only after that checkpoint-bearing commit succeeds. On commit error, retain the bounded entry for three retries (250 ms, 1 s, then 5 s), then reply `{:error, :persistence_unavailable}` and drop it with the checkpoint unchanged so the worker refetches. On process crash, linked callers fail and their workers reconnect/refetch from the last durable checkpoint. An empty successful submission commits its checkpoint immediately and replies only after commit because it consumes no visual capacity.

- [ ] Record `[:worldloom, :signals, :buffer, :depth]` telemetry after every enqueue/drain and assert depth returns to zero after a burst.

- [ ] Add `start_link/1` options for isolated process names plus injected clock/timer edges, add the default buffer after the coordinator in the supervision tree, and prove GREEN through real persisted rows/PubSub rather than mocking an internal coordinator:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/merger_test.exs test/worldloom/signals/buffer_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/signals lib/worldloom/application.ex test/worldloom/signals
  rtk git commit -m "Bound external signal throughput"
  ```

## Phase 3: Make external feeds private, resumable, and independent

### Task 8: Build the Req client, SSE parser, and retry policy

**Files:**

- Create: `lib/worldloom/signals/client.ex`
- Create: `lib/worldloom/signals/sse_parser.ex`
- Create: `lib/worldloom/signals/backoff.ex`
- Create: `test/worldloom/signals/client_test.exs`
- Create: `test/worldloom/signals/sse_parser_test.exs`
- Create: `test/worldloom/signals/backoff_test.exs`

- [ ] Write failing tests for SSE fields split across arbitrary chunks, CRLF, comments/heartbeats, multiline `data`, `id`, blank-line dispatch, malformed UTF-8 rejection, JSON success/error/status/timeout through `Req.Test`, response ETag extraction, and capped backoff with deterministic jitter.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/client_test.exs test/worldloom/signals/sse_parser_test.exs test/worldloom/signals/backoff_test.exs
  ```

- [ ] Implement `SSEParser.push(buffer, chunk) :: {frames, remaining_buffer}` as a pure incremental parser. A frame is `%{id: binary() | nil, event: binary() | nil, data: binary()}`. Comments do not create frames. Reject any frame over 256 KB and retain at most 256 KB of an incomplete buffer.

- [ ] Implement `Client.get_json/2` with Req, explicit connect/receive timeouts, `retry: false`, optional `If-None-Match`, and `User-Agent: Worldloom/1.0 (+https://github.com/romankhadka/worldloom)`. Return `{:ok, %{status:, body:, etag:}}` for 200/304 and a tagged error otherwise.

- [ ] Implement `Client.stream_sse/3` using Req `into: fun`, not experimental `into: :self`. Store the partial SSE buffer in `Req.Response.private`, parse chunks synchronously, and invoke the supplied frame callback before returning `{:cont, {request, response}}`. This preserves backpressure at the HTTP stream instead of creating a firehose mailbox. Send the same identifying User-Agent, `Accept: text/event-stream`, optional `Last-Event-ID`, `retry: false`, and no automatic body decoding. Return a tagged disconnect/error when the request ends.

- [ ] Implement `Backoff.delay(attempt, random_fraction)` as `min(300_000, 1_000 * 2^min(attempt, 8))` plus ±20% jitter, clamped to `1_000..300_000`.

- [ ] Prove GREEN:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/client_test.exs test/worldloom/signals/sse_parser_test.exs test/worldloom/signals/backoff_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/signals test/worldloom/signals
  rtk git commit -m "Add resilient feed HTTP boundary"
  ```

### Task 9: Normalize all upstream shapes without retaining private noise

**Files:**

- Create: `lib/worldloom/signals/normalizer.ex`
- Create: `test/worldloom/signals/normalizer_test.exs`
- Create: `test/support/fixtures/feeds/usgs.json`
- Create: `test/support/fixtures/feeds/open_meteo.json`
- Create: `test/support/fixtures/feeds/wikimedia_frames.json`

- [ ] Capture small, representative public fixtures and manually remove Wikimedia usernames, IPs, titles, comments, URLs, and revision ids before committing them. Document the scrubbing in a fixture README.

- [ ] Write failing tests for valid/malformed/bounds cases and assert the serialized normalized output does not contain any forbidden raw key.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/normalizer_test.exs
  ```

- [ ] Implement these pure functions:

  ```elixir
  def wikimedia_bucket(bucket)
  def earthquakes(geojson)
  def weather(responses, anchors)
  ```

  Wikimedia output retains only count, total absolute byte delta, top five language codes, and dominant edit type. USGS output retains feed feature id, magnitude clamped to `0.0..10.0`, public place, and public coordinates at the precision supplied by USGS. Weather output retains aggregate temperature range, precipitation coverage, mean wind, day/night ratio, and the twelve fixed city labels—never arbitrary requested coordinates.

- [ ] Derive lane and intensity deterministically from normalized public values and clamp both to `0.0..1.0`. Produce concise summaries bounded to 160 UTF-8 characters.

- [ ] Prove GREEN and scan forbidden fields:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/normalizer_test.exs
  rtk rg -n 'user|user_text|ip|title|comment|revision|server_url' test/support/fixtures/feeds lib/worldloom/signals
  ```

  Expected: only the fixture README's explicit forbidden-field list and negative test assertions match.

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/signals/normalizer.ex test/worldloom/signals/normalizer_test.exs test/support/fixtures/feeds
  rtk git commit -m "Normalize public signals for the loom"
  ```

### Task 10: Aggregate Wikimedia changes into one-second buckets

**Files:**

- Create: `lib/worldloom/signals/wikimedia_bucket.ex`
- Create: `test/worldloom/signals/wikimedia_bucket_test.exs`

- [ ] Write failing tests for second boundaries, count/byte/language/edit-type aggregation, heartbeat contact, cursor advancement, empty frames, malformed JSON, and absence of raw fields.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/wikimedia_bucket_test.exs
  ```

- [ ] Implement a pure state transition API:

  ```elixir
  def new(second)
  def add(bucket, sse_frame)
  def flush(bucket)
  ```

  `add/2` returns `{:ok, bucket}`, `{:flush, completed_bucket, next_bucket}`, `{:heartbeat, bucket}`, or `{:drop, reason, bucket}`. The cursor is the latest non-empty SSE id. `flush/1` returns `:empty` or a privacy-preserving bucket map accepted by `Normalizer.wikimedia_bucket/1`.

- [ ] Prove GREEN:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/wikimedia_bucket_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/signals/wikimedia_bucket.ex test/worldloom/signals/wikimedia_bucket_test.exs
  rtk git commit -m "Aggregate Wikimedia changes safely"
  ```

### Task 11: Implement independently supervised feed workers

**Files:**

- Create: `lib/worldloom/signals/wikimedia_worker.ex`
- Create: `lib/worldloom/signals/earthquake_worker.ex`
- Create: `lib/worldloom/signals/weather_worker.ex`
- Create: `lib/worldloom/signals/supervisor.ex`
- Create: `test/worldloom/signals/wikimedia_worker_test.exs`
- Create: `test/worldloom/signals/earthquake_worker_test.exs`
- Create: `test/worldloom/signals/weather_worker_test.exs`
- Modify: `config/config.exs`, `config/test.exs`, `config/runtime.exs`, `lib/worldloom/application.ex`

- [ ] Write worker tests with an injected client and timer. Cover success, malformed response, 304, disconnect, cursor/ETag restoration, no checkpoint movement before buffer durability, independent restart, and backoff reset after success.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/wikimedia_worker_test.exs test/worldloom/signals/earthquake_worker_test.exs test/worldloom/signals/weather_worker_test.exs
  ```

- [ ] Configure exact production sources and intervals:

  ```elixir
  config :worldloom, Worldloom.Signals,
    enabled: true,
    wikimedia_url: "https://stream.wikimedia.org/v2/stream/recentchange",
    usgs_url: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson",
    open_meteo_url: "https://api.open-meteo.com/v1/forecast",
    earthquake_interval_ms: 60_000,
    weather_interval_ms: 600_000
  ```

  In `config/test.exs`, set `enabled: false` so tests never reach the internet.

- [ ] In `config/runtime.exs`, allow operator-only overrides `WORLDLOOM_WIKIMEDIA_URL`, `WORLDLOOM_USGS_URL`, and `WORLDLOOM_OPEN_METEO_URL`, rejecting any non-HTTPS URL. These are for controlled pre-launch failure drills and incident response, never visitor input.

- [ ] Implement `WikimediaWorker` with a supervised stream task. Restore `Last-Event-ID` from the durable checkpoint, apply `WikimediaBucket` by upstream event second, and use a one-second worker timer to flush the final bucket even if no next frame crosses the boundary. Submit each complete bucket with cursor and `last_event_at`; throttle heartbeat-only contact checkpoints to at most one per 30 seconds. Reconnect using `Backoff` after clean EOF or error. The streaming callback must synchronously call the worker so Req backpressure is preserved.

- [ ] Implement `EarthquakeWorker`. Poll once on startup and every 60 seconds, send saved ETag, treat 304 as successful contact, normalize every unseen feature, and submit one batch whose checkpoint contains the response ETag and public feed generation time. Database uniqueness is the final dedupe guard.

- [ ] Implement `WeatherWorker` with these fixed anchors in this exact order: Vancouver, Mexico City, São Paulo, Reykjavík, London, Lagos, Nairobi, Cape Town, Mumbai, Singapore, Tokyo, Sydney. Request current `temperature_2m,precipitation,wind_speed_10m,is_day` with `timezone=UTC`, normalize one ambient event, and checkpoint the observation timestamp.

- [ ] Put each worker under a `one_for_one` `Signals.Supervisor`. Start that supervisor after `Signals.Buffer`; a worker crash must not terminate siblings, the coordinator, LiveView, or Endpoint.

- [ ] Prove GREEN and supervision isolation:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/wikimedia_worker_test.exs test/worldloom/signals/earthquake_worker_test.exs test/worldloom/signals/weather_worker_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add config lib/worldloom/signals lib/worldloom/application.ex test/worldloom/signals
  rtk git commit -m "Ingest resilient public signal feeds"
  ```

### Task 12: Project quiet and stale feed health

**Files:**

- Create: `lib/worldloom/signals/feed_health.ex`
- Create: `lib/worldloom/signals/health_monitor.ex`
- Create: `test/worldloom/signals/feed_health_test.exs`
- Create: `test/worldloom/signals/health_monitor_test.exs`
- Modify: `lib/worldloom/application.ex`

- [ ] Write failing tests at exact threshold boundaries: Wikimedia 60 seconds since `metadata.last_event_at`, USGS 3 minutes since successful contact, weather 30 minutes since successful contact. Cover missing checkpoints and recovery.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/feed_health_test.exs test/worldloom/signals/health_monitor_test.exs
  ```

- [ ] Implement pure `FeedHealth.project(checkpoints, now)` returning only:

  ```elixir
  %{
    wikimedia: %{state: :live | :quiet, observed_at: DateTime.t() | nil},
    usgs: %{state: :live | :quiet, observed_at: DateTime.t() | nil},
    open_meteo: %{state: :live | :stale, observed_at: DateTime.t() | nil}
  }
  ```

  No cursor, ETag, internal error, retry count, or source payload is exposed to the browser.

- [ ] Implement one supervised `HealthMonitor` that reads the three checkpoints every 15 seconds, projects them through `FeedHealth`, caches the safe map, emits telemetry, and broadcasts `{:feed_health, safe_map}` on `signals:health` only when the projection changes. `current/0` returns the cache. This prevents every connected LiveView from polling PostgreSQL independently.

- [ ] Prove GREEN and commit:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/signals/feed_health_test.exs test/worldloom/signals/health_monitor_test.exs
  rtk git add lib/worldloom/signals/feed_health.ex lib/worldloom/signals/health_monitor.ex lib/worldloom/application.ex test/worldloom/signals/feed_health_test.exs test/worldloom/signals/health_monitor_test.exs
  rtk git commit -m "Expose safe feed freshness states"
  ```

## Phase 4: Secure anonymous collaboration

### Task 13: Create anonymous identity and in-memory rate limits

**Files:**

- Create: `lib/worldloom_web/plugs/anonymous_identity.ex`
- Create: `lib/worldloom/loom/rate_limiter.ex`
- Create: `test/worldloom_web/plugs/anonymous_identity_test.exs`
- Create: `test/worldloom/loom/rate_limiter_test.exs`
- Modify: `lib/worldloom_web/endpoint.ex`, `lib/worldloom_web/router.ex`, `lib/worldloom/application.ex`, `config/prod.exs`, `config/runtime.exs`

- [ ] Write failing tests proving the identity is a 32-byte URL-safe random token, persists through the signed HTTP-only SameSite=Lax session cookie, is not regenerated, and never appears in response HTML. Test an isolated real `RateLimiter` process for one accepted identity gesture per 30 seconds, coarse IP burst exhaustion/refill, independent identities on one IP, expiry cleanup, and absence of raw/hash persistence.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/plugs/anonymous_identity_test.exs test/worldloom/loom/rate_limiter_test.exs
  ```

- [ ] Put `AnonymousIdentity` immediately after `:fetch_session` in the browser pipeline. It stores the random token under `:visitor_identity` in the existing signed cookie session; do not add a JavaScript-readable cookie. Set `http_only: true` and `same_site: "Lax"` explicitly on the session options. Read a compile-time `:secure_cookies` flag in the endpoint, set it false in development/test and true in `config/prod.exs`, and test both modes.

- [ ] Add `:peer_data` to LiveView websocket/longpoll `connect_info`. Derive a short-lived ETS key with `:crypto.mac(:hmac, :sha256, runtime_salt, :erlang.term_to_binary(peer_address)) |> binary_part(0, 12)`. Never log or persist the address or derived key.

- [ ] Implement `RateLimiter` as the sole owner of a protected named ETS table, with configurable process/table names for isolated tests. `authorize(identity, peer_address, now_ms)` atomically enforces a 30-second identity cooldown and a coarse IP token bucket of 10 attempts per 10 seconds with a burst of 10. Return `:ok` or `{:error, :cooldown | :rate_limited, retry_after_seconds}`. Purge expired rows every minute.

- [ ] Configure `WORLDLOOM_RATE_LIMIT_SALT` in production runtime and fail boot if it is missing. Tests inject a fixed salt.

- [ ] Prove GREEN:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/plugs/anonymous_identity_test.exs test/worldloom/loom/rate_limiter_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add config lib/worldloom/loom/rate_limiter.ex lib/worldloom/application.ex lib/worldloom_web test/worldloom/loom/rate_limiter_test.exs test/worldloom_web/plugs
  rtk git commit -m "Protect anonymous visitor identity"
  ```

### Task 14: Enforce the gesture policy and commit gestures

**Files:**

- Create: `lib/worldloom/loom/gesture_policy.ex`
- Create: `test/worldloom/loom/gesture_policy_test.exs`

- [ ] Write failing tests for the three allow-listed gestures, numeric lane bounds, strings/NaN/infinity rejection, live-edge requirement, invalid/missing identity, cooldown, IP burst, accepted event shape, and absence of identity/IP in payload.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/gesture_policy_test.exs
  ```

- [ ] Implement:

  ```elixir
  @spec authorize(map(), keyword()) :: {:ok, SourceEvent.t(), String.t()} | {:error, atom(), non_neg_integer() | nil}
  def authorize(%{"gesture" => gesture, "lane" => lane}, context)
  ```

  The context contains `identity`, `peer_address`, `live_edge?`, and an injectable clock. Validate all input before consuming rate-limit capacity. Accepted kinds are only `:tug`, `:knot`, and `:illuminate`; source is `:visitor`; `external_id` is nil; `occurred_at` is server time; payload includes only the human summary. Return a random request nonce alongside the event for visual derivation.

- [ ] Add `commit/2`, which authorizes and then calls `Coordinator.commit_visitor/2`. Map database failure to a safe `:unavailable` error without exposing changesets to the LiveView.

- [ ] Prove GREEN and commit:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/loom/gesture_policy_test.exs
  rtk git add lib/worldloom/loom/gesture_policy.ex test/worldloom/loom/gesture_policy_test.exs
  rtk git commit -m "Constrain anonymous loom gestures"
  ```

## Phase 5: Deliver the LiveView experience

### Task 15: Add Presence, routes, bounded history, and reconnect catch-up

**Files:**

- Create: `lib/worldloom_web/presence.ex`
- Create: `lib/worldloom_web/live/world_live.ex`
- Create: `lib/worldloom_web/live/world_live.html.heex`
- Create: `test/worldloom_web/live/world_live_test.exs`
- Modify: `lib/worldloom/application.ex`, `lib/worldloom_web/router.ex`

- [ ] Write failing LiveView tests for `/`, `/chapters`, `/chapters/:date/:sequence`, and `/about`; initial history capped at 600; bounded `history-before` pagination and beginning-of-archive response; malformed, missing, or date/sequence-mismatched permalinks returning 404; archive chapter listing; read-only historical mode; Presence viewer count; live PubSub event push; missing-range catch-up including empty bigint gaps; shared feed-health updates; and no unbounded collection assign.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
  ```

- [ ] Add routes:

  ```elixir
  live "/", WorldLive, :live
  live "/chapters", WorldLive, :archive
  live "/chapters/:date/:sequence", WorldLive, :chapter
  live "/about", WorldLive, :about
  ```

- [ ] Implement `WorldloomWeb.Presence` with `Phoenix.Presence`, start it after PubSub, and track a random per-connection presence key on connected mount. Only the aggregate count is assigned/rendered. On Presence diffs, push `worldloom:presence` with `%{viewer_count: count}`; no presence key or metadata crosses the LiveView boundary.

- [ ] On mount, load at most 400 latest events for live mode or 500 around the requested historical sequence and project them through `Instruction.from_event/1`. Load `Store.ambient_before/1` separately and expose it as `data-ambient`, not as part of sequence-gap accounting. Track Presence on every connected view. Subscribe to `Coordinator.topic/0` only in live mode and subscribe every connected view to `HealthMonitor`'s safe status topic; initialize from `HealthMonitor.current/0` without a per-view database timer. Keep at most 600 recent event records in the LiveView for trusted detail lookup. Use LiveView streams for rendered archive rows and the newest 20 accessible formations, deleting/resetting older entries as new events arrive. The HEEx skeleton must wrap all content in `<Layouts.app flash={@flash}>` and include stable ids `#worldloom`, `#loom-canvas`, `#live-edge`, `#viewer-count`, `#signal-legend`, `#gesture-dock`, `#timeline`, `#signal-detail`, `#archive-panel`, `#about-panel`, and `#accessible-formations`.

- [ ] Store initial instructions in `data-instructions={Jason.encode!(@instructions)}` on the hook element. For committed events, use `push_event(socket, "worldloom:event", instruction)`. On a client `sequence-gap` event, call `Store.after/3` with maximum 600 and push `worldloom:catch-up` as `%{instructions: list, watermark: requested_through_sequence}`. The watermark lets the client acknowledge legitimate holes consumed by PostgreSQL sequences without requesting them forever. If the numeric range is larger than 600, push `worldloom:reload` so the client reloads a bounded latest window.

- [ ] Handle `history-before` with a server-tracked oldest loaded sequence, a per-socket 500 ms throttle, `Store.before/2`, and a maximum 400-row response. Update the LiveView's bounded trusted-detail window to match the page sent. Push `worldloom:history` with instructions and `archive_start?: boolean`; never trust a client-supplied sequence/date/summary as the query cursor. This is the only deep-history pagination path.

- [ ] Historical mode never subscribes to loom event broadcasts and disables the dock with `aria-disabled="true"`; it still participates in aggregate Presence and shows `#return-live`. A selected formation patches the URL to its UTC chapter and sequence without changing its render contract.

- [ ] Prove GREEN:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
  ```

- [ ] Commit:

  ```bash
  rtk git add lib/worldloom/application.ex lib/worldloom_web test/worldloom_web/live
  rtk git commit -m "Add persistent Worldloom LiveView"
  ```

### Task 16: Wire gesture selection, keyboard lanes, cooldown, and details

**Files:**

- Modify: `lib/worldloom_web/live/world_live.ex`
- Modify: `lib/worldloom_web/live/world_live.html.heex`
- Modify: `test/worldloom_web/live/world_live_test.exs`

- [ ] Add failing tests for selecting Tug/Knot/Illuminate, arrow-key lane increments, gesture acceptance, sender receiving only the committed PubSub event, cooldown messaging/countdown, invalid payload rejection, dock disablement while the live route is panned away from the edge, historical rejection, safe source detail, and copyable permalink.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
  ```

- [ ] Render three real `<button>` controls with ids `#gesture-tug`, `#gesture-knot`, and `#gesture-illuminate`. Use `aria-pressed`, visible focus, a lane slider/input with `aria-label`, and a live cooldown status in `#gesture-status`. Make the canvas keyboard-focusable with a descriptive label; arrow keys cycle the visible formation hit regions and Enter opens detail. Mirror the newest 20 formations into the `#accessible-formations` stream as visually hidden focusable buttons so screen-reader users can inspect the same allow-listed details.

- [ ] Handle the hook's `viewport-state` event by storing only a boolean `at_live_edge`; disable the dock when false and expose Return live. Handle `gesture` by calling `GesturePolicy.commit/2` with session identity, socket peer address, and `live_edge?: socket.assigns.live? && socket.assigns.at_live_edge`. Never optimistic-render a gesture. A forged viewport boolean still cannot choose a horizontal coordinate—the coordinator always assigns the committed live sequence. On success set a 30-second UI cooldown; on PubSub delivery render it exactly once. On policy failure, show only safe user-facing text.

- [ ] Handle `select-formation` by resolving a stored event id from the current bounded window, assigning its allow-listed detail, and patching to `/chapters/:date/:sequence`. Do not accept client-supplied summary/source fields. Handle Share by pushing `worldloom:copy-link` with the server-generated permalink; the external Canvas hook uses the Clipboard API when available and falls back to selecting a visible read-only URL field.

- [ ] Prove GREEN and commit:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
  rtk git add lib/worldloom_web/live test/worldloom_web/live/world_live_test.exs
  rtk git commit -m "Make visitor gestures accessible"
  ```

### Task 17: Implement deterministic geometry and the Canvas hook

**Files:**

- Create: `assets/js/worldloom/random.js`
- Modify: `assets/js/worldloom/geometry.js`
- Create: `assets/js/worldloom/renderer.js`
- Create: `assets/js/worldloom/hook.js`
- Create: `assets/test/random.test.js`
- Create: `assets/test/geometry.test.js`
- Create: `assets/test/renderer.test.js`
- Modify: `assets/js/app.js`

- [ ] Write failing Node tests that consume `test/support/fixtures/render_contract_v1.json` plus focused cases for repeatable xorshift32 sequences, sequence-to-horizontal projection, lane-to-vertical projection, command generation per signal/gesture, version fallback, held ambient weather outside the visible event window, UTC chapter seam commands, resize invariance, mouse-wheel/pointer/touch history panning, throttled bounded history-prepend requests, archive-start behavior, live-edge return, hit regions, keyboard formation traversal, aggregate non-identifying viewer pulses, out-of-order event queuing, empty-gap watermarks, bounded in-memory event window, and reduced-motion stepping.

- [ ] Run and confirm RED:

  ```bash
  rtk npm test
  ```

- [ ] Implement `random.js` as a side-effect-free unsigned xorshift32 generator. Implement `commandsForEvent(instruction, viewport)` in `geometry.js`; it returns declarative line/bezier/arc/glow commands and hit regions rather than drawing directly. Never use `Math.random()` in geometry.

- [ ] Implement `Renderer` with a maximum of 600 events and 4,000 drawing commands. It owns device-pixel-ratio sizing, clamped horizontal pan offset, live-edge projection, UTC chapter seams, animation time, reduced-motion mode, hit testing, and `requestAnimationFrame`. It reconstructs entirely from instructions after resize. Wheel, drag, and one-finger touch pan only horizontally. Near the oldest loaded edge it requests one older page at a time, prepends it while retaining the 600-event window nearest the viewport, and stops at `archive_start?`. Return live requests a fresh latest window if newer events were dropped, then animates or steps to offset zero according to motion preference.

- [ ] Implement the `Worldloom` hook. On mount it parses initial instructions, creates `ResizeObserver`, installs pointer/keyboard handlers, and registers `handleEvent` for `worldloom:event`, `worldloom:catch-up`, `worldloom:history`, `worldloom:reload`, `worldloom:return-live`, `worldloom:copy-link`, and `worldloom:presence`. It sends `viewport-state` only when the at-live-edge boolean changes and `history-before` only when the renderer crosses the preload threshold with no request in flight. Aggregate Presence changes only the count of faint live-edge pulses; it never supplies cursor positions. When an event skips the observed watermark, queue it, request the missing range once, apply the returned instructions, advance to the explicit watermark even when the range is empty, and then drain queued events in order. It sends `sequence-gap` and `select-formation` events to the LiveView. On destroy it cancels animation, disconnects the observer, and removes every listener.

- [ ] Merge the hook with generated colocated hooks in `app.js`:

  ```javascript
  import {Worldloom} from "./worldloom/hook"

  hooks: {...colocatedHooks, Worldloom},
  ```

- [ ] Prove GREEN and commit:

  ```bash
  rtk npm test
  rtk proxy asdf exec mix assets.build
  rtk git add assets
  rtk git commit -m "Render the deterministic living fabric"
  ```

### Task 18: Apply the approved Living Fiber visual system

**Files:**

- Modify: `assets/css/app.css`
- Modify: `lib/worldloom_web/live/world_live.html.heex`
- Modify: `lib/worldloom_web/components/layouts/root.html.heex`
- Modify: `test/worldloom_web/live/world_live_test.exs`

- [ ] Add failing semantic assertions for the wordmark, UTC chapter, viewer count, four-family legend, archive/about/share controls, quiet/stale states, gesture dock, live edge, timeline, source attribution, and mobile detail sheet.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
  ```

- [ ] Implement the approved full-viewport Living Fiber composition. Use CSS custom properties for ink `#081311`, cyan `#63d7d1`, ember `#ec8d55`, moss `#8ba66d`, gold `#d3bb70`, ivory `#f3ead4`, and muted ink `#9eaaa3`. The canvas is the visual background; controls use translucent ink surfaces and one-pixel warm borders.

- [ ] Keep the header quiet: wordmark left; UTC chapter, viewer count, Archive, About, Share right. Center the bottom gesture dock, keep the legend low and secondary, and show the live edge as an ivory vertical shimmer. On mobile show only wordmark/viewer count in the header, three gesture buttons at bottom, and details as a small sheet.

- [ ] Add `@media (prefers-reduced-motion: reduce)` that disables shimmer/drift/transitions and ensure the hook also receives the preference. Add `forced-colors` borders, minimum 44×44 px targets, `:focus-visible` outlines, shape/pattern differences independent of color, an `aria-live="polite"` textual summary, and a `<noscript>` explanation.

- [ ] Do not add remote images, web fonts, DaisyUI, inline scripts, or SVG illustration dumps. The fabric is generated by Canvas; all icons use existing Heroicons.

- [ ] Prove focused tests and inspect responsive screenshots at 1440×1000, 1024×768, and 390×844:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/live/world_live_test.exs
  rtk npm test
  rtk proxy asdf exec mix phx.server
  ```

  Use the in-app browser or Playwright screenshot tooling; verify no horizontal page overflow, clipped controls, illegible detail, or blank initial canvas.

- [ ] Commit:

  ```bash
  rtk git add assets/css/app.css lib/worldloom_web
  rtk git commit -m "Style Worldloom as living fiber"
  ```

## Phase 6: Operational safety and end-to-end proof

### Task 19: Add health, telemetry, and privacy-safe logs

**Files:**

- Create: `lib/worldloom_web/controllers/health_controller.ex`
- Create: `test/worldloom_web/controllers/health_controller_test.exs`
- Create: `test/worldloom_web/telemetry_test.exs`
- Modify: `mix.exs`, `mix.lock`, `config/prod.exs`, `lib/worldloom_web/router.ex`, `lib/worldloom_web/telemetry.ex`, `lib/worldloom/loom/coordinator.ex`, `lib/worldloom/signals/*.ex`

- [ ] Write failing tests for `/healthz` returning 200 only when Repo and Coordinator are available, 503 otherwise, and never exposing feed internals. Attach a telemetry test handler and assert event throughput, commit latency, feed success/failure, retry, buffer depth, and viewer count measurements.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/controllers/health_controller_test.exs test/worldloom_web/telemetry_test.exs
  ```

- [ ] Add `GET /healthz` through the API pipeline. Execute `SELECT 1` with a one-second timeout and check `Process.whereis(Worldloom.Loom.Coordinator)`. Response bodies are exactly `{"status":"ok"}` or `{"status":"unavailable"}`.

- [ ] Add `{:logger_json, "~> 7.0.4"}` and configure `LoggerJSON.Formatters.Basic` in production with the built-in `JSON` encoder and an explicit metadata allow-list: request id, source atom, status, attempt, duration, and counts only. Keep human-readable test/dev logging. Add stable telemetry prefixes under `[:worldloom, ...]`, LiveDashboard metrics, and a periodic measurement for durable event row count/storage review. Add tests using `ExUnit.CaptureLog` to prove raw fixture titles/user fields, identities, peer addresses, cookies, cursors, and ETags never appear.

- [ ] Prove GREEN and commit:

  ```bash
  rtk proxy asdf exec mix test test/worldloom_web/controllers/health_controller_test.exs test/worldloom
  rtk git add mix.exs mix.lock config/prod.exs lib test
  rtk git commit -m "Add privacy-safe Worldloom operations"
  ```

### Task 20: Add deterministic seeds for development and local feed controls

**Files:**

- Modify: `priv/repo/seeds.exs`
- Modify: `config/dev.exs`, `README.md`
- Create: `lib/mix/tasks/worldloom.seed_demo.ex`
- Create: `test/worldloom/mix/tasks/worldloom_seed_demo_test.exs`

- [ ] Write a failing test that runs the task twice and proves it creates the same 120 demo events once, spanning all signal families and the previous UTC hour, without contacting external feeds.

- [ ] Run and confirm RED:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/mix/tasks/worldloom_seed_demo_test.exs
  ```

- [ ] Implement `mix worldloom.seed_demo` using deterministic external ids and `Coordinator`/`Store`, not direct SQL. Add `WORLDLOOM_FEEDS_ENABLED=false` runtime override so local visual work is repeatable and offline.

- [ ] Keep `priv/repo/seeds.exs` idempotent and limited to invoking the demo seed in development only.

- [ ] Prove GREEN and commit:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/mix/tasks/worldloom_seed_demo_test.exs
  rtk git add config priv lib/mix test/worldloom/mix README.md
  rtk git commit -m "Add repeatable Worldloom demo signals"
  ```

### Task 21: Add browser smoke and accessibility coverage

**Files:**

- Create: `playwright.config.js`
- Create: `e2e/worldloom.spec.js`
- Modify: `package.json`, `package-lock.json`, `config/test.exs`

- [ ] Configure Playwright to start `MIX_ENV=test asdf exec mix phx.server` on port 4002 with feeds disabled, one worker, traces on first retry, and Chromium only in CI.

- [ ] Write the two-context test first. Seed the database, open two independent browser contexts, wait for both `#loom-canvas[data-ready="true"]`, submit Illuminate in context A, and assert both hooks expose the same highest sequence in `data-rendered-sequence`. Reload B and assert reconstruction reaches the same sequence.

- [ ] Run and confirm RED before adding the remaining browser behavior:

  ```bash
  rtk npx playwright install chromium
  rtk npm run test:e2e
  ```

- [ ] Add tests for keyboard-only gesture/lane operation, historical read-only mode, share permalink round-trip, archive navigation, source detail focus/tap, reduced-motion emulation, 390×844 mobile controls, no console errors, and no request failures.

- [ ] Run and fix only product defects, not assertions that observe implementation details:

  ```bash
  rtk npx playwright install chromium
  rtk npm run test:e2e
  ```

- [ ] Commit:

  ```bash
  rtk git add e2e playwright.config.js package.json package-lock.json config/test.exs
  rtk git commit -m "Test Worldloom across live browsers"
  ```

### Task 22: Add the exact launch-capacity load scenario

**Files:**

- Create: `load/worldloom.js`
- Create: `load/README.md`
- Create: `load/phoenix_live_view.js`

- [ ] Install the current stable k6 runner and record its version in `load/README.md`:

  ```bash
  rtk proxy brew install k6
  rtk proxy k6 version
  ```

  Expected: k6 v2.0.0.

- [ ] Write the one-viewer smoke entrypoint first. It imports a not-yet-implemented protocol client and requires the real `WorldLive` process to appear in telemetry. Run it to confirm RED because the client exports are absent:

  ```bash
  rtk proxy env WORLDLOOM_FEEDS_ENABLED=false asdf exec mix phx.server
  rtk proxy k6 run --vus 1 --duration 10s load/worldloom.js
  ```

  Keep the Phoenix command in its own long-running terminal/session and stop it after the smoke.

- [ ] Implement `load/phoenix_live_view.js` as a small k6 protocol client for the real application path: GET `/`, retain the signed session cookie, parse the CSRF token plus `data-phx-session`/`data-phx-static`, connect to `/live/websocket` with Phoenix protocol `2.0.0`, send the `phx_join`, and expose helpers for heartbeat, LiveView `event`, diff sequence observation, and graceful leave. Do not add a test-only HTTP route or bypass gesture policy. Rerun the one-viewer smoke to GREEN before adding the launch scenario.

- [ ] Implement the k6 scenario for the exact Fly launch size `shared-cpu-1x` with 1 GB RAM:

  - ramp to 200 concurrent connected viewers;
  - hold 200 for 30 minutes;
  - generate a separate 20-attempts/second gesture burst for 60 seconds using distinct identities;
  - require `http_req_failed < 0.01`;
  - require committed-gesture-to-observed-sequence p95 `< 300ms`;
  - record rejected cooldown/rate-limit responses as expected policy outcomes, not transport failures.

- [ ] Document a before/during/10-minutes-after capture of Fly Machine RSS, BEAM process count, LiveView count, coordinator restarts, buffer depth, and database connection utilization. Passing requires no monotonic growth after viewers disconnect.

- [ ] Run a five-minute local smoke first, then the full 30-minute scenario against the private pre-launch Fly deployment created in Task 27. Store the dated text/JSON summary under `docs/performance/` but do not commit credentials or raw visitor identifiers.

- [ ] Commit the scenario before deployment:

  ```bash
  rtk git add load lib/worldloom_web
  rtk git commit -m "Define Worldloom launch load test"
  ```

### Task 23: Run the complete local release gate

**Files:**

- Modify only files required by failures, using systematic debugging and a new focused regression test for each defect.

- [ ] Run placeholder and privacy scans:

  ```bash
  rtk rg -n 'TODO|FIXME|TBD|HelloLive|hello_live|example\.com' . --glob '!deps/**' --glob '!_build/**' --glob '!docs/superpowers/**'
  rtk rg -n 'user_text|raw_ip|visitor_identity|set-cookie' lib test --glob '!**/*_test.exs'
  ```

  Expected: no placeholder/old-name matches; privacy matches only deliberate internal key names with no logging/rendering.

- [ ] Run every local gate:

  ```bash
  rtk proxy asdf exec mix precommit
  rtk npm test
  rtk npm run test:e2e
  rtk proxy asdf exec mix assets.deploy
  rtk proxy asdf exec mix release --overwrite
  ```

- [ ] Boot the release with a disposable local database and verify `/healthz`, `/`, a gesture from two browsers, restart reconstruction, and a historical permalink.

- [ ] Inspect `rtk git diff --check`, `rtk git status --short`, and the last 20 commits. Do not proceed with any uncommitted file or failing check.

## Phase 7: Publish and launch

### Task 24: Add public project documentation and licensing

**Files:**

- Create: `LICENSE`
- Rewrite: `README.md`
- Create: `ARCHITECTURE.md`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `docs/privacy.md`
- Create: `docs/data-sources.md`
- Create: `docs/operations.md`
- Create: `docs/release-notes/v1.0.0.md`
- Create: `docs/preview.mp4` or `docs/preview.gif`

- [ ] Add the standard MIT license with copyright year 2026 and repository owner name.

- [ ] Rewrite README with the product pitch, preview, a `WORLDLOOM_PUBLIC_URL` marker that Task 28 must replace with the Fly hostname actually allocated in Task 27, architecture diagram, exact toolchain, PostgreSQL setup, `mix setup`, feed-disable mode, tests, data attribution, privacy summary, accessibility, deployment, and contribution links.

- [ ] Document Wikimedia EventStreams, USGS, and Open-Meteo links and attribution. State explicitly that Open-Meteo's free tier is non-commercial and commercial use requires a licensing review.

- [ ] Document the persist-before-broadcast invariant, one-instance coordinator assumption, bounded history/queue, checkpoint semantics, recovery, and deferred multi-node leadership.

- [ ] Record a short preview from the real app after deterministic demo seeding. It must contain no browser chrome secrets or terminal output and should include live edge, one gesture, detail, and history pan.

- [ ] Run a link/placeholder scan, then commit:

  ```bash
  rtk rg -n 'TODO|TBD|your-app|example\.com|HelloLive' README.md ARCHITECTURE.md CONTRIBUTING.md SECURITY.md docs
  rtk git add LICENSE README.md ARCHITECTURE.md CONTRIBUTING.md SECURITY.md docs
  rtk git commit -m "Document Worldloom for the public"
  ```

### Task 25: Add CI and release construction

**Files:**

- Create: `.github/workflows/ci.yml`
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `lib/worldloom/release.ex`
- Create: `test/worldloom/release_test.exs`
- Create: `rel/overlays/bin/migrate`
- Modify: `mix.exs`, `config/runtime.exs`

- [ ] Write a failing test for `Worldloom.Release.migrate/0` against the test Repo.

- [ ] Run the release migration test and confirm RED before implementing the module:

  ```bash
  rtk proxy asdf exec mix test test/worldloom/release_test.exs
  ```

- [ ] Implement `Worldloom.Release.migrate/0` using `Ecto.Migrator.with_repo/2`.

- [ ] Configure production Endpoint URL from `PHX_HOST`, `force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]`, origin checking, and secure session cookies. Add a production-config test proving forwarded HTTP redirects to HTTPS while `/healthz` remains reachable through Fly's HTTPS edge.

- [ ] Create a multi-stage Dockerfile pinned to builder `hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim@sha256:9804c9fd6cefea19e2b1095763057d08d634cac29a0994503a468427a64e5e12` and runtime `debian:trixie-20260713-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd`. Build assets, digest, and release in the builder; install only release runtime libraries/CA certificates/locales, run as non-root in the minimal runtime, and add no source/test files to the final image.

- [ ] Implement CI with PostgreSQL service, Elixir/OTP matching `.tool-versions`, Node.js 24.18.0, and actions pinned to immutable commit SHAs. It must run:

  ```bash
  mix deps.get
  mix precommit
  npm ci
  npm test
  npx playwright install --with-deps chromium
  npm run test:e2e
  docker build .
  ```

  Cache Mix/Hex and Playwright using lockfile hashes. Use concurrency cancellation for superseded branch runs.

- [ ] In the same workflow, implement a `deploy` job with `needs: [elixir, assets, e2e, container]`, `if: github.ref == 'refs/heads/master' && github.event_name == 'push'`, GitHub environment `production`, and `flyctl deploy --remote-only --build-arg GIT_SHA=${{ github.sha }}`. Separate workflows cannot use `needs`, so do not split deployment into another file. Require only `FLY_API_TOKEN`; all application secrets live in Fly, not GitHub.

- [ ] Build and run the container locally, verify it executes as non-root, migrates a clean database, serves `/healthz`, and shuts down cleanly on SIGTERM.

- [ ] Commit:

  ```bash
  rtk git add .github Dockerfile .dockerignore lib/worldloom/release.ex rel mix.exs config/runtime.exs test
  rtk git commit -m "Add Worldloom continuous delivery"
  ```

### Task 26: Adversarial review and final local verification

**Files:** none unless review identifies a demonstrated defect.

- [ ] Review the complete diff against this plan and `docs/superpowers/specs/2026-08-03-worldloom-design.md`, focusing on data loss, checkpoint ordering, PubSub ordering, privacy leakage, unbounded memory, LiveView lifecycle, accessibility, and deployment safety. If the user selected Subagent-Driven execution or separately authorizes a fresh agent, invoke `superpowers:requesting-code-review`; otherwise perform the same checklist locally without spawning an agent.

- [ ] Resolve every Critical/Important finding with a focused failing regression test. Re-run review if a fix changes architecture.

- [ ] Invoke `superpowers:verification-before-completion` and run from a clean checkout state:

  ```bash
  rtk proxy asdf exec mix precommit
  rtk npm test
  rtk npm run test:e2e
  rtk docker build -t worldloom:verify .
  rtk git diff --check
  rtk git status --short
  ```

  Expected: every command succeeds and git status is clean.

### Task 27: Provision the final Fly app privately and prove launch capacity

**Files:**

- Create: `fly.toml`
- Create: `docs/performance/2026-08-03-launch-capacity.md`

- [ ] Install/authenticate flyctl if absent, then inspect owned apps and clusters:

  ```bash
  rtk proxy brew install flyctl
  rtk proxy fly auth whoami
  rtk proxy fly apps list
  rtk proxy fly mpg list
  ```

- [ ] Resolve one final app name before creation: use `worldloom` if Fly reports it available; otherwise use `roman-worldloom`. Store that exact name as `WORLDLOOM_FLY_APP` in the task notes and use it consistently in `fly.toml`, commands, docs, CI environment, Playwright, and k6. If neither name is available, stop for the user's naming choice rather than inventing a third public brand.

- [ ] Create the resolved app in the Denver region without announcing it, create/attach a Managed Postgres cluster, and set random production secrets. The commands below show the preferred `worldloom` name; mechanically substitute the resolved name if it is `roman-worldloom`:

  ```bash
  rtk proxy fly launch --no-deploy --name worldloom --region den
  rtk proxy fly mpg create --name worldloom-db --region den
  rtk proxy fly mpg attach worldloom-db --app worldloom
  rtk proxy zsh -c 'worldloom_secret_key=$(asdf exec mix phx.gen.secret); worldloom_rate_salt=$(openssl rand -base64 32); fly secrets set --app worldloom SECRET_KEY_BASE="$worldloom_secret_key" WORLDLOOM_RATE_LIMIT_SALT="$worldloom_rate_salt"; unset worldloom_secret_key worldloom_rate_salt'
  ```

  Before executing, resolve generated secret values in the shell without printing them to captured output. If Fly prompts for a paid plan or organization, stop and request the user's explicit billing choice; do not choose spending on their behalf.

- [ ] Normalize generated `fly.toml`: `primary_region = "den"`, internal port 4000, HTTPS force, `/healthz` check with `X-Forwarded-Proto: https` so the internal probe is not redirected by Plug.SSL, one always-running Machine, `[vm] size = "shared-cpu-1x"` and `memory = "1gb"`, and `[deploy] release_command = "/app/bin/migrate"`. Set `PHX_HOST`, `PORT`, and `WORLDLOOM_FEEDS_ENABLED=true`.

- [ ] Create a one-year app-scoped deploy token and pipe it directly into the existing GitHub repository secret without printing/capturing it. Verify only the secret name/timestamp:

  ```bash
  rtk proxy zsh -c 'fly tokens create deploy --config fly.toml --expiry 8760h | gh secret set FLY_API_TOKEN --repo romankhadka/hello_phoenix'
  rtk gh secret list --repo romankhadka/hello_phoenix
  ```

  Expected: `FLY_API_TOKEN` is listed; its value never appears in output, files, shell history, or docs.

- [ ] Deploy the private pre-launch app, inspect migration logs and feed health, and run the Playwright suite against its HTTPS URL.

- [ ] Before the load run, perform one controlled Wikimedia outage by temporarily setting its runtime URL to an unroutable local endpoint, redeploying, waiting past 60 seconds, and verifying the legend reports quiet while USGS, weather, history, and gestures continue. Remove the override, redeploy, and verify it returns live. Do not run this failure injection after public launch; USGS/weather independence is already covered by supervised integration tests with their longer thresholds.

- [ ] Run the full Task 22 k6 test for 30 minutes. Capture Fly metrics before, during, and 10 minutes after. If any threshold fails, diagnose, add a regression/load assertion, fix, re-run local gates, redeploy, and repeat the full test.

- [ ] Verify Managed Postgres automated backups are enabled and record the non-secret backup policy/status in `docs/operations.md`. Record the current durable event row count/bytes and a dated 30-day review command; do not design compaction before that review.

- [ ] Commit only the verified Fly configuration and redacted performance report:

  ```bash
  rtk git add fly.toml docs/performance docs/operations.md
  rtk git commit -m "Verify Worldloom launch capacity"
  ```

### Task 28: Finalize public artifacts, rename the repository, merge, and launch

**Files:** final public URL substitution, preview, and release notes.

- [ ] Read the allocated hostname from `fly status --json` (which uses the committed app in `fly.toml`), replace every `WORLDLOOM_PUBLIC_URL` marker in public documentation, and record the preview from that exact deployed build. Verify `rtk rg -n 'WORLDLOOM_PUBLIC_URL' README.md docs ARCHITECTURE.md` returns no matches. Commit the URL, preview, release notes, and any final Fly-name substitution before pushing the branch:

  ```bash
  rtk git add README.md ARCHITECTURE.md docs fly.toml
  rtk git commit -m "Finalize Worldloom launch artifacts"
  rtk proxy asdf exec mix precommit
  rtk npm test
  rtk npm run test:e2e
  rtk git status --short
  ```

  Expected: all gates pass and status is clean.

- [ ] Push the task branch, wait for CI, and inspect all failures before merge:

  ```bash
  rtk git push -u origin roman/worldloom
  rtk gh run list --branch roman/worldloom
  rtk proxy zsh -c 'worldloom_run_id=$(gh run list --branch roman/worldloom --workflow ci.yml --limit 1 --json databaseId --jq ".[0].databaseId"); gh run watch "$worldloom_run_id" --exit-status; unset worldloom_run_id'
  ```

- [ ] Only after branch CI is green, confirm `romankhadka/worldloom` still does not exist and the current remote resolves to the public `romankhadka/hello_phoenix` repository:

  ```bash
  rtk gh repo view romankhadka/worldloom --json name,url,visibility
  rtk gh repo view romankhadka/hello_phoenix --json name,url,visibility,defaultBranchRef
  ```

  Expected: first command reports not found; second reports `PUBLIC`.

- [ ] Rename the existing public repository rather than creating a second history, then update and verify the remote:

  ```bash
  rtk gh repo rename worldloom --repo romankhadka/hello_phoenix --yes
  rtk git remote set-url origin git@github.com:romankhadka/worldloom.git
  rtk gh repo view romankhadka/worldloom --json name,url,visibility
  rtk git remote -v
  ```

- [ ] Invoke `superpowers:finishing-a-development-branch`. Use the worktrunk flow below; do not use a branch-only merge. Push `master` only after local verification and branch CI are green:

  ```bash
  rtk wt merge --yes
  rtk git push origin master
  ```

- [ ] Deploy the exact merged commit to the already verified final Fly app and wait for the deploy workflow to finish. Do not recreate the database, rotate secrets, resize the Machine, or change app names during promotion.

- [ ] Verify from outside the local process:

  ```bash
  rtk proxy zsh -c 'worldloom_public_host=$(fly status --json | jq -r .Hostname); curl --fail --silent --show-error "https://$worldloom_public_host/healthz"; WORLDLOOM_BASE_URL="https://$worldloom_public_host" npx playwright test --config=playwright.config.js; unset worldloom_public_host'
  rtk gh repo view romankhadka/worldloom --json visibility,url,defaultBranchRef
  rtk gh run list --branch master --limit 5
  rtk proxy zsh -c 'worldloom_run_id=$(gh run list --branch master --workflow ci.yml --limit 1 --json databaseId --jq ".[0].databaseId"); gh run watch "$worldloom_run_id" --exit-status; unset worldloom_run_id'
  ```

  Also manually verify live signals within five seconds, two-browser gesture delivery, restart reconstruction, historical permalink, mobile keyboard/tap behavior, normal source status, and all public documentation links.

- [ ] Create the public launch release/tag only after every acceptance criterion passes:

  ```bash
  rtk git tag -a v1.0.0 -m "Worldloom v1.0.0"
  rtk git push origin v1.0.0
  rtk gh release create v1.0.0 --title "Worldloom v1.0.0" --notes-file docs/release-notes/v1.0.0.md
  ```

- [ ] Record final evidence: public repository URL, deployed demo URL, commit SHA, CI run URL, Fly Machine size, load-test report, and all acceptance checks. Only then mark the active `/goal` complete.

## Final acceptance audit

- [ ] Canvas reacts to committed signals within five seconds on a cold public visit.
- [ ] Wikimedia, USGS, Open-Meteo, and visitor effects are visually and textually distinct.
- [ ] A gesture in one browser appears from the committed PubSub event in another.
- [ ] Application restart reconstructs the same local topology from stored versioned instructions.
- [ ] Chapter/sequence permalinks reopen the same bounded historical position.
- [ ] Each feed can fail independently while history and visitor gestures continue.
- [ ] No identity, IP, raw Wikimedia payload, cursor, ETag, or cookie leaks to storage, HTML, logs, or public health output.
- [ ] Keyboard, focus, tap, reduced motion, screen-reader summary, contrast, and mobile targets pass.
- [ ] `shared-cpu-1x`/1 GB holds 200 viewers for 30 minutes, tolerates the gesture burst, remains under 300 ms p95, and returns to baseline memory/process counts.
- [ ] `mix precommit`, Node tests, Playwright, Docker build, CI, and deployment are green.
- [ ] Repository is public under MIT and both the demo and documentation are reachable.

## Plan self-review checklist

- [x] Every design-spec goal and acceptance criterion maps to at least one task and one verification step.
- [x] Every behavior task begins with a failing test and names the focused command.
- [x] Every external mutation has a read-only preflight and an explicit success check.
- [x] No implementation step contains an unresolved placeholder, invented secret, or unresolved module/API name; the single `WORLDLOOM_PUBLIC_URL` documentation marker has an explicit replacement step after Fly allocates the hostname.
- [x] Data contracts use one naming/type convention across database, Elixir, LiveView, and JavaScript.
- [x] Queue, history, renderer state, SSE frames, payloads, summaries, retries, and rate-limit state are all bounded.
- [x] The only spending boundary—Fly Managed Postgres/compute—requires an explicit user billing choice if the account prompts.
