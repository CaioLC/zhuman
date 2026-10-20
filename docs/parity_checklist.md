# Visual parity and screenshot matrix

How the prototype-parity checklist (PARITY-01..05) and the screenshot matrix (QA-10..13) are
evidenced in this project. This describes the verification *apparatus* — the deterministic
fixtures, the capture driver, and what each check looks for — not future work; the open
checklist items themselves live in [`roadmap.md`](roadmap.md).

## The apparatus

Visual verification has no synthetic-input render path into SDL (a frame's node tree needs the
platform font to measure text), so a screen is confirmed with a **window screenshot** compared to
the prototype. Two pieces make that reproducible:

- **Deterministic fixtures** — [`src/pages/fixture.zig`](../src/pages/fixture.zig). `HA_FIXTURE=<name>`
  seeds one named screen state (fixed logical window size, game clock, catalogs, balances, passerby
  state) and renders it through the **production page**. Because every value is fixed, a name yields
  the same screen on every launch, which is what makes a screenshot diff meaningful. The catalog's
  determinism (width class, clock, balances, encounter) is unit-tested SDL-free in that file.
- **The capture driver** — [`tools/capture_screenshots.ps1`](../tools/capture_screenshots.ps1).
  Launches the binary once per fixture, PrintWindow-captures the window, and writes one PNG per
  fixture under `docs/screenshots/`. Run after `zig build`:
  `pwsh -File tools/capture_screenshots.ps1`.

The input/interaction half of verification is automated and SDL-free: the scripted-input replay
driver ([`src/ui_client/replay.zig`](../src/ui_client/replay.zig)) and the keyboard journeys
([`src/ui_client/journey.zig`](../src/ui_client/journey.zig)) assert the interaction state machines
(QA-08/14/15) in `zig build test-ui`. Pixel rendering stays out of those tests by design.

## Screenshot matrix (QA-10..13)

Capture at the reference `900×820` and at each width class, comparing to the prototype
HTML/screenshots in [`prototypes/`](../prototypes/).

| Fixture name | QA | What it shows | Prototype reference |
|---|---|---|---|
| `act_one_default`   | QA-10 | Act I ACTIONS, reference 900×820 | `prototypes/act-i.html`, `legacy/act-i-final-actions.png` |
| `act_one_working`   | QA-10 | Act I BUILD + holdings mid-run | `legacy/act-i-final-build.png`, `legacy/act-i-final-building.png` |
| `act_one_low_stock` | QA-10 | low-stock / disabled states (danger tones) | `legacy/act-i-final-actions.png` |
| `act_one_passerby`  | QA-10 | Passerby present; trade dialog openable | `legacy/trade-screen.png` |
| `act_one_w760`      | QA-10 | narrow layout, 760 width class | `act-i.html` ≤760 media query |
| `act_one_w560`      | QA-10 | narrow layout, 560 width class | `act-i.html` ≤560 media query |
| `act_one_w440`      | QA-10 | narrow layout, 440 width class | `act-i.html` ≤440 media query |
| `act_one_hidpi`     | QA-13 | reference width at 2× DPI | `act-i.html` (crispness, not layout) |
| `act_two_actions`   | QA-11 | Act II shell ACTIONS / catalog | `act-ii.html`, `legacy/act-ii-focus-actions.png` |
| `act_two_build`     | QA-11 | Act II shell BUILD / recipe catalog | `legacy/act-ii-focus-build.png` |
| `act_two_w560`      | QA-11 | Act II narrow, 560 width class | `act-ii.html` ≤560 media query |

QA-12 (STRUCTURE board) and the remaining QA-13 overlays (modal backdrop/clipping, long-offer
wrapping, sort popup near edges, focus-visible, reduced-motion terminal, oversized-window
centering) have no fixture; their entries are in `roadmap.md`.

## Parity checklist (PARITY-01..05)

What each parity check inspects, and the fixture(s) and interaction tests that evidence it. The
screenshot of each fixture is read against the matching prototype reference above.

### PARITY-01 — Global visual grammar
Dark-only terminal, square corners, regular-weight monospace, tight density, one-pixel lines, the
accent/warn/danger/good role usage, no unapproved rounded cards. Evidenced across every `act_one_*`
and `act_two_*` fixture — the grammar is global, so any capture shows a violation. The role colors
come from one theme (`src/palette.zig` → `res.view.theme`); hairlines snap through `paint.hairline`.

### PARITY-02 — Focus and disabled states
Every interactive control shows a focus-visible outline; disabled controls use line2/dim + reduced
opacity, cannot activate, and keep readable reason text. The *behavioral* half is asserted SDL-free:
`control.zig` publishes `disabled`/`focused`/`focus_visible` and consumes a disabled click; the
keyboard journeys (`journey.zig`) confirm a disabled control is skipped by Tab traversal and that
focus-visible follows focus. The *visual* half (outline color/offset) is read from the
`act_one_working` (enabled controls) and `act_one_low_stock` (disabled/not-ready) captures.

### PARITY-03 — Overflow
Terminal/dialog clip correctly; scroll regions do not paint or hit outside; scrollbar gutter stable;
long single-line cells ellipsize; multiline copy wraps; no hidden control becomes unreachable at
narrow widths. Evidenced by the narrow captures (`act_one_w760/w560/w440`, `act_two_w560`) and the
passerby trade dialog (`act_one_passerby`) for clip/wrap. Scroll clip/hit behavior is additionally
covered by `drag.zig`'s scroll-thumb tests and the replay driver's topmost-hit / wheel-target tests.

### PARITY-04 — Motion
Holdings, stock-label sizing, board state, and opacity transitions use short functional timing,
interrupt cleanly, and snap under reduced motion; completion comes from simulation state, never a
decorative timer. The reduced-motion policy and the tween registry's interrupt/snap behavior are
unit-tested in `motion.zig`/`tween.zig`. The reduced-motion terminal-state capture is a QA-13
overlay fixture to be added when that state is reachable (`roadmap.md`).

### PARITY-05 — Semantic redundancy
Locked/available/researched, deficit/met, idle/working/building, selected, and low-stock states are
distinguishable by copy/glyph/border/opacity as well as hue. Evidenced by comparing `act_one_working`
(met/working, holdings present) against `act_one_low_stock` (deficit/weary, danger tones) — the two
states must be told apart with hue removed. The published semantic bits backing this redundancy
(`selected`, `disabled`, `checked`, `expanded`) are asserted in `control.zig`/`semantics.zig`.

## Running the full verification

```
zig build test-ui                       # input/interaction state machines (QA-08/14/15), SDL-free
zig build test                          # library + pages + templates, including fixture determinism
zig build                               # the binary the capture driver launches
pwsh -File tools/capture_screenshots.ps1   # the screenshot matrix (QA-10..13)
```
