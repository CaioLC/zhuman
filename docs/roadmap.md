# Roadmap

**The only document that discusses what isn't built.** Everything else describes what is —
the game's design is [`design.md`](design.md), its interface's is [`ui_design.md`](ui_design.md),
the code is [`../src/README.md`](../src/README.md),
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
- **Pause is deliberately not built** — not for architectural reasons (a dropped `Busy` leaves
  the body doing exactly one thing) but economic ones: chipping at a hatchet between forage runs
  makes the manufactured tier reachable by attrition, which is the pressure the merchant exists
  to relieve. *(Cancel itself is built — `capital.cancel_build`.)*
- **The sell path.** Counts are built (`count` per good, incremented in
  `finish_build`, spares broken first) — what is missing is a buyer. Selling is `break_good`
  plus a payment: the decrement-and-revoke-at-zero half already works, the payment needs the
  merchant's ratios. Until then a second pair of sandals is buildable and worth nothing, which
  is why the BUILD tile still refuses a good you own.

  Two correctness notes that fall out and are otherwise unrecorded: `health_apply` /
  `health_remove` is the one modifier pair that does **not** round-trip (apply raises `max` and
  fills `v`; remove lowers `max` and only clamps), and a build→sell→build cycle is where
  floating-point drift in the apply/remove pairs would accumulate.

### HUD

- **The HUD has no room for a persistent panel.** BUILD and HOLDINGS are built, but Holdings
  belongs *beside the resource readout* and does not fit there: the centre column is 640 wide
  inside an 868 content box, which leaves 114px of margin on ACTIONS and 71px on BUILD against
  the ~300 the panel needs. It rides under the ration dial instead, so it is only visible on one
  tab — and the effect it exists to explain is asked about on that tab, which is the only reason
  the compromise holds. Blocked on **Responsive layout** below, and the third thing that entry
  now owes.
- **Three margins Holdings cannot show.** The vigor ceiling, spoilage and food quality have their
  baseline as a literal in `main.spawn_agent` rather than a catalog default, so a delta would
  mean restating a number `capital.zig` owns. The ceiling is shown as a current value instead.
  The fix is to give `Vigor` and `InventoryFood` field defaults and spawn from them, which puts
  the starting condition in the catalog where every other default already lives.
- **Barter Modal** new screen overlay on top of PlayGame to implement the barter mechanics.
  Input capture is a mechanism now — an overlay genuinely blocks what it covers — but there is
  no modal *template* to build one from (see **Retire `widgets.zig`**).
- Menu Page exposing our `res.config` to edit
- Pause Overlay — wants the same modal template as the barter modal.

### UI foundation (`src/ui_client/`, `src/ui/`)

- **Text neither wraps nor complains.** A node is one line, and overrunning its buffer
  (see [`../src/ui_client/README.md`](../src/ui_client/README.md)) drops the tail with no
  error — it reads as a layout bug and is not one. Two different features: raising the cap,
  which is cheap and still a cap, and **wrapping**, which the layout has no concept of at
  all — a text node is measured once, as one line. Until then a long line splits across
  nodes by hand, which `build_list`'s footnote does.
- **Retire `widgets.zig`.** The pre-`elements` palette is unreferenced — nothing outside
  `ui_client/` calls it, since the screens moved onto `pages/templates/`. Deleting it and
  `root.zig`'s re-exports also drops the duplicate `scroll_speed` / `scrollbar_w` constants that
  `pages/templates/scroll_view.zig` already carries. Its `modal`, `tooltip` and `text_input`
  have no template equivalent yet, so those three want rebuilding on the foundation first rather
  than plain deletion — `modal` in particular is the only thing that would exercise input
  capture, which is now a mechanism with no caller; both overlays above want it. `text_input` has no live consumer at all — it
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
  Sharper than it was: hit-testing stops at the topmost node, so where the columns overlap it is
  now paint order that decides which one takes the click — and the log footer is built last.

### Revised UI backend contract

The Act I HTML prototype in [`../prototypes/act-i.html`](../prototypes/act-i.html) is deliberately
richer than the running slice. Its late-act stock numbers are fixtures, but every changing value
on it has an authoritative home below. This is the complete sim/data gap between that prototype
and a connected screen; layout, drawing and interaction gaps remain in the HUD and UI-foundation
entries above.

**Missing simulation and catalog capabilities:**

- **Merchant encounter state.** A run needs the passerby's eligibility trigger, arrival event,
  departure time, finite inventory and identity. The UI reads one state (`absent`, `approaching`,
  `present`, `departed`) plus remaining time; it does not infer an encounter from the day or the
  Shelter checklist.
- **Authoritative barter quotes.** Each visible offer needs a stable id, direction (buy/sell),
  give and receive bundles, remaining stock, affordability/refusal reason, expiry and a revision.
  A sell quote also returns the *next* marginal quote so the preview can state that the fourth
  pair is worth less before the player parts with the third. Food, raw materials and goods all
  use one bundle shape rather than one endpoint per resource.
- **Atomic exchange resolution.** Accepting a quote revalidates its revision, transfers both
  bundles or neither, decrements finite stock, applies replacement/revocation once, and emits one
  log result. A stale, departed, unaffordable or sold-out quote returns a reason the modal can say
  in the player's words; the UI never performs a local `break_good` followed by a separate
  payment that could leave half a trade committed.
- **Tool supersession.** The catalog needs replacement families and rank (Fishing rod → Fishing
  net, Hatchet → Hand axe). Equipping the better unit replaces the weaker unit's action stats
  without duplicate `SparseSet.add`, while physical counts remain available to sell. The quote
  preview needs the before/after margins produced by the same operation resolution will apply.
- **Continuous eating and recovery contract.** `comp.Metabolism.Setting` currently exposes only
  ration / normal / feast. The approved slider needs an authoritative bounded scalar (0.5×
  through 2×, normal at 1×) used by metabolism and persisted/read with agent state. BODY's
  “food lasts” and “full vigor in” values must be projections over current food, Vigor deficit,
  base metabolism, vigor-per-food, food quality and the selected rate; unavailable or no-recovery
  states need an explicit result rather than a UI fixture. Descriptive labels remain presentation.
- **Absolute Shelter Vigor condition.** The approved milestone requires current Vigor of 15, not
  80% of whatever ceiling upgrades provide. Replace or extend `unlock.vigor_frac` with an absolute
  catalog threshold, then use the same condition result for both the checklist and build resolution.
- **Catalog baselines for derived margins.** `Vigor` and `InventoryFood` need the defaults already
  called out under HUD so Holdings can derive ceiling, quality and spoilage deltas. Spawn literals
  are not a second source of truth.
- **Editable configuration contract.** The proposed menu may expose only values explicitly marked
  player-configurable, with validation/ranges and reset-to-default. Raw mutable access to all of
  `res.config` would turn tuning internals into accidental UI API. Persistence of those choices is
  a separate decision and must be stated before the menu promises it.

**Already present — not backend work:** action requirements and distributions, `dist.stats`,
affordability inputs, `Busy` progress, build cancellation/refund, good counts, spare-first
breaking, the event log and Shelter's food/goods conditions. BUILD can derive
ready/reach/blocked/owned/building from those facts as it does now; the distribution curve is
render/presentation work. The existing three-state ration mechanism and fractional Vigor check
are starting points, not the final backend for the approved slider and absolute threshold.
Persistent Holdings and its collapse control, modal input capture and responsive columns are UI
work, not sim blockers.

## Act II — first exchange (pop 2 → band)

Multi-agent simulation — per-agent vigor and inventories, per-agent demands, typed materials
and recipes, barter with exchange-ratio discovery, specialization by comparative advantage.
Gated on Act I's population crossing, and blocked on the open design questions in
[`design.md`](design.md), which can't be settled before agents exist.

### Revised UI backend contract

The board and barter fixture in [`../prototypes/act-ii.html`](../prototypes/act-ii.html) defines the
read contract while leaving the open economic rules open. `GROW` / `WOOD` / `FIBRE` / `STONE` /
`METAL` / `POWER`, the named agents, goods and sample ratios in that file are UX test data, not
canonical content. Connecting it requires the following domain capabilities.

- **Population lifecycle and identities.** Shelter capacity, sustained surplus and starvation
  drive arrivals and departures; each live person has a stable entity/id, display label, vigor,
  current work and specialization. The player remains one of those agents rather than becoming a
  settlement-wide cursor. The header needs live population and carrying capacity, not a scripted
  Act counter.
- **Per-agent typed ledgers.** Food and each authored material are held by an individual agent.
  A stable material/good id, display unit, quantity and ownership transfer API replace Act I's
  single `InventoryMaterial`; settlement totals, where shown, are derived views over those
  ledgers. Goods retain counts so effect-bearing first units and trade stock stay distinct.
- **Authored catalog graph.** Every material/capital good needs stable identity, Act, one or more
  specialization sectors, production stage, category tags, recipe, base labor/energy/time and
  outputs. A recipe accepts several inputs and marks each consumed, retained/tooling, upkeep or
  produced. Dependencies converge; they are display-and-cost structure and must not become hard
  unlock gates. Seam goods can name two sectors rather than relying on a coordinate convention.
- **Production quotes per agent.** Given actor + recipe + quantity, one calculation returns typed
  input deficits, vigor/time price, expected output distribution, busy/standing reason and the
  specialization multiplier. Cross-specialization work remains legal at a penalty. BUILD and the
  STRUCTURE detail use the same quote so a board number cannot disagree with resolution.
- **Specialization state and learning rule.** The sim needs the chosen model for comparative
  advantage (heterogeneous yields, skill, learning-by-doing or a combination), its per-agent
  values, and the operation that changes them. The UI only displays the resulting trade label and
  quote delta; it must not assign a profession by clicking a colored wedge unless the design later
  makes that an explicit action.
- **Subjective ordinal demands.** Each agent needs ranked, agent-local wants over food, typed
  materials and capital, including thresholds and quantity-sensitive marginal rank. There is no
  shared utility score. The barter view needs a deliberate observability policy — exact ranks,
  broad signals, or inferred behavior — before it can honestly show another person's demand list.
- **Autonomous `decide → act`.** AI agents consume the same action/build/trade options and invoke
  the same resolution paths as the player. Decisions cover labor, consumption policy, production,
  offer creation/acceptance and specialization; UI absence must not stop an agent from acting.
- **Bilateral offer and negotiation model.** Offers carry counterparty, give/receive typed bundles,
  quantities, expiry, revision and status. Counteroffers preserve lineage; acceptance is atomic
  across two private ledgers and returns both agents' post-trade holdings. The unresolved exchange-
  ratio rule in `design.md` decides whether acceptance comes from posted prices, bargaining or a
  market mechanism — the modal cannot hard-code all agents to a slider threshold.
- **Exchange-ratio evidence.** Completed trades feed a bounded history keyed by good pair, with
  quantity, time and direction. Any displayed range or ratio is derived from that history and says
  when evidence is absent; it is not a global price table. Act I fixed merchant ratios adapt to
  the same transaction record without pretending they were market discovery.
- **Money emergence.** If a medium of exchange appears, agents need acceptance/demand for that
  good and trades need direct-vs-mediated settlement. The HUD reads the resulting medium and
  balance only after the sim recognizes one; an Act/day threshold must not simply turn on a coin
  counter.
- **Observable agent/market snapshot.** One frame-consistent read exposes the selected agent,
  visible counterparties, observable holdings/demands, open offers and quote revisions. This is
  especially important while AI decisions run: a detail panel assembled from unrelated mutable
  reads can otherwise show a quantity from before a trade beside a quote from after it.
- **Durability and maintenance when surfaced.** Capital condition, decay and maintenance inputs
  must exist before Holdings or a board tile promises wear. Until then the revised UI omits a
  condition meter rather than drawing a decorative one.
- **Scale transition.** Individual decisions are authoritative through the Act II band. Before a
  later aggregate model replaces any of them, it must preserve per-agent ownership, ordinal
  demand and the transaction records the UI reads; aggregate totals cannot silently become shared
  inventory.

**Board derivations that do not require backend systems:** transitive upstream highlighting,
search, zoom, favourites and arrow-key navigation are UI state over the catalog graph. Owned / in
reach filters derive from holdings and production quotes. The board remains read-only: its only
route is “show in BUILD,” never direct recipe resolution. Hex coordinates, sector painting, shape
hit-testing, thick chords, focus and the selected detail composition are the UI-foundation/HUD
work already filed below.

- **The decider abstraction** — the `decide → act` split with a non-UI decider driving the same
  resolution the player's clicks do. The split exists in shape (the player is the only decider);
  no AI decider does. Built once and removed in the actions/capital redesign, alongside
  population.
- **Finish the category tags.** `tags.zig` has `Food` / `Comfort` / `Tool` / `WoodCutting` and
  stops. Nothing reads them yet, so the set is neither complete nor load-bearing — the first
  real consumer is likely the structure board's specialization and category model.
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
- **The structure board** — its shape, geometry and vocabulary are
  [`ui_design.md`](ui_design.md); what is missing is the building. Needs the hex coordinate
  module and sector hues below, `renderGeometry` for tiles and honest strokes, and — before any
  of it can be drawn honestly — the authored stages above, since a board is only as good as the
  structure it displays. It routes like the Act I curtain rather than floating as an overlay,
  which gives it the whole window.

  Two things it decides on arrival. Whether a detail panel beside the selected tile earns
  itself: it removes the surface hop to BUILD at the cost of duplicating the build affordance,
  and is worth adding only if the hop turns out to annoy. And that it **absorbs the catalog
  browser and capital tray** rather than sitting beside them — the tray is Act I's Holdings
  panel, and the browser is this board plus BUILD's filtered list. The design prototype's
  favourites (`☆`/`★`) and hover tooltips return here.
- **Distribution-curve glyph** — the other half of locked decision #5: a yield's p10–p90 band
  drawn as a mini curve, its *shape* telling normal from poisson from exponential, in place of
  the text line `action_card` prints today (`odds 1-3 in 8 of 10 (normal)`). The five
  distribution SVGs on screen now are static hand-drawn assets picked by `Dist.kind` — they say
  *normal-shaped*, never *this action's band is 3 to 7*. Wants the line feature below; this is
  the same drawing capability the board's edges need, seen twice.

### UI foundation (`src/ui_client/`)
- **Filled polygons, and honest thick strokes.** The `line` feature draws a polyline at any
  angle, which is what closes the diagonal/curve gap — but thickness above a hairline is faked by
  re-stroking along the *first* segment's normal, so it is right for a straight run and visibly
  wrong on a tight corner. Both want `renderGeometry` (already in the binding): mitred quads for a
  real stroke, and untextured coloured triangles for the board's hex tiles — which the `svg` route
  cannot do cheaply, since it forces a square content box and re-rasterises every tile on every
  zoom step (its cache is keyed per node on path and size).
- **A hex coordinate module** (`src/grid/`) — axial and cube coordinates, pixel conversion,
  rings, neighbours, pixel-to-tile rounding, and the point-in-tile tests. Pure functions, no UI
  types, never imported by core: the engine stays ignorant of tilings and gets its flexibility
  from that. Needs wiring into `build.zig` before it is testable, and `test-ui`'s described
  contents change with it.
- **Shape-aware hit-testing.** Slots store rects, so a hex is hit by its bounding box and
  neighbours overlap at the corners. The slot carries an optional predicate
  (`?*const fn(Rect, f32, f32) bool`) that `mark` calls when set — the same host-policy seam the
  engine already uses for `RenderData` and `IntFlags.transient`, so core never learns what a
  hexagon is. It slots into the ordered walk `mark` already does, as one more reason to skip a
  candidate beside `pass_through` and the clip test.
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
