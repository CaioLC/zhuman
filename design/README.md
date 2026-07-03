# Design reference — HUD redesign

Source of record for the **Human Action** HUD/gameplay redesign, imported from the Claude
Design project *"Human Action game design"* on 2026-07-02.

- **`Human Action HUD.dc.html`** — the interactive prototype. Its `<script type="text/x-dc">`
  block holds the full target game logic (catalog generation, distribution engine, tick/sim,
  tech-unlock gating, warmth/theme) — this is the spec we build toward, not the current Zig code.
- **`support.js`** — the `dc-runtime` that renders `.dc.html` (generated; needs a React host).

**Live view:** https://claude.ai/design/p/6bc72e9f-37a4-4444-ae22-fb02ff301be0

The local files are reference source; they don't render standalone (the design platform provides
the React host). Screenshots of the running prototype live in the project above (states: `fresh`,
`live`, `cap`, `catalog2`, `curves`, `dist`, `reload` × display-style variants).
