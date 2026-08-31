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
(see [`design.md`](design.md)); what is left is the content that leads there, and a BUILD pane
that has stopped serving it.

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
  His ratios are the first exchange numbers the game ever states, so they teach whatever they
  imply, and they are the largest unset number in the act. The guard against a treadmill is
  **diminishing marginal price** — he pays well for the first pair of sandals and poorly for
  the fourth, because his valuation of the fourth genuinely is lower — plus finite stock and a
  limited window. He is a passerby. "Selling must simply lose to scavenging" is the wrong guard:
  it makes production for sale strictly dominated, so nobody would ever do it.
- **Cancel a build.** A four-day build with an emptying larder is a trap with no exit today.
  Cancel drops `Busy` and refunds part of the materials; the energy and the time are gone. It
  reuses `resolve_busy`'s dispatch from `Busy.Doing` back to the concrete good to recover the
  price, and must be gated to the `build_*` arms — `Doing` also covers the six labor verbs.
  The refund is a flat fraction with a stated reason ("you salvage what you had not yet worked
  in"): `materials × remaining/total` reads natural and asserts a draw-down the sim does not
  run, since `begin_build` charges materials in full upfront and nothing consumes them over time.
  **Pause is deliberately not built** — not for architectural reasons (a dropped `Busy` leaves
  the body doing exactly one thing) but economic ones: chipping at a hatchet between forage runs
  makes the manufactured tier reachable by attrition, which is the pressure the merchant exists
  to relieve.
- **A count per good, and the sell path.** Once a trader will take goods off your hands, a lone
  actor stops building only what he means to use — making a second pair of sandals to sell is
  the first production for exchange in the game. One `count: u32 = 1` field per capital
  component. The increment belongs in `finish_build` (`if (w.get(e, GoodT)) |g| g.count += 1
  else { add; grant; }`), never in `begin_build`, which would hand over the good before the work
  resolves; today's unconditional `w.add` would corrupt the set, since `SparseSet.add` does not
  guard duplicates. Cancel decrements. **Only the first unit carries the effect** — a balance
  call, not a correctness one: a second pair of sandals is stock, not a deeper discount. Selling
  is `break_good` plus a payment, decrementing and only revoking at zero; `break_good` exists
  and has no gameplay caller yet. `goods_owned` asks `has()`, so the Shelter still counts kinds
  and four pairs of sandals will never be four goods built.

  Two correctness notes that fall out and are otherwise unrecorded: `health_apply` /
  `health_remove` is the one modifier pair that does **not** round-trip (apply raises `max` and
  fills `v`; remove lowers `max` and only clamps), and a build→sell→build cycle is where
  floating-point drift in the apply/remove pairs would accumulate.

### HUD

- **The BUILD pane is a catalog, not a choice.** Sixteen tiles land on screen the frame you
  open it, sorted by how `capital.zig` implements each good, with four different reasons for
  unavailability collapsed into one flat grey (busy elsewhere, prerequisite missing, standing
  conditions unmet, unaffordable — owned and building do read distinctly). It also does three
  jobs at once: what can I act on, what exists, what do I already own. The split:

  - **BUILD** keeps the tab and answers only *what can I act on now* — a short list of **rows,
    not tiles**, because a tile holds two strings and that is why the consequence column decayed
    into `spoil ×0.5`. Sorted by reach, so the top row is always the next thing. A reach meter
    (`31/48m`) on every unaffordable row, time in **days** to match the header clock, and
    consequences written as sentences. Cancel lives in the row's right corner; the build in
    progress keeps its row. Busy at labor is stated in one line, so rows read as *waiting*
    rather than unaffordable. The Shelter sits below the list, outside the sort and never
    filtered away, with a live checklist of its three standing conditions.
  - **Sort and filter instead of authored sections.** Grouping by hand would only be a second
    fixed taxonomy. Sort by reach / materials / time; show ready · in reach · all — which is
    where the "within reach" cutoff lives, as a visible state rather than a magic number.
    `built` is a toggle (off by default, on to run a production line once counts exist).
    UNLOCK / UPGRADE / HEALTH / INSTALL survives demoted to an optional chip, and
    **crude · manufactured gets its own chip** — that split *cuts across* the behavioural
    variants rather than restating them, and its invisibility is half the original complaint.
    A prerequisite-blocked good shows `needs: Hatchet` and is exempt from the reach filter;
    filtering it away silently is worse than the grey tile it replaces.
  - **HOLDINGS** becomes a persistent panel beside the resource readout, never opened, carrying
    per-good counts and — the readout that exists nowhere today — the **stacked effects**:
    three modifiers land on Forage and nothing on screen explains why it costs 1.7 energy. Its
    kind count is `goods_owned`, so it and the Shelter checklist agree by construction.

  Two things this must not assume. Pooled state is `std.mem.zeroes`-seeded, so a
  `BuildViewState`'s field defaults are ignored — the defaults have to be enum tag 0 or set
  explicitly. And the state type must be declared in `ui_client/ctx_binding.zig`'s `UiState`,
  not in `pages/templates/`; keyed on a node that is built every frame, since the BUILD div only
  exists while its tab is active and its slot is pruned the moment it stops being built.
- **The eating pulse runs backwards on a food surplus.** `ration_dial`'s active chip fills by
  `ceil(F) − F` (`pages/templates/ration_dial.zig`), which reads as progress through the current
  food unit only while the larder is *falling*: 5.0 → 4.0 sweeps the bar left to right and
  resets, once per unit eaten. Let net flow turn positive — a garden bed or chicken coop
  out-producing metabolism and spoilage — and F rises instead, so the same expression ramps
  1 → 0 and the `.top_left`-anchored fill retreats right to left. The fix has to say what the
  pulse *means* while the larder fills: mirror it (progress toward the next unit gained), hold
  it still, or drive it off the consumption rate rather than off the stock level — which is the
  honest reading, since the pulse's speed is meant to be the eating rate.
- **Barter Modal** new screen overlay on top of PlayGame to implement the barter mechanics.
  Wants input capture to be real first (below), or it is safe only while every action underneath
  it is idempotent.
- Menu Page exposing our `res.config` to edit
- Pause Overlay — same dependency on input capture as the barter modal.

### UI foundation (`src/ui_client/`, `src/ui/`)

- **Clip-aware, z-ordered hit-testing.** Two changes to one path, and they ship together because
  both touch `mark`.

  *Clip:* `Layout.overflow` crops the render walk, but `mark` tests a slot's raw rect, so a node
  scrolled out of its viewport stays clickable — which is why the BUILD panel grew the window
  instead of scrolling. The intersection belongs **in `mark`**, and the slot must carry *two*
  rects: the full one, which `rectOf` keeps returning, and the clip. Stamping only the
  intersection is the tempting shortcut and it silently kills scrolling — `scroll_view` derives
  `max_offset` from `content.rect` through that same channel, so it would clamp to the viewport
  forever, the wheel would die and the scrollbar never appear. Tile underbars size off it too.
  `Rect.intersect` and `draw_node`'s inheritance rule already exist to copy.

  *Z-order:* `mark` flags **every** slot containing the point, so overlapping nodes all fire and
  a modal does not block what is under it. Paint order is z-order and `stamp_rects` already
  walks it — roots in list order, each tree pre-order — so that walk pushes interactive nodes
  onto a per-frame list and `mark` walks it backwards, stopping at the first hit and bubbling up
  by a `parent_key` on the slot. Node pointers would need `Ctx` to be generic over `Node`, which
  it is not, and would carry frame-arena pointers across a frame boundary against the engine's
  own handles-not-pointers rule. **Not** built at `query` time: query order is not paint order —
  `scroll_view` queries a child before its parent, and `play_game.zig` appends into an earlier
  sibling after building a later one — and [`../src/ui/README.md`](../src/ui/README.md) promises
  identity is independent of wiring order. **Opaque by default**, with an explicit pass-through
  opt-out; transparent-by-default makes the mechanism a no-op, since `mark` could never stop.
  Three call sites query purely for geometry and need the opt-out: `scroll_view.zig`, and
  `widgets.zig` twice.

  This is what makes **input capture** a mechanism rather than host policy. It does *not* retire
  the O(interactive) `stamp_rects` entry below — the list is built by that walk, so the walk
  stays. It lands on a layout that already overlaps (see **Responsive layout**), where which
  node wins becomes window-size dependent; worth verifying at those aspect ratios.
- **`mark` and `stamp_rects` have no tests.** `ctx.zig` has no test block at all, so `test-ui`
  goes green through a total inversion of hit-test semantics, and [`../CLAUDE.md`](../CLAUDE.md)
  notes there is no synthetic-input path into SDL — a screenshot cannot show which of two
  overlapping nodes took a click. `mark` is pure over the slot pool and unit-testable with
  `UiCtx.init(undefined, alloc, undefined)`, which `ctx_binding.zig`'s existing interaction test
  already demonstrates. Budget it with the change above, not after.
- **Retire `widgets.zig`.** The pre-`elements` palette is unreferenced — nothing outside
  `ui_client/` calls it, since the screens moved onto `pages/templates/`. Deleting it and
  `root.zig`'s re-exports also drops the duplicate `scroll_speed` / `scrollbar_w` constants that
  `pages/templates/scroll_view.zig` already carries. Its `modal`, `tooltip` and `text_input`
  have no template equivalent yet, so those three want rebuilding on the foundation first rather
  than plain deletion — `modal` in particular is the proof that input capture works, and both
  the barter modal and the pause overlay want it. `text_input` has no live consumer at all — it
  returns with the catalog browser's search box.
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
  and growing. The default window is currently sized to the tallest screen rather than reflowing.

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
  stops. Nothing reads them yet, so the set is neither complete nor load-bearing — the first
  real consumer is likely the structure board's specializations or the Build pane's effect chip.
- **Population** - we need to account for population and agent needs. The ceiling is
  already data and unread: `comp.Shelter.capacity`, which Act I only ever asks to be > 1.
- **Higher order goods, as stages of production.** Today's roster is almost entirely
  second-order — sixteen goods that make food and comfort, and nothing that makes *them* — so
  the production structure is flat. Authoring it means goods that make goods (a forge, a
  workbench, worked stone, charcoal, planks), and recipes that **converge**: several inputs on
  one output, some retained and some consumed. Consumed intermediate inputs are the same
  mechanism as Act I's counts.

  Two rules this must keep. **Structure is displayed and costed, never enforced** — a
  prerequisite is a hard refusal, and an impossible good has no price to compare against, which
  would make the merchant a key instead of a counterparty and break `design.md`'s "stays
  buildable but is priced past what one body's time is worth". `prereq_of` keeps only its narrow
  existing job: don't let a modifier target a verb you lack. And **building across
  specializations stays possible at a penalty**, because locked decision #8 is comparative
  advantage — the Ricardian point is that trade pays even when you could make everything
  yourself, and a game where you trade because you *cannot* make the input forecloses exactly
  the demonstration this Act exists to deliver.
- **Generalized agents inventory** — per-agent stocks and holdings, of which Act I's Holdings
  panel is the single-agent case.
- **Materials split into several.** Act I has one undifferentiated `InventoryMaterial`. Act II
  wants typed materials, one per specialization, which is also what anchors the structure board's
  wedges.

### SIM
- **Capital decay** — durable goods should degrade on a slow trickle and need maintenance, the
  way food spoils fast. Nothing wears today; goods are permanent once built. Holdings is where
  wear would become visible, which is worth knowing before that panel's shape is fixed.
- **Add Ambiente music**

### HUD
- **The structure board.** A hex board carrying **materials and capital only** — consumption is
  deliberately off it, named once at the rim, which is what lets the radius mean one thing.
  Centre is the body and the gifts of nature; rim is where goods meet the mouth; so it runs raw
  to finished, centre to rim, and **radius is the length of production**. Ring is the stage,
  sextant is the specialization — hex geometry hands you both axes, since a ring at distance *n*
  holds exactly *6n* tiles. A tile on a wedge seam belongs to both trades, which falls out of
  the geometry rather than being authored.

  The economics is the point: an edge running **radially** is deepening your own trade, an edge
  running as a **chord** is needing what somebody else makes, and the density of chords is the
  degree of division of labour, drawn. Selecting a good lights everything upstream of it, and
  the reach of what lights up is what you cannot do alone. Say *stages*, not orders — Menger
  numbers inward from consumption, so on this board the centre is the highest order and "higher
  order outward" would invert him; Böhm-Bawerk's stages run raw to finished, which is the
  direction drawn.

  Read-only: the board is the map, BUILD is the shop. A detail panel beside the selected tile
  would remove the surface hop at the cost of duplicating the build affordance — worth adding
  only if the hop turns out to annoy. It routes like the Act I curtain rather than floating as
  an overlay, which gives it the whole window.

  This **absorbs the catalog browser and capital tray** rather than sitting beside them: the
  tray is Act I's Holdings panel, and the browser is this board plus BUILD's filtered list. The
  design prototype's favourites (`☆`/`★`) and hover tooltips return here.
- **Distribution-curve glyph** — the other half of locked decision #5: a yield's p10–p90 band
  drawn as a mini curve, its *shape* telling normal from poisson from exponential, in place of
  the text line `action_card` prints today (`odds 1-3 in 8 of 10 (normal)`). The five
  distribution SVGs on screen now are static hand-drawn assets picked by `Dist.kind` — they say
  *normal-shaped*, never *this action's band is 3 to 7*. Wants the line feature below; this is
  the same drawing capability the board's edges need, seen twice.

### UI foundation (`src/ui_client/`)
- **Place a child at a computed point.** `Layout` offers nine anchor presets and `.relative` and
  nothing else — `origin` positions only a parentless root, `scroll` translates a node's
  *children*. So no radial, graph or free-form layout is expressible. `offset_x`/`offset_y`
  applied after the anchor resolves is the missing primitive: `.center` plus a delta is polar
  placement. Nothing about it is hexagonal, and tooltips, badges and graph nodes want it too.
- **A line feature.** Rect fills draw any axis-aligned line at any thickness and nothing else —
  no diagonals, no curves, no chords. `svg` loads a *file*, so it cannot draw geometry computed
  from live data. This is **host work in `ui_client/features/`, not engine work**: a feature is
  one module, one `list` entry and one `RenderData` field, and `svg` was the proof. The binding
  already exposes `renderLine`/`renderLines` for hairlines and `renderGeometry` for thick strokes
  and filled polygons — the latter also draws the board's tiles, which the `svg` route cannot do
  cheaply (it forces a square content box and re-rasterises every tile on every zoom step, since
  its cache is keyed per node on path and size). The one genuinely new shape: this is the first
  feature carrying *variable-length* data rather than a tint, so points want a pooled `State`
  keyed on `node.key`, node-local and resolved against `paint.full` at draw time.
- **A hex coordinate module** (`src/grid/`) — axial and cube coordinates, pixel conversion,
  rings, neighbours, pixel-to-tile rounding, and the point-in-tile tests. Pure functions, no UI
  types, never imported by core: the engine stays ignorant of tilings and gets its flexibility
  from that. Needs wiring into `build.zig` before it is testable, and `test-ui`'s described
  contents change with it.
- **Shape-aware hit-testing.** Slots store rects, so a hex is hit by its bounding box and
  neighbours overlap at the corners. The slot carries an optional predicate
  (`?*const fn(Rect, f32, f32) bool`) that `mark` calls when set — the same host-policy seam the
  engine already uses for `RenderData` and `IntFlags.transient`, so core never learns what a
  hexagon is.
- **Six sector hues.** Wedges must be distinguishable, and position alone will not carry it once
  chords cross the board — you need to see which trade a chord runs to. They have no legal home
  in `Theme` (nine roles, and `ui_client` must not learn what a sextant is) and templates may not
  import `palette.zig`. `res.view.sectors: [6]Color`, filled where `build_ui` already assigns the
  theme, breaks no layer rule.
- **Animations**
- **Keyboard and focus on a board.** Nothing in the HUD is keyboard-reachable, and a board of a
  hundred-odd tiles makes that a real gap rather than a nicety — `design.md`'s text-forward and
  terminal-identity decisions argue for keyboard-first. Compounds with **focus pruning** below.

## Act III+ — village → town → city

Deliberately unspecified beyond [`design.md`](design.md)'s sketch: firms, deeper division of
labor, a global source of capital goods the city buys from. None of it can be designed before
Act II's demand model exists. Two entries are concrete already, because scale forces them rather
than content:

- **Thirds.** A hexagon divides into three rhombi meeting at its centre — a tile stops being one
  good and becomes a site with three slots, which is the granularity a full economy wants. It
  costs the engine nothing (same tile drawing, same offset placement, same hit predicate), so it
  can be deferred until the economy needs it and adopted without a rewrite.
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

No Act forces these; they are paced by whatever is most in the way. The first three are gaps in
the UI engine (`src/ui/`) — the extraction unit, whose [README](../src/ui/README.md) describes
only what it *does*; the last is a tooling limit.

- **Sizing combinators** — `range`/`max_of`, `stretch`/`align-content`, and a `strictness: f32`
  driving a violation-resolution pass that distributes slack and overflow among siblings. The
  per-axis `SizeRule` solve is in place; this extends it.
- **O(interactive) `stamp_rects`** — the event stage is already O(interactive), since `mark`
  iterates live slots carrying their own rects with no tree walk. `stamp_rects` is the one
  O(all) pass in *that* stage, because it reads geometry that only exists on the tree. Worth
  less than it looks: the frame walks the tree five times (size, percent resolution, placement,
  stamping, drawing) and stamping is the cheapest of them, so this is not what makes a large
  board affordable. Z-ordered hit-testing does not retire it either — that list has to be built
  by this walk, since query order is not paint order.
- **Focus pruning** — `Ctx.focused` is not swept the way interaction slots are, so a focused
  node that stops being built leaves it set. The host clears it today.
- **`q.iter()` completion.** A query's `next()` returns a `@Type`-constructed tuple, which no
  language server evaluates, so destructuring it resolves to nothing. Worked around by
  annotating multi-fetch destructures. Declaring `Query`'s params as a concrete `[]const type`
  instead of `anytype` was measured and changes nothing — the limit is `@Type`, and it lifts on
  its own if ZLS's comptime interpreter grows support for it.
