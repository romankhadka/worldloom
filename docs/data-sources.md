# Data sources and attribution

Worldloom is an artistic visualization, not an alerting, forecasting, or scientific
analysis service. Upstream data may be delayed, revised, incomplete, or unavailable.
The interface presents compact summaries and never raw source records.

## Wikimedia EventStreams

Source: [Wikimedia EventStreams](https://www.mediawiki.org/wiki/EventStreams), using
the public `recentchange` server-sent event stream.

Worldloom groups accepted changes into one-second buckets. It retains the UTC second,
total change count, total absolute byte delta, up to five language-family counts, and
the dominant edit type. It discards usernames, IP addresses, page titles, comments,
revision identifiers, page/server URLs, and the raw event before persistence.

Wikimedia project content has project-specific licensing. Worldloom does not reproduce
edited page content; it displays an original aggregate derived from the public activity
stream. Wikimedia and its project names are marks of their respective owners, and no
endorsement is implied.

## U.S. Geological Survey earthquakes

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

## Open-Meteo weather

Source: [Open-Meteo Forecast API](https://open-meteo.com/en/docs), sampled every ten
minutes across fixed anchors centered on Vancouver, Mexico City, São Paulo, Reykjavík,
London, Lagos, Nairobi, Cape Town, Mumbai, Singapore, Tokyo, and Sydney.

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

## Visitor gestures

Visitor gestures are not an external data source. They are constrained,
server-authored events containing one of three gesture names, a normalized vertical
lane, an acceptance timestamp, deterministic rendering fields, and a fixed summary.
See [privacy.md](privacy.md) for identity and network handling.
