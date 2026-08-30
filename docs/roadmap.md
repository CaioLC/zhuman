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

**Sim**

- **Balance the metabolism numbers.** Every rate is a first guess: `base_rate` 1.5 food/day at
  normal ration, the ½× / 1× / 2× ration multipliers, starvation at 4 vigor/day, spoilage at
  0.05/s, the ×0.7 weary penalty below 35% vigor, and the per-action hour costs (Forage 4h,
  Fish 5h, Chop 6h, rod build 12h). Playtesting retunes them — the global rates are
  `res.Config` fields, so retuning is a field edit, not a hunt across three files.
- **Capital decay** — durable goods should degrade on a slow trickle and need maintenance, the
  way food spoils fast. Nothing wears today; goods are permanent once built.
- **Cancelling a running act** — deliberately not built. A `Busy` runs to completion or dies
  with the agent. The refund question can wait until a 12h build feels like a trap.

**HUD**

- **Vigor sparkline** — needs a new persistence mechanism: a `Vigor`-history component plus a
  system sampling it on a fixed cadence, reset on death.
- **Distribution-curve glyph** — needs a new engine draw primitive. Nothing renders a polyline
  today; only rect fill/outline, text, image and svg.
- **Catalog browser + capital tray** — a second, text-first presentation of the action and
  capital rosters. Returns with the design prototype's favorites (`☆`/`★`), hover tooltips and
  per-good build state folded in.
- **Progress-ring polish** — a glanceable in-progress build indicator on the capital tile; the
  only cue today is the hover tooltip.

**Engine**

- **Retire `ui_client/widgets.zig`.** The pre-`elements` widget palette is unreferenced -
  nothing outside `ui_client/` calls it, since the screens moved onto `pages/templates/`.
  Deleting it and `root.zig`'s re-exports also drops the duplicate `scroll_speed`/
  `scrollbar_w` constants. Its `modal`, `tooltip` and `text_input` have no template
  equivalent yet, so those three want rebuilding on the foundation first rather than plain
  deletion.
- **Responsive layout** — the Resources/Log column (`top_left`) and the tabbed center column can
  overlap at some window sizes and aspect ratios. Independent anchors don't collision-avoid:
  each places from its own point and lets `fit_children` grow as large as it grows. The fix is a
  layout pass that reflows and shrinks columns against the live window size instead of
  anchoring and growing.
- **Responsive scaling** — every UI scalar (the `body`/`h1` font ladder, `pad`/`pad_sym`, `gap`,
  `stroke_w`, and the fixed px sizes callers pass) is authored at one reference resolution in
  `src/ui_client/style.zig` and never adapts, so the HUD reads too small or too large on a much
  bigger, smaller, or high-DPI screen. The fix: a global scale factor derived once per frame
  from window size and DPI, held on `Resources` beside `theme`, that the style fragments
  multiply into every dimension at `apply` time — authoring stays in reference units while
  output tracks the display. See the `TODO(responsive-scale)` note in `style.zig`. Composes with
  responsive layout above: scale each box, then reflow the scaled boxes.
- **Autolayout sizing** — `range`/`max_of` combinators and a `strictness: f32` driving a
  violation-resolution pass that distributes slack among siblings. See
  [`../src/ui/README.md`](../src/ui/README.md).
- **Scroll-thumb dragging** — `scroll_view` is wheel-only; the track and thumb render but don't
  respond to drag.
- **SparseSet memory scaling** — `world.zig`'s `SparseSet(T)` allocates three
  `[MAX_ENTITIES]`-sized arrays (`dense_ids`, `dense_values`, `sparse`) per component type
  regardless of how many entities carry `T`, so cost is `num_types × MAX_ENTITIES`, not
  occupancy. Harmless at one agent and ~10 types; real once the capital roster reaches the
  hundreds, or `MAX_ENTITIES` has to grow to fit more agents — entity ids are never recycled, so
  it is a lifetime-spawn cap, not a live-population one. The fix: size the dense arrays to
  occupancy, and back the `sparse` index with a hashmap for cold component types while hot ones
  (`Vigor`, `InventoryFood`) keep the flat array — a per-type storage policy decided once, where
  `Storages(ns)` builds each `SparseSet(T)`. Contained to `world.zig` (the storage swap) and
  `ecs.zig`, whose `Query` driver fast path reads `.dense_ids`/`.dense_values`/`.len` directly
  (`ecs.zig:137,147,178,181`) and would have to go through methods instead.

## Known limitations

- **Input capture is host policy, not a mechanism.** Hit-testing is a flat, occlusion-unaware
  slot scan, so a modal does not block the widgets built underneath it. Safe only while the
  guarded action is idempotent. The fix rides on `mark` intersecting the clip rect.
