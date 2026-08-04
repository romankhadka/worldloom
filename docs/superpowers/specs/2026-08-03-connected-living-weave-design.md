# Connected Living Weave Motion Design

**Date:** 2026-08-03
**Status:** Approved
**Scope:** Replace Worldloom's isolated canvas marks and two-step visitor gesture control with a deterministic connected spline network and direct gesture actions.

This addendum governs renderer and visitor-gesture behavior wherever it differs from the original Worldloom design.

## Problem

Worldloom currently renders each Wikimedia instruction as one isolated cubic Bézier mark. Its length ranges from 40 to 130 CSS pixels, so a busy scene reads as scattered dashes rather than a woven organism. Tug uses the same isolated curve primitive, while Knot and Illuminate are small circles. Their shapes are technically present but do not visibly bend, join, or light the surrounding fibers.

The controls compound that problem. Pressing Tug, Knot, or Illuminate only changes `aria-pressed`; a separate Weave button performs the commit. The selection change is too subtle, so the action buttons appear inert. The commit, persistence, broadcast, and cross-browser delivery paths work correctly.

## Goals

- Make the canvas read as one connected living weave composed of long, smooth fibers.
- Give Tug, Knot, and Illuminate distinct structural effects on that weave.
- Make each gesture button perform its action immediately at the selected vertical lane.
- Preserve persist-before-broadcast, deterministic reconstruction, historical permalinks, source distinctions, privacy, bounded memory, accessibility, and reduced-motion behavior.
- Keep settled animation inexpensive enough that topology is not rebuilt on every frame.

## Non-goals

- No physics or particle simulation.
- No database migration or durable instruction-contract change.
- No optimistic gesture mark before persistence succeeds.
- No change to upstream feeds, event ordering, history pagination, or multi-node assumptions.
- No redesign of the header, archive, detail panel, or public deployment architecture.

## Approved experience

### Connected living weave

The canvas displays a shared branching network instead of independent marks. Wikimedia activity extends fine cyan fibers through neighboring event anchors. When enough anchors are visible, a settled path spans 35–65% of the viewport. Shared endpoints and continuous tangents make adjacent spans read as one organism.

Earthquakes remain ember knots and tension ripples attached to the nearest fiber. Weather remains the moss-and-gold ambient field. Visitor gestures modify or accent the local network in warm ivory rather than adding unrelated symbols.

### Grow, settle, breathe

A newly received committed event draws its new path segment into place, emits one source-appropriate local response, and then joins the settled network. New segment growth lasts between 700 and 1,300 milliseconds according to projected path length. Reloaded, historical, catch-up, resized, and panned scenes render directly in their settled state.

After settling, the network breathes through a cached-layer translation of at most 1.25 CSS pixels and an alpha change of at most 0.04 over a 12-second cycle. The topology and control points do not change during the breath. At most eight transitions may remain active; when a ninth arrives, the oldest transition resolves immediately to its settled state.

Visitors who prefer reduced motion receive only the settled frame. Growth, pulses, breathing, and animated return-to-live behavior are disabled while all textual updates remain available.

## Rendering architecture

The durable Elixir event and instruction types remain authoritative. A new pure JavaScript geometry stage derives a graph and spline paths from the same bounded instruction window.

### `topology.js`

`topology.js` owns deterministic graph construction. It has no canvas, DOM, clock, or mutable global dependency.

Its input is only the unique, sequence-ordered instruction window. All graph relationships use normalized lanes, sequence relationships, and stored deterministic visual parameters; viewport dimensions cannot influence connectivity. It returns:

- stable event anchors with sequence and hit regions;
- connected fiber branches and junctions;
- ornaments for earthquakes and illumination;
- local deformation metadata for visitor tugs;
- source and intensity styling metadata.

Instructions are applied in sequence order. Wikimedia instructions extend the nearest eligible cyan branch in their normalized lane neighborhood. Ties are resolved by sequence and the stored deterministic seed. A new branch begins only when no eligible predecessor exists, and it receives a short connector to the nearest established branch so the visible network remains coherent.

Visitor instructions are applied to the graph at their committed sequence position:

- **Tug** displaces the nearest anchor and its two neighbors toward the chosen lane. Magnitude comes from stored intensity, spread, and bend. It leaves a deterministic local bend.
- **Knot** joins the nearest two distinct branches with a short crossover and durable knot core. If only one branch is available, it forms a loop on that branch instead of failing.
- **Illuminate** selects the nearest junction, or nearest anchor when no junction exists, and attaches a warm light point with connected-path glow metadata.

Earthquake instructions attach a knot and ripple to the nearest anchor without changing branch connectivity. Weather instructions do not add anchors; the latest visible or ambient weather instruction supplies atmosphere metadata.

Graph construction remains bounded by the existing 600-instruction window. Every instruction contributes a bounded number of anchors, edges, ornaments, and hit regions so the existing 4,000-command ceiling remains enforceable.

### `geometry.js`

`geometry.js` projects the graph into viewport coordinates. Fiber branches use centripetal Catmull–Rom interpolation with alpha `0.5`, converted to cubic Bézier segments for Canvas 2D. This preserves tangent continuity while avoiding the loops and overshoot common with uniform splines.

Projected controls are clamped to the viewport's vertical padding. Horizontal coordinates remain on the sequence timeline and may be offscreen so panning and historical reconstruction do not collapse old anchors onto an edge. A branch with sufficient visible history groups neighboring anchors into overlapping long spans. Each span contains at least four anchors and targets 35–65% of viewport width. Sparse history uses the longest valid connected span without inventing events.

Sequence-to-horizontal-position, normalized lane-to-vertical-position, chapter seams, panning, hit regions, and future-render-version fallback remain supported. A resize reprojects normalized anchors but does not change graph relationships.

### `renderer.js`

The renderer owns lifecycle and animation, not topology rules. It maintains:

1. the ambient weather layer;
2. a detached standard `<canvas>` cache of settled fibers and durable ornaments;
3. active growth and gesture-response overlays;
4. viewer pulses and interaction affordances.

Topology and settled caches rebuild only after an instruction-window change, resize, pan, history load, catch-up, or return-to-live. Animation ticks composite the settled cache and draw bounded transient overlays; they never reconstruct topology.

The renderer uses `requestAnimationFrame`. Path growth duration is `clamp(700, projected_length * 1.8, 1300)` milliseconds. Tug responds for 600 milliseconds, Knot for 900 milliseconds, and Illuminate for 1,200 milliseconds before retaining its settled geometry. Animation timestamps are client-local and never persisted. The final topology depends only on committed instructions and viewport projection.

## Direct gesture interaction

The vertical lane slider remains. The selected-gesture state and separate Weave button are removed.

Tug, Knot, and Illuminate become submit buttons in the lane form. The clicked button supplies the gesture name, and the form supplies the current lane. The LiveView boundary parses the encoded lane into a bounded number before calling the existing gesture policy; the policy continues rejecting encoded or malformed lanes when called directly.

On submission:

1. LiveView's form-loading state disables duplicate submission and the pressed button displays `Weaving…`.
2. The server validates live-edge state, anonymous identity, lane, and cooldown.
3. The coordinator persists the visitor event.
4. Only the committed PubSub broadcast reaches the renderer and starts the visual response.
5. The status region announces acceptance or a safe failure.

There is no optimistic canvas mutation. A rejected action leaves the network unchanged. During the 30-second cooldown, all three action buttons remain disabled and the live status communicates when another gesture is available. Historical or panned-away views retain the existing Return live behavior and disable the complete gesture form.

All action buttons preserve at least 44-by-44 CSS-pixel targets. Keyboard activation, focus indication, tap behavior, and screen-reader names are equivalent. `aria-pressed` is removed because the buttons are actions, not persistent choices.

## Formation semantics

### Tug

Tug visibly bends a neighborhood rather than drawing another independent line. The active response pulls the affected span toward the chosen lane, briefly reveals tension along adjacent segments, and settles into the derived bend.

### Knot

Knot visibly connects paths. The active response draws the short bridge from both sides toward the crossover, tightens once, and settles as an ivory loop with a gold core.

### Illuminate

Illuminate visibly lights the network. The active response blooms at the chosen junction and travels a short distance along connected edges, then settles as a small warm point with no continuous flashing.

The accessible formation list and detail panel continue describing the committed event source, time, and summary. No raw upstream data or anonymous identity enters canvas metadata, HTML, logs, or permalink state.

## Failure and lifecycle behavior

- Invalid geometry, non-finite controls, or an unsupported render version produces the existing bounded fallback mark for that instruction; it does not abort the frame.
- A history, catch-up, reload, resize, or pan rebuild resolves transient animations to settled geometry first.
- An out-of-order event remains queued behind existing sequence-gap recovery and does not enter topology before its gap is resolved.
- A failed gesture commit updates only safe status text. It does not advance the rendered watermark or mutate the cached network.
- Canvas/context absence remains a safe no-op for server rendering and unit tests.
- Destroying the LiveView hook cancels the animation frame and releases offscreen canvas references.

## Testing strategy

### Pure geometry tests

- The same instructions and viewport produce byte-for-byte equivalent graph and path commands.
- Input order and duplicate instructions do not change topology.
- Every eligible fiber span is connected, finite, within padded bounds, and tangent-continuous at shared joins.
- With sufficient history, long spans occupy 35–65% of viewport width.
- Resize changes projected coordinates without changing branch and junction relationships.
- Tug changes neighboring spline controls, Knot adds a cross-branch edge or single-branch loop, and Illuminate selects a junction or anchor.
- Sparse, malformed, and future-version instructions use bounded fallbacks.
- Event, edge, command, and active-transition limits cannot grow past their caps.

### Renderer tests

- Initial, history, reload, catch-up, resize, and pan paths settle immediately.
- A newly committed instruction grows once and resolves to the same settled commands as reconstruction.
- Animation ticks do not invoke topology construction.
- The ninth concurrent transition settles the oldest transition.
- Reduced motion requests no continuing animation and renders the settled frame.
- Destroy cancels the active frame and releases transient state.

### LiveView and browser tests

- Each action button submits its own gesture and the current lane without a separate confirmation.
- Pending, accepted, cooldown, invalid, historical, and panned-away states remain safe and accessible.
- No uncommitted gesture reaches either browser in the two-visitor scenario.
- The committed gesture appears in both browsers, survives reload, and exposes its accessible formation detail.
- Keyboard-only and mobile users can adjust the lane and invoke all three actions.
- Reduced-motion browser coverage observes the settled formation without growth or breathing.

The full Elixir, Node, Playwright, Docker, and launch-capacity gates remain required. The existing 200-viewer server test is unchanged. Client smoothness is defended structurally by cached settled rendering, bounded transitions, and tests proving topology is absent from animation ticks.

## Acceptance criteria

- The live scene reads as a connected network rather than scattered short dashes.
- With sufficient visible history, primary fibers span at least 35% and no more than 65% of the viewport.
- Shared spline joins have continuous tangents and no visible corners or loops.
- Tug bends nearby fibers, Knot joins branches, and Illuminate blooms along a junction.
- Pressing any gesture button commits that gesture immediately at the selected lane; no Weave button remains.
- The canvas changes only after the gesture is durably committed and broadcast.
- New paths grow, respond once, settle, and breathe within the specified limits.
- Reload, restart reconstruction, history, and permalinks produce the same settled topology.
- Reduced motion, keyboard, focus, tap, screen-reader text, cooldown, and mobile targets pass.
- Event, command, animation, and memory bounds remain enforced, and the complete release gate stays green.
