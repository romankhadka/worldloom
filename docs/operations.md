# Worldloom operations

This runbook covers the single-instance Worldloom v1 release. It assumes a Phoenix
release behind a TLS-terminating proxy and a durable PostgreSQL database.

Worldloom is an artistic aggregate, not an operational, social, cryptographic,
financial, scientific, alerting, or forecasting system. Preserve honest source gaps;
never expand a recovery window or reinterpret source failures to make the artwork
appear busier.

## Required production configuration

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | PostgreSQL connection URL |
| `SECRET_KEY_BASE` | At least 64 bytes of secret material for cookies and LiveView |
| `PHX_HOST` | Canonical public hostname used by generated permalinks |
| `WORLDLOOM_RATE_LIMIT_SALT` | Independent secret used to HMAC ephemeral rate-limit keys |
| `PHX_SERVER=true` | Starts the HTTP endpoint in a release |

Optional settings are `PORT` (default `4000`), `POOL_SIZE` (default `10`),
`ECTO_IPV6`, and `DNS_CLUSTER_QUERY`. Set `WORLDLOOM_FEEDS_ENABLED=false` to start a
healthy app with no external feed workers. `WORLDLOOM_WIKIMEDIA_URL`,
`WORLDLOOM_USGS_URL`, and `WORLDLOOM_OPEN_METEO_URL` are HTTPS-only diagnostic
overrides; remove them after controlled testing.

All public feeds start enabled. The four high-cadence additions retain independent
operator circuit breakers so an unhealthy, throttled, or drifting provider can be
isolated without silencing the rest of the artwork. These are not visitor controls.

| Source | Control | Default | Nominal cadence | Public expiry | Recovery bound |
|---|---|---:|---:|---:|---|
| Wikimedia | Global feed switch | On | 4-second windows | Quiet at 20 seconds | 60-second event-ID horizon |
| USGS | Global feed switch | On | 1 minute | Quiet at 3 minutes | Private ETag and source-ID deduplication |
| Open-Meteo | Global feed switch | On | 10 minutes | Stale at 30 minutes | Last ambient state plus local retry |
| drand Quicknet | `WORLDLOOM_DRAND_ENABLED` | On | 3 seconds | Stale at 12 seconds | 20 exact rounds, then one coarse gap |
| Bluesky Jetstream | `WORLDLOOM_BLUESKY_ENABLED` | On | 4-second windows | Quiet at 20 seconds | 5-second overlap, 60-second horizon |
| RIPE RIS Live | `WORLDLOOM_RIPE_ENABLED` | On | 4-second windows | Quiet at 20 seconds | Live edge only; no replay claim |
| Solana | `WORLDLOOM_SOLANA_ENABLED` | On | 4-second windows | Quiet at 20 seconds | Live edge only; preserve observed gaps |

`WORLDLOOM_FEEDS_ENABLED=false` overrides the entire table and starts no feed owner,
including an independently enabled incremental source. Official contracts and exact
field handling are linked from [data-sources.md](data-sources.md).

Never print, commit, or place production secret values in command history. Rotate
`SECRET_KEY_BASE` and the rate-limit salt independently. Rotating the former invalidates
browser sessions; rotating the latter clears the practical continuity of in-memory
rate-limit keys on the next restart.

## Release lifecycle

1. Build immutable assets with `mix assets.deploy` and an OTP release with
   `MIX_ENV=prod mix release`.
2. Run database migrations once before starting the new application version.
3. Start exactly one application instance.
4. Wait for `GET /healthz` to return HTTP 200 before routing traffic.
5. Stop with SIGTERM and allow the BEAM to shut down cleanly.

The deployment image and migration overlay are defined with continuous delivery in
the repository. Do not run multiple application instances until coordinator leadership
is implemented and verified.

### Capacity and release evidence

Before a release candidate is integrated, run the deterministic balanced-world
harness described in [load/README.md](../load/README.md). It starts the real test app,
all seven source workers, and one local TLS upstream; it never contacts production
providers or changes a production source flag.

The release gate then requires both:

- `npm run test:browser-100`: 100 independent Chromium contexts, one stable LiveView
  WebSocket each, two or more strictly increasing snapshot advances per page, zero
  browser/upstream-origin failures, exact Presence cleanup, and one server-owned
  provider connection/subscription set throughout the run;
- the `local-100` k6 profile against `http://localhost:4002`: 100 concurrent viewers
  plus ten gesture attempts per second for one minute, with zero protocol errors and
  p95 durable-gesture observation below 300 milliseconds.

Run the protocol profile exactly as:

```sh
k6 run \
  -e WORLDLOOM_PROFILE=local-100 \
  -e WORLDLOOM_BASE_URL=http://localhost:4002 \
  load/worldloom.js
```

The browser gate needs roughly two minutes and at least 4 GB of free memory. Keep its
aggregate output with the release evidence. Never point the deterministic upstream,
its test certificate, or its fixed ports at a public deployment.

## Health and source status

`GET /healthz` intentionally checks only database connectivity and the authoritative
loom coordinator. It returns `{"status":"ok"}` or HTTP 503 with
`{"status":"unavailable"}`. It does not expose dependency URLs, feed cursors, ETags,
queue contents, process identifiers, or detailed errors.

Feed health is a degraded-mode signal, not an application-health failure:

- Wikimedia and any enabled high-cadence WebSocket source are `quiet` after 20
  seconds without durably accepted activity while connected.
- A closed streaming transport becomes `disconnected` immediately.
- An enabled drand feed is `stale` after 12 seconds without a durably accepted round.
- USGS is `quiet` after three minutes without successful contact.
- Open-Meteo is `stale` after 30 minutes and the last ambient state remains visible.

These public states use only sanitized runtime connection, contact, and committed-
activity times. Database checkpoints remain private recovery positions and do not
make a currently unobserved source appear live.

One source can be unavailable while the other sources, visitor gestures, archive, and
health endpoint continue.

### Provider contract smoke check

Run `mix worldloom.providers.smoke` before an incremental-source canary or after a
provider announces a protocol change. The command concurrently checks the current
[drand v2 API](https://docs.drand.love/developer/API-v2/drand-http-api/),
[Bluesky legacy Jetstream](https://github.com/bluesky-social/jetstream-legacy), and
[RIPE RIS Live](https://ris-live.ripe.net/manual/) boundaries. It stops each probe
after one sanitizer-approved observation, starts neither the Worldloom application
nor Repo, persists nothing, and prints only `ok` or a fixed coarse failure class.

The repository also runs this command weekly and on manual dispatch. It is deliberately
absent from push and pull-request CI because public-provider drift is nondeterministic.
It does not probe Solana, enable a source, change remote configuration, or deploy a
canary. A failure blocks source enablement until the checked-in contract is reviewed;
it is not a reason to weaken validation or expose the provider response.

## Incremental source canaries

All four sources start enabled. For a first hosted deployment, or when restoring a
source after isolation, evaluate one source at a time. Record the pre-deploy maximum
sequence, per-source row count, public feed state, and sibling feed states. If a gate
fails, set only that source's switch to `false`; do not disable the global feed switch
unless every provider must be stopped.

### drand Quicknet

The checked-in release starts drand. Use this procedure to verify a fresh deployment
or to restore it after source-local isolation.

- **Restore/default:** remove a false override or set `WORLDLOOM_DRAND_ENABLED=true`
  and redeploy one instance. The
  optional `WORLDLOOM_DRAND_RELAYS` value may select a comma-separated, unique subset
  of the three pinned official relay origins; arbitrary origins fail startup.
- **Expected cadence:** one different real Quicknet round every three seconds.
- **Healthy threshold:** a newly durably accepted round must make the public drand
  state `live` within twelve seconds.
- **Recovery bound:** a restart may recover at most twenty missing rounds, in order.
  A larger gap jumps to the current exact round and records the skipped count.
- **Observe:** drand external IDs remain unique, no duplicate rows appear, sibling
  feed processes and cadence remain unaffected, and public copy makes no claim that
  Worldloom performs BLS signature verification.
- **Rollback:** set `WORLDLOOM_DRAND_ENABLED=false` and redeploy. This removes only the
  drand worker; it does not reset the durable checkpoint or alter other feeds.

Close the canary only after the cadence and health threshold remain stable and a
restart demonstrates bounded, ordered, idempotent recovery. A failed gate is a
rollback condition, not a reason to broaden timeouts or queue bounds.

### Bluesky legacy Jetstream

The checked-in release starts Bluesky. Use this procedure to verify a fresh deployment
or to restore it after source-local isolation. The adapter targets the deployed legacy
Jetstream protocol: it is a best-effort, unauthenticated artistic signal, not a
protocol-stable firehose or production-SLA dependency.

- **Restore/default:** remove a false override or set
  `WORLDLOOM_BLUESKY_ENABLED=true` and redeploy one instance. Do not
  change `WORLDLOOM_BLUESKY_URL` during the canary; the configured secure endpoint is
  validated before the supervision tree starts.
- **Subscription bound:** the server owns one socket and requests only
  `app.bsky.feed.post` and `app.bsky.feed.repost`, with
  `maxMessageSizeBytes=262144` and compression disabled.
- **Healthy threshold:** a connected feed with no durably accepted activity for
  twenty seconds becomes `quiet`; a closed transport becomes `disconnected`
  immediately. Neither state makes the application health endpoint fail.
- **Recovery bound:** reconnect from five seconds before the private fully committed
  numeric cursor, deduplicate the overlap, and accept no more than sixty seconds of
  replay. A missing checkpoint starts at the live tail; a future or older checkpoint
  returns there and reports one coarse gap instead of inventing activity.
- **Observe:** each non-empty four-second window creates at most one unique Bluesky
  event row; the checkpoint advances only in the same successful transaction. Confirm
  sibling feed cadence and processes remain unaffected through disconnect/reconnect.
- **Privacy gate:** inspect Bluesky `loom_events`, application logs, telemetry, and
  browser instructions for DID, handle, record text, record key, URI, CID, raw frame,
  and cursor leakage. The numeric recovery cursor is allowed only in the private
  `feed_checkpoints` row and redacted from logs, telemetry, health, and the browser.
- **Rollback:** set only `WORLDLOOM_BLUESKY_ENABLED=false` and redeploy. This removes
  only the Bluesky socket owner; it does not reset its private checkpoint or alter
  another source.

Close the canary only after a quiet-state observation and a forced reconnect prove
bounded, idempotent recovery with privacy-clean public surfaces. Protocol drift,
unexpected content retention, duplicate rows, an unbounded replay, or sibling-feed
interference is a rollback condition.

### RIPE RIS Live

The checked-in release starts RIPE RIS Live. Use this procedure to verify a fresh
deployment or to restore it after source-local isolation. RIS Live is an
unauthenticated, best-effort routing stream and may send a final error before closing
a slow consumer; Worldloom treats that as source-local degradation.

- **Restore/default:** remove a false override or set `WORLDLOOM_RIPE_ENABLED=true`
  and redeploy one instance. Keep the
  reviewed `WORLDLOOM_RIPE_URL` and configure one to four unique `rrcNN` names with
  `WORLDLOOM_RIPE_COLLECTORS`; invalid or empty configuration fails startup.
- **Subscription bound:** on every connection, request the current `ris_rrc_list`,
  intersect exact `rrcNN` or corresponding `rrcNN.ripe.net` advertised hostnames with
  the configured short-name allow-list, and send exactly one string-host subscription
  per match. Arbitrary domains and canonical duplicates fail closed. Every
  subscription is `UPDATE` only with
  `includeRaw=false` and `acknowledge=true`; an empty intersection or malformed,
  duplicate, unrequested, or incomplete acknowledgement fails that connection closed.
  No routing update is accepted until every exact acknowledgement arrives within five
  seconds of the WebSocket connection.
- **Healthy threshold:** a connected feed with no durably accepted activity for
  twenty seconds becomes `quiet`; a closed transport becomes `disconnected`
  immediately. Neither state makes the application health endpoint fail.
- **Recovery bound:** reconnect at the live edge, enumerate collectors again, and
  never request, synthesize, or label missed routing updates as replay. A provider
  close records one coarse gap observation without retaining its error text or close
  reason.
- **Observe:** each non-empty four-second window creates at most one unique RIPE
  event row, and its cursor-free checkpoint updates in the same successful
  transaction. Confirm every reconnect repeats collector negotiation and sibling
  feed cadence and processes remain unaffected.
- **Privacy gate:** inspect RIPE `loom_events`, application logs, telemetry, health,
  process status, and browser instructions for peer addresses, peer ASNs, prefixes,
  collector identities, message IDs, paths, communities, next hops, raw BGP bytes,
  provider errors, or close reasons. Only bounded ephemeral hashes may represent
  provider-observed peers and collectors during aggregation.
- **Rollback:** set only `WORLDLOOM_RIPE_ENABLED=false` and redeploy. This removes
  only the RIPE socket owner; it does not alter another source or fabricate the
  disconnected interval.

Close the canary only after a forced slow-consumer close demonstrates a privacy-safe
gap, fresh collector negotiation, no replay, and one summary per new non-empty
window. An unbounded subscription, raw payload, identity leakage, replay claim, or
sibling-feed interference is a rollback condition.

### Solana slot progression

The checked-in release starts one server-owned `slotSubscribe` connection against
`wss://api.mainnet-beta.solana.com/`. Solana's public endpoint is rate-limited, has no
SLA, and is not intended for production applications, so a dedicated or self-hosted
secure endpoint is preferable for a durable hosted deployment.

- **Restore/default:** remove a false override or set `WORLDLOOM_SOLANA_ENABLED=true`
  and redeploy one instance. `WORLDLOOM_SOLANA_URL` may select a different absolute
  `wss://` endpoint; an enabled source without an endpoint fails startup.
- **Subscription bound:** the server opens one socket and sends the exact
  parameterless `slotSubscribe` request. Browsers never open provider connections.
- **Healthy threshold:** a connected feed with no durably accepted activity for
  twenty seconds becomes `quiet`; a closed transport becomes `disconnected`.
- **Recovery bound:** reconnect at the live edge. Preserve and report observed slot
  gaps; never expand a gap into fabricated observations or claim replay.
- **Observe:** each non-empty four-second window creates at most one unique Solana
  event row. Confirm sibling feed cadence remains unaffected and inspect durable
  events, logs, telemetry, and browser instructions for transaction, account, wallet,
  program, token, parent/root, subscription ID, or raw-frame leakage.
- **Rollback:** set only `WORLDLOOM_SOLANA_ENABLED=false` and redeploy. This removes
  only the Solana socket owner and leaves every other source active.

Sustained throttling, contract drift, identity leakage, invented gap activity, or
sibling-feed interference is a rollback condition.

## Telemetry and logs

Structured production logs include event names and coarse source/status metadata,
never raw upstream bodies, identities, IP addresses, cookies, cursors, or ETags.
Monitor at least:

- endpoint latency and failures;
- active LiveView count and BEAM process count;
- accepted/rejected gestures and commit latency;
- feed contact, retry, stale/quiet transitions, and buffer depth;
- coordinator liveness and restart count;
- PostgreSQL pool capacity, ready connections, checkout queue, and utilization.

A coordinator restart is recoverable but should be investigated. A rising checkout
queue, repeated persistence failures, or `/healthz` failure is an incident.

## Recovery procedures

### Application restart

Restart the release without resetting PostgreSQL. Confirm `/healthz`, compare the
maximum `loom_events.id` before and after, open `/`, and open a known
`/chapters/YYYY-MM-DD/:sequence` permalink. The coordinator should resume from the
stored maximum sequence and the renderer should reproduce the same formation.

### Database interruption

Restore connectivity first. Worldloom broadcasts only rows returned by a successful
transaction, so it does not need to retract phantom events. Confirm the pool queue
returns to baseline, `/healthz` is 200, and the sequence advances after a new accepted
signal.

### One feed is unavailable

Confirm the affected legend state, worker retry telemetry, and that other sources and
a test visitor gesture still commit. Do not reset its `feed_checkpoints` row casually:
the cursor or ETag is the recovery position. Restore the source URL and verify a new
successful-contact timestamp before closing the incident.

### Queue pressure

The external buffer is capped at 64 entries globally, 16 entries per ordinary
source, and 20 ordered entries for drand. It drains ready source partitions fairly
and merges compatible summaries only within one source under pressure. Check commit
latency and database-pool telemetry before changing those bounds. Never solve
pressure by making a queue unbounded.

## Database review and backups

The public release retains normalized events so permalinks remain stable. Record these
figures at launch and again after 30 days:

```sql
SELECT count(*), min(id), max(id), min(inserted_at), max(inserted_at)
FROM loom_events;

SELECT pg_size_pretty(pg_total_relation_size('loom_events'));
```

Use the managed PostgreSQL provider's automated backup and point-in-time recovery
features. Verify their enabled status and retention in the provider control plane
before launch, then record the non-secret policy with the dated capacity report. Test
restore procedures against a separate database; never overwrite the live database to
test recovery.

No compaction or deletion policy is assumed for v1. Propose one only after measuring
growth and preserving permalink/reconstruction semantics.
