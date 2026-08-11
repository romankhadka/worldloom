# Night-sky visual language

Date: 2026-08-10
Status: approved (maintainer chose the night-sky direction and direct commit)

## Problem

The maintainer rejected the glyph-based weave: discrete fans, forks, diamonds,
and bead clusters hung from connector lines read as a decorated data chart, and
the repetition of identical motifs made the artwork mechanical. Restyling the
same marks was not enough; the visual language itself changes.

## Direction

The timeline becomes a living star chart. The same committed instruction
stream, hit model, bounds, and determinism render a night sky:

- Every formation is a **star**: an additive bloom with a warm near-white core,
  a source-colored halo, and diffraction spikes on bright events.
- Wikimedia renders as the **Milky Way band**: a soft nebula current along the
  spine with deterministic star dust seeded from event sequences; capillaries
  and connectors become faint dust filaments and dotted chart lines.
- Each source keeps a distinct non-color signature as a constellation figure:
  Bluesky an open cluster fanning from a primary star, RIPE angular chart-line
  chains with elbow stars, Solana a string of pearls whose genuine gaps stay
  visible, drand a diamond pulsar with a fine ring, USGS an expanding ring
  nova, Open-Meteo an aurora curtain across the upper sky.
- Visitor gestures become sky events: Tug a meteor streak, Knot a binary star
  bridged by an arc, Illuminate a nova that lights its neighboring chart lines.
- Chapter seams are faint meridian lines; the contextual memory band is a
  below-the-horizon field; the live edge remains the dawn-lit east.

## Ground palette

Token names and every signal color stay. The four dark foundation values shift
from wine-lacquer to deep night so the warm accents read as starlight:

| Token | Old | New |
|---|---|---|
| `--loom-lacquer-deep` | `#120708` | `#0b0d16` |
| `--loom-lacquer` | `#241013` | `#131628` |
| `--loom-wine` | `#35171a` | `#1c2136` |
| `--loom-wine-raised` | `#4b2020` | `#2a3050` |

`color_system.test.js`, the e2e palette equality map, and the localized
contrast contract's backing RGB update in the same change. The retired values
join the legacy-color denylist.

## Constraints preserved

- Server contract, topology graph, projection positions, hit areas, sequence
  identity, and `settledSceneDiagnostics` output are unchanged.
- Determinism: star dust and figure detail derive from instruction seeds and
  sequences through the existing xorshift32; no wall-clock or Math.random.
- Non-color source signatures remain distinct; reduced motion still paints the
  same settled scene without a scheduler; forced-colors and keyboard paths are
  untouched.
- No color literals in `renderer.js`/`geometry.js`; the one new Canvas color
  (`starCore`) joins `palette.js` and its pinned test.
- Legend swatches restyle to constellation marks but keep their `data-shape`
  names and semantic tokens. Public copy is unchanged in this pass; a wording
  pass may follow separately.

## Verification

`npm test`, `mix precommit`, darwin Playwright verify runs after visual
inspection of desktop, tablet, mobile, and reduced-motion output, and Linux
baselines regenerated in the Playwright v1.62.1-noble arm64 container per the
documented recipe.
