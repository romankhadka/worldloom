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
| `local` | Five-minute capacity rehearsal | 200 viewers; 20 gesture attempts/second for 60 seconds |
| `launch` | Exact launch gate | Two-minute ramp to 200, 30-minute hold, two-minute ramp-down; 20 gesture attempts/second for the first 60 seconds of the hold |

The default is the inexpensive `smoke` profile. The launch profile is explicit
so it cannot be started accidentally.

## Local commands

Start the real app with public feeds disabled in a separate terminal:

```sh
WORLDLOOM_FEEDS_ENABLED=false mix phx.server
```

Then run the protocol smoke:

```sh
k6 run --vus 1 --duration 10s load/worldloom.js
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
