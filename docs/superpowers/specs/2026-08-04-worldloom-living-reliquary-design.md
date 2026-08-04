# Worldloom Living Reliquary Design

**Date:** 2026-08-04
**Status:** Design approved; written specification pending review
**Scope:** Transform Worldloom's first impression, living-fiber renderer, visitor interactions, and public presentation without weakening its persistence, privacy, accessibility, or bounded-runtime guarantees.

## Summary

Worldloom will present itself as a mysterious living artwork before it presents itself as software. The approved direction, **Living Reliquary**, turns the existing cyan spline scene into a layered, tactile, bioluminescent organism. Visitors should first feel that they have encountered an artifact that is alive; the Phoenix, OTP, LiveView, persistence, and public-data machinery remain available through the About panel and repository for people who choose to look deeper.

This pass preserves Worldloom's strongest engineering decisions: persist before broadcast, append-only durable history, deterministic reconstruction, compact rendering instructions, bounded browser work, constrained anonymous gestures, stable permalinks, reduced motion, and semantic alternatives to canvas interaction.

## Audit findings

The current application has a stronger technical foundation than public presentation.

### Experience findings

- The canvas reads as a small number of oversized cyan plots rather than a tactile woven organism.
- Large isolated branches and abrupt triangular passages make the scene resemble an oscilloscope or chart.
- Every settled fiber uses one visual stroke, so the canvas lacks depth, material, and source-specific character.
- The empty Formation Detail panel obstructs the artwork before a visitor selects anything.
- The interface does not give a first-time visitor a memorable explanation of what they are witnessing.
- Tug, Knot, and Illuminate commit correctly, but their visual consequences are too restrained to feel meaningful.
- The horizontal lane slider is conceptually disconnected from the vertical location it controls.
- The hard header boundary and persistent utility chrome make the experience feel more like an application than an artwork.

### Public-project findings

- The GitHub About description, homepage, and topics are empty.
- The README advertises a placeholder `WORLDLOOM_PUBLIC_URL` as though it were a live demo.
- The document head lacks a public description, social-preview metadata, theme color, and a complete sharing presentation.
- The About panel is too sparse to function as a curatorial explanation of the work.
- Existing public history includes generic squash messages. This pass will use meaningful commits but will not force-rewrite published history without explicit authorization.

### Verification findings

- The k6 gesture journey sends a JavaScript object as a LiveView `form` event value. Phoenix expects URL-encoded form text, so the previous interaction-at-load exercise did not validate real gesture submissions.
- Unexpected WebSocket closure is not classified strongly enough in the load client.
- The untouched Elixir baseline contains a flaky privacy assertion. It searches the complete serialized visitor payload for the substring `127`, so a valid random visual value such as `0.127611` causes a false failure. The payload observed during the audit contained only the allowed `summary` and `visual` keys. The test must assert structure, not incidental digits.

## Goals

- Make the first five seconds emotionally arresting and immediately distinct from a conventional web interface.
- Make a label-free screenshot recognizable as one coherent living artwork.
- Render connected fibers with depth, continuity, restraint, and source-specific behavior.
- Make Tug, Knot, and Illuminate visibly and semantically consequential.
- Connect gesture placement to the live edge instead of presenting an abstract control.
- Reveal explanation and detail only when the visitor asks for them.
- Improve mobile composition without obscuring the artwork or gesture controls.
- Complete truthful web and GitHub presentation for a public project.
- Repair the load and flaky-test evidence uncovered during the audit.
- Preserve deterministic reconstruction, accessibility, performance bounds, privacy, and recovery behavior.

## Non-goals

- No account, profile, chat, upload, free-form text, avatar, or custom-color system.
- No database migration or new durable render-contract version unless implementation proves it unavoidable. The expected design fits render version 1.
- No particle or physics simulation.
- No audio, scoring, achievements, or game progression.
- No multi-node coordinator or deployment-architecture redesign.
- No optimistic visitor formation before persistence succeeds.
- No paid hosting activation or other cost-incurring infrastructure without explicit authorization.
- No force-push or published-history rewrite without explicit authorization.

## Governing experience principle

Worldloom is an artwork first. The interface should earn curiosity before explaining itself. Technical sophistication remains discoverable in the About panel and public repository but does not compete with the opening scene.

## Opening experience

The initial live route opens directly onto the active organism. A restrained introduction appears over the forming weave:

> The world is weaving itself.

A smaller line provides the minimum grounding:

> Public signals, becoming one persistent fabric.

The introduction recedes after the first meaningful interaction or a short bounded interval. It does not block controls or require dismissal. Its semantic heading remains present for assistive technology after the visual treatment recedes. Reduced-motion visitors receive a stable, non-animated version with the same information.

A single quiet prompt may explain historical movement: `Move left through earlier hours.` The prompt disappears after the visitor pans or after the same bounded introductory interval. It is not persisted as tracking data.

## Living Reliquary visual system

### Composition

- One coherent underlying spine carries the scene horizontally from history toward the live membrane.
- Secondary fibers branch from and reconnect to that spine rather than becoming unrelated full-screen plots.
- Older formations recede slightly in contrast and depth toward the left; the current region remains crisp.
- The right-hand live edge becomes a luminous membrane, not a hard chart axis.
- The composition preserves calm negative space around important knots and interventions.

### Fiber material

Each primary fiber is painted in controlled passes from one geometric command:

1. a broad, low-alpha atmospheric glow;
2. a narrower translucent body;
3. a fine luminous core;
4. occasional bounded capillary filaments at meaningful junctions.

The renderer derives these passes while drawing. It does not multiply durable instructions or expand the command window for cosmetic layers. Glow uses bounded multi-pass strokes rather than unbounded shadow effects.

### Signal language

| Signal | Structural role | Material response |
|---|---|---|
| Wikimedia | Extends connective fibers and capillaries | Cool cyan/verdigris threads with fine activity variation |
| Earthquake | Creates tension, compression, and knots | Ember cores with restrained rings carried by nearby fibers |
| Weather | Changes the containing atmosphere | Moss-and-gold field shifts, density, and warmth rather than new branches |
| Visitor | Alters or accents the organism | Warm ivory bends, joins, and light traveling through existing structure |

Signal meaning must remain distinguishable by structure and textual labeling, not color alone.

### Motion

Motion is biological and event-driven: grow, settle, breathe, respond. It is not constant decorative turbulence.

- New committed fibers grow once and settle.
- The settled organism breathes with the existing small cached-layer translation and alpha bounds.
- Gesture responses animate once, then remain as durable topology.
- Viewer presence remains an aggregate, bounded signal at the live membrane.
- Reduced motion removes growth, breathing, return gliding, and pulses while preserving settled state and textual updates.

## Interface composition

The hard header bar becomes an atmospheric floating layer. The wordmark, UTC chapter, viewer presence, Archive, About, and Share remain available but do not divide the canvas with a strong application boundary.

The empty detail card is removed. No formation panel or sheet is rendered visually until a formation has been selected.

The gesture dock becomes a quiet invitation labeled `Touch the loom`. It stays visually secondary to the artwork while retaining at least 44-by-44 CSS-pixel targets, clear focus treatment, and semantic action buttons.

The legend remains available but becomes quieter and more material: it should explain the scene without reading as a dashboard key. Feed-health qualifiers remain accessible and truthful.

## Visitor gestures

### Placement

The current lane is represented by a warm seed on the live membrane. Pointer and touch visitors can move that seed vertically along the live edge. Keyboard visitors use an explicit semantic range control and arrow keys. The visual control and the semantic range remain synchronized.

The seed is a placement affordance only. It must never preview a gesture result or imply that a formation has committed.

### Actions

The three direct actions retain their existing persistence path and gain short explanatory labels:

- **Tug — bend a strand**
- **Knot — join two paths**
- **Illuminate — awaken a junction**

Submission disables duplicate action while in flight. Only the committed PubSub instruction begins a structural response.

### Consequences

- **Tug** pulls a visible neighborhood toward the seed, shows tension along adjacent segments, and settles into a durable bend.
- **Knot** draws two branches toward a crossover, tightens once, and settles as a luminous structural join. A single available branch still produces a bounded loop.
- **Illuminate** blooms at the chosen junction and carries light a short bounded distance along connected paths before settling as a warm point.

The 30-second cooldown uses a small visual countdown and a polite textual status. Disabled controls must never be unexplained.

## Selection, history, and sharing

Selecting a formation adds a focused halo and opens a compact contextual card with:

- human-readable meaning;
- source;
- UTC occurrence time;
- permanent-link action.

Escape, outside selection, or a new selection closes or replaces the card. The card is positioned to avoid the selected formation where practical. Mobile uses a shallow bottom sheet that never overlaps the gesture dock.

Dragging, horizontal trackpad movement, mouse-wheel movement, and one-finger touch continue to reveal history. UTC chapter seams remain restrained. Returning live glides to the active membrane unless reduced motion is enabled.

Sharing a selected formation copies its stable chapter permalink. Sharing with no selection copies the live route. Clipboard failure exposes a focused, selectable URL and never strands the visitor without a fallback.

## About as curatorial note

The About panel is rewritten in this order:

1. the artistic concept;
2. how public signals become visual material;
3. what visitors can change;
4. persistence and shared history;
5. privacy and the absence of identity, text, and uploads;
6. accessibility behavior;
7. data-source attribution;
8. a concise explanation of the Phoenix/OTP machinery and a repository link.

The panel should reward curiosity without turning the opening experience into a technical case study.

## Rendering architecture

### `topology.js`

The pure topology stage remains independent of canvas, DOM, viewport, clock, and mutable global state. It will strengthen the coherent spine, secondary branches, junctions, and gesture relationships using only ordered versioned instructions and their deterministic visual parameters.

The same bounded instruction set must always produce the same graph relationships regardless of viewport, input order, or duplicates.

### `geometry.js`

The geometry stage projects normalized topology into finite, padded viewport coordinates. It continues using centripetal Catmull-Rom interpolation converted to cubic Bezier segments. It emits enough style metadata for layered fiber drawing without emitting duplicate cosmetic path commands.

Abrupt direction changes, isolated chart-like branches, offscreen-history placement, sparse history, malformed geometry, and future render versions require explicit test cases.

### `renderer.js`

The renderer owns painting and lifecycle, not connectivity rules. It paints settled geometry into a detached cache in ordered passes, then composites bounded transient overlays.

Animation ticks must not reconstruct topology. Rebuild boundaries remain instruction changes, resize, pan, history, catch-up, reload, and return to live. Existing limits remain authoritative:

- at most 600 retained instructions;
- at most 4,000 commands;
- at most eight active transitions;
- at most 12 viewer pulses;
- viewport-sized detached caches only.

### `hook.js`

The hook coordinates DOM input and LiveView events:

- introductory staging;
- lane-seed pointer, touch, and keyboard synchronization;
- selection dismissal;
- clipboard success and fallback;
- reconnect presentation;
- renderer lifecycle.

It does not derive topology or invent durable state.

## Authoritative data flow

External activity continues through the existing path:

```text
Public source -> normalize and bound -> merge buffer -> coordinator
-> transaction -> PostgreSQL -> PubSub -> LiveView instruction
-> topology -> geometry -> renderer
```

A visitor gesture continues through:

```text
Choose lane -> submit allow-listed gesture -> policy and rate validation
-> coordinator transaction -> PostgreSQL -> PubSub -> committed instruction
-> structural canvas response
```

No browser chooses sequence, horizontal position, visual seed, render version, arbitrary content, or an optimistic formation.

## Failure and recovery behavior

- A quiet or stale feed leaves history, gestures, and other sources working. Status is calm and honest.
- A disconnected browser holds the last committed frame and shows a restrained reconnecting state.
- A database failure prevents broadcast exactly as it does now.
- Sequence gaps continue through bounded catch-up or complete bounded reload.
- Unsupported or malformed instructions become finite fallback marks rather than aborting a frame.
- A missing canvas preserves semantic live summaries, source explanations, selection controls, and gesture actions where JavaScript remains available.
- No JavaScript produces a concise explanation rather than an empty visual shell.
- Clipboard failure exposes a selectable link.
- Reduced motion preserves all meaning and control.

## Public web presentation

The document head will include:

- a concise public description;
- Open Graph title, description, type, and preview image;
- corresponding social-card metadata;
- theme color;
- complete favicon links;
- truthful canonical behavior based on the configured public host.

The preview asset must be captured from the verified deterministic experience, not be a disconnected concept image.

## Public repository presentation

The README begins with the artwork and its purpose, then explains operation and architecture. It uses a current verified preview. A live-demo link appears only when a real public URL exists.

GitHub repository metadata will receive:

- description: `A persistent living tapestry woven from public signals and anonymous visitor gestures, built with Phoenix LiveView and OTP.`
- topics appropriate to the implementation and artwork, including `elixir`, `phoenix`, `liveview`, `creative-coding`, `generative-art`, `canvas`, and `real-time`;
- a homepage only after a real hosted URL is reachable.

New commits use small, meaningful, imperative messages. Published history is not rewritten within this scope.

## Testing strategy

All behavioral changes follow red-green-refactor. A new test must fail for the intended missing behavior before implementation changes are written.

### Baseline correction

Replace the flaky substring privacy assertion with exact structural assertions over allowed visitor payload keys and nested visual keys. The correction must continue proving that identity and peer-address material cannot enter stored visitor output.

### Pure JavaScript tests

- A representative busy window produces a coherent primary spine and connected secondary branches.
- The same instructions produce identical topology regardless of input order and duplicates.
- Curves remain finite, smooth, padded, and free from abrupt chart-like overshoot.
- Layered fiber style is derived from one structural command.
- Source families retain distinct structural and non-color meaning.
- Target-seed lane mapping is bounded and reversible.
- Tug, Knot, and Illuminate produce distinct durable structural effects.
- Cosmetic passes do not expand command or event limits.
- Reduced motion and animation ticks do not rebuild topology.
- Canvas/context absence remains safe.

### LiveView tests

- The opening content, semantic title, curatorial routes, and public metadata exist.
- No empty visual detail panel appears before selection.
- Gesture actions submit allow-listed names and bounded lanes.
- Pending, accepted, cooldown, rate-limited, panned, and historical states remain safe and accessible.
- Stored visitor payloads contain only the exact public structure.
- Permalinks and sharing remain stable.

### Playwright tests

- Desktop and mobile layouts show unobstructed artwork and non-overlapping controls.
- Keyboard, pointer, and touch visitors can place and commit each gesture.
- A committed gesture appears in two independent browser contexts and survives reload.
- Selection opens a contextual detail; Escape and outside interaction dismiss it.
- Reduced motion produces a settled scene without continuing animation.
- Clipboard success and fallback are both usable.
- Browser console errors, page errors, failed requests, and unexpected WebSocket errors fail the suite.

### Visual review

Deterministic feed-disabled data will be reviewed at desktop and mobile dimensions. Review explicitly checks:

- coherent organism rather than chart-like plots;
- visible depth and restrained glow;
- distinguishable signal families;
- no empty panels or artwork obstruction;
- readable focus and contrast;
- no clipping or control overlap;
- visibly different gesture consequences;
- stable reduced-motion composition.

### Load verification

The k6 LiveView helper must encode `form` values as URL-encoded text matching browser behavior. Unexpected socket closure, server error replies, decode failures, and unclassified gestures count as protocol failures.

After repair:

- run a gesture smoke profile and prove at least one real commit and observation;
- run 100 connected viewers with concurrent valid gesture traffic locally;
- run the existing 200-viewer launch profile on the exact public deployment size before claiming launch capacity;
- retain p95 committed-gesture-to-browser delivery below 300 milliseconds;
- show no sustained process or memory growth after load ends.

## Release gate

The change is eligible for integration only after:

- `mix precommit` passes cleanly;
- all JavaScript tests pass;
- all Playwright tests pass;
- the production container builds;
- corrected local load profiles pass;
- desktop, mobile, and reduced-motion screenshots receive visual review;
- the branch receives a final diff review;
- GitHub CI passes on the integrated revision;
- public repository metadata is verified after push.

Enabling paid or cost-incurring hosting remains a separate explicit approval. Until then, no page or README may imply that a hosted demo exists.

## Acceptance criteria

1. A new visitor encounters an active artwork and its core idea within five seconds.
2. With interface labels hidden, the scene reads as one coherent living organism rather than a chart or screensaver.
3. Primary fibers visibly contain glow, body, core, and restrained capillary detail without exceeding bounded commands.
4. Wikimedia, earthquake, weather, and visitor signals remain distinguishable by form, text, and color.
5. Tug bends a neighborhood, Knot joins paths, and Illuminate carries light through a junction after durable commit.
6. Lane placement is visually connected to the live membrane and fully operable by pointer, touch, and keyboard.
7. No empty detail panel appears before selection; selected detail never blocks core mobile controls.
8. Historical navigation, return-to-live, stable permalinks, sequence repair, and reconstruction remain deterministic.
9. Reduced motion, semantic summaries, visible focus, target sizes, and non-canvas meaning remain intact.
10. The corrected load client proves real LiveView gesture behavior under concurrent viewers.
11. The README, web metadata, preview asset, and GitHub About section are complete and truthful.
12. All release gates pass before integration to the public `master` branch.

## Deferred decisions

- Hosting provider activation and recurring cost.
- A public custom domain.
- A new durable renderer contract version.
- Generated per-formation social cards.
- Multi-node coordinator leadership.
- Sound, export, or installation modes.
- Rewriting existing public Git history.

Each deferred item requires separate explicit authorization or design work.
