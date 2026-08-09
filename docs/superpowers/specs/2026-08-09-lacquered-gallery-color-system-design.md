# Lacquered Gallery Color System Design

**Date:** 2026-08-09  
**Status:** Approved  
**Scope:** Replace Worldloom's current cyan-and-green visual palette with the approved Earth & Lacquer / Lacquered Gallery system across the browser interface, Canvas renderer, metadata, and social presentation.

## Summary

Worldloom will adopt a richer, more dramatic art direction called **Lacquered Gallery**. Oxblood-black atmosphere and saturated wine surfaces will frame vivid jade, smoky blue, copper, and saffron materials. Warm bone replaces cool white as the principal reading color. The result should feel like a living artifact installed in a dark gallery: tactile, magnetic, and ceremonial without becoming noisy or compromising long-session legibility.

The change is visual only. It does not alter data ingestion, signal semantics, topology, persistence, visitor actions, health behavior, layout, navigation, or public-source eligibility.

## Goals

- Make the whole application feel refined, distinctive, and engaging rather than merely dark and bioluminescent.
- Apply the chosen Earth & Lacquer character to the complete interface, not only the Canvas artwork.
- Preserve a clear visual hierarchy despite richer saturation.
- Keep every source recognizable through its existing structural grammar and a deliberate material color.
- Make interactive, health, focus, disabled, and disconnected states immediately legible.
- Keep desktop, mobile, reduced-motion, and forced-colors presentations complete.
- Update public metadata and the social preview so external presentation matches the application.

## Non-goals

- No layout, typography-family, copy, interaction, navigation, or animation redesign.
- No new themes, theme switcher, user-selected colors, or light mode.
- No change to signal topology, geometry, intensity, event ordering, or renderer limits.
- No change to feed-health rules or provider behavior.
- No additional fonts, packages, remote assets, or runtime dependencies.

## Governing visual principle

**A lacquered room containing a living artifact.** Saturation should be present throughout the interface, but the weave remains the visual subject. Surfaces gain color and material depth; they do not compete through gradients, glow, or brightness. Saffron marks moments of agency and attention. Warm bone carries information. Source colors belong primarily to the artwork and its key.

## Foundation palette

The implementation will use semantic tokens rather than component-specific color literals.

| Role | Token | Color | Use |
|---|---|---:|---|
| Deep ground | `lacquer-deep` | `#120708` | Body, deepest canvas corners, maximum-depth shadows |
| Atmospheric ground | `lacquer` | `#241013` | Main canvas field and header fade |
| Primary surface | `wine` | `#35171A` | Panels, legend, gesture dock, detail cards |
| Raised surface | `wine-raised` | `#4B2020` | Hovered controls and elevated surface accents |
| Primary text | `bone` | `#F6E2C5` | Titles, wordmark, important values, active labels |
| Secondary text | `parchment` | `#CBB89F` | Supporting copy, metadata, inactive navigation |
| Interface accent | `saffron` | `#E3A53A` | Focus, active actions, live-edge emphasis, key labels |
| Primary living material | `jade` | `#4DB69A` | Connective weave and primary organic energy |
| Structural cool material | `mineral-blue` | `#6C9BAD` | Routing and cool structural contrast |
| Event material | `copper` | `#E07245` | Ruptures, warnings, warm event energy |

Translucent backgrounds, borders, shadows, and atmospheric gradients derive from these foundations with explicit alpha values. New one-off hexadecimal colors are not introduced in component rules.

## Signal material palette

Signal meaning continues to be encoded by shape, rhythm, textual labels, and color. Color remains supplementary rather than authoritative.

| Source | Family | Stroke | Glow | Structural meaning preserved |
|---|---|---:|---:|---|
| Wikimedia | Aged jade | `#4DB69A` | `#9CE6D0` | Continuous connective backbone |
| Bluesky | Smoky periwinkle | `#9A84C7` | `#D4C5F1` | Branching conversation fan |
| RIPE RIS Live | Mineral blue | `#6C9BAD` | `#B9DCE5` | Angular route forks |
| Solana | Marigold | `#E0A43B` | `#F5CF7A` | Slot braid and beads |
| drand Quicknet | Moonstone | `#C7DDD6` | `#F2EFE2` | Crystalline public pulse |
| USGS earthquakes | Copper | `#E07245` | `#FFB080` | Rupture and scar rings |
| Open-Meteo weather | Olive jade | `#8DA56E` | `#C5C77C` | Shared atmospheric field |
| Visitors | Bright bone | `#FFE8C9` | `#FFF4DF` | Human intervention and illumination |

Canvas material widths, alpha layering, topology, and animation timing stay unchanged. Only stroke, glow, ambient, selection, seed, and viewer-pulse colors change.

## Interface application

### Atmosphere and canvas

- The background transitions from `lacquer-deep` through `lacquer` into a restrained wine edge.
- Radial atmosphere uses low-alpha jade, copper, and saffron rather than cyan, olive, and gold.
- Texture lines derive from jade and saffron at very low opacity.
- Vignettes use lacquer-black, avoiding neutral black wherever the material system is visible.
- The live membrane, target seed, selection halo, and viewer pulses use bone and saffron materials.

### Header and navigation

- The header haze becomes a lacquer-to-transparent fade with a restrained saffron boundary.
- The wordmark remains bone; its glyph uses jade with a copper-adjacent glow.
- Inactive navigation uses parchment. Hover and current emphasis use bone or saffron according to state.
- Focus rings use saffron and remain at least two CSS pixels wide with the existing offset.

### Panels and overlays

- Legend, About, Archive, formation detail, share fallback, mobile navigation, and gesture dock use translucent wine surfaces.
- Borders use saffron/bone-derived alpha values instead of neutral ivory alone.
- Raised or interactive surfaces use `wine-raised`; shadows use lacquer-black.
- Backdrop blur remains bounded and unchanged.

### Gesture controls

- Resting buttons use a subtle bone-on-wine contrast.
- Hover and pressed states use `wine-raised` plus a saffron or source-appropriate edge.
- Illuminate is the brightest action through saffron emphasis, while Tug and Knot remain equally discoverable through layout, labels, and focus behavior.
- Disabled and cooldown states lower saturation and opacity without removing explanatory text.

### Status colors

| State | Color | Notes |
|---|---:|---|
| Live | `#86D29D` | Clear green against wine surfaces |
| Quiet / pending | `#E3A53A` | Saffron communicates attention without alarm |
| Disconnected / error | `#F08268` | Coral remains distinct from copper source material through label and context |
| Disabled, if displayed in historical or operator contexts | `#9F8C82` | Muted but readable; never used for an enabled default source |

Every status retains a written label. No health or interaction state depends on color alone.

## Token architecture

- CSS foundation and interface tokens live in `assets/css/app.css` under `@theme` and `:root`, using semantic Lacquered Gallery names.
- Canvas-only material tokens live in a small immutable `assets/js/worldloom/palette.js` module.
- `geometry.js` imports source materials from the palette module rather than owning hexadecimal literals.
- `renderer.js` imports seed, selection, viewer, and fallback materials from the same module.
- CSS and Canvas have separate token declarations because they execute across different rendering boundaries. Tests verify the approved semantic mappings so accidental drift is visible.
- The root `theme-color`, Open Graph alternative text, Twitter alternative text, copper-colored favicon artwork, and social-preview asset use the same foundation palette.

## Accessibility

Opaque reference combinations exceed WCAG AA contrast requirements:

| Combination | Contrast ratio |
|---|---:|
| Bone on lacquer-deep | 15.67:1 |
| Bone on wine | 12.88:1 |
| Parchment on wine | 8.45:1 |
| Saffron on wine | 7.53:1 |
| Jade on lacquer-deep | 8.00:1 |
| Live green on wine | 9.09:1 |
| Disconnected coral on wine | 6.28:1 |
| Lacquer-deep on saffron | 9.16:1 |

Implementation verification must measure rendered translucent states against their composed backgrounds rather than relying only on these opaque references.

The existing forced-colors rules remain authoritative. Reduced motion receives the complete settled palette without relying on animated glow. Focus, hover, pressed, disabled, selected, cooldown, connected, quiet, and disconnected states require visual review with keyboard navigation.

## Public presentation

- Update the browser `theme-color` from the old green-black to `lacquer-deep`.
- Update social-image alternative text so it names the new oxblood, jade, copper, and saffron appearance truthfully.
- Recolor the existing favicon artwork from generic orange to the approved copper material while preserving its geometry and file contract.
- Regenerate `priv/static/images/worldloom-social-preview.png` from the verified deterministic experience at 1600 by 900 pixels.
- Keep the existing title, description, canonical behavior, and public claims unchanged.

## Error and recovery behavior

The color pass does not change application behavior. Existing reconnect, flash, cooldown, clipboard-fallback, no-JavaScript, and provider-health messages retain their semantics. Each receives a Lacquered Gallery surface and state treatment with the same DOM, copy, and assistive behavior.

If Canvas is unavailable, the semantic page remains readable in bone and parchment on lacquer surfaces. If custom colors are suppressed, the existing forced-colors presentation remains usable.

## Testing strategy

Implementation follows red-green-refactor for testable behavior and token contracts.

### CSS and JavaScript tests

- Assert the approved semantic CSS foundations are present and old foundation tokens are absent from active rules.
- Assert each Canvas source maps to the approved stroke and glow pair.
- Assert target seed, selection halo, viewer pulse, and renderer fallbacks use palette exports rather than hard-coded colors.
- Retain all existing topology, geometry, renderer-bound, reduced-motion, and malformed-input coverage.

### LiveView and metadata tests

- Assert `theme-color` matches `lacquer-deep`.
- Assert social-image alternative text truthfully describes the Lacquered Gallery preview.
- Retain all current interaction, panel, health, privacy, and semantic-content coverage.

### Browser and visual verification

- Capture deterministic desktop, mobile, and reduced-motion states.
- Review the opening scene, expanded legend, gesture hover/focus/disabled states, selected formation, About, Archive, share fallback, reconnect notice, and cooldown.
- Confirm the weave stays the focal point despite saturated surfaces.
- Confirm source materials remain distinguishable in busy scenes and under common color-vision deficiencies.
- Confirm no controls, text, canvas content, or responsive layouts regress.
- Regenerate and inspect the 1600-by-900 social preview only after the page is accepted.

### Release verification

- Run all JavaScript tests.
- Run all Playwright tests.
- Run `mix precommit`.
- Inspect the final diff for stray active legacy colors and unintentional non-color changes.
- Verify the exact integrated revision locally before pushing.

## Acceptance criteria

- The application reads immediately as Lacquered Gallery on desktop and mobile.
- Oxblood and wine replace the former green-black foundation everywhere outside forced-colors mode.
- Warm bone and parchment replace neutral cool whites and grays.
- The complete signal palette appears consistently in the legend and Canvas.
- All interactive and health states are readable, labeled, and visually distinct.
- No layout, behavior, data, performance, or accessibility regression is introduced.
- Metadata and social presentation match the delivered application.
- Automated suites and visual review pass on the integrated revision.
