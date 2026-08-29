# Roadmap

What's next. The game's design is [`design.md`](design.md); the code as it exists is
[`../CLAUDE.md`](../CLAUDE.md).

## The horizon: Act II

Multi-agent simulation — per-agent vigor and inventories, per-agent demands, typed materials
and recipes, barter with exchange-ratio discovery, specialization by comparative advantage.
Blocked on the open design questions in [`design.md`](design.md), which can't be settled before
agents exist.

Two pieces of Act I's foundation were built and then removed in the actions/capital redesign.
Both have to come back before Act II can start:

- **Population + carrying capacity** — Act I's win condition (crossing to pop 2) and the
  shelter-sets-capacity growth model of locked decision #2. No `Population` component exists
  today.
- **The decider abstraction** — the `decide → act` split with a non-UI decider driving the same
  resolution the player's clicks do. The split exists in shape (the player is the only decider);
  no AI decider does.

## Not built

**HUD**

- **Vigor sparkline** — needs a new persistence mechanism: a `Vigor`-history component plus a
  system sampling it on a fixed cadence, reset on death.
- **Distribution-curve glyph** — needs a new engine draw primitive. Nothing renders a polyline
  today; only rect fill/outline, text, image and svg.
- **Catalog browser + capital tray** — a second, text-first presentation of the action and
  capital rosters. Returns with the design prototype's favorites (`☆`/`★`), hover tooltips and
  per-good build state folded in.
- **Progress-ring polish** — a glanceable in-progress build indicator on the capital tile.

**Engine**

- **Scroll-thumb dragging** — `scroll_view` is wheel-only; the track and thumb render but don't
  respond to drag.
- **Autolayout sizing** — `range`/`max_of` combinators and a `strictness: f32` driving a
  violation-resolution pass that distributes slack among siblings. See
  [`../src/ui/README.md`](../src/ui/README.md).

## Known limitations

- **Input capture is host policy, not a mechanism.** Hit-testing is a flat, occlusion-unaware
  slot scan, so a modal does not block the widgets built underneath it. Safe only while the
  guarded action is idempotent. The fix rides on `mark` intersecting the clip rect.
