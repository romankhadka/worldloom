# Worldloom agent guide

This is the project briefing for agents and maintainers continuing Worldloom. Read it
before proposing or implementing a change. Then read the root `AGENTS.md` for framework
rules and the documents linked below for the part of the system you will touch.

## What Worldloom is

Worldloom is a public, persistent artwork: a living tapestry woven from seven real
public signals and three anonymous visitor gestures. Wikimedia edits form its connective
backbone; Bluesky activity, RIPE routing motion, Solana slot progression, drand rounds,
USGS earthquakes, and Open-Meteo weather each have a distinct structural or atmospheric
grammar. Visitors can Tug, Knot, or Illuminate the live edge without creating an account.

It is deliberately an artistic aggregate. It is not an alerting, forecasting, social,
financial, cryptographic-verification, operational, or scientific-analysis product. Its
source gaps and degraded states must remain honest.

The experience should feel calm, mysterious, legible, and alive:

- The luminous right edge is **Now**; earlier UTC history extends to the left.
- The 1m, 5m, and 15m scales show the same committed history at different densities.
- Every connected browser converges on the same durable formations.
- Pointer, keyboard, touch, reduced-motion, and screen-reader paths are first-class.
- No visitor needs an account, profile, name, post, upload, or public identity.

Start with [README.md](../README.md) for the public story and current commands. Use
[ARCHITECTURE.md](../ARCHITECTURE.md) as the authoritative system model,
[operations.md](operations.md) for runtime behavior, [privacy.md](privacy.md) for the
data contract, and [data-sources.md](data-sources.md) before changing an upstream feed.

## Current product state

Worldloom v1.0.0 is a working Phoenix/LiveView application with a deterministic Canvas
2D renderer, durable PostgreSQL history, seven independently supervised public sources,
anonymous visitor gestures, UTC chapter permalinks, timeline zoom, source-health states,
and desktop/mobile accessibility coverage.

The repository contains historical design specifications and implementation plans under
`docs/superpowers/`. They are valuable decision records, but their unchecked boxes are
not a current backlog. Verify present code, tests, release notes, Git history, deployment
configuration, and open issues before treating an old plan item as unfinished.

At the time this guide was introduced, the README described Worldloom as public source
and a local experience, while production deployment remained conditional on repository
configuration. Re-check that claim before planning work or editing public copy.

## The mental model

```text
public providers
    -> isolated OTP workers
    -> pure validation and normalization
    -> fair bounded buffer
    -> one authoritative Loom.Coordinator
    -> PostgreSQL transaction
    -> Phoenix PubSub after commit
    -> bounded LiveView snapshot
    -> pure topology and geometry
    -> Canvas 2D renderer

anonymous gesture
    -> cookie and coarse network rate limits
    -> gesture policy
    -> the same coordinator, persistence, and broadcast path
```

The system has three owners of truth:

- OTP owns live ingestion and authoritative sequencing.
- PostgreSQL owns append-only durable history and feed checkpoints.
- The browser owns deterministic drawing, interaction, and local animation.

The browser receives only compact, allow-listed rendering instructions. It never receives
raw provider payloads or gets to choose sequence IDs, seeds, horizontal positions, or
free-form content.

## Non-negotiable invariants

Treat these as design constraints, not implementation details:

1. **Persist, then broadcast.** `Worldloom.Loom.Coordinator` publishes only rows returned
   from a successful store transaction. Never draw an optimistic visitor formation.
2. **The database ID is the global sequence.** It orders commits, detects transport loss,
   identifies formations, and anchors permalinks. Display omissions are not sequence gaps.
3. **Rendering is deterministic and versioned.** The same complete snapshot must reproduce
   the same topology. Preserve old `render_version` behavior; add a new version for a
   meaning-changing contract and retain a bounded fallback for future versions.
4. **Every burst path is bounded.** Do not casually raise limits or introduce an unbounded
   list, queue, payload, retry, history request, transition set, drawing-command set, or
   provider replay. Read the exact limits in `ARCHITECTURE.md` first.
5. **Raw upstream content stays at the edge.** Persist and expose only sanitized aggregates.
   Never log or publish posts, identities, IP addresses, routing identifiers, raw payloads,
   provider cursors, ETags, signatures, or account-level blockchain information.
6. **Source gaps remain truthful.** `live`, `quiet`, `stale`, and `disconnected` describe
   observed runtime facts. Never fabricate events, silently extend replay, or mark a source
   live from a private checkpoint.
7. **Sources are independent.** A failed or isolated provider must not stop the loom,
   visitor gestures, archive, health endpoint, or sibling sources. Source environment
   switches are operator circuit breakers, not visitor preferences; all sources default on.
8. **Accessibility is part of the feature.** Any pointer path needs keyboard and touch
   equivalents. Any motion change needs a reduced-motion outcome. Meaning cannot depend on
   color or canvas alone.
9. **Worldloom v1 is single-instance.** Starting a second application writer is unsafe
   until coordinator leadership, cross-node catch-up, distributed Presence, and provider
   ownership are designed and verified together.
10. **Privacy claims and artistic disclaimers are product behavior.** A change that alters
    collected fields, retention, attribution, rate limiting, source meaning, or reliability
    claims must update the relevant public documents in the same change.

## Where the important code lives

| Area | Primary locations | Responsibility |
|---|---|---|
| Supervision | `lib/worldloom/application.ex` | Repo, PubSub, Presence, limiter, coordinator, signals, endpoint |
| Provider ingestion | `lib/worldloom/signals/` | Transport, validation, aggregation, recovery, health, fair buffering |
| Durable loom | `lib/worldloom/loom/` | Events, instructions, projection, policy, coordinator, store |
| Live interface | `lib/worldloom_web/live/world_live.*` | Bounded state, chapters, selection, gestures, source status |
| Browser boundary | `assets/js/worldloom/hook.js` | LiveView protocol, input ownership, timeline controls |
| Visual model | `topology.js`, `geometry.js`, `source_grammar.js` | Pure deterministic structure and projection |
| Painting | `renderer.js`, `palette.js`, `assets/css/app.css` | Canvas state, hit testing, animation, Lacquered Gallery system |
| Contracts and fixtures | `test/support/fixtures/`, `assets/test/fixtures/` | Versioned render and balanced-world acceptance evidence |
| End-to-end behavior | `e2e/`, `playwright.config.js` | Real browser, mobile, accessibility, convergence, visual baselines |
| Launch capacity | `load/` | 100-browser and k6 release evidence |
| Operations and policy | `docs/` | Deployment, privacy, source contracts, designs, release record |

Keep pure decisions in normalizers, policies, projection, topology, and geometry so they
remain deterministic and cheap to test. Keep network, database, DOM, clock, and Canvas
effects at their existing boundaries.

## How to start a task

1. Inspect the current branch, worktrees, status, recent commits, CI, and open issues. Do
   not assume this guide's snapshot is still current.
2. On the maintainer workstation, prefix shell commands with `rtk` and use worktrunk for
   task isolation:

   ```bash
   rtk git rev-parse --abbrev-ref HEAD
   rtk wt list
   rtk wt switch --create <focused-branch-name> --yes
   ```

3. Read the whole file being changed and trace its callers, dependencies, tests, and public
   documentation. For providers, also verify the current official protocol; contracts drift.
4. For a material behavior or architecture change, write or update a design and implementation
   plan under `docs/superpowers/` before coding. Record bounds, failure behavior, privacy,
   accessibility, migration, rollback, and proof—not just the happy path.
5. Add the smallest failing test that expresses the user-visible or invariant-level outcome.
   Keep deterministic tests offline; CI must not depend on live public providers.
6. Implement in small, meaningful commits. Keep structural cleanup separate from behavioral
   changes when doing so makes review safer. Never add AI attribution trailers.
7. Review the final diff for leaked identifiers, changed claims, accidental bound expansion,
   dead paths, stale fixtures, and undocumented configuration.

## Verification ladder

Run focused tests while iterating, then use the gates proportional to the change.

```bash
# Required for every completed change
mix precommit
npm test

# Required for UI, LiveView protocol, rendering, touch, navigation, or accessibility
npm run test:e2e

# Required before a production release or when production configuration changes
mix hex.audit
mix assets.deploy
MIX_ENV=prod mix release --overwrite
docker build --build-arg GIT_SHA="$(git rev-parse HEAD)" .
```

Use `mix worldloom.providers.smoke` manually after a provider announces a contract change
or before an incremental-source canary. It intentionally contacts public providers and is
not a deterministic pull-request gate.

Before public launch or a capacity-sensitive release, also run the exact 100-browser and k6
profiles in [load/README.md](../load/README.md). Visual changes require inspecting the actual
desktop and mobile result, including reduced motion, before accepting new snapshots. Generate
Linux baselines in the documented Playwright container rather than approving unexplained
platform drift.

Do not claim success from an old run, a partial suite, or a subagent report. Run the relevant
commands on the final diff and read their exit status.

## How to move Worldloom forward

Prefer the smallest milestone that measurably improves public wonder, reliability, safety,
or comprehension without weakening the invariants above. The current priority order is:

### 1. Complete and prove the public launch

This is the highest-value next milestone while the README has no verified hosted demo.

- Select and configure durable hosting, PostgreSQL backups, TLS, secrets, health checks, and
  exactly one application instance.
- Make an explicit production endpoint and cost decision for Solana; its public endpoint has
  no SLA. Re-check Open-Meteo licensing before commercial or durable public use.
- Run provider smoke checks, one-source-at-a-time canaries, the 100-browser test, k6 profile,
  production image build, migration rehearsal, rollback rehearsal, and a real mobile audit.
- Configure the deployment environment, custom domain, monitoring, and public demo link only
  after the deployed revision and `/healthz` are verified.
- Preserve coarse, privacy-safe observability. Operational visibility must not expose the data
  the product promises to discard.

### 2. Learn from the first 30 days

Collect operational evidence before changing architecture:

- Provider uptime, reconnect behavior, quiet/stale duration, and contract drift.
- Database growth, query latency, timeline-window cost, and backup/restore evidence.
- Browser performance across modest phones, reduced-motion usage, touch completion, and archive
  comprehension—without visitor profiling.
- Which source grammars visitors can distinguish and whether the tapestry stays balanced.

Use this evidence to decide retention/compaction, dedicated provider plans, performance work,
and experience refinements. Do not design compaction or distribution from guesswork.

### 3. Deepen the public artifact

Good candidates after launch evidence include server-generated formation preview cards,
high-resolution still exports, stronger chapter storytelling, and carefully curated new public
signals. Each needs a separate design because it can affect privacy, storage, rendering
determinism, provider terms, accessibility, or abuse resistance.

Keep Worldloom contemplative. Accounts, competition, chat, scores, and engagement mechanics
are not automatic improvements and must not be smuggled in as routine feature work.

### 4. Scale only when measurements require it

If one instance becomes the proven constraint, design coordinator leadership, provider-owner
election, distributed deduplication, cross-node catch-up, PubSub, and Presence as one coherent
multi-node system. Never put the current release behind multiple active application writers.

### 5. Add sources through the full contract path

A new source is not just a worker. It needs official-contract research, licensing and privacy
review, bounded normalization, aggregation semantics, checkpoint/recovery rules, independent
health and rollback, fair-buffer behavior, a versioned instruction contract, non-color visual
grammar, deterministic fixtures, mobile/accessibility evidence, provider smoke coverage, and
operations documentation. Prefer diversity of meaning over raw event volume.

## Choosing between candidate tasks

Choose the task with the strongest answers to these questions:

1. What will a visitor perceive or an operator be able to prove afterward?
2. Is the need supported by production evidence, a failing test, or a clear launch blocker?
3. Which invariant could the change threaten, and what bounded test protects it?
4. Can it ship and roll back independently?
5. Does it preserve the calm artistic identity instead of merely adding activity?
6. What public claim, runbook, source contract, privacy text, or release evidence must change?

When two ideas are equal, prefer reliability and comprehension over novelty, and prefer the
smaller reversible change.

## Definition of done

A Worldloom change is done only when:

- The user-visible outcome and failure behavior are explicit.
- New behavior is covered at the lowest deterministic layer and at the real boundary when
  interaction, persistence, or transport is involved.
- Bounds, deterministic reconstruction, historical compatibility, and persist-before-broadcast
  still hold.
- Keyboard, touch, reduced motion, textual meaning, and responsive layout were considered.
- No private or raw provider value reaches storage, logs, telemetry, PubSub, HTML, or fixtures.
- Configuration, operations, privacy, source, README, and release documentation are current.
- The final relevant verification ladder passes on the exact diff.
- The commit message says what changed and why, the worktree is clean, and remote CI is checked
  after push when integration was requested.

The standard is not “more movement.” It is a more beautiful, truthful, resilient public loom.
