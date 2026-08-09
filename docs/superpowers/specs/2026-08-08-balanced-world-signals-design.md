# Balanced World Signals Design

**Date:** 2026-08-08

**Status:** Architecture reviewed; revised specification awaiting user approval

**Scope:** Diversify Worldloom's live public signals, repair source starvation in the visible weave, and preserve the project's deterministic, private, bounded architecture.

## Summary

Worldloom currently receives several real signals, but its one-second Wikimedia stream dominates the latest-event window and pushes earthquakes, weather, and visitor gestures offscreen within seconds. The renderer compounds the problem by assigning a minimum horizontal step to each Wikimedia event. The stored data is diverse; the live composition is not.

The approved **Balanced World** direction adds four public event families:

- Bluesky Jetstream public activity;
- RIPE RIS Live internet-routing changes;
- Solana slot progression; and
- drand Quicknet randomness rounds.

Together with Wikimedia, earthquakes, weather, and anonymous visitor gestures, they create a living view of human knowledge, public conversation, internet infrastructure, shared computation, physical events, planetary conditions, and participation in the artwork.

The design does not merely add feeds. It first repairs projection independently of every new provider, then qualifies and introduces sources through reversible phases. The finished experience replaces sequence-distance layout at the live edge with a shared time axis, gives each source a structurally distinct visual language, and summarizes high-volume streams on staggered four-second beats. Under normal source availability, visitors should see several kinds of genuine world activity every few seconds without one source consuming the canvas or the database.

## Problem statement

The application currently loads the latest 400 committed rows without considering source. Wikimedia normally emits about one durable event per second, while weather, earthquakes, and visitor gestures occur much less often. Repeated local observations found that the latest-400 snapshot was almost entirely Wikimedia, although the exact minority rows changed as the live feed advanced.

The live geometry also advances at least four display units for every consecutive Wikimedia event. At the current scale, approximately twelve seconds of Wikimedia activity can occupy the visible width. Real weather, earthquake, and visitor events still exist in PostgreSQL but age offscreen almost immediately.

This violates Worldloom's intended experience: public signals are meant to remain distinguishable parts of one organism, not become invisible metadata behind a Wikimedia visualization. The projection and selection defect is corrected in the first phase and does not depend on any new provider succeeding.

## Goals

- Show a balanced cross-section of genuine public activity throughout the live experience.
- Qualify four complementary, machine-readable sources and degrade honestly when their best-effort public endpoints are unavailable.
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

Bluesky adds the pulse of public conversation. The deployed legacy Jetstream service provides a public JSON WebSocket stream intended to make repository activity easier to consume than the full AT Protocol firehose. It is suitable for informal visualizations, but it is not a stable AT Protocol API, does not authenticate its events, and has no production SLA. Worldloom pins the legacy subscribe contract behind a replaceable adapter and treats protocol drift as source unavailability rather than malformed activity.

Worldloom subscribes only to the collections needed to derive bounded activity categories. It may inspect an incoming record long enough to distinguish an original post from a reply, but it immediately discards record content and identifiers. A durable summary contains only allow-listed counts:

- total accepted operations;
- original posts;
- replies;
- reposts; and
- creates, updates, and deletes.

Limiting the subscription to post and repost collections keeps input volume and content exposure smaller than following likes and graph changes. The visual payload stores counts and bounded ratios, never text or identity. The maximum fully committed Jetstream `time_us` is checkpointed for best-effort bounded overlap-and-deduplicate resume.

Source documentation: [Bluesky Jetstream](https://docs.bsky.app/blog/jetstream), the [legacy implementation](https://github.com/bluesky-social/jetstream-legacy), and the [replacement project](https://github.com/bluesky-social/jetstream).

### RIPE RIS Live

RIPE RIS Live adds the movement of the public internet. Its unauthenticated WebSocket publishes BGP announcements and withdrawals collected by RIPE's routing collectors.

Worldloom subscribes only to `UPDATE` messages from a configured allow-list of at most four collectors, intersected with the server's current collector list. No match is a configuration failure; Worldloom never silently falls back to the full firehose. It reduces accepted messages to:

- announced-prefix count;
- withdrawn-prefix count;
- IPv4 and IPv6 proportions;
- number of distinct collectors observed; and
- number of distinct peers observed.

Counts are per prefix inside an UPDATE, not per WebSocket message. Collector and peer identifiers may be counted in bounded worker-local sets during a window, but the identifiers themselves are discarded before persistence. Prefixes, AS paths, communities, and raw messages are never stored or broadcast. `includeRaw` is always false. If Worldloom cannot consume promptly, RIS Live may close the connection; this is an expected degraded state.

RIS Live has no replay contract that Worldloom can treat as authoritative. A reconnect resumes from the live edge and never invents the missed interval.

Source documentation: [RIPE RIS Live manual](https://ris-live.ripe.net/manual/).

### Solana slot progression

Solana adds a precise computational rhythm. A configurable secure WebSocket endpoint receives the exact parameterless JSON-RPC `slotSubscribe` request and `slotNotification` responses. Worldloom observes consensus progression only; it does not request transactions, accounts, balances, wallets, tokens, or prices.

Each summary contains accepted slot count, first and last slot, observed forward slot gaps, and a `truncated` flag. Solana defines slot positions as unsigned 64-bit integers; Worldloom admits the non-negative JSON-safe subset through `9_007_199_254_740_991` so the durable number remains exact in the browser. Thirty-two-bit bounds apply only to aggregate counters. The adapter validates the notification's integer `slot`, `parent`, and `root` fields, then discards `parent` and `root`; this release does not publish a root-lag metric. Unknown account-, transaction-, wallet-, program-, or token-shaped fields are never retained. Duplicate and backward slot positions are dropped without changing state.

`gap_count` sums the missing positions between consecutive accepted observations, including the first accepted observation after a window boundary or reconnect when a previous slot is known. It never expands gaps into fabricated slot observations. `slot_count` and `gap_count` saturate independently at the unsigned 32-bit maximum and set `truncated` when either loses precision.

Official public Solana endpoints are suitable only for development: they are rate-limited, have no SLA, may block clients, and are explicitly not intended for production applications. The adapter and deterministic fixtures can be implemented without enabling the source publicly. Production Solana remains disabled until the owner explicitly approves a dedicated provider or self-hosted endpoint; changing endpoints does not change Worldloom's event contract.

Source documentation: [Solana `slotSubscribe`](https://solana.com/docs/rpc/websocket/slotsubscribe) and [Solana public RPC guidance](https://solana.com/docs/references/clusters).

### drand Quicknet

drand adds a pale crystalline pulse derived from public randomness. Quicknet publishes a new beacon round every three seconds. Worldloom pins drand API v2 and Quicknet chain hash `52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971`. At initialization it validates the chain-info response: `beacon_id == "quicknet"`, the exact chain hash, `period == 3`, a positive `genesis_time`, a 64-character hexadecimal `genesis_seed`, a 192-character hexadecimal `public_key`, and `scheme == "bls-unchained-g1-rfc9380"`.

A v2 round response contains a positive integer `round` and a 96-character hexadecimal `signature`. Worldloom decodes the 48 signature bytes, computes SHA-256, and uses the lowercase 64-character hexadecimal digest only as ephemeral render identity. The signature and complete response are then discarded. Worldloom races bounded concurrent Req calls to the three current v2-capable `drand.sh` relays and accepts the first structurally valid response.

The durable payload contains only the round number and fixed summary. `occurred_at` is computed as `genesis_time + (round - 1) * period`; the round is the external ID and provides natural idempotency. The fixed client contract identifies the source as Quicknet, so chain identity is not duplicated in every payload.

drand publishes cryptographically verifiable randomness, but Worldloom is an artwork rather than a beacon verifier. This release relies on HTTPS and structural validation. It does not verify the BLS signature and must not describe the derived digest as independently verified randomness.

Source documentation: [drand Quicknet](https://docs.drand.love/blog/2023/10/16/quicknet-is-live/), the [drand v2 HTTP API](https://docs.drand.love/developer/API-v2/drand-http-api/), and the [drand cryptography documentation](https://docs.drand.love/docs/cryptography/).

## Durable event contract

The `loom_events` check constraints and `Worldloom.Loom.Event` allow lists gain four source-kind pairs:

| Source | Kind | External ID |
|---|---|---|
| `bluesky` | `public_activity` | four-second window start in UTC plus fixed span |
| `ripe_ris` | `route_change` | four-second window start in UTC plus fixed span |
| `solana` | `slot` | four-second window start in UTC plus fixed span |
| `drand` | `randomness` | Quicknet round number |

Wikimedia's external ID also becomes its four-second window start plus the fixed span. Existing rows and permalinks remain unchanged. A migration adds the expanded kind/source constraint as a validated superset before removing the old constraint; it does not rewrite historical events. Application allow lists in `Event`, `SourceEvent`, `FeedCheckpoint`, `Instruction`, and source-specific payload validation change together.

Every payload uses string keys, contains a server-authored summary of at most 160 characters, remains below the existing 16 KiB encoded limit, and passes a source-specific allow-list before it can enter the coordinator. Unknown keys, malformed numbers, excessive collection sizes, and non-finite values are rejected. Occurrence time follows the source-specific event-time rules below: validated provider time where available, bounded server receipt time otherwise. Untrusted timestamps cannot bypass skew, replay, or lateness limits to stretch the visual timeline.

The existing unique index on `(source, external_id)` provides idempotency. Sequence IDs remain the authoritative total order after persistence.

### Versioned renderer input

The new source families require metrics that the current public instruction deliberately omits. Render version 2 adds a bounded, source-specific `metrics` map to the instruction projection. Existing version 1 rows continue through their current projection and are never rewritten. This explicitly supersedes the earlier Living Reliquary assumption that a new durable render contract would probably be unnecessary.

`contextual_memory` is not durable event truth. It is a presentation role derived by the live snapshot and carried in a separate `memory_events` collection. The same stored event can therefore be a faded memory at the live edge and a normal historical formation in its chapter without changing the row or its render version.

For drand, `VisualParameters` derives the version 2 seed from the SHA-256 digest of the decoded v2 signature rather than only the round-number external ID. The signature, digest, and complete upstream response are not persisted.

## Cadence and aggregation

Wikimedia, Bluesky, RIPE, and Solana are consumed continuously but summarized into non-overlapping four-second windows. Their window boundaries are offset against UTC:

| Boundary offset modulo four seconds | Source |
|---:|---|
| `0` | Wikimedia |
| `1` | Bluesky |
| `2` | RIPE RIS Live |
| `3` | Solana |

Each worker uses a monotonic timer for scheduling and a UTC boundary for the durable window identity. Wikimedia, Bluesky, and RIPE assign observations from their validated provider timestamps; Solana uses a once-captured server receipt time because `slotSubscribe` has no wall-clock field. The event's `occurred_at` is the window start, and the external ID includes that start plus the fixed span. A one-second grace period admits ordinary provider-time reordering. Solana cannot reorder by provider time, but may hold one bounded immediate-successor aggregate through the same close boundary. A non-empty elapsed frame requires the caller to close and durably submit the prior window before retrying that same sanitized frame, so commit failure cannot silently advance state.

This cadence targets one different high-volume family each second while limiting each source to fifteen normal durable rows per minute. Network and commit delay can change when a visitor sees the row; the stored event time does not change to disguise that delay. drand contributes its genuine three-second rounds independently. Earthquake, weather, and visitor events retain their real occurrence cadence.

A zero-count window does not create a `loom_events` row. When a resumable stream advanced during that interval, the worker still submits a checkpoint-only commit through the same coordinator transaction. A source outage therefore creates an honest visual gap without forcing already-consumed frames to replay. The interface reports the source's health state separately.

Complete decoded text frames larger than 256 KiB are rejected before JSON decoding. This is an application parsing limit, not a transport-allocation guarantee: WebSockex has already assembled the frame. Category maps contain fixed allow-listed keys, numeric counters saturate at a 32-bit unsigned maximum, and RIPE's worker-local collector and peer sets stop accepting new members at 2,048 entries each. JSON traversal, process heaps, and message queues receive explicit tested bounds. When a limit is reached, the aggregate records a bounded `truncated` flag; it never grows the collection or logs the discarded source material.

## Architecture and components

The existing signal path remains authoritative:

```text
Public provider -> source worker -> bounded normalizer/aggregator
-> Buffer -> Coordinator -> transaction -> PostgreSQL
-> PubSub -> LiveView -> topology -> geometry -> renderer
```

### WebSocket transport

A source-specific supervised process uses WebSockex for each WebSocket feed. WebSockex is chosen because it fits OTP supervision and callback-driven reconnect behavior without requiring Worldloom to implement WebSocket framing, ping/pong handling, and Mint connection state itself.

The WebSockex process owns connection, subscription, bounded synchronous frame handling, aggregation state, and reconnect timing for exactly one source. Pure normalizer and aggregator modules remain independent of that process. This avoids an ordinary `send/2` handoff and its unbounded mailbox. Reconnect delay blocks only that source process.

WebSockex has no documented transport-level maximum-frame option and emits raw received frames in its own telemetry event metadata. Worldloom does not attach handlers, loggers, or exporters to raw WebSockex frame events, and an automated privacy test enforces that application telemetry observes only Worldloom's coarse derived events. Cursors embedded in connection URLs are redacted before logging. These are explicit dependency constraints, not claims that raw bytes never exist transiently in process memory.

WebSockex documentation: [hexdocs.pm/websockex](https://websockex.hexdocs.pm/).

### Source workers and aggregators

Each new stream has a dedicated supervised worker and a pure aggregator module. The aggregator accepts sanitized observations and emits either an updated bounded state, a completed summary, or an explicit drop reason. It has no network, database, process, or clock dependency.

The worker:

1. connects and subscribes;
2. rejects complete frames above the application parsing limit;
3. passes only validated fields to its aggregator;
4. flushes on its assigned boundary;
5. sends completed summaries and checkpoint metadata to the existing bounded buffer; and
6. reports contact, activity, drops, truncation, retry, and recovery through existing health telemetry.

drand uses a separate Req-based polling worker because it is an HTTP round feed, not a continuous WebSocket stream.

### Persistence and broadcast

All new summaries use `SourceEvent` and the existing Buffer, Coordinator, and Store transaction. Checkpoint advancement and event insertion remain atomic where the upstream protocol supplies a meaningful cursor. PubSub receives only rows returned by a successful transaction.

The Buffer changes from one retrying FIFO to fair per-source partitions drained round-robin within one global bound. A failing source can delay its own partition but cannot hold the head of every other source. No source worker writes directly to PostgreSQL or broadcasts directly to a LiveView.

Under pressure, Wikimedia, Bluesky, RIPE, and Solana may combine adjacent pending summaries through source-specific associative reducers. The result declares its actual `window_count` and `window_span_seconds`; it is never mislabeled a normal four-second window. drand rounds never merge. They remain in a bounded twenty-round recovery queue, after which skipped rounds are reported honestly. Every new source receives an explicit `Merger` implementation so queue pressure cannot trigger the current unsupported-source pattern-match crash.

## Checkpoints and recovery

- **Wikimedia:** persist the last accepted EventStreams cursor with the completed summary. Reconnect with `Last-Event-ID`, but accept at most sixty seconds of replay before moving to the live edge and reporting a gap.
- **Bluesky:** persist the maximum fully committed Jetstream `time_us`. Reconnect with `cursor = max(0, committed_cursor - 5_000_000)`, discard observations at or before the committed cursor, and use bounded transient fingerprints to deduplicate overlap in the open window. A missing or future cursor starts at the live tail. Public replay is best-effort and only roughly transferable between legacy instances; Worldloom accepts at most sixty seconds before reporting a gap and returning to the live edge.
- **RIPE RIS Live:** record successful contact and summary-window metadata. Reconnect at the live edge; do not replay or synthesize the disconnected interval.
- **Solana:** record the last observed slot. After reconnect, subscribe to current progress and use the first returned slot to establish the new live edge. If a previous slot is known, a forward jump contributes to the next summary's gap count; it is never expanded into fabricated slots. A duplicate or backward first position is dropped while the adapter waits for newer progress.
- **drand:** persist the last committed round. Fetch at most twenty missed rounds in ascending order; if more than one minute was missed, resume from the latest valid round and report the skipped span.

Recovery observations keep their validated provider occurrence time. A newly persisted recovery row older than the current primary window advances the global commit watermark but is classified as historical recovery and is not appended to the current display. Cursor overlap, deduplication, lateness, replay cap, and checkpoint advancement are tested together for each replayable source.

Each source has independent capped exponential backoff with jitter. A new ephemeral health registry records connection, valid contact, committed activity, dropped or merged windows, recovery, and retry state. Persisted checkpoints remain recovery positions rather than being overloaded as immediate connection status. These states must remain distinct so a connected but quiet source is not mislabeled healthy activity.

Wikimedia, Bluesky, RIPE, and Solana become quiet after twenty seconds without a valid observation while connected. A closed socket becomes disconnected immediately. drand becomes stale after twelve seconds without a valid new round. Existing USGS and Open-Meteo freshness thresholds remain unchanged.

## Live-window selection and memory

The live route no longer treats its visible rows as the sequence ledger. It loads a versioned snapshot containing:

- `window_end`, the server-selected event-time anchor;
- `commit_watermark`, the highest committed database sequence whether displayed or not;
- `display_events`, primary events in `[window_end - 60 seconds, window_end]`;
- `memory_events`, contextual earthquake and visitor instructions outside that interval; and
- `ambient`, the latest weather instruction and its freshness.

On initial load, `window_end` is the latest occurrence time eligible for primary display, truncated to a UTC second. It advances monotonically when a newly committed non-recovery event has a later occurrence time. It never uses the browser clock and never moves backward. During a total activity outage the artwork freezes while source health reports the outage; a late recovery row cannot drag the live axis backward.

If more than 600 primary candidates occupy the minute, selection uses deterministic source round-robin over newest-per-source queues, followed by stable `(occurred_at, sequence)` ordering. No source contributes more than 240 of the 600 primary anchors. Selection and pruning happen before topology construction; hidden rows are not merely projected offscreen.

The most recent earthquake and latest three visitor gestures become explicit **memory traces** only when absent from the minute and no more than 24 hours old. They remain real persisted events with their original sequence and occurrence time. They are sent in `memory_events`, rendered with lower prominence, and remain selectable through the same trusted event map. They are not copied, re-sequenced, included in the primary quota, or passed through catch-up as if newly emitted.

Display-set omissions are not sequence gaps. Normal consecutive commits advance `commit_watermark` and either update the display, replace contextual memory, or remain history-only. If the next observed sequence skips the watermark, the server reprojects a complete snapshot at the new authoritative watermark instead of blindly appending every intervening row to the primary display.

Historical chapters and permalinks continue to use sequence-authoritative queries. A formation permalink must reconstruct the same event and surrounding context after this change.

## Temporal layout

The live canvas projects exactly sixty seconds across the usable width using the snapshot's `window_end`. Horizontal position is derived from normalized `occurred_at`, not from a fixed step per database sequence. Events sharing a time boundary share a time column and separate through source-specific vertical and structural rules. The same complete snapshot envelope always produces the same topology and geometry.

Sequence order resolves ties and remains authoritative for selection, cursor repair, history, and accessibility summaries. Time projection changes only geometry; it never changes database ordering or permalink identity.

The current unconditional minimum Wikimedia display step is removed. Sparse deterministic fixtures receive explicit timestamps during fixture construction and use the same production time projection; the geometry layer has no separate scaffold spacing mode.

Older history continues linearly to the left on the same event-time scale and is loaded in bounded pages as a visitor pans. Memory traces anchor inside a quiet contextual band rather than pretending to have occurred in the current minute. When their real historical page is loaded, they render there as normal events rather than duplicate contextual copies. Weather continues to alter the whole atmospheric field based on its original observation and freshness.

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

## Balance target

In deterministic acceptance fixtures where Wikimedia, Bluesky, RIPE, Solana, and drand produce every scheduled window:

- every rolling ten-second event-time interval contains all five families;
- no family supplies more than 40 percent of durable primary anchors; and
- all five remain structurally recognizable in named desktop, tablet, and mobile snapshots.

This is not a wall-clock availability guarantee. In production, eligible sources are those reporting valid activity and healthy enough to meet their cadence. Over a rolling five-minute observation, at least 95 percent of eligible ten-second event-time intervals should contain each eligible scheduled source. Missing, delayed, or recovering activity is measured and reported; the renderer never fabricates a mark to satisfy the target.

Earthquakes, weather, and visitor interventions remain contextual layers and do not enter the five-source quota. Their importance comes from persistence, contrast, and memory rather than artificial emission frequency.

## Privacy and security

The server, not the browser, contacts every provider. Content security policy and browser behavior must not expose visitor addresses to upstream sources.

Source adapters follow a deny-by-default contract:

- accept only documented message types and required fields;
- reject complete frames above the parsing cap and bound decoded collection traversal before aggregation;
- convert categories through fixed allow lists rather than dynamic atoms;
- reject non-finite or out-of-range numeric values;
- never send raw frames, subscription cursors, identifiers, response bodies, or malformed payloads to Worldloom-owned logs or exported telemetry;
- never place upstream URLs or connection details in public health output; and
- discard raw values immediately after updating a bounded aggregate.

Bluesky content and identity, RIPE routing identifiers, and Solana account-level activity cannot appear in `loom_events`, PubSub instructions, rendered HTML, semantic summaries, Worldloom telemetry, or application logs. WebSockex's internal raw-frame telemetry events remain handler-free; this constraint is covered by an automated attachment test and documented for future observability work.

Per-source processes enforce a tested mailbox ceiling and terminate cleanly on sustained overload. A process heap ceiling limits damage from an unexpectedly large assembled frame, but the threat model remains explicit: the 256 KiB application check occurs after WebSockex allocates the complete frame. Eliminating that transient allocation would require a separately reviewed lower-level transport.

Existing visitor privacy remains unchanged: no accounts, analytics SDK, free-form content, stable public identity, raw address persistence, or browser-to-source requests.

## Failure behavior

- One disconnected source leaves all other sources, visitor gestures, archive browsing, and `/healthz` operational.
- Reconnect attempts use capped exponential backoff with jitter and cannot form a tight crash loop.
- A malformed or oversized frame is dropped with a coarse reason counter; it does not crash the worker or leak content into logs.
- A full downstream buffer applies the documented source-specific reducer or bounded drand recovery policy. Fair draining prevents one retrying source from holding every other partition.
- A database failure prevents checkpoint advancement and broadcast.
- Duplicate windows or rounds are harmless because persistence is idempotent.
- A provider timestamp anomaly outside the source's documented skew and replay bounds is rejected rather than stretching the canvas.
- A stale weather event remains visible with stale labeling; missing high-cadence sources leave honest visual space.
- Unsupported renderer instructions produce finite fallback marks and preserve semantic text.
- Reduced-motion mode removes growth and pulses but preserves every source's settled structure and meaning.

`GET /healthz` remains limited to database and coordinator readiness. Feed health is degraded-mode status, not whole-application failure.

## Configuration and operations

Each source can be enabled independently. Secure diagnostic URL overrides remain server-side and are rejected unless they use the required `https` or `wss` scheme. All new sources default off in production and move through one-source canaries after qualification. `WORLDLOOM_FEEDS_ENABLED=false` still disables every external worker for deterministic tests and operational recovery.

Operations documentation will add source-specific freshness thresholds, retry telemetry, configuration names, attribution, and recovery procedures. It will also state the practical limitations of public endpoints and avoid promising uninterrupted delivery.

Wikimedia, the legacy Bluesky public instances, RIPE, and drand require no production secret for the proposed best-effort artwork. Solana production enablement explicitly requires a separate endpoint and cost decision. Any authenticated, paid, or self-hosted provider requires explicit approval before configuration or activation.

## Testing strategy

Behavioral implementation follows red-green-refactor. Tests exercise pure source boundaries directly and mock only external WebSocket/HTTP edges.

### Normalizer and aggregator tests

- Valid frames produce the exact source-specific allow-listed aggregate.
- Content, identities, prefixes, peers, wallets, accounts, and unknown keys cannot enter stored payloads.
- Oversized, malformed, unknown, late, and out-of-range frames are dropped without state corruption.
- Counters and distinct sets saturate at documented bounds and mark truncation.
- Empty windows emit no durable event.
- Four-second windows close on the assigned UTC offsets with deterministic external IDs.
- Provider-time observations, one-second lateness, replay overlap, and history-only recovery classification are deterministic.
- Pressure reducers disclose multi-window spans and remain associative; drand never merges.
- The same accepted observations produce the same aggregate regardless of frame chunking.

### Worker and recovery tests

- Subscription messages contain only the approved filters.
- Connection, valid contact, activity, quiet, stale, retry, and recovery are distinct health states.
- Backoff is capped and jittered.
- Wikimedia and Bluesky resume with their specified overlap, deduplication, and replay caps.
- RIPE and Solana reconnect without fabricated replay.
- drand catches up missed rounds in order and respects its cap.
- Duplicate windows and rounds produce one stored row.
- A source crash or malformed frame does not stop sibling workers.
- Slow consumers, forced provider reconnects, oversized fragmented messages, mailbox pressure, process-heap limits, and database outages produce bounded degradation.
- No Worldloom handler attaches to raw WebSockex frame telemetry, and URL cursors never reach application logs.
- Provider contract smoke tests run on a schedule outside deterministic CI and report drift without making pull requests flaky.

### Store and LiveView tests

- Source-kind constraints reject invalid pairings in both changeset and database.
- Old rows survive the additive constraint migration and version 1 instructions remain renderable.
- The live snapshot returns explicit `window_end`, `commit_watermark`, primary display, memory, and ambient fields without duplicating rows.
- A display omission does not trigger gap repair; a real commit gap causes full snapshot reprojection.
- Late historical recovery advances the watermark without re-entering the primary minute.
- Deterministic round-robin selection respects 600 total and 240-per-source bounds.
- Trusted selection maps retain sequence authority across both primary and memory layers.
- Memory traces remain selectable and expose their original occurrence time.
- Source health and semantic summaries are accessible without canvas or color.
- Existing permalink and chapter reconstruction remains stable.

### Renderer tests

- Named balanced, Wikimedia-surge, delayed-recovery, total-outage, and memory-expiry fixtures cover the full snapshot contract.
- A minute with overwhelming Wikimedia input still displays every eligible active source family.
- Time-column projection is deterministic for a complete snapshot envelope, finite, padded, and independent of database density.
- Events at the same boundary remain distinguishable.
- Each source has a non-color structural signature.
- No scaffold-only spacing path can push live source events offscreen.
- Memory traces and ambient weather remain visually distinct from current structural events.
- Existing instruction, command, transition, and cache limits hold under worst-case aggregates.
- Reduced motion preserves settled source meaning without continuing animation.

### Browser and load tests

- Playwright verifies all source families, legend states, memory selection, mobile layout, accessibility, reconnect presentation, and reduced motion against deterministic feed-disabled fixtures.
- A two-browser test proves that newly committed summaries broadcast once and reconstruct after reload.
- A local instrumented fake upstream counts connections and subscriptions while 100 browsers connect, proving that browser count does not multiply upstream connections.
- The same load run exercises real summary broadcasts, snapshot reprojection, and LiveView responsiveness rather than disabling every feed.
- The exact release candidate passes existing Elixir, JavaScript, browser, container, dependency-audit, and CI checks.

## Documentation and attribution

`docs/data-sources.md`, `docs/privacy.md`, `docs/operations.md`, the About panel, and the README will describe the new sources in the same restrained language as the existing feeds. Each source receives a direct official attribution link and a clear statement that Worldloom presents an artistic aggregate, not an operational or financial interpretation.

The interface must call the streams by their source names. It must not imply endorsement by Wikimedia, Bluesky, RIPE NCC, Solana, or drand.

## Rollout

This work is too broad for one coupled implementation gate. It is divided into independently reviewable phases:

1. **Projection foundation:** introduce the deterministic snapshot envelope, separate `commit_watermark` from visible rows, remove Wikimedia-only minimum spacing, and reproject rather than append after a real gap. This phase fixes the reported defect with no new provider.
2. **Contract migration:** add render version 2 metrics, the separate memory layer, old-row compatibility, expanded source/checkpoint allow lists, and four-second Wikimedia windows.
3. **Provider qualification:** prove the pinned legacy Jetstream contract, bounded RIPE collector subscription and load, drand v2 failover and seed derivation, and the Solana adapter against development infrastructure. No provider is production-enabled in this phase.
4. **Transport and health:** add the supervised WebSockex workers, handler-free raw telemetry policy, bounded process behavior, ephemeral health registry, fair per-source buffering, and pressure reducers.
5. **Incremental sources:** enable drand first, then Bluesky and RIPE one at a time through independently reversible canaries. Solana remains disabled until its production endpoint is separately approved.
6. **Balanced visual release:** add the complete source materials, legend, semantic summaries, deterministic balance fixtures, provider-aware documentation, and instrumented 100-browser verification.

Every phase receives its own red-green tests, diff review, and clean `mix precommit`. Public source enablement additionally requires its privacy, reconnect, drift-smoke, and canary evidence.

The release gate adds `mix hex.audit`. The current lock reports the medium-severity Postgrex `:comment` advisory; implementation planning must either upgrade to a fixed release or document and verify a temporary non-reachability mitigation. The advisory cannot be silently accepted for a public release.

## Acceptance criteria

1. Wikimedia, Bluesky, RIPE RIS Live, Solana, and drand render as distinct genuine signals in deterministic qualification fixtures; publicly enabled sources additionally pass their canary gates.
2. Every rolling ten-second event-time fixture window with all five feeds scheduled contains all five families, and none exceeds 40 percent of durable primary anchors.
3. A Wikimedia surge cannot push another current source, an eligible earthquake memory, or the latest three eligible visitor memories out of the intended live composition.
4. Weather remains a clearly labeled atmosphere and never masquerades as a fresh structural event when stale.
5. No raw Bluesky content or identity, BGP routing identifier, or Solana account-level information reaches durable storage, Worldloom-owned logs or telemetry, PubSub, or the browser.
6. Normal stream summaries use staggered non-overlapping four-second windows; pressure summaries disclose their longer span; drand follows real three-second rounds; empty windows create no event.
7. Every collector reconnects with bounded replay and honest health, while fair buffering prevents one retrying source from holding every other source behind it.
8. Sequence IDs remain authoritative for commit ordering, loss detection, selection, chapters, and permalinks; display omissions never count as sequence loss.
9. The same complete snapshot envelope produces the same topology and geometry across reloads and browsers; version 1 rows remain compatible.
10. Source meaning survives mobile layout, color-vision differences, missing canvas, and reduced-motion mode.
11. An instrumented 100-browser local simulation observes one upstream subscription per enabled source and does not destabilize event delivery.
12. `mix precommit`, `mix hex.audit` or an approved verified mitigation, JavaScript tests, Playwright tests, container build, final diff review, and GitHub CI all pass before integration into `master`.

## Deferred decisions

- Cryptographic BLS verification of drand beacons inside Worldloom.
- Solana's production RPC provider or self-hosting decision.
- Authenticated or paid endpoints for any other provider.
- Multi-node collector leadership and distributed deduplication.
- Alerting, analytics, dashboards, or source-specific historical exploration.
- Retention or compaction changes to append-only loom history.
- Additional event families beyond the approved balanced quartet.

Each deferred item requires separate design work or explicit authorization.
