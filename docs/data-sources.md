# Data sources and attribution

Worldloom is an artistic visualization, not an alerting, forecasting, social,
financial, cryptographic-verification, or scientific analysis service. Upstream data
may be delayed, revised, incomplete, disconnected, rate-limited, or unavailable. The
interface presents compact summaries and never raw source records.

## Sources contacted by the current application

The Worldloom server currently contacts only Wikimedia, the U.S. Geological Survey,
and Open-Meteo. A visitor's browser does not contact those providers.

### Wikimedia EventStreams

Source: [Wikimedia EventStreams](https://www.mediawiki.org/wiki/EventStreams), using
the public `recentchange` server-sent event stream.

Worldloom groups accepted changes into non-overlapping four-second UTC windows. It
retains the window start, total change count, total absolute byte delta, up to five
language-family counts, and the dominant edit type. It discards usernames, IP
addresses, page titles, comments, revision identifiers, page/server URLs, and the raw
event before persistence.

Wikimedia project content has project-specific licensing. Worldloom does not
reproduce edited page content; it displays an original aggregate derived from public
activity. Wikimedia and its project names are marks of their respective owners, and
no endorsement is implied.

### U.S. Geological Survey earthquakes

Source: [USGS real-time earthquake feeds](https://earthquake.usgs.gov/earthquakes/feed/v1.0/),
using the versioned all-earthquakes, past-hour GeoJSON summary feed.

Each accepted event retains the public USGS identifier, occurrence time, bounded
magnitude, place label, coordinates, and a generated summary. Source IDs provide
idempotency when the rolling feed repeats an earthquake. The feed is polled once per
minute and may revise previously published observations.

Credit: U.S. Geological Survey. USGS-authored data and information are generally in
the U.S. public domain; USGS asks reusers to acknowledge it as the source. See the
[USGS copyright and credit guidance](https://www.usgs.gov/faqs/are-usgs-reportspublications-copyrighted)
and [feed lifecycle policy](https://earthquake.usgs.gov/earthquakes/feed/policy.php).
Use of USGS data does not imply U.S. Government endorsement.

### Open-Meteo weather

Source: [Open-Meteo Forecast API](https://open-meteo.com/en/docs), sampled every ten
minutes across fixed anchors centered on Vancouver, Mexico City, São Paulo,
Reykjavík, London, Lagos, Nairobi, Cape Town, Mumbai, Singapore, Tokyo, and Sydney.

Worldloom combines the observations into one ambient event: UTC observation time,
temperature range, precipitation coverage, mean wind, day/night ratio, and the fixed
city labels. It does not store a visitor location or ask Open-Meteo about one.

Weather data by [Open-Meteo.com](https://open-meteo.com/), licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Worldloom transforms and
aggregates the source observations into an artistic ambient signal.

The unauthenticated free API endpoint is limited to non-commercial use and published
request limits. Commercial operation, advertising, subscriptions, promotional use,
or a materially different request volume requires a licensing review and likely an
[Open-Meteo commercial API plan](https://open-meteo.com/en/pricing). The MIT license
for Worldloom's source code does not grant rights to use an upstream API outside its
terms.

## Qualified but disabled future sources

Worldloom contains deterministic, deny-by-default qualification boundaries for the
four sources below. No worker, production source flag, or upstream connection for
them is active yet. Qualification proves the sanitized contract; it does not promise
availability or authorize production enablement.

### Bluesky legacy Jetstream

Sources: [Bluesky's Jetstream introduction](https://docs.bsky.app/blog/jetstream) and
the [deployed legacy Jetstream implementation](https://github.com/bluesky-social/jetstream-legacy).

The qualified legacy subscription is limited to `app.bsky.feed.post` and
`app.bsky.feed.repost`. Accepted public commit operations become four-second counts
of total actions, original posts, replies, reposts, creates, updates, and deletes,
plus a bounded truncation flag. Worldloom does not retain post text, handles, DIDs,
record keys, URIs, CIDs, records, or raw frames. A future resumable worker may
checkpoint only its fully committed numeric cursor and bounded overlap fingerprints;
neither exists in current production because the worker is disabled.

Legacy Jetstream is appropriate for an informal artistic aggregate, but it is not a
stable authenticated firehose and has no production SLA. Protocol drift or relay
failure is source unavailability, not activity to invent or reinterpret.

### RIPE RIS Live

Source: [RIPE RIS Live](https://ris-live.ripe.net/manual/).

The qualified contract accepts only `UPDATE` messages from an explicit allow-list of
one to four configured collectors that also appear in RIPE's current collector list.
It emits one exact subscription per approved collector with `includeRaw: false`. An
empty intersection is a configuration failure: Worldloom never falls back to an
unfiltered or full-firehose subscription.

Four-second summaries contain only announced- and withdrawn-prefix occurrence
counts, IPv4 and IPv6 counts, distinct collector count, distinct peer count, and a
bounded truncation flag. Collector and peer values are reduced immediately to capped
in-memory fingerprints; prefixes, peers, collectors, next hops, ASNs, paths,
communities, message IDs, and raw payloads are discarded and never enter the public
event.

RIS Live is best-effort and may disconnect a slow consumer. Reconnection starts at
the live edge; Worldloom does not fabricate the missed interval.

### Solana slot progression

Sources: [Solana `slotSubscribe`](https://solana.com/docs/rpc/websocket/slotsubscribe)
and [Solana public RPC guidance](https://solana.com/docs/references/clusters).

The qualification boundary accepts the exact parameterless `slotSubscribe` contract
and structurally valid `slotNotification` positions. Four-second summaries contain
only accepted slot count, first and last slot, observed forward-gap count, and a
bounded truncation flag. Subscription IDs, parent/root validation fields, accounts,
transactions, wallets, programs, tokens, and unknown fields are discarded.

Solana is qualified only against deterministic fixtures and development
infrastructure. It remains production-disabled until a dedicated provider or
self-hosted secure endpoint is separately approved. No production Solana URL is
hidden in Worldloom configuration, and the public development endpoints are not an
approved production dependency.

### drand Quicknet

Sources: [drand Quicknet](https://docs.drand.love/blog/2023/10/16/quicknet-is-live/)
and the [drand v2 HTTP API](https://docs.drand.love/developer/API-v2/drand-http-api/).

The qualified client pins API v2, Quicknet chain hash
`52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971`, and
relay origins `https://api.drand.sh`, `https://api2.drand.sh`, and
`https://api3.drand.sh`. It races bounded chain-info and exact-round requests and
accepts the first structurally valid response. A round produces only its positive
JSON-safe round number and a transient SHA-256 render identity derived from the
decoded signature. The durable payload contains only the round and fixed summary;
the signature, digest, chain-info body, and complete response are discarded.

This is HTTPS failover plus structural validation. Worldloom does not verify the BLS
signature, recompute chain identity, compare relay consensus, or describe the result
as verified randomness. Failed or malformed relays collapse to source unavailability.

## Best-effort source behavior

Every public endpoint above is operated outside Worldloom and may throttle, delay,
revise, disconnect, or change its protocol. Streaming providers may disconnect slow
consumers. Worldloom leaves an honest gap when a qualified source is unavailable; it
does not fabricate events to maintain visual balance. Source names and links provide
attribution and do not imply endorsement by Wikimedia, USGS, Open-Meteo, Bluesky,
RIPE NCC, Solana, or drand.

## Visitor gestures

Visitor gestures are not an external data source. They are constrained,
server-authored events containing one of three gesture names, a normalized vertical
lane, an acceptance timestamp, deterministic rendering fields, and a fixed summary.
See [privacy.md](privacy.md) for identity and network handling.
