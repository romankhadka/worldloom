# Balanced World Signals Implementation Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evolve Worldloom from a Wikimedia-dominant sequence display into a truthful, resilient, one-minute composition of distinct public-world signals.

**Architecture:** Land six independently reviewable phases. First make the snapshot and event-time projection correct, then widen the durable contract, qualify providers without enabling them, harden transport and health, activate sources through reversible canaries, and finish with a balanced visual and accessibility release.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, Phoenix LiveView 1.2, Ecto/PostgreSQL, Req, WebSockex 0.5.1, Canvas 2D, browser-native JavaScript, Node test runner, Playwright, k6, Docker, GitHub Actions.

---

## Governing specification

Implement against `docs/superpowers/specs/2026-08-08-balanced-world-signals-design.md`. If a phase plan and the specification disagree, stop and amend the plan before changing code.

## Phase plans

1. `docs/superpowers/plans/2026-08-08-balanced-world-phase-1-projection-foundation.md`
2. `docs/superpowers/plans/2026-08-08-balanced-world-phase-2-contract-migration.md`
3. `docs/superpowers/plans/2026-08-08-balanced-world-phase-3-provider-qualification.md`
4. `docs/superpowers/plans/2026-08-08-balanced-world-phase-4-transport-health.md`
5. `docs/superpowers/plans/2026-08-08-balanced-world-phase-5-incremental-sources.md`
6. `docs/superpowers/plans/2026-08-08-balanced-world-phase-6-visual-release.md`

Execute them in order. Every phase ends in working software, a focused review, and a clean verification run. Do not squash the behavioral commits; their boundaries are the rollback boundaries.

## Specification traceability

| Specification area | Executable coverage |
| --- | --- |
| Snapshot envelope, display quota, memory, ambient | Phase 1, tasks 1–5 |
| Exact event-time geometry and history | Phase 1, tasks 6–7 |
| Additive source migration and v1 compatibility | Phase 2, tasks 1–4 |
| Four-second windows and source offsets | Phase 2 task 5; phase 3 tasks 2–4 |
| Provider qualification and privacy | Phase 3, tasks 2–6 |
| WebSocket bounds, replay, redaction, supervision | Phase 4, tasks 1, 5–7 |
| Ephemeral health and failure isolation | Phase 4, tasks 2, 5–7 |
| Fair buffering and pressure semantics | Phase 4, tasks 3–4 |
| Independent configuration and canaries | Phase 5, tasks 1–5 |
| Scheduled provider drift detection | Phase 5, task 6 |
| Distinct visual grammar and accessibility | Phase 6, tasks 1–5, 7 |
| Five-minute balance measurement | Phase 6, task 6 |
| Instrumented fake upstream and 100 browsers | Phase 6, tasks 8–9 |
| Public docs, attribution, complete release matrix | Phase 5 task 7; phase 6 task 10 |

## Global invariants

- [ ] Persist before broadcast; a failed database transaction advances neither checkpoint nor public state.
- [ ] Database sequence remains the only commit ledger, selection identity, history cursor, and permalink identity.
- [ ] `window_end` comes only from eligible persisted event time, is truncated to a UTC second, never moves backward, and never reads a browser clock.
- [ ] Display omissions are not sequence gaps; a real watermark gap triggers complete snapshot reprojection.
- [ ] Raw content, identities, routing identifiers, accounts, wallets, cursors, URLs, and response bodies never cross the source adapter boundary.
- [ ] New production feeds default off and can be disabled independently without affecting existing feeds.
- [ ] The renderer never invents a source event to satisfy a visual balance target.
- [ ] Version 1 events, chapters, selections, and permalinks remain compatible.
- [ ] Existing command, instruction, transition, cache, mailbox, decoded-frame, distinct-set, and replay bounds remain explicit and tested.

## Integration sequence

### Gate 1: Projection foundation

- [ ] Complete phase 1 with no new provider or durable source kind.
- [ ] Confirm a Wikimedia surge cannot push another eligible current source or contextual memory out through sequence spacing.
- [ ] Confirm the exact same snapshot envelope renders identically after reload.
- [ ] Run `rtk mix precommit`, `rtk npm test`, and `rtk npm run test:e2e`.
- [ ] Commit only after the phase diff is reviewed against the specification.

### Gate 2: Durable contract migration

- [ ] Complete phase 2 using an additive database constraint migration.
- [ ] Migrate forward and backward against a database containing version 1 rows.
- [ ] Confirm version 1 instructions have no `metrics` key and version 2 instructions expose only bounded allow-listed metrics.
- [ ] Run `rtk mix precommit` and `rtk npm test`.

### Gate 3: Provider qualification

- [ ] Complete phase 3 with production flags still false.
- [ ] Capture sanitized provider contract fixtures only; never commit raw identity or content-bearing payloads.
- [ ] Run scheduled-contract tests manually against official endpoints, but keep them outside deterministic CI.
- [ ] Record the pinned protocol assumptions in `docs/data-sources.md`.

### Gate 4: Transport and health

- [ ] Complete phase 4 with one independently supervised process per source.
- [ ] Prove fair draining, bounded pressure reduction, bounded replay, redacted telemetry, and sibling survival.
- [ ] Prove no application handler is attached to WebSockex raw-frame telemetry events.
- [ ] Run `rtk mix precommit`, targeted stress tests, and `rtk npm test`.

### Gate 5: Incremental canaries

- [ ] Complete phase 5 in the order drand, Bluesky, RIPE.
- [ ] Keep Solana production-disabled until a separately approved endpoint decision exists.
- [ ] Require a rollback switch and observed quiet/stale/recovery behavior for each canary before starting the next.
- [ ] Do not interpret a quiet feed as whole-application failure; `/healthz` remains database/coordinator readiness only.

### Gate 6: Balanced visual release

- [ ] Complete phase 6 with named deterministic fixtures and responsive visual snapshots.
- [ ] Prove non-color source recognition and reduced-motion settled meaning.
- [ ] Run the instrumented 100-browser profile against fake upstreams and prove one upstream connection per enabled source.
- [ ] Run the complete release matrix below.

## Release matrix

- [ ] `rtk mix format --check-formatted`
- [ ] `rtk mix compile --warning-as-errors`
- [ ] `rtk mix test`
- [ ] `rtk npm test`
- [ ] `rtk npm run test:e2e`
- [ ] `rtk docker build --build-arg GIT_SHA=$(rtk git rev-parse HEAD) .`
- [ ] `rtk git diff --check master...HEAD`
- [ ] `rtk mix hex.audit` reports no unapproved advisory.
- [ ] GitHub CI passes on the exact integration commit.

## Dependency-audit release blocker

The current lock contains Postgrex 0.22.3 and `mix hex.audit` reports advisory `EEF-CVE-2026-66838` for the `:comment` option to `Postgrex.stream/4`.

- [ ] At the start of each phase, run `rtk mix hex.audit` and record whether a fixed Postgrex release exists.
- [ ] When a fixed version exists, update the dependency and lock in a separate commit, run `rtk mix precommit`, then rerun `rtk mix hex.audit`.
- [ ] Until then, retain a test-backed non-reachability note showing Worldloom never calls `Postgrex.stream/4` or supplies its `:comment` option.
- [ ] Do not call that note a fix and do not merge the public release while the advisory remains unapproved.

## Commit map

Keep structural changes separate from behavior. The expected high-level history is:

1. `Project the live loom from an authoritative minute snapshot`
2. `Separate display membership from the commit watermark`
3. `Expand the durable signal contract without rewriting history`
4. `Qualify bounded public signal adapters`
5. `Isolate signal transports and ephemeral feed health`
6. `Drain source pressure fairly`
7. `Enable the drand public pulse`
8. `Enable bounded Bluesky activity summaries`
9. `Enable bounded RIPE route-change summaries`
10. `Give every public signal a distinct visual grammar`
11. `Verify balanced Worldloom under 100 concurrent browsers`
12. `Document the balanced world and its operational limits`

No commit may include an AI-attribution trailer.
