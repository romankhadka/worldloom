# Worldloom Design

Date: 2026-08-03
Status: Design approved

## Summary

Worldloom is a public, persistent, collaborative artwork built with Elixir and Phoenix. A continuous horizontal fabric is woven in real time from Wikimedia activity, earthquakes, global weather, and constrained anonymous visitor gestures. The current moment appears at the right-hand “live edge”; visitors can scroll left through earlier hours and dated UTC chapters.

The project exists primarily as a polished showcase of Phoenix, LiveView, OTP, PubSub, Presence, and supervision. It should also be strange, immediately understandable, visually memorable, and easy to share. The first public release is scoped to roughly two or three weeks of focused work.

## Goals

- Demonstrate a real-time system that feels native to Elixir rather than like conventional CRUD.
- Let strangers shape one persistent artifact together without registration.
- Translate real public signals into a coherent visual language instead of a dashboard.
- Produce interesting moments that can be shared with stable permalinks.
- Remain safe to expose publicly without requiring a moderation team.
- Ship a polished, accessible desktop and mobile experience from the existing public repository.

## Non-goals

- Accounts, profiles, follows, chat, comments, free-form text, uploads, or custom colors.
- A scientifically precise data-analysis or alerting tool.
- A game with scores, inventories, progression, or competitive mechanics.
- Redis, Kafka, Oban, distributed coordination, or multi-region operation in the first release.
- A native mobile application.
- Commercial use of upstream data in the first release.

## Product experience

### The continuous fabric

Worldloom presents one continuous horizontal fabric. The right edge is being woven now. Scrolling left reveals earlier events. At midnight UTC, a subtle seam marks a new dated chapter without resetting the tapestry.

The default route opens at the live edge. `/chapters/:date/:sequence` opens a stable historical position centered on the specified event sequence. The archive lists daily UTC chapters and returns visitors to the same continuous browsing surface rather than a separate gallery.

The canvas begins responding to live signals within five seconds of loading. A compact legend explains the four signal families. Hovering, focusing, or tapping a formation reveals its source, time, and human-readable summary. The interface never exposes raw upstream payloads.

### Anonymous visitor gestures

Every visitor can contribute immediately through three allow-listed gestures:

- **Tug** bends nearby fibers.
- **Knot** joins two nearby strands.
- **Illuminate** makes a small region glow.

A visitor at the live edge chooses a gesture and a normalized vertical lane. The horizontal position always comes from the committed event sequence, so visitors can shape the present but cannot rewrite earlier chapters. Historical views disable the gesture dock and offer a “Return live” action. The server validates the gesture, derives deterministic visual parameters, persists the event, and broadcasts it. Each signed anonymous browser identity may contribute once every 30 seconds.

Active visitors appear only as faint pulses along the live edge and as an aggregate viewer count. Worldloom has no avatars, cursors, names, or chat.

### Sharing

Selecting any woven formation creates a permalink using its UTC chapter and nearest event sequence. A shared link reconstructs the same local topology even after renderer changes by honoring the stored render version and visual parameters.

The first release supports link sharing without custom per-event social preview images. Server-generated previews are deferred until after launch.

## Visual direction

The approved direction is **Living Fiber**: warm, tactile, bioluminescent strands that suggest roots, nerves, and mycelium. The experience is immersive and atmospheric, not dashboard-like.

Signal families have stable palette roles:

| Signal | Visual role | Palette |
|---|---|---|
| Wikimedia | Fine connective fibers | Cyan |
| Earthquakes | Knots and tension ripples scaled by magnitude | Ember |
| Weather | Motion, density, and ambient shifts | Moss and gold |
| Visitors | Tugs, joins, and points of light | Warm ivory |

The canvas fills the viewport. A quiet header contains the wordmark, chapter, viewer count, archive, about, and share actions. A centered bottom dock contains the three visitor gestures and cooldown state. The legend sits near the lower edge, and the timeline remains secondary to the artwork.

Mobile keeps the full-screen canvas but reduces chrome to the wordmark, viewer count, and a three-action bottom dock. Signal detail opens as a small sheet. Desktop-only hover behavior always has focus and tap equivalents.

## External signals

### Wikimedia

The [Wikimedia EventStreams recent-change stream](https://wikitech.wikimedia.org/wiki/Event_Platform/EventStreams_HTTP_Service) supplies continuous internet activity over server-sent events. Raw edits are summarized into one-second buckets containing counts, language distribution, and total change intensity. Worldloom does not persist usernames, IP addresses, titles, or raw edit payloads.

### USGS

The [USGS GeoJSON earthquake feed](https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php) is polled once per minute. Each new earthquake becomes an individual event. Magnitude drives knot size and ripple intensity; location is retained only at the precision already present in the public feed.

### Open-Meteo

The [Open-Meteo forecast API](https://open-meteo.com/en/docs) is queried every ten minutes for fixed coordinates centered on Vancouver, Mexico City, São Paulo, Reykjavík, London, Lagos, Nairobi, Cape Town, Mumbai, Singapore, Tokyo, and Sydney. Temperature, precipitation, wind, and day/night are combined into one ambient weather event. Open-Meteo attribution appears in the About view. Its free non-commercial tier requires no API key; commercial use requires a licensing review and likely a paid plan.

### Visible-rate limit

The loom displays at most four new signal events per second. Excess source activity is merged into stronger aggregate fibers rather than queued indefinitely. Visitor gestures are never silently merged.

## Technical foundation

The existing generated application is upgraded within the current stable release lines:

- Elixir 1.20
- Phoenix 1.8
- Phoenix LiveView 1.2
- Ecto and PostgreSQL
- Req for all external HTTP access
- Canvas 2D for fiber rendering

As of the design date, Hex lists [Phoenix 1.8.9](https://hex.pm/packages/phoenix) and [LiveView 1.2.8](https://hex.pm/packages/phoenix_live_view). Exact lockfile versions are resolved during implementation.

## Architecture

OTP owns the authoritative loom; browsers draw it.

### `Worldloom.Signals.WikimediaWorker`

Maintains the Wikimedia SSE connection, restores its cursor after restart, aggregates accepted changes into one-second buckets, and submits normalized source events. It depends on Req and the feed checkpoint store.

### `Worldloom.Signals.EarthquakeWorker`

Polls the USGS feed once per minute, honors response caching metadata, identifies unseen earthquakes, and submits normalized source events. It depends on Req and the feed checkpoint store.

### `Worldloom.Signals.WeatherWorker`

Polls all fixed anchor coordinates in one batched request every ten minutes, derives the ambient weather state, and submits one normalized source event. It depends on Req and the feed checkpoint store.

### `Worldloom.Signals.Normalizer`

A pure module that converts each upstream shape into a single internal source-event representation. It performs bounds checks and drops fields the application does not need. It has no database or network dependency.

### `Worldloom.Loom.Coordinator`

A single supervised GenServer sequences normalized source events and accepted visitor gestures. It assigns deterministic visual parameters, persists each `LoomEvent`, and broadcasts the committed event through Phoenix PubSub. It never renders frames and never keeps historical chapters in memory.

The first release runs one application instance, so a single local coordinator is authoritative. Multi-node leadership is explicitly deferred.

### `Worldloom.Loom.GesturePolicy`

Validates the signed anonymous identity, gesture allow-list, vertical-lane bounds, live-edge state, 30-second identity cooldown, and coarse IP token bucket. Accepted gestures are handed to the coordinator. It depends on an ETS rate-limit table but does not persist raw or hashed IP addresses.

### `WorldloomWeb.WorldLive`

Loads a bounded historical window, subscribes to the live topic, tracks aggregate Presence, handles archive and permalink navigation, and exchanges compact drawing instructions with the renderer hook. It does not contain ingestion, persistence, or geometry rules.

### Canvas renderer hook

The browser owns animation, panning, hover/focus inspection, responsive projection, and drawing at display refresh rate. It receives small deterministic event instructions rather than server-rendered animation frames. Rendering calculations are isolated from DOM and LiveView plumbing so they can be tested as pure JavaScript.

## Data model

### `loom_events`

An append-only table containing:

- `id`: monotonic bigint primary key and global event sequence.
- `kind`: source signal or one of the three visitor gestures.
- `source`: `wikimedia`, `usgs`, `open_meteo`, or `visitor`.
- `external_id`: source-specific idempotency key; null only for visitor gestures.
- `occurred_at`: upstream occurrence time or server acceptance time.
- `render_version`: integer selecting the historical rendering contract.
- `render_seed`: deterministic integer seed.
- `lane`: normalized vertical lane independent of viewport dimensions.
- `intensity`: bounded numeric visual intensity.
- `payload`: small, allow-listed JSON metadata used by details and rendering.
- `inserted_at`: database insertion time. Rows are never updated.

A partial unique index on `(source, external_id)` where `external_id` is not null prevents duplicate upstream events. Indexes on `occurred_at` and `id` support chapter and catch-up queries. UTC chapters are date-range queries; they do not require a separate table in the first release.

Visitor identity and IP data are not stored in `loom_events`.

### `feed_checkpoints`

One row per external source stores its resumable cursor or ETag, last successful contact time, and small allow-listed checkpoint metadata. A successful contact always advances `last_successful_at`. Cursor or ETag changes are committed in the same transaction as any newly accepted source events, so checkpoints never move past undurable events.

## Event flow

### External signal

1. A supervised worker receives or polls upstream data.
2. The normalizer converts it into an internal source event and drops unnecessary fields.
3. The coordinator deduplicates, sequences, derives visual parameters, and inserts a `loom_events` row.
4. After commit, the coordinator broadcasts the stored event through PubSub.
5. Subscribed LiveViews push the compact instruction to their renderer hooks.
6. Each browser animates the same topology at its own resolution.

### Visitor gesture

1. At the live edge, the renderer sends the selected gesture and normalized vertical lane to the LiveView.
2. The gesture policy validates identity, cooldown, rate, gesture, lane bounds, and live-edge state.
3. The coordinator persists and broadcasts the gesture through the same event path.
4. Every connected client, including the sender, renders the committed event.

### Reconnect and history

Each client tracks the highest sequence received. A new connection requests a bounded window ending at the live sequence. If a connected client observes a sequence gap, it requests the missing range before applying later events. Historical navigation requests bounded ranges by sequence or UTC time; the server never assigns an unbounded event list to a LiveView.

## Failure handling and backpressure

- Feed workers are independently supervised. One failed source cannot stop the coordinator or other feeds.
- Retries use exponential backoff with jitter, capped at five minutes.
- Wikimedia is marked quiet after 60 seconds without accepted data, USGS after three minutes, and weather after 30 minutes.
- A quiet source gains a subtle status in the legend. Weather holds its last known state with a stale marker. Worldloom never fabricates substitute data.
- If every external source is unavailable, visitor gestures and historical browsing continue.
- An event is broadcast only after it commits. A coordinator crash between commit and broadcast is repaired when clients detect a sequence gap.
- The coordinator recovers from the highest stored event sequence after restart. Deterministic rendering comes from stored visual parameters, not transient GenServer state.
- Workers advance cursors and ETags transactionally with accepted events, making retries safe with the unique source index.
- The four-events-per-second visible cap prevents upstream bursts from growing an unbounded client queue.

## Public safety and privacy

- Anonymous identities are random browser tokens stored in a signed, HTTP-only, same-site cookie.
- A visitor can contribute once every 30 seconds.
- A second coarse token bucket is keyed by a short-lived salted IP hash in ETS. Neither raw nor hashed IP addresses are persisted.
- Only the three named gestures and a normalized in-bounds vertical lane are accepted, and only at the live edge.
- There is no free-form text, image upload, URL submission, custom color, or public identifier.
- CSRF protection remains enabled for the LiveView connection and events.
- Logs exclude signed identities, IP addresses, upstream raw payloads, and cookie contents.
- Data-source attribution and privacy behavior are documented publicly.

## Accessibility

- Tug, Knot, and Illuminate are fully keyboard operable.
- The vertical lane can be chosen with arrow keys after selecting a gesture.
- Every hover detail also appears on focus and tap.
- A reduced-motion mode replaces drifting animation with stepped updates; the system preference is honored by default.
- A textual live-signal summary and semantic legend accompany the canvas for screen-reader users.
- Signal type is communicated by shape and text as well as color.
- Controls meet WCAG AA contrast and target-size expectations.

## Testing strategy

### Unit tests

Cover source normalization, one-second bucketing, visible-rate aggregation, deterministic visual parameters, gesture validation, chapter boundaries, and pure JavaScript drawing-command generation.

### Integration tests

At the Req boundary, simulate upstream success, malformed data, disconnects, cache responses, cursor recovery, and retry sequences. Exercise database idempotency, checkpoint ordering, commit-before-broadcast behavior, coordinator recovery, PubSub ordering, and sequence-gap catch-up.

### LiveView tests

Cover initial loading, bounded history, live event delivery, gesture selection and cooldown, stale-source indicators, archive navigation, stable permalinks, keyboard interactions, and reduced-motion behavior. Assertions target stable element IDs and outcomes rather than raw HTML strings.

### Renderer and browser tests

Renderer tests compare deterministic drawing-command output rather than brittle canvas pixels. One browser smoke test opens two independent sessions, performs a gesture in one, and verifies both clients receive and render the same event sequence.

### Load test

Before public launch, the exact single-instance VM size configured for the public deployment must:

- Hold 200 concurrent connected viewers for 30 minutes.
- Tolerate a burst of 20 gesture attempts per second while enforcing policy.
- Keep p95 committed-gesture-to-browser delivery below 300 milliseconds.
- Show no sustained process or memory growth after the test ends.

## Deployment and operations

- Deploy one Phoenix release to Fly.io with a managed PostgreSQL database.
- Run migrations as a release step before starting the new application version.
- Terminate TLS at the platform edge and force HTTPS.
- Expose a lightweight application health endpoint; keep detailed ingestion health private.
- Use structured logs and Phoenix telemetry for request latency, LiveView count, event throughput, feed health, retry counts, PubSub delivery, and coordinator restarts.
- Keep LiveDashboard private rather than routing it publicly.
- Back up PostgreSQL according to the managed database policy.
- Retain all normalized events for the first release. Monitor row count and storage at 30 days before designing compaction.

## Continuous integration and release bar

GitHub Actions runs:

- The project’s `mix precommit` alias, which covers formatting, compilation with warnings treated as errors, unused dependencies, and Elixir tests.
- JavaScript renderer tests.
- The two-session browser smoke test.

Deployment from `master` occurs only after CI passes.

The public launch includes:

- A deployed demo URL.
- An MIT license.
- A README explaining the experience and local setup.
- An architecture overview.
- Data-source attribution.
- A contribution guide.
- A short screen recording or animated preview.

## Acceptance criteria

Worldloom v1 is complete when:

1. A visitor sees an active living fabric within five seconds without signing in.
2. Wikimedia, earthquake, weather, and visitor signals have distinct, explainable effects.
3. A gesture accepted in one browser appears in another connected browser in real time.
4. The current tapestry survives application restarts and reconstructs deterministically.
5. Historical chapters and sequence permalinks reopen the same local topology.
6. Individual feed outages degrade visibly but do not interrupt other signals or gestures.
7. Keyboard operation, reduced motion, and textual signal summaries work on desktop and mobile.
8. The load-test targets pass on the exact VM size configured for public launch.
9. CI is green, the repository is public under MIT, and the hosted demo is reachable.

## Deferred extensions

- Additional curated feeds.
- Server-generated social preview images.
- Daily chapter compaction or archival storage.
- Multi-node coordinator leadership.
- Optional accounts or attributed contributions.
- High-resolution exports, sound, scores, or competitive mechanics.

Each deferred item requires a separate design decision; none is implied by the first release.
