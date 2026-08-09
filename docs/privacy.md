# Worldloom privacy

Worldloom is designed to create one shared artifact without creating visitor
profiles. It has no registration, login, analytics SDK, advertising, chat, free-form
text, uploads, or public identity.

## What the application handles

On first visit, the server generates a random 32-byte browser token. It is stored in
a signed, HTTP-only, same-site session cookie and used to enforce one accepted
gesture per 30 seconds. The token is held in LiveView process memory while connected
and in a short-lived, salted HMAC key in the rate limiter. It is not written to
`loom_events`, rendered into public HTML, broadcast, or intentionally logged.

The LiveView connection also sees the network peer address. A salted HMAC of that
address is kept only in an in-memory ETS token bucket to absorb bursts. Peer buckets
expire after 10 seconds of inactivity and the cleanup process runs every minute. Raw
and hashed addresses are not persisted.

Phoenix sets the signed session cookie needed for those controls and LiveView. The
cookie is HTTP-only and same-site `Lax`; production uses the secure flag. Standard
infrastructure may create transient request logs, but application logs deliberately
exclude IP addresses, cookie contents, browser tokens, submitted payloads, raw
upstream responses, provider URLs, and external failure bodies.

## What becomes public and durable

An accepted visitor gesture stores only:

- the allow-listed kind (`tug`, `knot`, or `illuminate`);
- server acceptance time;
- a normalized vertical lane and fixed intensity;
- versioned deterministic rendering parameters; and
- a fixed, server-authored summary.

There is no visitor external ID or request nonce in the stored event. Public feed
events contain only the normalized fields described in
[data-sources.md](data-sources.md). Formation permalinks expose their UTC date and
database sequence, both of which are already visible in the shared artwork.

Raw provider frames and HTTP responses are never written to `loom_events`, PubSub,
browser instructions, or checkpoints. They may exist transiently in the server
process that parses a current source response, after which only the approved bounded
shape remains.

## Qualified future-source boundaries

Bluesky, RIPE RIS Live, Solana, and drand have deterministic qualification modules,
but no worker or production enablement. They do not create upstream connections,
checkpoints, or durable events in the current deployment.

If separately enabled in a later reviewed phase, their server-side boundaries permit
only these privacy-preserving transformations:

- Bluesky post/repost commits become aggregate action/category counts. Text, handles,
  DIDs, record keys, URIs, CIDs, records, and raw frames are discarded.
- RIPE `UPDATE` messages become prefix-occurrence, address-family, and distinct-count
  totals. Collector and peer values are represented only by bounded ephemeral hashes;
  prefixes, next hops, ASNs, paths, communities, IDs, and raw payloads are discarded.
- Solana slot notifications become slot progression and gap counters. Subscription,
  parent/root, account, transaction, wallet, program, and token fields are discarded.
- drand exact-round signatures are decoded transiently to derive a SHA-256 render
  identity. Neither the signature nor digest is durable; only the round, fixed
  summary, and deterministic numeric render parameters can be persisted.

The checked-in qualification fixtures contain deliberately synthetic input-only
identity and routing fields, plus a deterministic public drand sample. They are test
vectors, not captured visitor data or retained production frames. Their inventory is
documented in the [fixture README](../test/support/fixtures/feeds/README.md).

## Aggregate presence

Connected LiveViews receive a random, ephemeral Presence key. The interface displays
only an aggregate viewer count and up to 12 decorative pulses. It has no avatar,
cursor, geographic location, stable identifier, or list of viewers.

## Retention and control

Normalized loom events are append-only and retained for the first public release so
historical permalinks remain stable. Existing active-source cursors and ETags may be
stored per source for safe recovery. Browser tokens, peer-address HMACs, Presence
keys, raw provider frames, response bodies, drand signatures, and drand render
identities are not part of that durable history.

The four qualified future sources currently have no running worker, so they add no
production checkpoint or event retention. Future enablement requires its own reviewed
retention and recovery path; qualification alone does not activate one.

Visitors can stop future cookie use by leaving the site and clearing the Worldloom
site data in their browser. Because a gesture is intentionally anonymous and has no
stored owner identifier, Worldloom cannot reliably identify one visitor's historical
gesture for access or deletion without compromising that design.

## External services

The current application server—not each browser—contacts Wikimedia, USGS, and
Open-Meteo. Visiting Worldloom does not cause the browser to call those providers.

Bluesky legacy Jetstream, RIPE RIS Live, Solana, and drand are qualified future
server-side sources and are not contacted by the current production application. If
one is separately enabled after review, only the Worldloom server will contact it;
browser-to-provider connections remain forbidden. Following an attribution link
leaves Worldloom and is then governed by that provider's policies.

Questions or security-sensitive concerns should use the channel in
[SECURITY.md](../SECURITY.md).
