# Timeline Zoom and Touch Reliability Design

**Date:** 2026-08-09
**Status:** Approved — plan-reviewed against repository and runtime evidence
**Scope:** Add bounded 1-, 5-, and 15-minute timeline scales to live and historical Worldloom views, harden the existing two-step touch interaction, repair obsolete mobile touch verification, and update the public README.

## Summary

Worldloom currently projects the live weave across one fixed 60-second event-time window. Visitors can pan left into loaded history, but they cannot change the visible time scale. The renderer also exposes a two-step touch interaction—position a lane on the live membrane, then submit Tug, Knot, or Illuminate—but the canvas still advertises browser-owned vertical panning and one mobile browser test guesses formation positions with a projection model the application no longer uses.

This change adds a curated **1m / 5m / 15m** timeline-scale control. One minute remains the default. At the live edge, Now stays fixed to the right while longer scales reveal more recent history to the left. In a historical view, scale changes preserve the timestamp at the center of the viewport. The existing gesture semantics remain unchanged: touching the membrane positions a lane, and only pressing a named gesture button commits a formation.

The implementation keeps timeline state client-local and adds a bounded, server-authorized range projection for wider windows. It preserves all renderer, persistence, privacy, and source limits while sampling real stored events across the full requested interval instead of assuming that the nearest 600 sequences cover fifteen minutes.

## Goals

- Let visitors view one, five, or fifteen minutes of the weave without changing routes.
- Make zoom behavior coherent at live Now, in panned history, and in read-only chapter views.
- Preserve a stable historical timestamp while snapshots continue arriving.
- Keep the existing timeline-pan gestures and explicit visitor-action semantics.
- Make direct touch lane placement reliable on mobile browsers.
- Replace obsolete coordinate guessing in browser tests with renderer-authoritative hit regions.
- Prove Tug, Knot, and Illuminate through real mobile touch input.
- Document the shipped controls and verification posture in the README.

## Non-goals

- No continuous or arbitrary zoom values.
- No browser, trackpad, or pinch gesture for changing scale.
- No scale query parameter, permalink state, cookie, or local-storage persistence.
- No persisted server-side personalized viewport state. LiveView may answer a validated, ephemeral range request, but it does not retain a visitor's selected scale.
- No change to event ingestion, source qualification, health, persistence, cooldown, rate limiting, gesture meaning, or public privacy behavior.
- No increase to the 600-event renderer bound, 4,000-command bound, or one-timeline-request-in-flight rule.
- No new package, remote asset, font, or runtime dependency.

## Interaction design

### Scale control

The interface presents three native buttons in a group labeled **Timeline scale**:

- `1m` — active by default;
- `5m`;
- `15m`.

The current button has `aria-pressed="true"` and a restrained saffron-on-wine active treatment. Every button retains a minimum 44-by-44 CSS-pixel target, visible keyboard focus, and a written label. The scale is never communicated by spacing or color alone.

On desktop, the control sits beneath the Earlier—Now timeline rule and above the gesture dock. On compact screens, where the decorative timeline rule is hidden, the same control sits immediately above the gesture dock. It remains visually subordinate to the weave and uses the existing Lacquered Gallery tokens.

Scale changes occur only through these explicit buttons. Wheel motion, pointer drag, and one-finger horizontal movement remain timeline panning. This avoids overloading trackpad and touch gestures and keeps the current interaction learnable.

### Live anchoring

At the live edge, the visible right boundary is the snapshot's canonical `window_end`. Changing from one minute to five or fifteen minutes keeps Now fixed on the right and expands the visible interval leftward. A scale change alone does not make the viewport historical and does not disable visitor gestures.

### Historical anchoring

Once the visitor pans away from Now, the renderer tracks how far the visible right boundary lags behind the canonical live edge. Changing scale preserves the timestamp under the horizontal center of the viewport. The view does not jump to Now, to the oldest event, or to an arbitrary sequence.

When a new live snapshot arrives while the visitor is historical, the canonical live edge may advance but the visible historical interval remains fixed. Return live resets historical lag to zero while retaining the chosen scale.

Read-only chapter reloads include the selected formation's trusted `anchor_at`. The renderer centers that timestamp at the default scale and preserves it through later scale changes. Scale and pan remain available, while all gesture controls remain disabled as they are today.

### Touch the loom

The existing two-step interaction remains authoritative:

1. A touch on the live membrane positions the vertical lane and updates the lane control.
2. The visitor presses Tug, Knot, or Illuminate to submit that named action at the chosen lane.

Touching the canvas never commits a gesture by itself. There is no selected-gesture mode and no optimistic formation. The server continues validating live-edge state, identity, lane, cooldown, and rate limits before persistence and broadcast.

One-finger horizontal movement outside direct placement pans the timeline. Direct placement owns vertical movement after a valid live-membrane start. A cancelled gesture or second touch restores the previous lane and creates no server update. A normal end synchronizes the final lane at most once.

Panning away from Now disables the lane and gesture buttons and exposes Return live. Zooming out at Now leaves them operable.

## Renderer architecture

### Timeline state

The renderer owns two explicit values:

- `timelineDurationMilliseconds`, restricted to `60_000`, `300_000`, or `900_000`;
- `viewLagMilliseconds`, a finite non-negative offset between canonical Now and the visible right boundary.

The renderer exposes a scale-setting method that accepts only the three supported durations. Invalid values fall back to one minute at initialization and are ignored after a valid renderer exists. Scale is browser-local and resets to one minute on a new page load.

`atLiveEdge()` depends on historical lag rather than display scale. A zero lag is live at every supported duration.

### Time projection

Geometry no longer owns a module-level fixed 60-second projection assumption. The projected viewport supplies:

- the visible interval end;
- the selected interval duration;
- viewport width, height, padding, and bounded instructions.

`eventTimeToX` maps timestamps into that explicit interval. Live display, history, scaffold, hit regions, seams, and diagnostics use the same projection values. Sequence spacing remains only the legacy fallback for inputs without a valid time axis.

Pan input converts horizontal pixels into elapsed milliseconds using the usable canvas width and current duration. Dragging right moves toward earlier time; dragging left moves toward Now. Lag is clamped to zero at the live edge and to the oldest authorized extent at the historical boundary.

For a panned view, changing from duration `oldDuration` to `newDuration` adjusts lag so the old center time remains the new center time, then clamps only where the live or archive boundary makes perfect preservation impossible.

### Snapshot stability

Before installing a newer live snapshot, the renderer records the canonical window-end delta. If lag is non-zero, it increases lag by the same delta so the visible interval does not drift forward. At Now, lag remains zero and the view advances normally.

Reload and route transitions establish a fresh canonical anchor. Return live clears lag, historical instructions, request state, and transient selection exactly as today, but it does not reset the visitor's chosen 1m/5m/15m scale during the current page session.

### Bounded range coverage

At one minute, the initial live snapshot remains sufficient. A measured balanced local interval contains 1,022 genuine events over fifteen minutes, so nearest-sequence cursor pages cannot both cover the requested time and preserve the 600-event renderer bound. Wider zoom and time-axis panning therefore use a typed `timeline-window` LiveView request rather than cursor-page autofill.

The server validates the requested duration against `60`, `300`, or `900` seconds and parses the requested UTC interval end strictly. It queries no more than fifteen minutes through the existing source/time indexes and builds level-of-detail from stored records:

- keep at most 100 deterministic temporal-bucket representatives per non-weather source across the complete interval, including that source's first and last event;
- force-include a selected chapter anchor when present, replacing its nearest same-source representative if necessary;
- reserve mandatory endpoints and the anchor first, round-robin the remaining representatives across sources to a final cap of 600, then restore chronological order;
- load the public scaffold and the latest authorized ambient weather at or before the interval end;
- authorize exactly the returned selectable formations.

This projection does not average, stretch, duplicate, interpolate, or invent events. Sparse sources remain sparse and genuine temporal gaps remain empty. The 600-event renderer bound, 4,000-command bound, and one-request-in-flight rule remain unchanged.

The request uses the LiveView push reply as its acknowledgement. An accepted reply contains the bounded instructions, scaffold, ambient state, exact axis, and archive boundary. A request inside the existing 500-millisecond server guard returns an explicit `throttled` reply with `retry_after_ms`; it is never silently discarded. The browser keeps only the newest unsatisfied scale/pan intent, retries it after the guard, and ignores stale replies after a route-generation change. It stops at coverage or the returned archive boundary.

The existing `history-before` cursor handler and its validation remain intact for compatibility in this change, but the new zoom path does not depend on repeated cursor requests.

## Component boundaries

### `geometry.js`

- Accept explicit interval duration and visible end.
- Project all timed commands and hit regions through the same axis.
- Preserve bounded sequence fallback for non-timed legacy inputs.
- Expose deterministic diagnostics for the selected scale and visible UTC range.

### `renderer.js`

- Own supported scale, canonical window end, historical lag, and coverage checks.
- Convert pan pixels to elapsed time.
- Preserve historical center on scale changes and historical time on snapshots.
- Request bounded range coverage, queue only the latest unsatisfied intent, and keep Return live semantics.
- Report scale and visible range to the hook.

### `hook.js`

- Bind the external scale buttons idempotently across LiveView updates.
- Apply `aria-pressed`, active data state, and readable UTC-range text from renderer state.
- Bridge accepted/throttled `timeline-window` replies to the renderer with a route-generation guard.
- Keep explicit wheel, pointer, and touch panning behavior.
- Preserve direct touch placement completion and cancellation invariants.
- Synchronize diagnostics after scale, pan, resize, snapshot, range, and route changes.

### LiveView template and CSS

- Render the semantic scale-button group with stable IDs.
- Place one group inside a `.timeline-controls` wrapper with the decorative Earlier—Now rule. Desktop stacks both above the dock; compact layouts hide only the decorative rule and retain the same group above the dock.
- Use Lacquered Gallery semantic tokens, visible focus, forced-colors support, and reduced-motion-safe states.
- Keep historical gesture disablement and Return live rendering server-authoritative.

### LiveView server

The server adds one bounded `timeline-window` request/reply contract. It receives a requested duration and UTC interval end, validates both without persisting them, projects an authorized interval, and replaces range-selection authorization atomically with exactly that reply. Chapter reloads also expose the selected event's trusted `anchor_at`. Existing history cursors, viewport live-edge state, lane changes, selection events, and gesture submissions retain their current validation.

### Timeline projection and Store

- Query the requested event-time interval using the existing `(source, occurred_at, id)` and partial `(occurred_at, id)` indexes.
- Bound database output with deterministic per-source temporal buckets before loading full event structs into the LiveView process.
- Balance only genuine representatives and force-include a trusted selected anchor without exceeding 600 events.
- Return the relevant historical ambient state and archive boundary with the same projection.

## Touch reliability correction

The Canvas shell is fixed and already hides page overflow, but `.loom-stage` currently declares `touch-action: pan-y`. That declaration gives the browser ownership of the same vertical motion direct lane placement needs and may produce `touchcancel` before Worldloom finishes placement. The stage will declare `touch-action: none`; scrollable panels remain separate overlay targets with their existing overflow behavior.

The hook retains its explicit state machine:

- one active pointer type at a time;
- one active touch for placement;
- no server lane push during preview;
- one final lane push on a normal end when the snapped lane changed;
- full rollback on cancellation or multi-touch;
- short click suppression after placement so the generated click does not select a formation.

No gesture event is emitted by Canvas placement. Native form submission remains the only client entry to visitor formation creation.

## Root cause of the failing mobile test

The existing mobile browser test successfully taps Tug and observes a committed sequence. It fails afterward while trying to inspect a formation for two independent test-harness reasons:

1. The deterministic seed occupies the previous UTC hour. Committing a current visitor gesture advances the canonical live minute and can legitimately remove the older seed from the visible one-minute interval before inspection.
2. `tapVisibleFormation` reconstructs x-coordinates with `(maximumSequence - sequence) * 28`, an obsolete sequence-spacing model. Production projection has used event time since commit `c9c372a`.

The production action succeeds; the verification path is stale. The corrected test will inspect an existing rendered formation before creating a new gesture and will use renderer-reported hit commands instead of reimplementing geometry.

## Error and recovery behavior

- Unsupported scale input never produces non-finite geometry and cannot expand beyond fifteen minutes.
- A scale change with insufficient loaded history shows available material while one bounded range request is in flight.
- A throttled range request is explicitly acknowledged and retried once the guard expires; rapid changes retain only the latest intent.
- Archive start stops further requests and preserves the visible empty interval.
- Live snapshot arrival during a range request cannot move the selected historical time.
- Touch cancellation, lost capture, second touch, disabled lane state, cooldown, and historical mode create no gesture.
- A failed gesture commit updates only the safe status region and leaves Canvas topology unchanged.
- Canvas or context absence remains a safe no-op for server rendering and unit tests.
- Reduced motion changes animation only; scale, pan, touch, and gesture actions remain complete.

## Accessibility

- Scale buttons are native buttons in a named group and expose the active choice with `aria-pressed`.
- Each scale target is at least 44 by 44 CSS pixels on desktop and mobile.
- The rendered timeline exposes the selected scale and visible UTC start/end as persistent text referenced by the control group. It is not an `aria-live` region, so panning and live snapshots do not create announcement noise.
- Keyboard visitors can Tab to any scale and activate it with standard button behavior.
- Focus uses the existing saffron ring and remains visible against wine surfaces.
- Forced-colors mode retains button boundaries and current-state text.
- Gesture actions retain native buttons, descriptions, cooldown messaging, lane slider, and status announcements.
- Touch, pointer, and keyboard routes produce the same committed server event and permanent formation semantics.

## Testing strategy

Implementation follows red-green-refactor. Each production behavior begins with a failing test that fails for the missing or incorrect behavior.

### Geometry tests

- One-, five-, and fifteen-minute endpoints map exactly to padded viewport edges.
- Equal timestamps remain in one time column at every scale.
- History and scaffold positions use the same explicit interval without clamping old timestamps onto an edge.
- Unsupported or non-finite duration inputs stay finite and bounded.
- Hit regions and painted commands share projected coordinates.

### Renderer tests

- Scale defaults to one minute and accepts only 1m/5m/15m.
- Now stays on the right at every scale and `atLiveEdge()` remains true.
- A historical center timestamp survives scale changes where boundaries permit it.
- New snapshots leave a panned visible interval unchanged.
- Pan distance maps proportionally to elapsed time at each scale.
- Wider intervals request one bounded range at a time, coalesce rapid changes to the latest intent, retry explicit throttles, and stop on coverage or archive boundary.
- Return live clears lag without resetting the selected scale.
- Resize and reduced motion preserve the same time interval and settled topology.

### Hook tests

- Scale controls bind once across repeated LiveView updates.
- Activating a control updates renderer scale, active state, assistive range text, and diagnostics.
- Accepted, throttled, stale-generation, and destroyed-hook range replies cannot deadlock or overwrite a newer intent.
- Direct touch placement previews locally and pushes one changed lane only on completion.
- Cancel, second touch, disabled state, and historical state restore safely without a lane or gesture push.
- Touch placement and horizontal panning remain isolated.

### LiveView tests

- Live, panned, and chapter routes render stable scale-control IDs and accessible group semantics.
- Chapter routes keep gesture controls disabled while scale remains available.
- A range request accepts only supported durations and strict UTC ends, returns bounded real instructions, atomically authorizes them, preserves a selected chapter anchor, and explicitly replies when throttled.
- Existing history cursor validation, authorization, throttling, and viewport-state tests remain green.

### Timeline projection and Store tests

- A 1,000-plus-event fifteen-minute fixture returns at most 600 real records while retaining temporal endpoints and every represented source.
- Dense sources cannot crowd out sparse sources; ordering is deterministic and chronological after selection.
- Weather remains ambient rather than topology, a selected anchor is force-included, and invalid intervals fail before a query.
- Query-plan/index assertions cover the bounded source/time access path.

### Browser tests

- Desktop and mobile can choose 1m/5m/15m and observe the exact scale/range state.
- Now remains pinned when zooming live; a historical center remains stable when zooming panned.
- Keyboard activation and 44-pixel targets pass.
- A real mobile touch on the live membrane changes the lane once, followed by a touch submission that commits the chosen gesture.
- Tug, Knot, and Illuminate each pass through native `.tap()` in isolated mobile identities and produce their distinct committed formation.
- Formation inspection occurs before the new current-time gesture and taps a renderer-authoritative visible hit region.
- A compact overlay remains touch-scrollable after the Canvas takes full touch ownership.
- Reduced motion preserves zoom and touch operation.
- Browser console, page, request, response, and WebSocket failure monitors remain empty.

### Visual verification

- Preserve the current `0.08` screenshot threshold.
- Keep the existing balanced one-minute desktop/mobile baselines and add a deterministic quarter-hour E2E scene with genuine prior events for dedicated fifteen-minute desktop/mobile baselines.
- Inspect the scale group, dock spacing, live-edge alignment, legend overlap, selected formation, cooldown, and historical Return live state.
- Confirm the weave remains legible at fifteen minutes without lifting renderer bounds.

### Release verification

- Run all Node tests.
- Run `mix precommit`.
- Run all Playwright tests without snapshot-update mode.
- Build the production container.
- Inspect every changed visual baseline and the final desktop/mobile localhost render.
- Obtain an independent code and specification review.
- Require exact-head GitHub CI before merge.

## README changes

The README will be updated only for shipped behavior:

- Add 1m/5m/15m zoom to **What you can do**.
- Explain live Now anchoring and historical center anchoring.
- Describe the two-step touch flow: position the lane, then press a named action.
- Expand verification language to include timeline scale, anchor preservation, and real mobile touch submission.

No hosted-demo claim, source posture, privacy claim, runtime version, or deployment requirement changes as part of this work.

## Acceptance criteria

- Visitors can choose 1m, 5m, or 15m on desktop and mobile with 1m active by default.
- At Now, all scales keep the live edge pinned right and leave gestures enabled.
- In panned history, scale changes preserve the viewport center time where boundaries permit.
- Live snapshots do not drag a historical view forward.
- Chapter views support the same scales and remain read-only.
- Wider scales fetch only an authorized, temporally representative bounded projection and stop correctly.
- Timeline and hit geometry use one explicit time axis; browser tests do not duplicate projection math.
- Direct mobile touch reliably positions a lane, cancellation restores state, and a normal end synchronizes once.
- Tug, Knot, and Illuminate commit through real mobile taps and remain durable, shared, and inspectable.
- All controls meet keyboard, focus, labeling, forced-colors, reduced-motion, and touch-target requirements.
- README documentation matches delivered behavior.
- Node, Phoenix, Playwright, container, local visual, independent-review, and exact-head CI gates pass.
