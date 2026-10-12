# The Simulation

The game's model and the loop that runs it: the ECS, the components, the systems, and the
per-agent actions and capital goods.

The UI engine is [`ui/README.md`](ui/README.md) and its host binding is
[`ui_client/README.md`](ui_client/README.md). What the game is *for* is
[`../docs/design.md`](../docs/design.md); what is next is
[`../docs/roadmap.md`](../docs/roadmap.md).

## The model

The first slice is **one actor under scarcity** — Robinson Crusoe economics, plus a passing
merchant for the first barter; no money. There is deliberately **no world and no space**:
everything the player sees and does is UI.

The resource model separates survival from accounting:

- **Energy** is the *unit of work* — the **price** of an action, never a stock you hold. It is
  paid from a source. Today that source is the body; later it is harnessed external energy.
- **Vigor** (`comp.Vigor { v, max }`) is that source, and **`vigor == 0` is death**. The
  fraction `v/max` also scales an action's output quality, so a tired actor produces less.
- **Food** (`comp.InventoryFood { v, quality, spoils }`) is a perishable larder — produced by
  labor, consumed continuously by the metabolism, and always spoiling.
- **Materials** (`comp.InventoryMaterial { v }`) is the fungible durable stockpile: the early
  score, and the currency capital is built from. One bucket on purpose — typed materials wait
  for the market.

**Eating is a standing policy, not an action.** `systems.metabolize` converts larder to vigor
every tick at `base_rate × rate`, where `comp.Metabolism.rate` is a persisted agent-local
multiplier in `[0.5, 2.0]` (`1.0` at normal) that the Eating Policy slider sets; `Config` owns
the range and default, and `Config.clampMetabolism` is the one place a rate is made legal. An
empty larder drains vigor instead. Because labor's energy gate is strict — an action can never
take vigor to zero — **starvation is the only path to death**.

**Starting values live on the components.** `Vigor`, `InventoryFood`, and `Metabolism` carry
field defaults, `spawn_agent` spawns them default-valued, and `baselines.zig` *reads* those
defaults (`(comp.Vigor{}).max`) as the canonical ceiling/larder baseline, so Holdings can show
current-vs-base margins against a value that cannot drift from the spawn.

**The BODY readouts are the sim's own arithmetic.** `body.project` takes larder units and
quality, the vigor deficit and ceiling, base metabolism, the rate, and `vigor_per_food`, and
returns food coverage in days plus a tagged `Recovery` — `at_ceiling`, `no_food`,
`no_quality`, `partial`, or `recovering { days }` — using the same products `metabolize`
applies, so the projection and the loop agree by construction. `eating.zig` is the slider's
side of it: `rate(value) = 0.5 × 4^(value/100)` over a `0..100` slider, its inverse
`valueFromRate`, the policy word ladder (meager … lavish), and the per-act coverage/recovery
constants; it imports nothing and serves both the template and a future system.

That yields the two praxeological margins the game is about: *labor vs. leisure* (working
spends vigor, which refills only through eating, whose rate is a standing choice) and *now vs.
later* (act for food and materials now, or spend materials and hours on capital).

Death is total: a start-over wipes everything accumulated (`res.sim.reset()`).

The decision is split **`decide → act`**. The player is the only decider; the roadmap's AI
deciders are meant to feed the same options.

## Main loop (`main.zig`)

`App` owns all state. `App.init` does SDL and window setup only; `App.setup` runs once after
`App` is stable on the stack — font, `Resources`, the ECS `World`, the player actor, the
per-frame arena, and the `UiCtx` (safe here because internal pointers are taken after the
struct's address is fixed). `main.zig` owns `App`, the event loop, the sim tick, and
`spawn_agent`/`spawn_player`; the screens live in `pages/`.

Each frame:

1. **Events** — the SDL poll updates `res.input`. Hover, primary press/release, and wheel
   route through the last frame's reverse paint order (capture first). Primary down emits
   `.pressed`; motion tracks a 4px drag threshold; up emits `.released`, and matching
   release over the same key emits one `.clicked`. Drag, cancellation, focus loss, pointer
   mismatch, and release elsewhere suppress activation. Each frame republishes `.held` on
   the stable press key, `.dragging` after threshold crossing, and `.captured` only on the
   exact capture owner. Scroll consumers require routed `.wheel`, not merely hover; their
   thumbs preserve the press origin, capture through outside movement, apply the release
   position, and owner-release. UI build resets and resolves cursor requests (pointer,
   text, grab/grabbing, horizontal-resize, not-allowed) before SDL applies the supported
   system shape, with default/move fallbacks where needed. Key events normalize into
   semantic commands before build: Tab traverses, arrows move/activate roving groups,
   Enter/Space emit the same `.clicked` as pointer release, `/` focuses registered search,
   and editing/text reach registered text owners only. Escape is focus/overlay dismissal;
   only SDL quit/terminating exits the process.
2. **Mark** — `ui.mark(.hovering, …)` hit-tests *last* frame's stamped rects by iterating the
   interaction slot pool. No tree walk.
3. **Update** — the tween registry advances by the frame `dt` and takes the reduced-motion
   policy, then `ecs.run(&world, &res, system)` per system in the order below, with the
   passerby clock (`market.tick`) and the generators run as direct calls between them.
4. **Build UI** — `ui.beginFrame()`, arena reset, `pages.build_ui()` builds fresh trees and
   returns `Trees`, a flat list of independent roots (a screen, plus any floating overlay).
   The command registry and the host **semantic snapshot** (`res.semantics`) both
   `beginBuild` here, so interactive controls publish their prior-build command owners and
   their owned accessibility metadata (role/label/value/state/relationships/live-region) in
   paint order as they build.
5. **Layout** — `set_global_pos()` per root: solve sizes, then resolve positions. Pure — content
   was measured at build time.
6. **Stamp** — `ui.stamp_rects(root)` copies each queried node's rect into its slot, feeding
   the next frame's step 2.
7. **Render** — `ui_client.draw_tree()` per root in list order, so later trees paint on top.
   Then `ui.endFrame()`; the command registry and the semantic snapshot `endBuild` here,
   double-buffer-swapping this frame's build into the completed prior snapshot the next
   event stage (and the accessibility bridge) reads — the semantic snapshot owns its
   strings by value, so it never borrows the frame arena that resets in step 4.

There is no retained tree between frames. The interaction slot pool is what bridges the
boundary.

## ECS (`ecs.zig`, `world.zig`)

A [Bevy](https://bevyengine.org)-inspired ECS over a sparse-set `World` — the ergonomics are
modelled on Bevy, the storage is comptime Zig rather than archetypes.

**World.** One `SparseSet` per component or tag type, generated at comptime from the public
decls of `components.zig` and `tags.zig`. `spawn(bundle)` takes a tuple of component
*instances* and bare *tag types*; then `add`, `remove`, `get`, `has`, `despawn`. Ids are never
recycled — `next_id` only climbs, so `MAX_ENTITIES` is a lifetime-spawn cap, not a live one.

**System params** are declared as a system function's parameter types and built by `ecs.run`
through comptime introspection:

| Param | Meaning |
|---|---|
| `Query(.{…})` | iterate every matching entity |
| `Single` / `MaybeSingle` | expect exactly one / at most one |
| bare component type | a *fetch* — drives iteration, yields `*T` |
| `With(T)` / `Without(T)` | filter without fetching |
| `Maybe(T)` | yields `?*T` |
| `Entity` | yields the id; does not drive iteration |
| `*Resources` / `*World` | taken directly |
| `*Sim`, `*const Config`, `*const Time`, … | one **resource group** — any struct-typed field of `Resources` |

Prefer naming groups over taking `*Resources`: the signature then states what the system
reaches, and the compiler holds it to that — `metabolize` has no `*Platform` param, so it
cannot touch the renderer. `*const` vs `*` says whether it reads or writes, which is why
`*const Config` (tuning) and `*Sim` (the run) read differently at a glance. The set is
derived from `Resources`' fields, so a new group needs no change in `ecs.zig`; two guards
keep the type-directed binding honest — only struct-typed fields inject (a bare `f32` on
`Resources` would make `*f32` bind to it), and two fields sharing a type is a build error
rather than a silent bind to the first. `resolve_busy` still takes `*Resources`, because it
delegates to `finish_labor`/`finish_build`, which do too.

`ecs.getMany(world, entity, params)` is `Query`'s non-iterating sibling, for pulling several
components off an entity you already have. It panics on a missing required component rather
than degrading to `?*T`, because the caller is expected to have already qualified the entity;
`With`/`Without` are a compile error there, since there is no set to filter.

**Annotate a multi-fetch destructure.** `it.next()` returns a comptime-built tuple, and no
language server evaluates `@Type`-constructed types — so `const vigor, const food = entry;`
leaves an editor with nothing to offer on `vigor.`. Writing the types restores it:

```zig
const vigor: *comp.Vigor, const food: *comp.InventoryFood, const met: *comp.Metabolism = entry;
```

Worth it wherever several components come out at once, where the annotation doubles as
documentation of which name is which. A single-component capture (`while (it.next()) |f|`) is
already unambiguous from the `Query` a line above, and is left bare.

**Structural changes go through a raw `*World` param.** A deferred `Commands` buffer is
deliberately not built (see the `project_commands_deferred` memory). Two consequences bind
every system: mutating the storage you are iterating is unsafe, so collect ids first and apply
after (`despawn_dead` is the pattern); and an entity that can be despawned must be read with
`MaybeSingle`, or the UI build panics the frame it dies.

## The tick, in order (`systems.zig`)

| System | Does |
|---|---|
| `advance_clock` | bumps `sim.elapsed`, only while a player exists |
| `update_food` | spoils each larder toward zero at its own `spoils` rate |
| `metabolize` | eats at the ration rate (food → vigor, clamped at `max`), or starves vigor down on an empty larder; logs each band crossing once |
| `resolve_busy` | ticks work in progress and dispatches its finish half at completion, then drops the `Busy` |
| `track_reach` | logs `A new recipe is within reach: {name}.` once on the false→true edge of a prerequisite-gated good's `prereq_met`; the seen-set is `Sim.reach_seen`, indexed by `buildable_bundle` order, so tab/filter/sort rebuilds never re-announce and a lost prerequisite re-arms it |
| `market.tick` | advances the passerby's clock (not an ECS system — one encounter per run, on `Sim`) |
| `capital.run_generators` | pays each generator's upkeep and deposits its yields |
| `mark_dead` | tags `Dead` at `vigor ≤ 0` and logs the death line |
| `despawn_dead` | reaps them; the UI then shows the start-over screen |

Naming convention: `update_<component_snake_case>` drives one component.

Band crossings — "You feel weak with hunger.", "You are starving." — come from
`Config.condition(frac)`, the single definition of the ALIVE/WEARY/SPENT thresholds that the
status word, the vigor chip and `actions.yield_factor` all share.

## Actions and capital (`actions.zig`, `capital.zig`)

**Every action an agent can perform, and every good it owns, is a typed component on that
agent's entity.** Not a catalog row, not a separate entity. Two properties fall out for free:
each agent can hold its own `ActionForage` with different costs and yields, and a good is
owned by exactly one agent and can never be stacked — the sparse set structurally allows at
most one instance of a type per entity, so no bookkeeping enforces it.

### Actions

Innate: `ActionForage`, `ActionScavenge`. Capital-unlocked: `ActionFish`, `ActionChopWood`,
`ActionCheckTraps`, `ActionHunt`.

Each carries `requires: Requires { energy, materials, hours }` — the price — and
`yields: Yields { food, materials }` — the reward. Both yields are `dist.Dist`, sampled at
resolution: **the spread is the risk**, there is no separate success roll. Every action has its
own risk texture; all five `dist.Kind`s are in use (Scavenge is exponential on both sides —
mostly scraps, occasionally a jackpot; Hunt is a big poisson). Check traps and Hunt are the
first actions with `requires.materials > 0`, spending bait and ammunition as inputs.

`Requires` and `Yields` are deliberately **not `pub`**. `World`'s comptime storage scan only
sees a file's public decls when reflecting across files, so keeping them private avoids
generating a dead `SparseSet` for each. The cost: no other file can name them to build one.

`actions_bundle` lists the *innate* action types and is spliced into `World.spawn`'s bundle
with `++`. It cannot simply be nested — `spawn` does not auto-flatten a nested tuple element,
so nesting is a compile error.

**Labor resolves in two halves,** because actions take time:

- `begin_labor` — refuse if `Busy` (one body, one act) or unaffordable; pay upfront; lock
  `quality` at the *advertised* pre-payment vigor; add `comp.Busy`.
- `finish_labor` — sample the yields at that locked quality, deposit, log the receipt.
  Dispatched by `resolve_busy` via `Busy.Doing` and `actions.doing_of`.

Both are `comptime ActionT: type` parameterized, so each action stays its own queryable
component while sharing one resolution path. Dying mid-task loses the work: paid, undelivered.

The affordability gates are asymmetric on purpose — **energy is strict** (vigor must stay above
zero), **materials may be spent to exactly zero** (a `>=` gate would refuse every action that
costs no materials at all).

### Capital

Sixteen buildable goods in four behavioral variants over one build path, plus two that only
the passerby carries (below).
`begin_build` / `finish_build` / `break_good` are comptime-parameterized over the good exactly
as labor is over the action — the gate/pay/start half is identical for all sixteen, only
`grant`/`revoke` differ.

| Variant | Goods | Behavior |
|---|---|---|
| **Unlocker** | Fishing rod, Hatchet, Wire snares, Air rifle | grants an action component outright — owning the good is what makes the verb possible |
| **`ActionModifier`** | Sandals, Work gloves, Bicycle, Cookpot, Root cellar, Chainsaw, Leaf bed, Pantry, Medicine chest | mutates an existing margin once, at build and again at break |
| **`Generator`** | Garden bed, Chicken coop | runs continuously: `requires` is the build order, `upkeep` the per-tick drain |
| **Curtain** | Shelter | grants nothing mechanical: owning it is Act I's win condition, and `build_ui` routes to the curtain on it |

Cutting across those variants is a second split, named by `capital.is_crude` and otherwise
carried entirely by the prices. **Crude**
goods — sandals, leaf bed, wire snares, root cellar, garden bed — are what one person makes
from scavenged scrap in half a day. **Manufactured** goods are the rest, at ×8 the materials
and ×10 the hours: a hatchet is four days of building nothing else while the larder drains.
They are not forbidden, only priced past what one body's time is worth — buying one is meant
to beat building it, which is the whole argument the merchant makes. Two goods may modify one
verb and stack (sandals and a bicycle both cheapen Forage); a better tool *superseding* a
weaker one is a different rule, below.

**Supersession is per family, by recompute.** `FishNet` outranks `FishRod` and `HandAxe`
outranks `Hatchet`; both rank-2 tools are traded, not built, so the BUILD catalog count is
unchanged. On any grant or break in a family, `recompute_fishing`/`recompute_chopping` read
the best rank owned and set the verb's stats *from the action's canonical defaults* — rank 2
is 0.7× energy and 1.4–1.5× yield — then re-apply the independent modifiers that share the
verb (gloves, chainsaw) on top. Resetting from base is what makes three things hold at once:
same-family stats replace rather than stack, breaking the better tool restores the next-best
exactly, and any number of build → sell → build cycles leaves the stats bit-exact. The verb
component is added only when absent, so a family change never appends a duplicate dense
entry. `break_good` removes the good before it revokes, so the recompute sees post-removal
state. The health pair is deliberately asymmetric: `health_apply` raises `max` and fills `v`,
`health_remove` lowers `max` and only clamps, so a night's rest is kept, not un-rested.

A modifier's `apply_*`/`remove_*` pair *scales* its target's `.s`/`.sd` rather than replacing
them, so a boost preserves the distribution's shape. The health trio is relative (`+=`/`-=`)
and fills what it adds — 1 for the crude leaf bed, 2 each for the manufactured pair — so
`v/max` never dips on an upgrade — which matters because the status
word and `yield_factor` both read that fraction. The Chainsaw is the Act II teaser: chop energy
×0.3 but `requires.materials += 1` for fuel, the first substitution of external energy for
muscle.

A generator's `upkeep` and `yields` are authored **per in-game day** and scaled by the frame's
dt, so a flow reads as a trickle. `run_generators` is an `inline for` over
`capital.generator_bundle`, one `Query` per type. **That list is manual, not derived**, because
"every component type tagged `Generator`" is a fact about *types*; the ECS only answers
instance-level questions, so there is no runtime query for a type-level category.

`capital.prereq_of` declares a good's prerequisite component — Work gloves and Chainsaw both
target `ActionChopWood`, which only exists once the Hatchet is built. It gates the build *and*
the tile, so a modifier can never be applied to a component that is not there, which would
panic in `getMany`. It is also the roster's only tech-tree edge.

`capital.unlock_met` is the second gate, and the Shelter is its only subject: a good may carry
an `unlock` — an *absolute* current-Vigor floor (`vigor_abs`, so a raised ceiling never moves
the bar), a larder floor and a count of good kinds already owned — stating what it asks of
the builder, as against `requires`, which is what the build spends. Goods with no `unlock`
field are ungated (`@hasField`). One function serves the milestone's checklist, its action
enablement, and `begin_build`. The conditions are read at `begin_build` and not again, so a
dip mid-build doesn't stop work already paid for. Completing the Shelter is what raises the
Act I curtain; `pages/root` routes on the player owning one. `capital.goods_owned` counts them
by sweeping `buildable_bundle` with `has`, so it counts **kinds** — four pairs of sandals are
never four goods built.

Every good carries a `count`, and owning one is not a reason you can't make another: building
for someone else is what a count is for. Only the **first unit carries the effect** — a second
pair of sandals is stock, not a deeper discount — so `finish_build` increments an existing
component and runs `grant` only on the way in from absent. It increments rather than re-adding
because `SparseSet.add` does not guard duplicates: a second `add` would append a second dense
entry and leave the index pointing at one of them. `break_good` takes spares first and revokes
only with the last unit, so losing a spare can't cost you the discount you're still wearing.
`grant_public` is the same grant path exposed for a *bought* good, so a traded tool lands its
effect exactly as a built one does.

`capital.cancel_build` abandons work in progress: it salvages `config.cancel_refund` of the
materials and frees the body, while the energy and every hour already spent are gone. The refund
is flat rather than prorated because materials are charged in full at `begin_build` and nothing
draws them down over time — a time-proportional refund would imply a consumption schedule the
sim doesn't run. `good_of_doing` inverts `doing_of_good` to recover the price from a `Busy` that
was never handed one, and returns null for the six labor verbs, which is what refuses a cancel
on a half-finished forage.

## Catalog, passerby, and barter (`catalog.zig`, `market.zig`, `barter.zig`)

**`catalog.zig` is the one table of stable identity.** Every action and good component maps to
a stable string ID (`act.forage`, `good.*`), a `Kind` (`action` / `crude_good` /
`manufactured_good`), coarse input/output keys, an authored order, and an `on_surface` flag.
The flag is the load-bearing part: a component *existing* is not a reason to show it —
`ActionHunt` and `AirRifle` are defined and off the Act I surface, which is exactly five
verbs. The goods table is generated comptime over `capital.buildable_bundle`, so it cannot
drift from the roster, and its tiers come from `capital.is_crude`. Copy (display names,
effect sentences) stays at the page tier in `good_text`; this module owns identity, type,
order, and membership.

**The passerby is sim state, not UI.** `market.Encounter` lives on `Sim` as a clock-driven
machine `absent → approaching → present → departed → absent`, ticked by `market.tick` off the
sim clock (never a calendar day). Each arrival bumps a monotonic `id` and refills a finite
satchel of `Ware`s (food, materials, fish_hook, whetstone); stock does not regenerate until
the next visit. `dealable()` is `phase == .present`, the only gate the UI reads, so hiding the
strip cannot change whether a passerby is here.

**One transfer grammar.** A `Line{item, qty}` and a fixed-cap `Bundle` express both sides of
any deal; a `Quote` carries the offer's stable `id`, the encounter `rev` it was captured
under, its `Direction`, give/receive bundles, an effect preview, remaining `stock`, and
`next_unit` — what the *following* unit of a sell would fetch, shown before confirmation.
`Quote.refusal` is the single revalidation everyone shares, in precedence order: `departed`,
then `stale` (the passerby changed), then `sold_out`, then `unaffordable`; every refusal has
player-readable copy.

**Sell prices diminish.** `sell_value(ware, n)` is a geometric decline `base·ratio^n` clamped
to a positive floor, authored per ware: Food `2.5 / 0.75 / 0.5`, Materials `1.5 / 0.6 /
0.25`, the tools `~6–8 / 0.3 / 1.0`. The floor is the anti-domination guarantee — selling
always beats discarding, and the first units pay well — while the satchel and the visit
window cap how much can be dumped at the top price.

**`barter.resolve` is all-or-nothing.** It revalidates the quote plus give-side ownership
before touching anything, then moves both bundles: Food/Materials on the inventory
components, a sold good through `capital.break_good` (its effect leaves symmetrically), a
bought good through `capital.grant_public` (its effect lands once; a repeat is stock), the
satchel decremented, one log line pushed. A failed check mutates nothing and returns the
reason. `market` stays world-free; `barter` is the only place a `Quote` meets an entity.

## The authored roster (`roster.zig`, `data/`)

The labor verbs and the capital goods are also written as data: `data/actions.zon` and
`data/goods.zon`, parsed at load by `std.zon.parse` into one `roster.Catalog`. The typed
components above remain the roster the sim runs on; the catalog is held equal to them by
test, record for record (`roster.typed_actions`/`typed_goods` is the bridge), and the
interpreter that runs the sim from the catalog instead is roadmap work ("CAT-01"). The files
are the contract new content is written against.

**One id space.** A record's id is plain snake case — `forage`, `hatchet`, `charcoal` — and
the file is its kind. Resources, actions and goods share the space: a reference resolves by
lookup, and a collision is a load error. Resources are the `Resource` enum in code, not data,
because each one is structural (a stockline, a palette hue, a board wedge) and has its own
behavior (food spoils, coin settles); a line names one by its tag name.

**Lines.** Every quantity is a `Line { item, n, kind = .fixed, sd, per = .once }`: an item and
an amount, drawn when `kind` is not `.fixed`, settled `once` (an input at begin, an output at
completion) or per `day` (a flow while the good is owned — all of a good's day lines
together, affordable-or-nothing). A record carries `requires { energy, hours }` — the
body-and-time price, apart from the lines because energy is a flow and its gate is strict —
plus `input` and `output` lists. A generator is a good with day lines; an intermediate is a
good whose once-output is a lot of itself; neither is a category field.

**Effects.** What owning a good does is a list from a fixed vocabulary: `grant` a verb;
`scale` or `add` a verb's `energy`, `hours`, or a named `input`/`output` line;
`vigor_ceiling`; `food_quality`; `spoil_scale`. A `family { name, rank }` says a better tool
supersedes a weaker one; `needs` names the verb a modifier works on; `unlock`, `capacity` and
`milestone` are the shelter's. `copy` carries the player's words — the BUILD effect sentence,
the rail's short form, the receipt line.

**Validation.** `roster.load` refuses a file whole: a parse error carries its line and
column, a shape or cross-reference failure its `Rule` and the offending id — an unknown item
or target, a later-act reference, a grant on an innate verb, a modifier on a verb the good
neither needs nor grants, a rank or milestone collision, a drawn input, a day line on an
action. The shipped files are compiled in (`roster.shipped`, wired in `build.zig`) and parsed
through the same path, so `zig build test` validates the real content.

## Shared text and search

`query.zig` is the one catalog query parser. It tokenizes a search string once into a bounded
`Query` whose terms are slices of the input — quoted phrases, a leading `-` for negation, a
bare `*` wildcard, `field:value` with comma-OR alternatives, all case-insensitive — and
matches rows through a duck-typed provider (`text(field)`, `haystack()`, `inReach()`) with no
per-row allocation. Fields are one enum for both catalogs (`in`/`out`/`type`/`state`/`is`,
plus the recipe-only `tech`); `input`/`output`/`kind`/`status` alias onto them, `built` folds
to `owned`, `state:in-reach` means ready or reach ≥ 0.5, and `is:` matches state or type.

`log.Log` is a 64-entry ring of toned lines with a `max_len` of 256 bytes per entry. A longer
message is refused as a whole: the entry stores the visible `overflow_marker` and sets
`refused`, never a cut or mid-codepoint prefix, and `push` stays `void` because the refusal is
observable on the stored entry.

`tokens.zig` is the leaf of design tokens — page padding, the gap ladder, the hairline, the
control-height and rail-width ladders — in logical px, with the typography sizes and
transition durations re-exported from `ui_client` so every finalized number has one home.

## Module map

| File | Holds |
|---|---|
| `main.zig` | `App`, the event loop, the sim tick, `spawn_agent`/`spawn_player` |
| `components.zig` / `tags.zig` | component and tag types — **only** `pub const <Name> = struct {…}`, since `World` enumerates them at comptime |
| `world.zig` | the sparse-set `World` |
| `ecs.zig` | `ecs.run` + the system-param machinery, including `getMany` |
| `systems.zig` | the sim systems, in tick order |
| `actions.zig` | per-agent labor, `actions_bundle`, `yield_factor` |
| `capital.zig` | the generic build path, the modifier pairs, the generator system |
| `baselines.zig` | the fresh-agent baseline, read from the component defaults |
| `body.zig` | the BODY projection: food coverage and the tagged recovery outcome |
| `eating.zig` | the Eating Policy math: slider value ↔ rate, the word ladder, per-act coverage/recovery |
| `catalog.zig` | stable IDs, kinds, authored order, and Act I surface membership for actions and goods |
| `roster.zig` | the authored roster: the record grammar, the ZON loader and validator, and the bridge table to the typed components |
| `market.zig` | the passerby encounter, wares, bundles, quotes, refusals, and the sell-value schedule |
| `barter.zig` | atomic resolution of a quote against the world |
| `query.zig` | the catalog query parser |
| `dist.zig` | the distribution engine (normal / poisson / uniform / exponential / fixed) + `stats` for the p10–p90 band, and `kindLabel` for the glyphs' spoken names |
| `res.zig` | `Resources`, grouped by who writes it: `platform`, `input`, `time`, `sim`, `config`, `view`, plus the host registries (`cursor`, `commands`, `semantics`, `announcements`, `a11y`, `motion`, `tween`). `Sim` carries the log, the reach seen-set and the passerby encounter |
| `palette.zig` | the game's palette — the ten `Theme` roles, the terminal ground, and the six resource hues |
| `tokens.zig` | the non-color design tokens, in logical px |
| `log.zig` | `Log`, a 64-entry ring buffer of toned event lines; refuses an over-long line whole. Leaf module |
| `font.zig` | `Fonts`, a lazy size → `ttf.Font` cache. One font per point size |
| `pages/` | the screens (`build_ui`, `play_game`, `gameover`, `act_one_end`) and the template shelf |
| `root.zig` | the `ha` library root and its re-exports |

`build.zig` makes the module import *itself* as `ha`, so library-internal files can
`@import("ha")` rather than reaching across with relative paths.

`dist`'s `.fixed` kind is exempt from the `scaleOf` 0.2 floor — every action leaves one yield
slot at a fixed zero, and without the exemption each draw silently deposited +0.2.

## Assets

- `data/actions.zon`, `data/goods.zon` — the authored roster, compiled in by `build.zig`.
- `assets/fonts/` — TTF variants; `JetBrainsMonoNL-Regular.ttf` is the one loaded.
- `assets/icons.png` — a 2×2 sheet of 512px capital-good icons, sampled by
  `ui_client.icon_sprite`. Currently unused.
- `assets/hello.png` — test image.
