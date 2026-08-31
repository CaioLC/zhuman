# Roadmap

**The only document that discusses what isn't built.** Everything else describes what is —
the game's design is [`design.md`](design.md), the code is [`../src/README.md`](../src/README.md),
[`../src/ui/README.md`](../src/ui/README.md) and
[`../src/ui_client/README.md`](../src/ui_client/README.md). A gap, a limitation, an intention
or an argument about a future feature belongs here, and only here.

**Filed by Act.** An entry sits in the earliest Act that needs it — either that Act's content is
blocked on it, or something on that Act's screen is missing or broken. Sim, HUD and engine work
therefore sit side by side under one Act rather than in layer buckets. What no Act forces is
under [Whenever](#whenever); what each Act *is* is in [`design.md`](design.md).

## Act I — Robinson Crusoe (pop 1)

The slice on screen today. Its ending is built — the Shelter, and the curtain raising it drops
(see [`design.md`](design.md)); what is left is the content that leads there.

### Sim

- **The merchant passerby** — [`design.md`](design.md): as Act I approaches its end, the player
  gets a glimpse of the Act II barter mechanics, with a passerby offering simple goods for the
  food and raw materials the player holds. We need goods that can be bought at the merchant
  (food, fishing rod, hatchet, etc.) and the purchase/sell mechanics at fixed ratios.
  When a bought tool is a better version of one already held, the better tool **replaces** the
  weaker one's stats rather than stacking — and it has to, for unlockers: `grant` adds the
  action component outright and `SparseSet.add` does not guard duplicates, so two goods
  granting one verb would double-add it. Modifiers that merely share a target still stack
  (sandals and a bicycle both cheapen Forage).

### HUD

- **The eating pulse runs backwards on a food surplus.** `ration_dial`'s active chip fills by
  `ceil(F) − F` (`pages/templates/ration_dial.zig`), which reads as progress through the current
  food unit only while the larder is *falling*: 5.0 → 4.0 sweeps the bar left to right and
  resets, once per unit eaten. Let net flow turn positive — a garden bed or chicken coop
  out-producing metabolism and spoilage — and F rises instead, so the same expression ramps
  1 → 0 and the `.top_left`-anchored fill retreats right to left. The fix has to say what the
  pulse *means* while the larder fills: mirror it (progress toward the next unit gained), hold
  it still, or drive it off the consumption rate rather than off the stock level — which is the
  honest reading, since the pulse's speed is meant to be the eating rate.
- **Barter Modal** new screen overlay on top of PlayGame to implement the barter mechanics
- Menu Page exposing our `res.config` to edit
- Pause Overlay
- complete refactor of the build menu.

### UI foundation (`src/ui_client/`)

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

## Act II — first exchange (pop 2 → band)

Multi-agent simulation — per-agent vigor and inventories, per-agent demands, typed materials
and recipes, barter with exchange-ratio discovery, specialization by comparative advantage.
Gated on Act I's population crossing, and blocked on the open design questions in
[`design.md`](design.md), which can't be settled before agents exist.

- **The decider abstraction** — the `decide → act` split with a non-UI decider driving the same
  resolution the player's clicks do. The split exists in shape (the player is the only decider);
  no AI decider does. Built once and removed in the actions/capital redesign, alongside
  population.
- **Finish the category tags.** `tags.zig` has `Food` / `Comfort` / `Tool` / `WoodCutting` and
  stops. Nothing reads them yet, so the set is neither complete nor load-bearing — settle it
  when something (the catalog browser's chips, an AI decider's preferences) actually needs to
  group goods.
- **Population** - we need to account for population and agent needs. The ceiling is
  already data and unread: `comp.Shelter.capacity`, which Act I only ever asks to be > 1. 
- **Higher Order Goods**
- **Generalized Agents Inventory**

### SIM 
- **Capital decay** — durable goods should degrade on a slow trickle and need maintenance, the
  way food spoils fast. Nothing wears today; goods are permanent once built.
- **Add Ambiente music**

### HUD
- **Catalog browser + capital tray** — a second, text-first presentation of the action and
  capital rosters. Returns with the design prototype's favorites (`☆`/`★`), hover tooltips and
  per-good build state folded in.
- **Distribution-curve glyph** — the other half of locked decision #5: a yield's p10–p90 band
  drawn as a mini curve, its *shape* telling normal from poisson from exponential, in place of
  the text line `action_card` prints today (`odds 1-3 in 8 of 10 (normal)`). Needs a new engine
  draw primitive — nothing renders a polyline; only rect fill/outline, text, image and svg.

### UI foundation (`src/ui_client/`)
- **Animations**

## Act III+ — village → town → city

Deliberately unspecified beyond [`design.md`](design.md)'s sketch: firms, deeper division of
labor, a global source of capital goods the city buys from. None of it can be designed before
Act II's demand model exists. One entry is concrete already, because scale forces it rather
than content:

- **SparseSet memory scaling** — `world.zig`'s `SparseSet(T)` allocates three
  `[MAX_ENTITIES]`-sized arrays (`dense_ids`, `dense_values`, `sparse`) per component type
  regardless of how many entities carry `T`, so cost is `num_types × MAX_ENTITIES`, not
  occupancy. Harmless at one agent and ~10 types; real once the capital roster reaches the
  hundreds, or `MAX_ENTITIES` has to grow to fit more agents — entity ids are never recycled, so
  it is a lifetime-spawn cap, not a live-population one. The fix: size the dense arrays to
  occupancy, and back the `sparse` index with a hashmap for rarely-carried component types while
  hot ones (`Vigor`, `InventoryFood`) keep the flat array — a per-type storage policy decided
  once, where `Storages(ns)` builds each `SparseSet(T)`. Contained to `world.zig` (the storage
  swap) and `ecs.zig`, whose `Query` driver loop reads `.dense_ids` / `.dense_values` / `.len`
  directly and would have to go through methods instead.

## Whenever

No Act forces these; they are paced by whatever is most in the way. The first four are gaps in
the UI engine (`src/ui/`) — the extraction unit, whose [README](../src/ui/README.md) describes
only what it *does*; the last is a tooling limit.

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
- **`q.iter()` completion.** A query's `next()` returns a `@Type`-constructed tuple, which no
  language server evaluates, so destructuring it resolves to nothing. Worked around by
  annotating multi-fetch destructures. Declaring `Query`'s params as a concrete `[]const type`
  instead of `anytype` was measured and changes nothing — the limit is `@Type`, and it lifts on
  its own if ZLS's comptime interpreter grows support for it.
