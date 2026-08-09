# Worldloom operations

This runbook covers the single-instance Worldloom v1 release. It assumes a Phoenix
release behind a TLS-terminating proxy and a durable PostgreSQL database.

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
