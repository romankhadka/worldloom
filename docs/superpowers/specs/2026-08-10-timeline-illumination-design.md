# Timeline illumination design

Date: 2026-08-10
Status: approved (maintainer granted full creative liberty for the visual pass)

## Problem

The Lacquered Gallery color system is distinctive, but its execution reads flat.
The canvas paints thin strokes at low alpha over a near-black field with normal
compositing, so the "glow" material layers look like wide dim lines rather than
light. The stage background is an even maroon wash, the live edge barely reads
as luminous, and the interface panels carry more visual weight than the artwork.
The result is legible but not something a visitor wants to watch for hours.

## Direction

Keep the approved Lacquered Gallery tokens and signal palette exactly. Change how
that palette is *lit*:

1. **A real light model on the canvas.** Glow layers composite additively
   (`globalCompositeOperation: "lighter"`), so overlapping fibers brighten the
   way light does. Illuminations, knots, ripples, seeds, pulses, and the
   selection halo become radial-gradient blooms with soft falloff instead of
   flat fills and hairline circles. Fibers get round caps.
2. **A depth-lit stage.** The CSS shell gains a deeper vignette, a warm aurora
   biased toward the live edge where Now lives, a finer woven texture, and film
   grain, so the field reads as lacquer depth instead of flat maroon.
3. **Luminous Now.** The live edge shimmers gently (reduced motion: static) and
   its seed blooms, making "the present lives at the luminous right edge" true.
4. **Quieter chrome.** Panels become thinner glass with hairline borders and a
   saffron accent; interactive controls gain unhurried hover/focus transitions;
   typography spacing is refined. The interface recedes; the weave leads.

## Constraints preserved

- Signal palette and Lacquered Gallery token hex values are unchanged;
  `palette.test.js` and the token maps in `color_system.test.js` still hold.
- No color literals in `renderer.js`/`geometry.js`; gradients derive their
  stops from palette entries at runtime.
- No hex literals after the `@property --cooldown-progress` sentinel in
  `app.css`; every new tint is a `--loom-*` token defined in `:root`.
- Topology, geometry, instruction contract, bounds, determinism, hit areas,
  and `settledSceneDiagnostics` output are untouched. Painting changes only.
- Reduced motion, keyboard focus, forced colors, and touch targets keep their
  existing behavior; animations added here are decorative and disabled under
  `prefers-reduced-motion`.
- DOM structure and element IDs are unchanged.

## Verification

`mix precommit`, `npm test`, then `npm run test:e2e` with regenerated darwin
baselines after visually inspecting desktop, mobile, tablet, and reduced-motion
screenshots. Linux baselines regenerate in the Playwright container image so CI
compares like for like.
