# Roadmap

**The only document that discusses what isn't built.** Everything else describes what is —
the game's design is [`design.md`](design.md), the code is [`../src/README.md`](../src/README.md),
[`../src/ui/README.md`](../src/ui/README.md) and
[`../src/ui_client/README.md`](../src/ui_client/README.md). A gap, a limitation, an intention
or an argument about a future feature belongs here, and only here.

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

## Sim

- **Balance the numbers.** Every rate is a first guess: `base_rate` 1.5 food/day at normal
  ration, the ½× / 1× / 2× ration multipliers, starvation at 4 vigor/day, spoilage at 0.05/s,
  the ×0.7 penalty below 35% vigor, and the per-action hour costs (Forage 4h, Fish 5h, Chop 6h,
  rod build 12h). Playtesting retunes them. The *global* rates are `res.Config` fields, so
  retuning those is a field edit; the per-agent ones (`Metabolism.base_rate`,
  `InventoryFood.spoils`, each action's `Requires`/`Yields`) are component defaults at the
  spawn site.
- **Capital decay** — durable goods should degrade on a slow trickle and need maintenance, the
  way food spoils fast. Nothing wears today; goods are permanent once built.
- **Cancelling a running act** — deliberately not built. A `Busy` runs to completion or dies
  with the agent. The refund question can wait until a 12h build feels like a trap.
- **Finish the category tags.** `tags.zig` has `Food` / `Comfort` / `Tool` / `WoodCutting` and
  stops. Nothing reads them yet, so the set is neither complete nor load-bearing — settle it
  when something (the catalog browser's chips, an AI decider's preferences) actually needs to
  group goods.
- **SparseSet memory scaling** — `world.zig`'s `SparseSet(T)` allocates three
  `[MAX_ENTITIES]`-sized arrays (`dense_ids`, `dense_values`, `sparse`) per component type
  regardless of how many entities carry `T`, so cost is `num_types × MAX_ENTITIES`, not
  occupancy. Harmless at one agent and ~10 types; real once the capital roster reaches the
  hundreds, or `MAX_ENTITIES` has to grow to fit more agents — entity ids are never recycled, so
  it is a lifetime-spawn cap, not a live-population one. The fix: size the dense arrays to
  occupancy, and back the `sparse` index with a hashmap for cold component types while hot ones
  (`Vigor`, `InventoryFood`) keep the flat array — a per-type storage policy decided once, where
  `Storages(ns)` builds each `SparseSet(T)`. Contained to `world.zig` (the storage swap) and
  `ecs.zig`, whose `Query` driver loop reads `.dense_ids` / `.dense_values` / `.len` directly
  and would have to go through methods instead.

## HUD

- **Finish removing COLD↔WARM.** The temperature identity is two-thirds gone and the leftovers
  are inert: `draw_scanlines` no longer exists, `compute_warmth` is defined and re-exported but
  never called, and `build_ui` pins the theme at a hardcoded `palette.lerp(0.6)`. Decide it
  either way — revive warmth by wiring `compute_warmth` back into `build_ui`, or finish the
  removal and collapse `palette.zig` to a single palette, dropping `cold`/`warm`/`lerp` and
  `compute_warmth`. Leaving it half-done means the code reads as if a mechanic exists that does
  not.
- **Vigor sparkline** — needs a new persistence mechanism: a `Vigor`-history component plus a
  system sampling it on a fixed cadence, reset on death.
- **Distribution-curve glyph** — needs a new engine draw primitive. Nothing renders a polyline
  today; only rect fill/outline, text, image and svg.
- **Catalog browser + capital tray** — a second, text-first presentation of the action and
  capital rosters. Returns with the design prototype's favorites (`☆`/`★`), hover tooltips and
  per-good build state folded in.
- **Progress-ring polish** — a glanceable in-progress build indicator on the capital tile; the
  only cue today is the hover tooltip.
- **Scroll-thumb dragging** — `pages/templates/scroll_view.zig` is wheel-only; the track and
  thumb render but don't respond to drag.

## UI foundation (`src/ui_client/`)

- **Retire `widgets.zig`.** The pre-`elements` palette is unreferenced — nothing outside
  `ui_client/` calls it, since the screens moved onto `pages/templates/`. Deleting it and
  `root.zig`'s re-exports also drops the duplicate `scroll_speed` / `scrollbar_w` constants that
  `pages/templates/scroll_view.zig` already carries. Its `modal`, `tooltip` and `text_input`
  have no template equivalent yet, so those three want rebuilding on the foundation first rather
  than plain deletion. `text_input` in particular has no live consumer at all — it returns with
  the catalog browser's search box.
- **Responsive scaling** — every UI scalar (the `default_font`/`h1` ladder, `pad`/`pad_sym`,
  `gap`, `stroke_w`, and the fixed px sizes callers pass) is authored at one reference
  resolution in `style.zig` and never adapts, so the HUD reads too small or too large on a much
  bigger, smaller, or high-DPI screen. The fix: a global scale factor derived once per frame
  from window size and DPI, held on `res.view` beside `theme`, that the style fragments multiply
  into every dimension at `apply` time — authoring stays in reference units while output tracks
  the display. Composes with responsive layout below: scale each box, then reflow the scaled
  boxes.
- **Responsive layout** — the Resources/Log column (`top_left`) and the tabbed center column can
  overlap at some window sizes and aspect ratios. Independent anchors don't collision-avoid:
  each places from its own point and lets `fit_children` grow as large as it grows. The fix is a
  layout pass that reflows and shrinks columns against the live window size instead of anchoring
  and growing.

## UI engine (`src/ui/`)

Gaps in the extraction unit itself. Its README describes only what the engine *does*.

- **Sizing combinators** — `range`/`max_of`, `stretch`/`align-content`, and a `strictness: f32`
  driving a violation-resolution pass that distributes slack and overflow among siblings. The
  per-axis `SizeRule` solve is in place; this extends it.
- **Clip-aware hit-testing** — `Layout.overflow` crops the render walk, but `mark` still tests a
  slot's raw rect, so a node scrolled out of its viewport stays clickable. The fix is
  intersecting the clip rect in `mark` — the second consumer that put `overflow` in core rather
  than in the host's `RenderData`. This is also what would make **input capture** a mechanism
  rather than host policy: today a modal does not block the widgets built underneath it, which
  is safe only while the guarded action is idempotent.
- **O(interactive) `stamp_rects`** — the event stage is already O(interactive), since `mark`
  iterates live slots carrying their own rects with no tree walk. `stamp_rects` is the one
  O(all) pass left, because it reads geometry that only exists on the tree. It could match if
  `query` pushed nodes onto a per-frame list, at the cost of threading that list through `Ctx`.
- **Focus pruning** — `Ctx.focused` is not swept the way interaction slots are, so a focused
  node that stops being built leaves it set. The host clears it today.

## Tooling

- **`q.iter()` completion.** A query's `next()` returns a `@Type`-constructed tuple, which no
  language server evaluates, so destructuring it resolves to nothing. Worked around by
  annotating multi-fetch destructures. Declaring `Query`'s params as a concrete `[]const type`
  instead of `anytype` was measured and changes nothing — the limit is `@Type`, and it lifts on
  its own if ZLS's comptime interpreter grows support for it.
