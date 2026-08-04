# Worldloom privacy

Worldloom is designed to create one shared artifact without creating visitor profiles.
It has no registration, login, analytics SDK, advertising, chat, free-form text,
uploads, or public identity.

## What the application handles

On first visit, the server generates a random 32-byte browser token. It is stored in a
signed, HTTP-only, same-site session cookie and used to enforce one accepted gesture
per 30 seconds. The token is held in LiveView process memory while connected and in a
short-lived, salted HMAC key in the rate limiter. It is not written to `loom_events`,
rendered into public HTML, broadcast, or intentionally logged.

The LiveView connection also sees the network peer address. A salted HMAC of that
address is kept only in an in-memory ETS token bucket to absorb bursts. Peer buckets
expire after 10 seconds of inactivity and the cleanup process runs every minute. Raw
and hashed addresses are not persisted.

Phoenix sets the signed session cookie needed for those controls and LiveView. The
cookie is HTTP-only and same-site `Lax`; production uses the secure flag. Standard
infrastructure may create transient request logs, but application logs deliberately
exclude IP addresses, cookie contents, browser tokens, submitted payloads, and raw
upstream responses.

## What becomes public and durable

An accepted visitor gesture stores only:

- the allow-listed kind (`tug`, `knot`, or `illuminate`);
- server acceptance time;
- a normalized vertical lane and fixed intensity;
- versioned deterministic rendering parameters; and
- a fixed, server-authored summary.

There is no visitor external ID or request nonce in the stored event. The public feed
events contain only normalized fields described in [data-sources.md](data-sources.md).
Formation permalinks expose their UTC date and database sequence, both of which are
already visible in the shared artwork.

## Aggregate presence

Connected LiveViews receive a random, ephemeral Presence key. The interface displays
only an aggregate viewer count and up to 12 decorative pulses. It has no avatar,
cursor, geographic location, stable identifier, or list of viewers.

## Retention and control

Normalized loom events are append-only and retained for the first public release so
historical permalinks remain stable. Feed cursors and ETags are stored per source for
safe recovery. Browser tokens, peer-address HMACs, and Presence keys are not part of
that history.

Visitors can stop future cookie use by leaving the site and clearing the Worldloom
site data in their browser. Because a gesture is intentionally anonymous and has no
stored owner identifier, Worldloom cannot reliably identify one visitor's historical
gesture for access or deletion without compromising that design.

## External services

The server—not each browser—contacts Wikimedia, USGS, and Open-Meteo. Visiting
Worldloom does not cause the browser to call those providers. Following an attribution
link leaves Worldloom and is then governed by that provider's policies.

Questions or security-sensitive concerns should use the channel in
[SECURITY.md](../SECURITY.md).
