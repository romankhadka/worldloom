# Balanced World Phase 5: Incremental Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make drand, Bluesky, and RIPE independently deployable through reversible canaries while keeping Solana production-disabled.

**Architecture:** A typed runtime configuration validates source flags and secure endpoints. Signals Supervisor builds children only for explicitly enabled sources. Each source lands in its own commit with deterministic tests, an external contract probe, operational evidence requirements, and a rollback switch. Enabling a production flag or deploying a canary is a separate authorized operational action, not an automatic side effect of merging code.

**Tech Stack:** Elixir 1.20, Phoenix releases, Mint WebSocket, Req, Mint, GitHub Actions, Fly.io-compatible runtime configuration.

---

## Files

### Create

- `lib/worldloom/signals/config.ex`
- `test/worldloom/signals/config_test.exs`
- `lib/mix/tasks/worldloom.providers.smoke.ex`
- `test/worldloom/mix/tasks/worldloom.providers.smoke_test.exs`
- `.github/workflows/provider-contract.yml`

### Modify

- `config/config.exs`
- `config/runtime.exs`
- `config/test.exs`
- `lib/worldloom/signals/supervisor.ex`
- `test/worldloom/signals/supervisor_test.exs`
- `docs/data-sources.md`
- `docs/operations.md`
- `docs/privacy.md`
- `README.md`

## Task 1: Make source configuration explicit and fail closed

- [x] **Step 1: Write runtime parsing tests**

Create `test/worldloom/signals/config_test.exs`. Assert defaults:

```elixir
assert config.enabled
refute config.drand_enabled
refute config.bluesky_enabled
refute config.ripe_enabled
refute config.solana_enabled
```

Assert only literal `"true"` and `"false"` parse, invalid booleans raise with the environment key, production HTTP endpoints require `https`, production WebSockets require `wss`, RIPE collectors are 1..4 values matching `~r/^rrc\d{2}$/`, and all URL labels strip queries.

Assert `WORLDLOOM_FEEDS_ENABLED=false` overrides every per-source flag.

- [x] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/config_test.exs test/worldloom/runtime_config_test.exs
```

- [x] **Step 3: Create the typed config boundary**

Create `lib/worldloom/signals/config.ex` with a struct and pure `from_keyword!/2`. Keep `System.get_env/1` in `config/runtime.exs`; pass strings into the pure parser for tests.

Use these config keys and defaults in `config/config.exs`:

```elixir
drand_enabled: false,
drand_relays: ["https://api.drand.sh", "https://api2.drand.sh", "https://api3.drand.sh"],
bluesky_enabled: false,
bluesky_url: "wss://jetstream2.us-west.bsky.network/subscribe",
ripe_enabled: false,
ripe_url: "wss://ris-live.ripe.net/v1/ws/",
ripe_collectors: ["rrc00", "rrc01", "rrc03", "rrc10"],
solana_enabled: false,
solana_url: nil
```

Environment keys are `WORLDLOOM_DRAND_ENABLED`, `WORLDLOOM_DRAND_RELAYS`, `WORLDLOOM_BLUESKY_ENABLED`, `WORLDLOOM_BLUESKY_URL`, `WORLDLOOM_RIPE_ENABLED`, `WORLDLOOM_RIPE_URL`, `WORLDLOOM_RIPE_COLLECTORS`, and `WORLDLOOM_SOLANA_ENABLED`. Reject `WORLDLOOM_SOLANA_ENABLED=true` in production with a message that a production endpoint decision is required.

- [x] **Step 4: Verify and commit**

```bash
rtk mix test test/worldloom/signals/config_test.exs test/worldloom/runtime_config_test.exs
rtk git add lib/worldloom/signals/config.ex test/worldloom/signals/config_test.exs config/config.exs config/runtime.exs config/test.exs test/worldloom/runtime_config_test.exs
rtk git commit -m "Fail closed around independent public feed configuration"
```

## Task 2: Make supervisor composition independently reversible

- [x] **Step 1: Write child-composition tests**

Extend `test/worldloom/signals/supervisor_test.exs`. For every flag combination, assert exact child IDs. The all-off case still starts existing enabled Wikimedia, USGS, and Open-Meteo workers when global ingestion is on; global off starts none. Assert enabling one new source adds exactly one child and preserves `:one_for_one` sibling isolation.

- [x] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/signals/supervisor_test.exs
```

- [x] **Step 3: Build children from validated config**

Update `Worldloom.Signals.Supervisor.configured_children/1` to append child specs in stable order: existing feeds, drand, Bluesky, RIPE, Solana. Pass only source-specific config to each child. A disabled source creates no process, timer, connection, checkpoint touch, or health claim.

- [x] **Step 4: Verify and commit**

```bash
rtk mix test test/worldloom/signals/supervisor_test.exs
rtk git add lib/worldloom/signals/supervisor.ex test/worldloom/signals/supervisor_test.exs
rtk git commit -m "Supervise public feeds behind independent switches"
```

## Task 3: Land drand as the first production-capable source

- [x] **Step 1: Add end-to-end persistence tests**

In `test/worldloom/signals/drand_worker_test.exs`, run the real worker against injected relay responses and real Buffer/Coordinator under SQL sandbox ownership. Assert exact durable row, v2 instruction, snapshot display membership, replay idempotence, and public health.

- [x] **Step 2: Run the focused vertical slice**

```bash
rtk mix test test/worldloom/signals/drand_worker_test.exs test/worldloom/loom/coordinator_test.exs test/worldloom_web/live/world_live_test.exs
```

- [x] **Step 3: Document the canary and rollback evidence**

In `docs/operations.md`, define a one-source canary with:

- flag: `WORLDLOOM_DRAND_ENABLED=true`;
- expected cadence: one real Quicknet round every three seconds;
- healthy threshold: new valid round within twelve seconds;
- recovery cap: twenty rounds;
- rollback: set the flag false and redeploy;
- observe: no duplicate rows, no BLS-verification claim, other feeds unaffected.

- [x] **Step 4: Verify code readiness without changing production**

```bash
rtk mix precommit
rtk mix run -e 'IO.inspect(Worldloom.Signals.Config.from_keyword!(Application.fetch_env!(:worldloom, Worldloom.Signals), :prod))'
```

Do not set a remote environment variable or deploy from this task. Stop for explicit operational authorization before the canary.

- [x] **Step 5: Commit the drand vertical slice**

```bash
rtk git add test/worldloom/signals/drand_worker_test.exs docs/operations.md docs/data-sources.md
rtk git commit -m "Prepare the drand public pulse for canary release"
```

## Task 4: Land bounded Bluesky summaries second

- [x] **Step 1: Add the complete fake-edge vertical test**

Use a local fake WebSocket server to emit fixture frames, disconnect, and replay a five-second overlap. Assert one source-owned GenServer, two `wantedCollections` query values, `maxMessageSizeBytes=262144`, dedupe, one durable aggregate per non-empty four-second window, checkpoint cursor advancement, and no account/identity/content retention.

- [x] **Step 2: Run focused verification**

```bash
rtk mix test test/worldloom/signals/bluesky_socket_test.exs test/worldloom/signals/bluesky_window_test.exs test/worldloom/signals/buffer_test.exs
```

- [x] **Step 3: Document canary and rollback evidence**

Add to `docs/operations.md`:

- flag: `WORLDLOOM_BLUESKY_ENABLED=true`;
- protocol: deployed legacy Jetstream, best-effort and not protocol-stable;
- quiet threshold: twenty seconds without valid activity;
- replay: five-second cursor overlap capped at sixty seconds;
- rollback: disable only the Bluesky flag;
- privacy checks: no DID, handle, record text, URI, CID, or cursor in public event
  rows, logs, telemetry, or the browser; the numeric cursor is confined to the
  private checkpoint row.

- [x] **Step 4: Verify code readiness without changing production**

```bash
rtk mix precommit
rtk rg -n 'did|handle|record|uri|cid|cursor' docs/privacy.md docs/operations.md lib/worldloom/signals/bluesky_socket.ex test/worldloom/signals/bluesky_socket_test.exs
```

Review input-only matches; do not deploy without explicit authorization.

- [x] **Step 5: Commit the Bluesky vertical slice**

```bash
rtk git add docs/data-sources.md docs/operations.md docs/privacy.md docs/superpowers/plans/2026-08-08-balanced-world-phase-5-incremental-sources.md lib/worldloom/signals/bluesky_socket.ex test/support/websocket_fixture_server.ex test/support/websocket_fixture_server/router.ex test/worldloom/signals/bluesky_socket_test.exs
rtk git commit -m "Prepare bounded Bluesky summaries for canary release"
```

## Task 5: Land RIPE route movement third

- [x] **Step 1: Add the complete fake-edge vertical test**

Use a local fake WebSocket server to answer `request_rrc_list`, acknowledge subscriptions, emit fixture UPDATEs, close as a slow consumer, and reconnect. Assert one source-owned GenServer, one string-host subscription per approved current collector, no replay after reconnect, honest gap health, one aggregate per non-empty window, and no prefix/peer/collector identity outside ephemeral hashed sets.

- [x] **Step 2: Run focused verification**

```bash
rtk mix test test/worldloom/signals/ripe_socket_test.exs test/worldloom/signals/ripe_window_test.exs test/worldloom/signals/buffer_test.exs
```

- [x] **Step 3: Document canary and rollback evidence**

Add:

- flag: `WORLDLOOM_RIPE_ENABLED=true`;
- subscription: UPDATE only, maximum four configured collectors intersected with current `ris_rrc_list`, `includeRaw=false`;
- quiet threshold: twenty seconds;
- recovery: no replay, honest gap after disconnect;
- rollback: disable only RIPE;
- privacy checks: no peer, ASN, prefix, collector, message id, or raw BGP bytes outside the adapter.

- [x] **Step 4: Verify code readiness without changing production**

```bash
rtk mix precommit
rtk rg -n 'peer|prefix|collector|raw|asn|message.*id' docs/privacy.md docs/operations.md lib/worldloom/signals/ripe_socket.ex test/worldloom/signals/ripe_socket_test.exs
```

- [x] **Step 5: Commit the RIPE vertical slice**

```bash
rtk git add docs/data-sources.md docs/operations.md docs/privacy.md docs/superpowers/plans/2026-08-08-balanced-world-phase-5-incremental-sources.md lib/worldloom/signals/ripe_socket.ex lib/worldloom/signals/ripe_socket/state.ex test/worldloom/signals/ripe_socket_test.exs
rtk git commit -m "Prepare bounded RIPE summaries for canary release"
```

## Task 6: Add non-flaky scheduled provider contract probes

- [ ] **Step 1: Write the Mix-task tests with injected probes**

Create `test/worldloom/mix/tasks/worldloom.providers.smoke_test.exs`. Assert the task returns per-source pass/fail, exits nonzero on protocol drift, emits only source and coarse reason, times out each probe, and never prints endpoint query, cursor, payload, or response body.

- [ ] **Step 2: Run and verify RED**

```bash
rtk mix test test/worldloom/mix/tasks/worldloom.providers.smoke_test.exs
```

- [ ] **Step 3: Implement the bounded task**

Create `lib/mix/tasks/worldloom.providers.smoke.ex`. Probe drand, legacy Jetstream, and RIPE concurrently with a 15-second per-source timeout. Each WebSocket probe stops after one valid sanitized observation and persists nothing. Exclude Solana because no production provider is approved.

- [ ] **Step 4: Add the scheduled workflow**

Create `.github/workflows/provider-contract.yml` triggered by weekly `schedule` and `workflow_dispatch`, not `push` or `pull_request`. Run `mix worldloom.providers.smoke`; upload no raw artifact. Protocol drift may open a failing workflow signal but may not make pull-request CI flaky.

- [ ] **Step 5: Verify and commit**

```bash
rtk mix test test/worldloom/mix/tasks/worldloom.providers.smoke_test.exs
rtk git add lib/mix/tasks/worldloom.providers.smoke.ex test/worldloom/mix/tasks/worldloom.providers.smoke_test.exs .github/workflows/provider-contract.yml
rtk git commit -m "Detect public provider contract drift on a schedule"
```

## Task 7: Close the operational and public documentation

- [ ] **Step 1: Update public descriptions**

Update README and source/privacy/operations docs with direct official attribution links, accurate best-effort language, per-source switches, freshness, recovery, and the statement that Worldloom is an artistic aggregate rather than operational, social, cryptographic, or financial analysis.

- [ ] **Step 2: Complete verification**

```bash
rtk mix precommit
rtk npm test
rtk npm run test:e2e
rtk docker build --build-arg GIT_SHA=$(rtk git rev-parse HEAD) .
rtk git diff --check master...HEAD
rtk mix hex.audit
```

- [ ] **Step 3: Commit documentation**

```bash
rtk git add README.md docs/data-sources.md docs/privacy.md docs/operations.md
rtk git commit -m "Document the balanced world's canary operations"
```

## Phase 5 completion gate

- [ ] Code defaults every new production source off.
- [ ] Global feed disable overrides every source.
- [ ] drand, Bluesky, and RIPE each have one isolated switch, vertical test, contract probe, canary checklist, and rollback procedure.
- [ ] Solana cannot be enabled in production.
- [ ] No task silently changes a remote environment or deploys a canary.
- [ ] Provider drift checks run outside deterministic pull-request CI.
