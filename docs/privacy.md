# Worldloom privacy

Worldloom is designed to create one shared artifact without creating visitor
profiles. It has no registration, login, analytics SDK, advertising, chat, free-form
text, uploads, or public identity.

This minimization makes an artistic aggregate; it does not turn upstream activity
into operational, social, cryptographic, financial, or scientific analysis, and it
does not certify the completeness or correctness of any provider.

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

## Incremental-source boundaries

Bluesky, RIPE RIS Live, Solana, and drand have deterministic qualification boundaries
and independently supervised source owners. Every switch is false by default. A
disabled source creates no process, upstream connection, checkpoint, or durable
event, and merging a production-capable worker does not authorize enabling it.

If separately enabled in a later reviewed phase, their server-side boundaries permit
only these privacy-preserving transformations:

- Bluesky post/repost commits become aggregate action/category counts. Text, handles,
  DIDs, record keys, URIs, CIDs, records, and raw frames are discarded. Only the
  maximum fully committed numeric cursor may enter its private `feed_checkpoints`
  row; it never enters `loom_events`, logs, telemetry, health, PubSub, or browser
  instructions.
- RIPE `UPDATE` messages become prefix-occurrence, address-family, and distinct-count
  totals. The reviewed collector allow-list remains operational configuration, while
  provider-observed collector and peer values are represented only by bounded
  ephemeral hashes. Acknowledgement values are checked transiently against those
  hashes; prefixes, next hops, ASNs, paths, communities, IDs, raw payloads, provider
  error text, and close reasons are discarded.
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

The local 100-browser capacity gate creates synthetic, numbered cookie and
local-storage tokens solely to prove browser-context isolation. They never enter a
loom event or the fake upstream statistics. A passing run prints only aggregate
counts, minimum snapshot progress, browser failure totals, and provider connection
totals. Failed network diagnostics retain the method, status, origin, and path needed
for debugging but remove credentials, query parameters, and fragments before storage
or output. The gate does not use production traffic, visitor cookies, IP addresses,
or raw snapshots as release evidence.

## Retention and control

Normalized loom events are append-only and retained for the first public release so
historical permalinks remain stable. Existing active-source cursors and ETags may be
stored per source for safe recovery. Browser tokens, peer-address HMACs, Presence
keys, raw provider frames, response bodies, drand signatures, and drand render
identities are not part of that durable history.

The checked-in configuration starts none of the four incremental source owners, so it
adds no production checkpoint or event retention by default. Separately authorized
enablement follows the source-specific canary and rollback gate in
[operations.md](operations.md#incremental-source-canaries); capability alone does not
activate a source.

Visitors can stop future cookie use by leaving the site and clearing the Worldloom
site data in their browser. Because a gesture is intentionally anonymous and has no
stored owner identifier, Worldloom cannot reliably identify one visitor's historical
gesture for access or deletion without compromising that design.

## External services

The current application server—not each browser—contacts Wikimedia, USGS, and
Open-Meteo. Visiting Worldloom does not cause the browser to call those providers.

[Bluesky legacy Jetstream](https://github.com/bluesky-social/jetstream-legacy),
[RIPE RIS Live](https://ris-live.ripe.net/manual/),
[Solana WebSocket RPC](https://solana.com/docs/rpc/websocket), and
[drand Quicknet](https://docs.drand.love/blog/2023/10/16/quicknet-is-live/) are
false-by-default server-side sources. If one is separately enabled after review,
only the Worldloom server contacts it; browser-to-provider connections remain
forbidden. Solana has no approved production endpoint and must remain disabled there.
Following an attribution link leaves Worldloom and is then governed by that
provider's policies.

Questions or security-sensitive concerns should use the channel in
[SECURITY.md](../SECURITY.md).
