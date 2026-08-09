# Worldloom load verification

Worldloom's launch-capacity scenario uses k6 v2.1.0. It fetches the real public
page, retains its signed anonymous session cookie, parses the CSRF and LiveView
tokens, joins the real `WorldLive` process over Phoenix protocol 2.0.0, sends
heartbeats and LiveView events, observes persisted broadcast sequences, and
leaves gracefully. There is no load-only route and visitor policy is never
bypassed.

## Profiles

| Profile | Purpose | Shape |
| --- | --- | --- |
| `smoke` | Protocol development | One connected viewer for 10 seconds |
| `gesture-smoke` | Persistence and policy classification | One or more fresh anonymous identities |
| `local-100` | Local LiveView capacity profile | 100 viewers; 10 gesture attempts/second for 60 seconds |
| `local` | Five-minute capacity rehearsal | 200 viewers; 20 gesture attempts/second for 60 seconds |
| `launch` | Exact launch gate | Two-minute ramp to 200, 30-minute hold, two-minute ramp-down; 20 gesture attempts/second for the first 60 seconds of the hold |

The default is the inexpensive `smoke` profile. The launch profile is explicit
so it cannot be started accidentally.

## Deterministic balanced-world gate

The balanced-world gate runs the real test application against one local,
TLS-protected upstream process. The upstream owns every provider connection;
the k6 client only visits Worldloom over its public LiveView route. Its `/stats`
response contains fixed aggregate counters only—never cookies, IP addresses,
cursors, raw frames, source content, prefixes, peers, accounts, or visitor
identities. Persistent sources report lifetime `connection_opens`, current
`active_connections`, and `peak_connections`. RIPE records one subscription per
collector message, so the harness's single collector set is exactly two
subscriptions on one socket.

Prepare the isolated `worldloom_e2e` database. The reset replaces that test
database only:

```sh
MIX_ENV=test WORLDLOOM_E2E=true mix clean
MIX_ENV=test WORLDLOOM_E2E=true mix ecto.reset
```

Start the real app, all seven source workers, and the single instrumented
upstream in one terminal:

```sh
MIX_ENV=test WORLDLOOM_E2E=true mix run --no-start --no-halt \
  -e 'Worldloom.TestSupport.BalancedWorldHarness.start!()'
```

The test app listens at `http://localhost:4002`; aggregate upstream stats are
available at `https://localhost:4443/stats`. In a second terminal, require real
snapshot movement and every enabled public source role:

```sh
k6 run load/balanced_world.js
```

Passing means the client joined the real `WorldLive` process, observed at least
two strictly increasing committed watermarks, found all seven enabled source
names across display, memory, and ambient snapshot roles, and completed with no
Phoenix protocol errors. The observation exits early once all conditions are
true; otherwise it waits up to 30 seconds. Override that ceiling or the exact
expected set explicitly when diagnosing a subset:

```sh
k6 run \
  -e WORLDLOOM_BALANCED_OBSERVATION_MS=45000 \
  -e WORLDLOOM_EXPECTED_SOURCES=wikimedia,bluesky,ripe_ris,solana,drand,usgs,open_meteo \
  load/balanced_world.js
```

Inspect the privacy-safe server counters without disabling TLS verification:

```sh
curl --cacert test/support/fixtures/tls/localhost_ca.pem \
  https://localhost:4443/stats
```

To run only the fake provider server on the same fixed port, first compile the
test environment and then start it with Solana explicitly enabled:

```sh
MIX_ENV=test WORLDLOOM_E2E=false mix clean
MIX_ENV=test WORLDLOOM_E2E=false mix run --no-start --no-halt \
  -e '{:ok, _} = Application.ensure_all_started(:bandit); {:ok, server} = Worldloom.TestSupport.FakeUpstream.start_link(port: 4443, cadence_ms: 1000, solana: true); Process.unlink(server)'
```

## One hundred isolated browsers

With the deterministic balanced-world harness running, launch the explicit
real-browser gate in a second terminal:

```sh
npm run test:browser-100
```

This starts one headless Chromium process and creates 100 independent browser
contexts—one page, cookie jar, and local-storage namespace per context. It ramps
10 pages every two seconds, waits for every canvas to become ready and observe
two real snapshot advances, then holds all 100 LiveViews for 60 seconds. Reduced
motion and an 800×600 viewport keep the gate focused on server ownership and
snapshot reprojection instead of continuous paint cost.

Passing requires:

- 100 ready pages with unique synthetic cookie and storage tokens;
- two or more strictly increasing snapshot advances in every page;
- zero console, page, request, response, or WebSocket failures;
- zero browser requests to any origin other than the Worldloom app;
- one lifetime open, one active connection, and a peak of one for each
  server-owned streaming source;
- exactly one Bluesky filter subscription, one two-message RIPE collector set,
  and one Solana slot subscription;
- bounded drand and polling request deltas based on elapsed time, never browser
  count;
- the Presence count returning to its pre-run baseline after every context
  closes.

The runner measures its disconnected Presence baseline first, so a developer's
already-open localhost tab does not create a false failure. This gate is
intentionally heavier than pull-request CI. Allow roughly two minutes and have
at least 4 GB of free memory available. A diagnostic run may override visitor,
batch, ramp, hold, or timeout values with the `WORLDLOOM_BROWSER_*` variables,
but only the default 100-browser, 60-second run is release evidence.

## Local commands

Start the real app with public feeds disabled in a separate terminal:

```sh
WORLDLOOM_FEEDS_ENABLED=false mix phx.server
```

Then run the protocol smoke:

```sh
k6 run --vus 1 --duration 10s load/worldloom.js
```

Run the one-gesture profile to verify that a real LiveView form event is
classified and its committed sequence is observed:

```sh
k6 run -e WORLDLOOM_PROFILE=gesture-smoke load/worldloom.js
```

Run the explicit 100-viewer profile to exercise concurrent LiveView joins and
a 10-per-second gesture stream under the launch thresholds:

```sh
k6 run -e WORLDLOOM_PROFILE=local-100 load/worldloom.js
```

Contributors with the optional RTK output wrapper can run the equivalent
commands as:

```sh
rtk env WORLDLOOM_PROFILE=gesture-smoke k6 run load/worldloom.js
rtk env WORLDLOOM_PROFILE=local-100 k6 run load/worldloom.js
```

Exercise both durable commits and expected peer-rate rejections with fresh
signed identities:

```sh
k6 run \
  -e WORLDLOOM_PROFILE=gesture-smoke \
  -e WORLDLOOM_GESTURE_ITERATIONS=15 \
  load/worldloom.js
```

Run the five-minute local rehearsal:

```sh
k6 run -e WORLDLOOM_PROFILE=local load/worldloom.js
```

Inspect the exact launch shape without running it:

```sh
k6 inspect -e WORLDLOOM_PROFILE=launch load/worldloom.js
```

## Private launch gate

Task 27 supplies the private pre-launch hostname. Run the complete gate only
against that exact HTTPS deployment:

```sh
k6 run \
  -e WORLDLOOM_PROFILE=launch \
  -e WORLDLOOM_BASE_URL="https://${WORLDLOOM_FLY_APP}.fly.dev" \
  --summary-export "docs/performance/${CAPACITY_DATE}-launch-capacity.json" \
  load/worldloom.js
```

Passing requires:

- fewer than 1% failed bootstrap HTTP requests and LiveView joins;
- no WebSocket protocol errors;
- at least one durable visitor gesture;
- fewer than 1% unclassified gesture outcomes or missed committed sequences;
- committed-gesture-to-observed-sequence p95 below 300 ms.

Cooldown and peer-burst rejections are successful visitor-policy outcomes. They
increment `worldloom_gesture_policy_rejected`; they do not count as transport
failures. Every gesture iteration clears its cookie jar before bootstrap, so
each attempt receives a distinct signed anonymous identity.

## Before, during, and after capture

Use one worksheet for the run. Capture the same fields at `T-0`, at 5, 15, and
30 minutes of the hold, immediately after ramp-down, and again 10 minutes later.
Never record session cookies, CSRF values, IP addresses, or raw visitor
identities.

| Signal | Source | Passing evidence |
| --- | --- | --- |
| Machine RSS | Fly Metrics: `fly_instance_memory_mem_total - fly_instance_memory_mem_available` | No OOM; returns near the pre-run band 10 minutes after disconnect |
| BEAM process count | `worldloom.runtime.beam_process_count` | No monotonic post-disconnect growth |
| Connected LiveViews | `worldloom.runtime.live_view_count` | Reaches about 200 during hold and returns to baseline |
| Coordinator restarts | `worldloom.runtime.coordinator_restart_count` plus Fly logs | Remains zero |
| Signal buffer depth | `worldloom.signals.buffer.depth` | Bounded and drains after burst/feed recovery |
| DB pool | `worldloom.runtime.database_pool_utilization` and `database_pool_queue` | Queue remains bounded; utilization returns to baseline |
| Managed Postgres connections | MPG Metrics tab connection/pool charts | Below plan capacity with no sustained saturation |

For an application telemetry snapshot, open a remote release console and attach
a temporary handler before asking the existing periodic measurement to emit:

```elixir
handler = "capacity-snapshot-#{System.unique_integer([:positive])}"
:telemetry.attach(handler, [:worldloom, :runtime], fn _, measurements, _, _ ->
  IO.inspect(measurements, label: "worldloom runtime")
end, nil)
WorldloomWeb.Telemetry.measure_runtime()
:telemetry.detach(handler)
```

Use the Fly dashboard's Machine Metrics and Managed Postgres Metrics tabs for
the platform series. Preserve only the dated k6 text/JSON summary and aggregate
metric readings under `docs/performance/`; do not commit raw visitor-level data.
