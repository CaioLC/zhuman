# Human Action — Redesign Roadmap

Forward plan for the HUD + gameplay redesign. `CLAUDE.md` documents the *current* code; this
documents where we're taking it. Design source of record: `design/` (imported Claude Design
prototype) + the live link therein.

## Vision

A terminal-styled **accumulator** that dramatizes Mises' *Human Action*: the arc from
**autistic exchange** (Robinson Crusoe, acting alone) → **interpersonal exchange** (barter, then
money) → the market economy. The progression spine is **population itself** — humans are both the
gate that unlocks new production *and* the score that goes up. Start alone, cold and starved; end
with billions.

The flywheel: **food surplus feeds people → more hands produce more → bigger surplus.**

## Scope & the core challenge

**Two pillars, nothing else: UI and AI.** No world, no space, no graphics beyond the terminal HUD —
everything the player sees and does is UI, and everything the world *does* is autonomous agents.
Anything that isn't one of those two pillars is out of scope by default.

**The core challenge of the whole project: designing the *needs* of an infinitely growing,
autonomous population.** What each agent demands, how those demands are ranked under scarcity, and
how the model still holds from pop 1 to billions. Needs are what drive every agent's `decide → act`,
and what make specialization, exchange, and markets *emerge* rather than be scripted. The crux is
**autonomy vs. scale**: 10⁹ full deciders is intractable, so the model must degrade gracefully from
individual agents → aggregate demand while keeping preferences subjective and ordinal (never a
global utility function). Everything below serves those two pillars.

## Locked decisions (2026-07-02)

1. **Passive rest.** No active rest/eat actions; vigor refills only via the passive trickle, food
   via passive `metabolize`. Overwork can't kill you — only starvation. (Keeps CLAUDE.md's stance.)
2. **Progression spine = population**, not an abstract tech score. Growth is a **carrying-capacity
   model: shelter sets capacity, sustained food surplus fills it, starvation empties it.** It
   self-regulates — a food collapse costs you people.
3. **Curated catalog, large across Acts.** Hand-authored (no procedural formulas); each Act's slice
   stays bounded and legible.
4. **Text-forward UI.** Retire the sprite-icon tray (`icons.png` / `icon_button` / `data_sprite` /
   the drawer) for text rows with cost chips + inline curves.
5. **Richer risk yields.** Sample yields from distributions (normal / poisson / uniform /
   exponential); show the p10–p90 band as a mini curve. Replaces flat `yield × p_success`.
6. **Terminal identity.** Monospace; a palette that lerps **COLD↔WARM** with a computed "warmth";
   scanlines, ASCII vitals figure, vigor sparkline, distribution curves.
7. **A second human is an autonomous agent** — an AI decider ranking the same action catalog, not a
   labor multiplier. The north-star sim; arrives at Act II.
8. **Act II = barter.** Player and every agent hold their own inventories and have demands for
   food/materials. Specialization + comparative advantage make "x wood for y food" beat gathering
   both alone — gains from trade emerge, and with them, typed materials.

## Act structure

- **Act I — Robinson Crusoe (pop 1).** Crude labor + crude capital; one fungible `Materials`
  bucket. *Win condition:* build a sustained food surplus + shelter capacity large enough to support
  a second person → cross to pop 2.
- **Act II — First exchange (pop 2 → band).** An autonomous 2nd agent arrives. `Materials`
  differentiates into typed goods. Demand-driven **barter** with emergent exchange ratios;
  specialization by comparative advantage.
- **Act III+ — village → town → city → … (deferred).** Money emerges from barter; firms, deeper
  division of labor; the long climb to billions.

## Milestones

**M0 — Parity quick wins** — ✅ done 2026-07-02 (branch `feat/hud-redesign`): number formatting
(k/M) · log/event feed panel · day clock · status word. Progress-bar-on-capital was deferred to M4
(it rides the icon tray being retired there); the status word is a plain colored word for now — the
bordered pill lands with M5.

**M1 — Risk yields** — ✅ done 2026-07-02 (`feat/hud-redesign`): `src/dist.zig` engine
(normal / poisson / uniform / exponential — sampled from `res.random()`, p10–p90 `stats`, unit-tested),
and actions wired to it (each button shows its p10–p90 band). Curve glyph deferred to M5 (text-only
ranges for now). Act I stays ungated — population is the spine, and Act I is pop 1, so no tech formula.

**M2 — Engine: scrolling** — ✅ done 2026-07-06 (`feat/hud-redesign`): mouse-wheel into
`Input` (`wheel_y`, one-frame edge) · `Layout.scroll_x/scroll_y` translate a node's
flowed children without a second layout pass (`place` folds it into the child's base
position — same idea as root `origin`, one level down) · `RenderData.clip` + a clip-stack
in `main.zig`'s render walk (nested via `Rect.intersect`) crop a viewport's overflowing
content · `widgets.scroll_view` (viewport + content + track/thumb, wheel-driven, clamped
against last frame's content rect the way the hover tooltip reads a prior-frame rect).
Wired into the HUD's Log panel, replacing its old hard 6-line cap — the whole run's
history (up to the ring buffer's 64) is now reachable. No drag yet (wheel-only, per
scope); dragging the thumb is a natural M4 add if the catalog browser wants it.

**M3 — Engine: modal** — ✅ modal half done 2026-07-06 (`feat/hud-redesign`):
`widgets.modal` (a fullscreen scrim root + centered content box, mirroring `tooltip`'s
"build my own root" shape) with click-outside-to-dismiss (compares `ctx.res.input
.mouse_down` against the box's prior-frame rect, same trick `scroll_view` uses for its
content height). Wired into the game-over screen: "Start over" now opens a confirm
dialog ("Yes, start over" / "Cancel") instead of reseeding immediately — the loss is
irreversible, so the extra step guards against a misclick. "Input capture" is
documented as host policy, not a mechanism (hit-testing is flat/occlusion-unaware) —
safe today only because the guarded action (open the modal) is idempotent.
`text_input` (keyboard → focus/caret/backspace) is **deferred to M4**: it has no live
consumer yet (the catalog browser's search box is the first one), and enabling SDL's
global text-input/IME mode for a widget nothing uses risks a platform-dependent change
to existing key-event delivery for zero present benefit. Land it alongside M4 instead.

**M4 — Catalog browser** (needs M2+M3): category sidebar, search, filters (hide can't-do / owned /
favourites), sort cycle, favorites/pins, rich text rows. Author the curated Act I catalog. Retire
icons here.

**M5 — Visual identity** — ✅ palette/font/scanlines/figure done 2026-07-06
(`feat/hud-redesign`): `src/theme.zig` (`Theme` struct, `cold`/`warm` poles lifted 1:1
from `design/`'s palette, `lerp(t)` blending every field together) · `compute_warmth`
(rested 28% + fed 40% + capital built 32%, capped at 8 goods + a flat fireplace bonus —
mirrors the design's model) drives it, resolved once per frame in `build_ui` onto
`Resources.theme` so every widget reads `ctx.res.theme.*` instead of a fixed color ·
every widget/HUD color (buttons, panels, log tones, the status pill, the window clear)
now routes through theme roles (`fg`/`acc`/`dim`/`warn`/`danger`/`line`/`line2`/`panel`/
`bg`) instead of hardcoded RGB · monospace font (`Kenney Mini Square Mono.ttf`, already
bundled) · a scanline overlay (`draw_scanlines`, partial-alpha repeating darkening —
first use of the renderer's blend mode) · a 3-line ASCII vitals figure (weary/ok/robust,
picked from warmth + hunger/exhaustion; a 4th, dead, on the game-over screen) beside a
sine-pulsed "heartbeat" readout (`Color.lerp`, freezes when the run clock stops).
**Deferred**: the **vigor sparkline** needs a new persistent history-sampling mechanism
(an ECS component + system sampling `Vigor` on a fixed cadence, reset on death) — a
separable unit of work, not a quick add. The **distribution-curve glyph** (parked at M1
for M5) needs a new engine draw primitive — nothing currently renders a polyline, only
rect fill/outline/text/image — so it's parked again until that primitive exists. Both
land in a follow-up pass rather than blocking the rest of M5.

**M6 — Population (closes the Act I loop)**: shelter-capacity model, surplus-fills,
starvation-empties; the Act I win condition (reach pop 2). This is what gives Act I a *goal* beyond
"don't die."

**M7 — Decider abstraction**: make the `decide → act` split real — a decider interface with a
player-decider (today) and an AI-decider, both producing ranked choices over one catalog. Prereq
for autonomous agents.

**M8 — Act II epic**: multi-agent (per-agent Vigor / Satiety / inventories / demands) · typed
materials + recipes · barter with exchange-ratio discovery · specialization / comparative advantage.

**Dependencies & float:** M0 unblocks everything. **M1 and M5 are floats** — they only need M0, so
pull them early for game feel. M4 needs M2+M3. M8 needs M6 (population) + M7 (deciders).

## Parked for Act II design (record, don't litigate yet)

The first item **is the project's core challenge** (see Scope) — parked only because we can't design
a demand model before agents exist, not because it's minor.

- How agents form **demands** — subjective/ordinal preferences over food vs materials, needs,
  thresholds; and how it degrades from per-agent deciders to aggregate demand at scale.
- How an **exchange ratio** forms — posted price, bilateral bargaining, or double auction.
- What **specialization** is — per-agent skills, comparative advantage from differing yields/vigor,
  or learning-by-doing.
- **Per-agent inventories** vs a shared stockpile (barter requires individual holdings).
- **Autonomous decider policy** — how an AI agent ranks the catalog under scarcity.

## Reference

`design/` — imported prototype (`Human Action HUD.dc.html` + runtime) and the live link.
