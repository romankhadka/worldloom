function freezePalette(palette) {
  return Object.freeze(
    Object.fromEntries(
      Object.entries(palette).map(([name, material]) => [name, Object.freeze(material)]),
    ),
  )
}

export const signalPalette = freezePalette({
  wikimedia: {family: "aged-jade", stroke: "#4db69a", glow: "#9ce6d0"},
  bluesky: {family: "smoky-periwinkle", stroke: "#9a84c7", glow: "#d4c5f1"},
  ripe_ris: {family: "mineral-blue", stroke: "#6c9bad", glow: "#b9dce5"},
  solana: {family: "marigold", stroke: "#e0a43b", glow: "#f5cf7a"},
  drand: {family: "moonstone", stroke: "#c7ddd6", glow: "#f2efe2"},
  usgs: {family: "copper", stroke: "#e07245", glow: "#ffb080"},
  open_meteo: {family: "olive-jade", stroke: "#8da56e", glow: "#c5c77c"},
  visitor: {family: "bright-bone", stroke: "#ffe8c9", glow: "#fff4df"},
})

export const canvasPalette = Object.freeze({
  fallback: "#ffe8c9",
  targetSeed: "#ffe8c9",
  selectionHalo: "#e3a53a",
  viewerPulse: "#f6e2c5",
})
