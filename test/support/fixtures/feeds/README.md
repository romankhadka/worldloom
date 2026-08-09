# Scrubbed public-feed fixtures

These deterministic fixtures exercise Worldloom's provider boundaries without
retaining a real person's identity, content, routing activity, wallet activity, or
visitor network data. Input-only sensitive shapes are deliberately synthetic and are
kept only where a privacy test must prove that the boundary discards them. Normalized
test expectations contain only the sanitized outputs listed below.

## Current-source fixtures

- `wikimedia_frames.json` contains representative synthetic timestamps,
  language-family codes, edit types, and byte lengths. It was stripped of `user`,
  `user_text`, IP address, title, comment, revision, server URL, URI, and numeric edit
  IDs. Its sanitized output is a four-second aggregate containing counts, byte delta,
  bounded language counts, and dominant edit type.
- `usgs.json` keeps the public-feed shape for synthetic feature IDs, magnitudes,
  places, timestamps, and coordinates. Its sanitized output contains those approved
  public earthquake fields and a server-authored summary.
- `open_meteo.json` omits requested coordinates because Worldloom supplies a fixed,
  reviewed anchor list separately. Its sanitized output is one aggregate of
  temperature range, precipitation coverage, mean wind, day/night ratio, and fixed
  city labels.

## Qualified future-source fixtures

These fixtures qualify boundaries only. No corresponding provider worker is active.

- `bluesky_frames.json` includes synthetic DIDs, handle, cursor, record key, text,
  URI, CID, identity event, and account event as input-only rejection material. The
  accepted output contains only four-second counts for total actions, original posts,
  replies, reposts, creates, updates, deletes, and truncation. None of the synthetic
  values enters aggregate state, inspection, durable payloads, logs, or telemetry.
- `ripe_frames.json` includes documentation-range collectors, peers, ASNs, message
  IDs, next hops, prefixes, paths, communities, and a synthetic raw marker. These are
  input-only. The accepted output contains only announced/withdrawn prefix-occurrence
  counts, IPv4/IPv6 counts, distinct collector/peer counts, and truncation; bounded
  worker-local fingerprints are omitted from inspection and output.
- `solana_slot_frames.json` includes synthetic subscription IDs, parent/root
  positions, account, transaction, wallet, program, and token fields. The accepted
  output contains only slot count, first/last slot, gap count, window fields, and
  truncation. Continuity state and every input-only field are omitted from the public
  event.
- `drand_chain_info.json` records the pinned public Quicknet v2 metadata used for
  structural qualification. The client retains only period and genesis time from the
  accepted response.
- `drand_rounds.json` contains one deterministic public exact-round signature as an
  input test vector. The client returns only the matching round and an ephemeral
  SHA-256 render identity; normalization persists neither the signature nor digest.

Adversarial collections larger than the documented bounds are constructed
mechanically inside tests rather than checked in. This keeps fixtures reviewable and
prevents large or identity-bearing input samples from becoming accidental output
contracts.
