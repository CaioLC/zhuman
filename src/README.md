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

**An agent owns goods as counts, and everything it can do follows from them.** `comp.Goods`
is one count per record of the authored roster (below); zero is not owned. A verb is never
stored on the agent: `effects.verb` derives its effective terms from the base record and
the goods owned, so each agent's Forage has its own price once it owns sandals, and a good
is owned by exactly one agent and stacks only as a count. `comp.Granted` records what the
goods contribute to the body and larder, so those deltas stay relative.

### Actions

Innate verbs are the records flagged `innate`; every other verb exists while an owned good
`grant`s it. `actions.quote` is the one gate calculation — the tile, `begin` and a future
decider read the same answer: the verb's effective terms, the quality a begin would lock,
and a `Standing` of `ready`, `busy`, `energy` or `short` with the first unpayable line.

**Labor resolves in two halves,** because actions take time:

- `begin` — refuse unless the quote is ready (one body, one act; energy strict; inputs
  payable); pay the energy and the input lines upfront; lock `quality` at the *advertised*
  pre-payment vigor; add `comp.Busy{ .doing = .{ .labor = index } }`.
- `finish` — draw each output line at the locked quality (**the spread is the risk**, there
  is no separate success roll), deposit through `ledger.draw`, log the receipt built from
  what landed. A verb lost mid-task — the rod sold while fishing — finishes as nothing.

Both take a catalog index; `systems.resolve_busy` dispatches on the busy marker's tag.
The affordability gates are asymmetric on purpose — **energy is strict** (vigor must stay
above zero), **an item may be spent to exactly zero** (a `>=` gate would refuse every action
that costs no materials at all). The typed entry points (`action_forage` …) resolve their id
and call `begin`.

### Capital

Every buildable record goes through one path — `quote`, `begin`, `finish` — and what it does
once owned is its `effects`, interpreted by `effects.zig`: a grant, a scale or offset on a
verb's price or lines, a ceiling, a larder quality step, a spoilage factor. Generators are
the goods with `day` lines, intermediates the goods whose once-output is a lot of themselves;
neither is a category in code.

`capital.quote` answers for the BUILD row and the gate at once: the units owned, the `reach`
of the build order (the smallest held-over-needed across its once-inputs), and a `Standing`
in precedence order — `needs` (the verb or tool a modifier works on is not held: the roster's
only tech-tree edge, so a chainsaw is never offered without Split wood), `unlock` (the
shelter's standing conditions: an absolute current-vigor floor, a larder floor, a count of
good kinds owned — read at `begin` and not again, so a dip mid-build doesn't stop work already
paid for), `busy`, `energy`, `short`, `ready`.

**Ownership moves through four doors and settles the same way each time.** `finish` adds the
built lot; `acquire` adds a traded one; `release` takes units, spares first; `break_one` is
`release` with the receipt line. On the way in from zero and on the way out to zero they
*settle*: `effects.apply` moves the body and larder by the delta of what the owned goods now
contribute — a raised ceiling fills what it adds, a lowered one only clamps — and
`bridge.shadow` mirrors the derived ownership and verb terms onto the typed components for
what still reads them. **Only the first unit carries the effect**: a second pair of sandals
is stock, and losing a spare keeps the discount.

**Supersession is per family, by derivation.** A good's `family` and `rank` say the fishing
net outranks the rod and the hand axe the hatchet; `effects.applies` lets only the best rank
owned of a family apply, so same-family stats replace rather than stack, losing the better
tool restores the next-best exactly, and any number of build → sell → build cycles leaves the
terms bit-exact, because nothing is ever mutated in place. Goods outside a family stack
freely (gloves and a chainsaw on the same verb).

`cancel_build` abandons work in progress: it salvages `config.cancel_refund` of the build
order and frees the body, while the energy and every hour already spent are gone. The refund
is flat rather than prorated because the order is charged in full at `begin` and nothing
draws it down over time. It refuses on a labor verb — half-foraging is not a thing you can
take materials back from.

`run_generators` ticks every owned good with `day` lines on every agent: if this tick's
slice of the upkeep is payable, pay it and deposit the same slice of the flow. Both are
authored **per in-game day** and scaled by the frame's dt, so a flow reads as a trickle.

`goodsOwned` counts **kinds** — four pairs of sandals are never four goods built;
`ownsMilestone` is what the curtain routes on; `capacity` sums the housing of what is owned.

**The typed roster is a shadow.** `comp.FishRod` and the other typed good and verb components
still exist and still carry the sim's numbers as field defaults; `bridge.shadow` keeps their
presence, counts and terms equal to the derived state after every settle, so the pages, the
stable-id catalog and the migration read them unchanged. The typed effect pairs at the end of
`capital.zig` are the reference the interpreter is held equal to in `effects.zig`; nothing
live calls them. Their retirement is roadmap work ("CAT-01").

## Catalog, passerby, and barter (`catalog.zig`, `market.zig`, `barter.zig`)

**`catalog.zig` is the one table of stable identity.** Every action and good component maps to
a stable string ID (`act.forage`, `good.*`), a `Kind` (`action` / `crude_good` /
`manufactured_good`), coarse input/output keys, an authored order, and an `on_surface` flag.
The flag is the load-bearing part: a component *existing* is not a reason to show it —
`ActionHunt` and `AirRifle` are defined and off the Act I surface, which is exactly five
verbs. The goods table is generated comptime over `capital.buildable_bundle`, so it cannot
drift from the roster, and its tiers come from `capital.is_crude`. Copy (display names,
effect sentences) is the record's `copy` in the authored roster; this module owns identity, type,
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

The labor verbs and the capital goods are data: `data/actions.zon` and `data/goods.zon`,
parsed at load by `std.zon.parse` into one `roster.Catalog`, which is what the sim runs on
(`actions.zig`, `capital.zig`, `effects.zig`) and the pages read. The typed components above
are its shadow, kept current by `bridge.shadow` and held equal to the records by `bridge.zig`'s
tests until they are retired ("CAT-01"). The files are the contract new content is written
against.

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

**The interpreter (`effects.zig`, `ledger.zig`).** What an agent can do, and on what
terms, is a pure function of the catalog and the goods it owns: `effects.verb` folds every
applying good's effects into the base record, in roster order, and returns null when
nothing grants the verb. Nothing is cached and there is no remove path — losing a good is a
different input to the same function, which is what keeps a build → sell → build cycle
bit-exact. A family's best rank owned is the only member of that family that applies. The
body and larder are the one exception to derive-never-store, because their components have
other writers: `effects.apply` computes the contribution, diffs it against `comp.Granted`,
and applies the delta — a raised ceiling fills what it adds, a lowered one only clamps.
`ledger.zig` is where a line meets holdings: the one switch over `Resource` to the inventory
components, plus `comp.Goods` counts for a good item, with `short`/`pay`/`draw` over a list
of lines. Per agent that leaves `Goods` (a count per catalog index) and `Granted`; the
catalog itself sits on `Resources` as `catalog`, so a system declares `*const roster.Catalog`.

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
| `roster.zig` | the authored roster: the record grammar, the ZON loader and validator. Reaches only `std` and `dist`, since `res.zig` carries it |
| `bridge.zig` | which record each typed component transcribes, and the parity tests; goes with the typed roster |
| `effects.zig` | the interpreter: a verb's effective terms from the catalog and the owned goods; the body/larder delta |
| `ledger.zig` | where a line meets holdings: the `Resource` → inventory-component switch, good counts, `short`/`pay`/`draw` |
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
