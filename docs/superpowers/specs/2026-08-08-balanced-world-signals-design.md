# Balanced World Signals Design

**Date:** 2026-08-08  
**Status:** Design approved; written specification pending review  
**Scope:** Diversify Worldloom's live public signals, repair source starvation in the visible weave, and preserve the project's deterministic, private, bounded architecture.

## Summary

Worldloom currently receives several real signals, but its one-second Wikimedia stream dominates the latest-event window and pushes earthquakes, weather, and visitor gestures offscreen within seconds. The renderer compounds the problem by assigning a minimum horizontal step to each Wikimedia event. The stored data is diverse; the live composition is not.

The approved **Balanced World** direction adds four public event families:

- Bluesky Jetstream public activity;
- RIPE RIS Live internet-routing changes;
- Solana slot progression; and
- drand Quicknet randomness rounds.

Together with Wikimedia, earthquakes, weather, and anonymous visitor gestures, they create a living view of human knowledge, public conversation, internet infrastructure, shared computation, physical events, planetary conditions, and participation in the artwork.

The design does not merely add feeds. It replaces sequence-distance layout at the live edge with a shared time axis, gives each source a structurally distinct visual language, and summarizes high-volume streams on staggered four-second beats. Under normal source availability, visitors should see several kinds of genuine world activity every few seconds without one source consuming the canvas or the database.

## Problem statement

The application currently loads the latest 400 events without considering source. Wikimedia normally emits about one durable event per second, while weather, earthquakes, and visitor gestures occur much less often. A recent local sample contained 398 Wikimedia events, one weather event, one visitor event, and no earthquake among the latest 400 rows.

The live geometry also advances at least four display units for every consecutive Wikimedia event. At the current scale, approximately twelve seconds of Wikimedia activity can occupy the visible width. Real weather, earthquake, and visitor events still exist in PostgreSQL but age offscreen almost immediately.

This violates Worldloom's intended experience: public signals are meant to remain distinguishable parts of one organism, not become invisible metadata behind a Wikimedia visualization.

## Goals

- Show a balanced cross-section of genuine public activity throughout the live experience.
- Introduce four dependable, machine-readable sources with complementary meanings.
- Preserve the artistic hierarchy: structural signals form the organism, weather shapes its atmosphere, and visitors leave meaningful interventions.
- Keep raw high-volume records out of PostgreSQL, PubSub, LiveView, logs, and browser payloads.
- Maintain persist-before-broadcast, deterministic reconstruction, stable sequence IDs, bounded queues, and source-independent failure recovery.
- Keep database growth predictable despite consuming streams that may deliver hundreds of messages per second.
- Make source health and meaning understandable without relying on color alone.
- Preserve historical navigation, formation selection, chapter permalinks, reduced motion, and semantic summaries.

## Non-goals

- No display or retention of Bluesky post text, handles, DIDs, record URIs, or links.
- No display or retention of raw BGP prefixes, peer identifiers, or routing payloads.
- No Solana transaction, wallet, token, price, or financial visualization.
- No social feed, moderation surface, blockchain explorer, network-monitoring tool, alerting system, or scientific dashboard.
- No fabricated activity when a source is quiet or unavailable.
- No browser-to-provider connections; the Worldloom server remains the only upstream client.
- No unbounded replay of missed stream data.
- No multi-node feed leadership or coordinator redesign in this scope.
- No claim that Worldloom cryptographically verifies drand signatures in this release.

## Sources

### Wikimedia EventStreams

Wikimedia remains the cool-cyan connective backbone. It continues to consume the public `recentchange` EventStream, but summarizes activity in four-second windows instead of emitting a durable row every second.

Each event retains only the existing aggregate concepts: total accepted changes, total absolute byte delta, up to five language-family counts, dominant edit type, window time, and a generated summary. The raw upstream event and all identity or page-level fields are discarded.

Source documentation: [Wikimedia EventStreams](https://www.mediawiki.org/wiki/EventStreams).

### Bluesky Jetstream

Bluesky adds the pulse of public conversation. Jetstream provides a public JSON WebSocket stream intended to make repository activity easier to consume than the full AT Protocol firehose.

Worldloom subscribes only to the collections needed to derive bounded activity categories. It may inspect an incoming record long enough to distinguish an original post from a reply, but it immediately discards record content and identifiers. A durable summary contains only allow-listed counts:

- total accepted operations;
- original posts;
- replies;
- reposts;
- likes;
- follows; and
- creates, updates, and deletes.

The visual payload stores counts and bounded ratios, never text or identity. The last accepted Jetstream timestamp cursor is checkpointed for bounded resume.

Source documentation: [Bluesky Jetstream](https://docs.bsky.app/blog/jetstream).

### RIPE RIS Live

RIPE RIS Live adds the movement of the public internet. Its unauthenticated WebSocket publishes BGP announcements and withdrawals collected by RIPE's routing collectors.

Worldloom reduces accepted messages to:

- announcement count;
- withdrawal count;
- IPv4 and IPv6 proportions;
- number of distinct collectors observed; and
- number of distinct peers observed.

Collector and peer identifiers may be counted in bounded worker-local sets during a window, but the identifiers themselves are discarded before persistence. Prefixes, AS paths, communities, and raw messages are never stored or broadcast.

RIS Live has no replay contract that Worldloom can treat as authoritative. A reconnect resumes from the live edge and never invents the missed interval.

Source documentation: [RIPE RIS Live manual](https://ris-live.ripe.net/manual/).

### Solana slot progression

Solana adds a precise computational rhythm. A configurable secure WebSocket endpoint receives `slotSubscribe` notifications. Worldloom observes consensus progression only; it does not request transactions, accounts, balances, wallets, tokens, or prices.

Each summary contains:

- accepted slot count;
- first and last slot;
- observed slot gaps;
- final root lag; and
- maximum root lag during the window.

Public Solana endpoints are suitable for light development and may enforce limits. Production configuration may use a compatible provider endpoint without changing Worldloom's event contract.

Source documentation: [Solana `slotSubscribe`](https://solana.com/docs/rpc/websocket/slotsubscribe) and [Solana public RPC guidance](https://www.solanakit.com/docs/guides/rpc-subscriptions).

### drand Quicknet

drand adds a pale crystalline pulse derived from public randomness. Quicknet publishes a new beacon round every three seconds. Worldloom polls the documented HTTPS endpoint with Req, validates the configured chain hash, monotonic round, expected field shapes, and timing bounds, then derives the durable render seed from the returned randomness.

The normalized payload contains the round number, chain identity, occurrence time, and a fixed summary. It does not retain the complete upstream response. The round number is the external ID and provides natural idempotency.

drand publishes cryptographically verifiable randomness, but Worldloom is an artwork rather than a beacon verifier. This release relies on HTTPS and structural validation and must not claim that it independently verifies the BLS signature.

Source documentation: [drand Quicknet](https://docs.drand.love/blog/2023/10/16/quicknet-is-live/).

## Durable event contract

The `loom_events` check constraints and `Worldloom.Loom.Event` allow lists gain four source-kind pairs:

| Source | Kind | External ID |
|---|---|---|
| `bluesky` | `public_activity` | four-second window end in UTC |
| `ripe_ris` | `route_change` | four-second window end in UTC |
| `solana` | `slot` | four-second window end in UTC |
| `drand` | `randomness` | Quicknet round number |

Wikimedia's external ID also becomes its four-second window end. Existing rows and permalinks remain unchanged. A migration replaces the database kind/source-pair constraint without rewriting historical events.

Every payload uses string keys, contains a server-authored summary of at most 160 characters, remains below the existing 16 KiB encoded limit, and passes a source-specific allow-list before it can enter the coordinator. Unknown keys, malformed numbers, excessive collection sizes, and non-finite values are rejected. Stream-window occurrence times are assigned by the server. Upstream timestamps are used only for protocol validation, ordering, and recovery; they cannot stretch the visual timeline.

The existing unique index on `(source, external_id)` provides idempotency. Sequence IDs remain the authoritative total order after persistence.

## Cadence and aggregation

Wikimedia, Bluesky, RIPE, and Solana are consumed continuously but summarized into non-overlapping four-second windows. Their window boundaries are offset against UTC:

| Boundary offset modulo four seconds | Source |
|---:|---|
| `0` | Wikimedia |
| `1` | Bluesky |
| `2` | RIPE RIS Live |
| `3` | Solana |

Each worker uses a monotonic timer for scheduling and a UTC boundary for the durable window identity. The event's `occurred_at` is the window end. A window describes activity observed by Worldloom during that interval; it does not reinterpret an arbitrary upstream timestamp as the publication beat.

This cadence normally contributes one different high-volume family each second while limiting each source to fifteen durable rows per minute. drand contributes its genuine three-second rounds independently. Earthquake, weather, and visitor events retain their real occurrence cadence.

A zero-count window does not create a `loom_events` row. When a resumable stream advanced during that interval, the worker still submits a checkpoint-only commit through the same coordinator transaction. A source outage therefore creates an honest visual gap without forcing already-consumed frames to replay. The interface reports the source's health state separately.

Decoded text frames are capped at 256 KiB. Category maps contain fixed allow-listed keys, numeric counters saturate at a 32-bit unsigned maximum, and RIPE's worker-local collector and peer sets stop accepting new members at 2,048 entries each. When a limit is reached, the aggregate records a bounded `truncated` flag; it never grows the collection or logs the discarded source material.

## Architecture and components

The existing signal path remains authoritative:

```text
Public provider -> source worker -> bounded normalizer/aggregator
-> Buffer -> Coordinator -> transaction -> PostgreSQL
-> PubSub -> LiveView -> topology -> geometry -> renderer
```

### WebSocket transport

A small reusable WebSocket transport wraps WebSockex. WebSockex is chosen because it fits OTP supervision and callback-driven reconnect behavior without requiring Worldloom to implement WebSocket framing, ping/pong handling, and Mint connection state itself.

The transport owns only connection mechanics and frame delivery. It does not know source payloads, aggregation rules, persistence, or visual meaning. Each source worker owns its subscription message, normalizer, checkpoint semantics, and health transitions.

WebSockex documentation: [hexdocs.pm/websockex](https://websockex.hexdocs.pm/).

### Source workers and aggregators

Each new stream has a dedicated supervised worker and a pure aggregator module. The aggregator accepts sanitized observations and emits either an updated bounded state, a completed summary, or an explicit drop reason. It has no network, database, process, or clock dependency.

The worker:

1. connects and subscribes;
2. parses frames with a maximum accepted byte size;
3. passes only validated fields to its aggregator;
4. flushes on its assigned boundary;
5. sends completed summaries and checkpoint metadata to the existing bounded buffer; and
6. reports contact, activity, drops, truncation, retry, and recovery through existing health telemetry.

drand uses a separate Req-based polling worker because it is an HTTP round feed, not a continuous WebSocket stream.

### Persistence and broadcast

All new summaries use `SourceEvent` and the existing Buffer, Coordinator, and Store transaction. Checkpoint advancement and event insertion remain atomic where the upstream protocol supplies a meaningful cursor. PubSub receives only rows returned by a successful transaction.

A feed failure cannot block visitor gestures or another source. No source worker writes directly to PostgreSQL or broadcasts directly to a LiveView.

## Checkpoints and recovery

- **Wikimedia:** persist the last accepted EventStreams cursor with the completed summary, retaining the existing bounded replay behavior.
- **Bluesky:** persist the maximum accepted Jetstream `time_us` cursor with the completed summary and request resume from that cursor after reconnect. Any provider-imposed resume limit is treated as a live gap, not backfilled fiction.
- **RIPE RIS Live:** record successful contact and summary-window metadata. Reconnect at the live edge; do not replay or synthesize the disconnected interval.
- **Solana:** record the last observed slot. After reconnect, subscribe to current progress and use the first returned slot to establish the new live edge. A forward gap is reported as a gap, not expanded into fabricated slots.
- **drand:** persist the last committed round. Fetch at most twenty missed rounds in ascending order; if more than one minute was missed, resume from the latest valid round and report the skipped span.

Each source has independent capped exponential backoff with jitter. A successful connection changes health to connected; a valid frame updates contact; a committed non-empty summary updates activity. These states must remain distinct so a connected but quiet source is not mislabeled healthy activity.

Wikimedia, Bluesky, RIPE, and Solana become quiet after twenty seconds without a valid observation while connected. A closed socket becomes disconnected immediately. drand becomes stale after twelve seconds without a valid new round. Existing USGS and Open-Meteo freshness thresholds remain unchanged.

## Live-window selection and memory

The live route no longer asks only for the latest 400 rows. A source-aware query returns:

- all authoritative events in the most recent 60 seconds, capped at the existing bounded instruction limit;
- the most recent weather event at or before the live edge;
- the most recent earthquake when no earthquake exists in the minute; and
- the latest three visitor gestures not already present in the minute.

The latter earthquake and visitor events are explicit **memory traces**. They remain real persisted events with their original sequence and occurrence time. They are marked as contextual memory in the server instruction, rendered with lower prominence, and remain selectable through the same trusted event map. They are not copied, re-sequenced, or passed through normal catch-up as if newly emitted.

Historical chapters and permalinks continue to use sequence-authoritative queries. A formation permalink must reconstruct the same event and surrounding context after this change.

## Temporal layout

The live canvas projects exactly sixty seconds across the usable width. Horizontal position is derived from normalized `occurred_at` within that window, not from a fixed step per database sequence. Events sharing a time boundary share a time column and separate through source-specific vertical and structural rules.

Sequence order resolves ties and remains authoritative for selection, cursor repair, history, and accessibility summaries. Time projection changes only geometry; it never changes database ordering or permalink identity.

The current unconditional minimum Wikimedia display step is removed. Sparse deterministic fixtures receive explicit timestamps during fixture construction and use the same production time projection; the geometry layer has no separate scaffold spacing mode.

Memory traces anchor inside a quiet contextual band rather than pretending to have occurred in the current minute. Weather continues to alter the whole atmospheric field based on its original observation and freshness.

## Visual language

Every family differs through topology, rhythm, texture, and text as well as color:

| Signal | Structural role | Material response |
|---|---|---|
| Wikimedia | Connective backbone | Cool cyan and verdigris strands with fine activity variation |
| Bluesky | Branching public conversation | Violet branching fans; reply and repost ratios shape divergence and return |
| RIPE RIS Live | Internet-route movement | Electric angular forks; announcements extend and withdrawals pinch inward |
| Solana | Computational cadence | Precise amber beads and short braids; slot gaps interrupt the rhythm |
| drand | Shared public pulse | Pale crystalline wave emitted on each real three-second round |
| Earthquake | Physical rupture | Ember scars, tension, and restrained rings |
| Weather | Planetary atmosphere | Moss-and-gold temperature, wind, precipitation, and daylight field |
| Visitor | Human intervention | Warm ivory bends, joins, and traveling illumination |

High source volume changes bounded local density, thickness, branching, or rhythm. It does not create an unbounded number of commands. The renderer retains its existing instruction, command, transition, pulse, and viewport-cache limits.

The legend names every source, explains its material behavior in plain language, and shows independent health. Semantic live summaries announce meaningful aggregates without producing a message for every raw upstream frame.

## Balance invariant

When all five high-cadence sources are connected and producing activity:

- every rolling ten-second live interval contains Wikimedia, Bluesky, RIPE, Solana, and drand events;
- no one family supplies more than 40 percent of primary visible marks; and
- all five remain structurally recognizable at desktop and mobile widths.

An unavailable or genuinely quiet source is exempt from the interval requirement and must be labeled honestly. The renderer does not duplicate another source to fill its place.

Earthquakes, weather, and visitor interventions remain contextual layers and do not enter the five-source quota. Their importance comes from persistence, contrast, and memory rather than artificial emission frequency.

## Privacy and security

The server, not the browser, contacts every provider. Content security policy and browser behavior must not expose visitor addresses to upstream sources.

Source adapters follow a deny-by-default contract:

- accept only documented message types and required fields;
- cap frame and decoded collection sizes before aggregation;
- convert categories through fixed allow lists rather than dynamic atoms;
- reject non-finite or out-of-range numeric values;
- never log raw frames, subscription cursors, identifiers, response bodies, or malformed payloads;
- never place upstream URLs or connection details in public health output; and
- discard raw values immediately after updating a bounded aggregate.

Bluesky content and identity, RIPE routing identifiers, and Solana account-level activity cannot appear in `loom_events`, PubSub instructions, rendered HTML, semantic summaries, telemetry metadata, or application logs.

Existing visitor privacy remains unchanged: no accounts, analytics SDK, free-form content, stable public identity, raw address persistence, or browser-to-source requests.

## Failure behavior

- One disconnected source leaves all other sources, visitor gestures, archive browsing, and `/healthz` operational.
- Reconnect attempts use capped exponential backoff with jitter and cannot form a tight crash loop.
- A malformed or oversized frame is dropped with a coarse reason counter; it does not crash the worker or leak content into logs.
- A full downstream buffer merges compatible summaries according to existing bounds. It never becomes unbounded.
- A database failure prevents checkpoint advancement and broadcast.
- Duplicate windows or rounds are harmless because persistence is idempotent.
- A source clock anomaly outside the accepted range is rejected rather than stretching the canvas.
- A stale weather event remains visible with stale labeling; missing high-cadence sources leave honest visual space.
- Unsupported renderer instructions produce finite fallback marks and preserve semantic text.
- Reduced-motion mode removes growth and pulses but preserves every source's settled structure and meaning.

`GET /healthz` remains limited to database and coordinator readiness. Feed health is degraded-mode status, not whole-application failure.

## Configuration and operations

Each source can be enabled independently. Secure diagnostic URL overrides remain server-side and are rejected unless they use the required `https` or `wss` scheme. Production defaults enable the approved sources, while `WORLDLOOM_FEEDS_ENABLED=false` still disables all external workers for deterministic tests and operational recovery.

Operations documentation will add source-specific freshness thresholds, retry telemetry, configuration names, attribution, and recovery procedures. It will also state the practical limitations of public endpoints and avoid promising uninterrupted delivery.

No production secret, API token, or paid provider is required by the design. If a future public deployment needs a commercial or authenticated endpoint for reliability, enabling cost-bearing infrastructure requires separate approval.

## Testing strategy

Behavioral implementation follows red-green-refactor. Tests exercise pure source boundaries directly and mock only external WebSocket/HTTP edges.

### Normalizer and aggregator tests

- Valid frames produce the exact source-specific allow-listed aggregate.
- Content, identities, prefixes, peers, wallets, accounts, and unknown keys cannot enter stored payloads.
- Oversized, malformed, unknown, late, and out-of-range frames are dropped without state corruption.
- Counters and distinct sets saturate at documented bounds and mark truncation.
- Empty windows emit no durable event.
- Four-second windows close on the assigned UTC offsets with deterministic external IDs.
- The same accepted observations produce the same aggregate regardless of frame chunking.

### Worker and recovery tests

- Subscription messages contain only the approved filters.
- Connection, valid contact, activity, quiet, stale, retry, and recovery are distinct health states.
- Backoff is capped and jittered.
- Bluesky resumes from its timestamp cursor.
- RIPE and Solana reconnect without fabricated replay.
- drand catches up missed rounds in order and respects its cap.
- Duplicate windows and rounds produce one stored row.
- A source crash or malformed frame does not stop sibling workers.

### Store and LiveView tests

- Source-kind constraints reject invalid pairings in both changeset and database.
- The live query returns the current minute plus the required weather, earthquake, and visitor context without duplicating rows.
- Catch-up and trusted selection maps retain sequence authority.
- Memory traces remain selectable and expose their original occurrence time.
- Source health and semantic summaries are accessible without canvas or color.
- Existing permalink and chapter reconstruction remains stable.

### Renderer tests

- A minute with overwhelming Wikimedia input still displays every active source family.
- Time-column projection is deterministic, finite, padded, and independent of database density.
- Events at the same boundary remain distinguishable.
- Each source has a non-color structural signature.
- The scaffold fallback cannot push live source events offscreen.
- Memory traces and ambient weather remain visually distinct from current structural events.
- Existing instruction, command, transition, and cache limits hold under worst-case aggregates.
- Reduced motion preserves settled source meaning without continuing animation.

### Browser and load tests

- Playwright verifies all source families, legend states, memory selection, mobile layout, accessibility, reconnect presentation, and reduced motion against deterministic feed-disabled fixtures.
- A two-browser test proves that newly committed summaries broadcast once and reconstruct after reload.
- A local 100-browser simulation confirms that browser count does not multiply upstream connections, source summaries remain visible, and LiveView stays responsive.
- The exact release candidate passes existing Elixir, JavaScript, browser, container, and CI checks.

## Documentation and attribution

`docs/data-sources.md`, `docs/privacy.md`, `docs/operations.md`, the About panel, and the README will describe the new sources in the same restrained language as the existing feeds. Each source receives a direct official attribution link and a clear statement that Worldloom presents an artistic aggregate, not an operational or financial interpretation.

The interface must call the streams by their source names. It must not imply endorsement by Wikimedia, Bluesky, RIPE NCC, Solana, or drand.

## Rollout

The feature lands behind independent source enablement so each collector can be disabled without reverting the renderer or schema. Feed-disabled deterministic mode remains the first verification environment.

The release order is:

1. extend and test the durable source contract;
2. add pure bounded aggregators;
3. add supervised transport workers and health states;
4. introduce source-aware live-window selection;
5. replace live sequence-distance geometry with time projection;
6. add the approved source materials, legend, and semantic summaries;
7. update privacy, operations, attribution, and public documentation; and
8. run complete browser, load, container, CI, and visual verification.

The new feeds are enabled publicly only after their privacy allow-list tests, reconnect tests, and source-balance acceptance fixture pass.

## Acceptance criteria

1. Wikimedia, Bluesky, RIPE RIS Live, Solana, and drand appear as distinct genuine signals under normal source availability.
2. Every rolling ten-second test window with all feeds active contains all five high-cadence families, and none exceeds 40 percent of primary marks.
3. A Wikimedia surge cannot push another current source, the latest earthquake, or the latest three visitor gestures out of the intended live composition.
4. Weather remains a clearly labeled atmosphere and never masquerades as a fresh structural event when stale.
5. No raw Bluesky content or identity, BGP routing identifier, or Solana account-level information reaches durable storage, logs, PubSub, or the browser.
6. The four stream summaries use staggered non-overlapping four-second windows; drand follows its real three-second rounds; empty windows create no event.
7. All collectors reconnect independently with bounded memory, bounded catch-up, idempotent persistence, and honest health state.
8. Sequence IDs remain authoritative for ordering, catch-up, selection, chapters, and permalinks.
9. The same persisted events produce the same topology and geometry across reloads and browsers.
10. Source meaning survives mobile layout, color-vision differences, missing canvas, and reduced-motion mode.
11. A 100-browser local simulation does not multiply upstream connections or destabilize event delivery.
12. `mix precommit`, JavaScript tests, Playwright tests, container build, final diff review, and GitHub CI all pass before integration into `master`.

## Deferred decisions

- Cryptographic BLS verification of drand beacons inside Worldloom.
- Authenticated or paid endpoints for any provider.
- Multi-node collector leadership and distributed deduplication.
- Alerting, analytics, dashboards, or source-specific historical exploration.
- Retention or compaction changes to append-only loom history.
- Additional event families beyond the approved balanced quartet.

Each deferred item requires separate design work or explicit authorization.
