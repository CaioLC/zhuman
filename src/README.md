# The Simulation

The game's model and the loop that runs it: the ECS, the components, the systems, and the
per-agent actions and capital goods.

The UI engine is [`ui/README.md`](ui/README.md) and its host binding is
[`ui_client/README.md`](ui_client/README.md). What the game is *for* is
[`../docs/design.md`](../docs/design.md); what is next is
[`../docs/roadmap.md`](../docs/roadmap.md).

## The model

The first slice is **one actor under scarcity** — Robinson Crusoe economics, no exchange and
no money. There is deliberately **no world and no space**: everything the player sees and does
is UI.

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
every tick at the rate the player selects (`comp.Metabolism.setting`: ration ½× / normal /
feast 2×), and an empty larder drains vigor instead. Because labor's energy gate is strict —
an action can never take vigor to zero — **starvation is the only path to death**.

That yields the two praxeological margins the game is about: *labor vs. leisure* (working
spends vigor, which refills only through eating, whose rate is a standing choice) and *now vs.
later* (act for food and materials now, or spend materials and hours on capital).

Death is total: a start-over wipes everything accumulated (`res.sim.reset()`).

The decision is split **`decide → act`**. The player is the only decider today; AI deciders
are meant to feed the same options later.

## Main loop (`main.zig`)

`App` owns all state. `App.init` does SDL and window setup only; `App.setup` runs once after
`App` is stable on the stack — font, `Resources`, the ECS `World`, the player actor, the
per-frame arena, and the `UiCtx` (safe here because internal pointers are taken after the
struct's address is fixed). `main.zig` owns `App`, the event loop, the sim tick, and
`spawn_agent`/`spawn_player`; the screens live in `pages/`.

Each frame:

1. **Events** — the SDL poll writes into `res.input`; a left click also calls
   `ui.mark(.clicked, x, y)`.
2. **Mark** — `ui.mark(.hovering, …)` hit-tests *last* frame's stamped rects by iterating the
   interaction slot pool. No tree walk.
3. **Update** — `ecs.run(&world, &res, system)` per system, in the order below.
4. **Build UI** — `ui.beginFrame()`, arena reset, `pages.build_ui()` builds fresh trees and
   returns `Trees`, a flat list of independent roots (a screen, plus any floating overlay).
5. **Layout** — `set_global_pos()` per root: solve sizes, then resolve positions. Pure — content
   was measured at build time.
6. **Stamp** — `ui.stamp_rects(root)` copies each queried node's rect into its slot, feeding
   the next frame's step 2.
7. **Render** — `ui_client.draw_tree()` per root in list order, so later trees paint on top.
   Then `ui.endFrame()`.

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

Fifteen goods, all buildable end-to-end, in three behavioral variants over one build path.
`begin_build` / `finish_build` / `break_good` are comptime-parameterized over the good exactly
as labor is over the action — the gate/pay/start half is identical for all fifteen, only
`grant`/`revoke` differ.

| Variant | Goods | Behavior |
|---|---|---|
| **Unlocker** | Fishing rod, Hatchet, Wire snares, Air rifle | grants an action component outright — owning the good is what makes the verb possible |
| **`ActionModifier`** | Boots, Work gloves, Bicycle, Cookpot, Root cellar, Chainsaw, Bed, Pantry, Medicine chest | mutates an existing margin once, at build and again at break |
| **`Generator`** | Garden bed, Chicken coop | runs continuously: `requires` is the build order, `upkeep` the per-tick drain |

A modifier's `apply_*`/`remove_*` pair *scales* its target's `.s`/`.sd` rather than replacing
them, so a boost preserves the distribution's shape. The health trio is relative (`+=`/`-=`)
and fills what it adds, so `v/max` never dips on an upgrade — which matters because the status
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

`begin_build` checks `has` **first**; `SparseSet.add` does not guard duplicates.

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
| `dist.zig` | the distribution engine (normal / poisson / uniform / exponential / fixed) + `stats` for the p10–p90 band |
| `res.zig` | `Resources`, grouped by who writes it: `platform`, `input`, `time`, `sim`, `config`, `view` |
| `palette.zig` | the game's `cold`/`warm` palettes and the blend between them |
| `log.zig` | `Log`, a 64-entry ring buffer of toned event lines. Leaf module |
| `font.zig` | `Fonts`, a lazy size → `ttf.Font` cache. One font per point size |
| `pages/` | the screens (`build_ui`, `play_game`, `gameover`) and the template shelf |
| `root.zig` | the `ha` library root and its re-exports |

`build.zig` makes the module import *itself* as `ha`, so library-internal files can
`@import("ha")` rather than reaching across with relative paths.

`dist`'s `.fixed` kind is exempt from the `scaleOf` 0.2 floor — every action leaves one yield
slot at a fixed zero, and without the exemption each draw silently deposited +0.2.

## Assets

- `assets/fonts/` — TTF variants; `JetBrainsMonoNL-Regular.ttf` is the one loaded.
- `assets/icons.png` — a 2×2 sheet of 512px capital-good icons, sampled by
  `ui_client.icon_sprite`. Currently unused; the tray that drew from it is not built.
- `assets/hello.png` — test image.
