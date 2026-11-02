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
- **Biomass** (`comp.InventoryBiomass { v }`) is the fungible durable stockpile in every act:
  Act I UI and log prose cover its official name as **Materials**, while Act II shows Biomass.
  The curtain carries the same balance unchanged; typed resources join it rather than replacing it.

**Eating is a standing policy, not an action.** `systems.metabolize` converts larder to vigor
every tick at `base_rate × rate`, where `comp.Metabolism.rate` is a persisted agent-local
multiplier in `[0.5, 2.0]` (`1.0` at normal) that the Eating Policy slider sets through a
`SetRation` intent; `Config` owns
the range and default, and `Config.clampMetabolism` is the one place a rate is made legal. An
empty larder drains vigor instead. Because labor's energy gate is strict — an action can never
take vigor to zero — **starvation is the only path to death**.

**Starting values live on the components.** `Vigor`, `InventoryFood`, and `Metabolism` carry
field defaults, `spawn_agent` spawns them default-valued, and `baselines.zig` *reads* those
defaults (`(comp.Vigor{}).max`) as the canonical ceiling/larder baseline, so Holdings can show
current-vs-base margins against a value that cannot drift from the spawn.

**Three components are derived, each by one writer system.** The UI reads them and recomputes
none of them, and each writer is idempotent: run twice on an unchanged world it writes the same
values and emits nothing new, and a test says so.

- `comp.Condition` is the agent's band, `alive`, `weary` or `spent` (`Condition.Band`, `sim.Band`).
  `rules/condition.refresh` is the one place the two thresholds (`Config.condition`) are
  applied, and the `condition` system calls it on every agent and emits `BandCrossed` for each
  band that moved. The vigor chip's tone, the hall's vigor line and labor's yield step
  (`actions.yield_factor`) read the band. `actions.begin` and `capital.begin` also refresh the
  agent they charge, and carry the crossing on `WorkBegun.weary`, because the log words labor's
  toll ("You feel weak. Work will yield less.") apart from hunger ("You feel weak with
  hunger.") and a writer that only compares with the previous band cannot tell the two causes
  apart; `capital.collect_generator` refreshes for the same reason, since a collection's energy
  can outweigh the vigor it restores. Every crossing the writer reports is the metabolism's.
- `comp.Outlook` is the BODY projection: the days the larder lasts at the current rate
  (`food_days`) and a tagged `Recovery`, `at_ceiling`, `no_food`, `no_quality`,
  `partial { days, restored }` or `recovering { days }`. The `outlook` system computes it with
  the same products `metabolize` applies (`base_rate × rate`, `× vigor_per_food × quality`), so
  the projection and the loop agree by construction, and both BODY lines of the Act I holdings
  read it.
- `comp.Quotes` is what each verb, recipe and generator would answer right now: per verb the
  standing and the quality a begin would lock, per recipe the standing, the count owned and the
  reach, per generator the standing and its progress, and in each the first unpayable line by
  its index. The `quotes` system fills every slot through `actions.quote`, `capital.quote` and
  `capital.generator_quote`, so the ACTIONS tile, the BUILD row, the GENERATORS tile and a
  decider read one answer; the handlers still ask the rule at apply time, and the rule is the
  authority. It holds standings and not a verb's terms, which stay the pure read
  `actions.verbOf`, because the world stores every component inline for its full entity
  capacity and a copy of the terms per verb would add tens of megabytes to it.

The writers close each act's `handle` and `update` sets, just before `log`, so a paused intent
or a build finished this tick shows the next frame (the schedule, below). The fixture seed,
which runs after the tick, brings all three current after it sets a world by hand
(`fixture.derive`); a seeded band is set, not reached, so it is written without a
`BandCrossed`. The debug page's pokes are intents, applied before the writers run.

`eating.zig` is the slider's side of the BODY: `rate(value) = 0.5 × 4^(value/100)` over a
`0..100` slider, its inverse `valueFromRate`, the policy word ladder (meager … lavish), and the
per-act coverage/recovery constants; it imports nothing and serves both the template and a
future system.

That yields the two praxeological margins the game is about: *labor vs. leisure* (working
spends vigor, which refills only through eating, whose rate is a standing choice) and *now vs.
later* (act for food and materials now, or spend materials and hours on capital).

Death is total: a new run (`begin_run`) wipes everything accumulated (`Sim.reset`).

The decision is split **`decide → act`**. The player is the only decider; the roadmap's AI
deciders are meant to feed the same options.

## Main loop (`main.zig`)

`App` owns all state. `App.init` does SDL and window setup only; `App.setup` runs once after
`App` is stable on the stack — font, `Resources`, the ECS `World` (empty until a `NewRun`
begins a run), the per-frame arena, and the `UiCtx` (safe here because internal pointers are
taken after the struct's address is fixed). `main.zig` owns `App`, the event loop and the one
call to the schedule; the screens live in `pages/`.

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
3. **Update** — host `real_dt` advances roster watching and the tween registry. `Playback`
   derives simulation `time.dt` at pause/1×/2×/3×. Then one call,
   `sim.schedule.tick(&world, &res.game)`, runs the simulation (see *The states and the
   schedule*). Then `pages.prepare(&ui, &world)`: with `HA_FIXTURE` set, the fixture harness
   seeds the world here, after the tick and before the build, so the seed is what renders;
   otherwise it does nothing.
4. **Build UI** — `ui.beginFrame()`, arena reset, `pages.build_ui(ui, &world)` builds fresh
   trees over a `*const World` and returns `Trees`, a flat list of independent roots (a screen, plus any floating overlay).
   The command registry and the host **semantic snapshot** (`res.semantics`) both
   `beginBuild` here, so interactive controls publish their prior-build command owners and
   their owned accessibility metadata (role/label/value/state/relationships/live-region) in
   paint order as they build.
5. **Layout** — `set_global_pos_measured()` per root: solve sizes, then resolve positions.
   Content was measured at build time; the one host call is the text measurer re-measuring
   `.fill` text at its solved width, between the width and height passes.
6. **Stamp** — `ui.stamp_rects(root)` copies each queried node's rect into its slot, feeding
   the next frame's step 2.
7. **Render** — `ui_client.draw_tree()` per root in list order, so later trees paint on top.
   Then `ui.endFrame()`; the command registry and the semantic snapshot `endBuild` here,
   double-buffer-swapping this frame's build into the completed prior snapshot the next
   event stage (and the accessibility bridge) reads — the semantic snapshot owns its
   strings by value, so it never borrows the frame arena that resets in step 4.

There is no retained tree between frames. The interaction slot pool is what bridges the
boundary.

## ECS (`ecs/`, `sim/ecs.zig`)

A [Bevy](https://bevyengine.org)-inspired ECS over a sparse-set `World`: the ergonomics are
modelled on Bevy, the storage is comptime Zig rather than archetypes. The engine is the package
`src/ecs/` (module `ecs`), generic over the component and tag namespaces and the resources
type, and knows nothing of this game; its API, the queries and the binding rules of `run` are
in [`ecs/README.md`](ecs/README.md). This game instantiates it in one file, `sim/ecs.zig`:
`World = ecs.World(components.zig, tags.zig)`, plus `Entity`, `MAX_ENTITIES` and `SparseSet`,
and the system params over that `World` and `sim.Resources`. `Query(.{…})`, `Single` and
`MaybeSingle` are over `*World` and yield `*T`; `ConstQuery`, `ConstSingle` and
`ConstMaybeSingle` are over `*const World` and yield `*const T`. `With`, `Without`, `Maybe` and
`getMany` are the engine's; `run(world, res, system)` takes `*World` and `*sim.Resources`, so
the host calls `ecs.run(&world, &res.game, system)`.

**System, rule, read.** A **system** is a function the schedule calls with system params, and
the only code that holds `*World`. A **rule** is a function a system calls (a gate, a payment, a
deposit, an interpretation): it takes `*World` for a write and `*const World` for a read. A
**read** is a pure function over values, or a component a system derived; that is what the UI
holds. The UI build takes `*const World`, reads components through the `Const` queries and the
read rules, and writes intents; a template that writes a component does not compile, and
`tools/boundary_check.sh` fails a page or template whose `pub fn` takes a mutable world. The one
exception is the fixture harness, which seeds the world before the build (`pages.prepare`).

**Resources.** `sim/res.zig` holds `sim.Resources { sim, config, time, catalog, events }`:
exactly what a system may reach. `sim: Sim` is the run (the clock, the log, the prng behind `random()`, the
reach seen-set, the passerby, the merchant, the stub neighbours, the Exchange and the
population stand-in; `reset` starts a
fresh one), `config: Config` the tuning, `time: Time` this frame's real and simulation deltas,
`catalog` the authored roster, `events` the intents and facts (*Events*, below); `hours_to_secs`
lives beside them. Every field has a default, so
a sim test builds `sim.Resources{}` whole. The host's `Resources` (`res.zig`) embeds it as the
field `game` beside its own: the platform, input, the UI registries, playback, menu, route,
title, settings, saves and view. The UI reads the simulation through `ctx.res.game.sim`,
`ctx.res.game.config`, `ctx.res.game.catalog` directly and writes intents through
`ctx.res.game.events.writer(T)`; it reads an outcome it waits on (a trade settled, a tile
researched) as a fact, with a cursor of its own. `sim/root.zig` is the `sim` namespace,
re-exported by the library as `ha.sim`; a caller spells the folder (`ha.sim.rules.actions`,
`ha.sim.data.roster`). `zig build test-sim` compiles the sim files and the `ecs` package with
no `sdl3`, `ui` or host import (root: `sim/root.zig`), so a sim file that reaches the host fails
it.

**World.** One `SparseSet` per public decl of `components.zig` and `tags.zig`.
`spawn(bundle)` takes a tuple of component *instances* and bare *tag types*; then `add`,
`remove`, `get`, `has`, `despawn`. `get` through a `*const World` yields `?*const T`. Ids are
never recycled, so `MAX_ENTITIES` is a lifetime-spawn cap, not a live one.

**System params** are declared as a system function's parameter types and built by `ecs.run`
through comptime introspection:

| Param | Meaning |
|---|---|
| `Query(.{…})` | iterate every matching entity |
| `Single` / `MaybeSingle` | expect exactly one / at most one |
| bare component type | a *fetch*: drives iteration, yields `*T` |
| `With(T)` / `Without(T)` | filter without fetching |
| `Maybe(T)` | yields `?*T` |
| `Entity` | yields the id; does not drive iteration |
| `*sim.Resources` / `*World` | taken directly |
| `*Sim`, `*const Config`, `*const Time`, `*const roster.Catalog`, `*Events` | one **resource group**: any struct-typed field of `sim.Resources` |
| `EventWriter(T)` | appends `T` to the store on `sim.Resources.events` |
| `EventReader(T, id)` | reads `T` with the cursor the store keeps for reader `id` |

Prefer naming groups over taking `*sim.Resources`: the signature then states what the system
reaches, and the compiler holds it to that. No system can touch the renderer, the input or the
view, because `run` is handed the simulation's resources, not the host's. `*const` vs `*` says
whether it reads or writes, which is why `*const Config` (tuning) and `*Sim` (the run) read
differently at a glance. The groups are derived from `sim.Resources`' fields, so a new group
needs no change in `ecs.zig`, and the engine's two guards apply (struct-typed fields only,
distinct types). `resolve_busy` takes `*sim.Resources`, because it delegates to
`finish_labor`/`finish_build`, which do too.

`ecs.getMany(world, entity, params)` is `Query`'s non-iterating sibling, for pulling several
components off an entity you already have. It panics on a missing required component rather
than degrading to `?*T`, because the caller is expected to have already qualified the entity;
`With`/`Without` are a compile error there, since there is no set to filter.

**Annotate a multi-fetch destructure.** `it.next()` returns a comptime-built tuple, and no
language server evaluates `@Tuple`-constructed types — so `const vigor, const food = entry;`
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

## Events (`sim/events.zig`)

The simulation's event store is the engine's `Events` (see [`ecs/README.md`](ecs/README.md))
over `sim/events.zig`, held on `sim.Resources.events`. Every event is plain fixed-size data that
names agents, records and items by index and amounts by number, never by text.

**Intents** say what an agent means to do: `BeginLabor`, `BeginBuild`, `CancelBuild`,
`ToggleGenerator`, `CollectGenerator`, `SetRation`, `Barter`, `MerchantDeal`, `Research`,
`RaiseExchange`, `NeighbourDeal`, and `NewRun`, which asks for a fresh run. The UI writes them through
`ctx.res.game.events.writer(T).push(…)` where it used to call a rule, and mutates nothing; a
decider will write the same events. A **handler** system reads one intent family and calls the
rule it already has; a rule that refuses changes nothing and returns a `Refused.Reason`, and
the handler answers with `Refused{agent, intent, reason}`.

**Facts** say what happened: `WorkBegun`, `WorkDone`, `WorkLost`, `BuildCancelled`,
`GoodBroke`, `Collected`, `BandCrossed`, `FoodRanOut`, `Died`, `GoodsChanged`,
`RecipeInReach`, `Traded`, `Researched`, `ExchangeRaised`, `NeighbourSettled`, `Arrived`,
`Departed`, `Refused`, and the run's own: `RunBegun` (a run began) and `ActEnded{act}` (the
player's act ended and the next is requested). Systems and the rules they call write them.
A receipt in a fact is a `ledger.Receipt`: up to a record's `roster.max_lines` lines of
`{ item: ledger.Item, qty }`.

**The two-tick rule.** `events.update()` opens each frame and expires what was written before
the previous frame began. An intent the UI writes during frame N's build is read by the
handlers of frame N+1, and gone at the top of N+2; a fact a system writes is readable for the
rest of its frame and the next.

**Reader ids.** `ReaderId` names every scheduled reader: `labor`, `build`, `generators`,
`ration`, `passerby`, `barter`, `merchant`, `research`, `exchange`, `neighbours`, `run`
(`new_run`), `log`. The store keeps one cursor per event type per id, so a handler
reading its family sees each intent once. The UI reads facts with a `u64` cursor it keeps
itself, through `events.readerAt(T, &cursor)`: the trade dialogs read `Traded` on
`TradeState.heard`, the research board `Researched` on `ResearchState.heard`, the Act II page
`ExchangeRaised` on `ViewMemory.heard`, and `build_ui` `ActEnded` on `CurtainState.heard`.

**The log.** `systems/log.zig` is the one reader that writes `Log`. It reads every fact with
the `.log` cursor, in the order the frame writes the types, and words each with the rules' text
helpers (`actions.paymentText`, `actions.receiptText`, `actions.itemWordOf`,
`capital.lowerName`) and the catalog (the roster's authored `copy.built`, a technology's cost,
the merchant's lot records); `RunBegun` is the opening line, "You wake alone. Cold. Hungry." A
fact no line describes, such as `GoodsChanged`, an upward `BandCrossed` or `ActEnded`, is
passed over.

## The states and the schedule (`sim/state.zig`, `sim/schedule.zig`)

`GameState` is `{ title, act_one, act_two, act_three, game_over }`, held as the engine's
`States` on `sim.Resources.states` (see [`ecs/README.md`](ecs/README.md)). A fresh
`sim.Resources{}` is on the title with an empty world. A system requests a transition with
`states.set`; the schedule applies it at the top of the next tick, running the leaving state's
`on_exit` set and the entering state's `on_enter` set once each (a request for the current state
is a restart). The transitions, and who requests them:

| Transition | Requested by | On entering |
|---|---|---|
| any → `act_one` | `run.new_run`, reading `NewRun`, in every state's `handle` set | `run.begin_run`: retires any living player, spawns one (`spawn_player`), `Sim.reset` (the prng carries over), `RunBegun` |
| `act_one` → `act_two` | `curtain.detect_shelter`, the tick the player owns the Act I milestone (`capital.ownsMilestone`); it emits `ActEnded{ .act_one }` with the request, once | `curtain.cross_curtain`: `migration.migrate_to_act_two` on the player |
| `act_two` → `act_three` | `curtain.detect_exchange`, once `Sim.exchange` stands | — |
| an act → `game_over` | `run.detect_death`, after `despawn_dead`, when no player remains | — |

`ActEnded` belongs to the detector rather than to an `on_exit` set, because a restart also
leaves Act I and the act did not end.

`schedule.tick(world, res)` does, in order: `events.update()`; apply the pending transition;
run the current state's `handle` set; if `time.dt > 0`, run its `update` set. That split is
what pausing means: an intent applies while the menu or the curtain holds the run still, so a
slider does not snap back, while nothing that spends or detects time runs. `log` closes both of
an act's sets, so a fact a handler writes while the run is paused becomes its line in the same
tick instead of expiring unread; its cursor makes the second run of a tick read nothing twice.
The derived components' writers (`condition`, `outlook`, `quotes`) run just before `log` in
both of an act's sets, for the same reason. `debug.poke`, the template audit harness's door,
runs in every act's `handle` set after the handlers and `new_run` and before the writers, so a
`DebugPoke` shows in the derived components the tick it applies. Each set runs in the order it declares, and
`schedule.zig`'s tests hold the rules: `log` last in every `update` set and in every act's
`handle` set, `outlook` and `quotes` the two before it, `condition` the one before them (after `metabolize`),
`new_run` in every `handle` set, no handler in an `update` set.

The `handle` sets:

| State | Handlers, in order |
|---|---|
| `title`, `game_over` | `new_run` |
| `act_one` | `labor`, `build`, `cancel`, `generators_toggle`, `generators_collect`, `ration`, `barter`, `new_run`, `condition`, `outlook`, `quotes`, `log` |
| `act_two`, `act_three` | `labor`, `build`, `cancel`, `generators_toggle`, `generators_collect`, `ration`, `merchant_deal`, `research`, `raise_exchange`, `neighbour_deal`, `new_run`, `condition`, `outlook`, `quotes`, `log` |

| Handler | Reads | Does |
|---|---|---|
| `labor.labor` | `BeginLabor` | `actions.begin`: pays and starts the work, `WorkBegun` |
| `build.build` | `BeginBuild` | `capital.begin`: pays and starts the build, `WorkBegun` |
| `build.cancel` | `CancelBuild` | `capital.cancel_build`: the salvage, `BuildCancelled` |
| `generators.generators_toggle` | `ToggleGenerator` | `capital.toggle_generator` |
| `generators.generators_collect` | `CollectGenerator` | `capital.collect_generator`: the cycle's yield, `Collected` |
| `ration.ration` | `SetRation` | `Metabolism.rate`, clamped by `Config.clampMetabolism` |
| `barter.barter` | `Barter` | `barter.resolve`: both bundles move against the passerby, `Traded` |
| `merchant.merchant_deal` | `MerchantDeal` | revalidates the lot against `Sim.merchant` (present, in stock) and the agent's holdings, moves both sides, takes the stock, `Traded` |
| `research.research` | `Research` | `rules/research.research` on the agent's board, then pays the tile's cost from the ledger in the same function, `Researched` with the tiles it opened |
| `exchange.raise_exchange` | `RaiseExchange` | refuses while standing, locked (`exchange.lifecycle`: a ring-4 technology and more than 500 of `Sim.population`) or short; else pays `exchange.cost` from the ledger and stands it, `ExchangeRaised` |
| `neighbours.neighbour_deal` | `NeighbourDeal` | seeds the stub book if unseeded; refuses an unknown neighbour, a deal the neighbour's `verdict` does not accept on the agent's spare (held less `neighbours.reserve`), or one the agent cannot pay; else settles both sides (the book's `settle`, the agent's ledger, goods and coin), `NeighbourSettled` |
| `run.new_run` | `NewRun` | requests `act_one`; several in one tick are one request |

The `update` sets, one column per act; the rows are in the order each set runs them:

| System | `act_one` | `act_two` | `act_three` | Does |
|---|---|---|---|---|
| `tick.advance_clock` | ✓ | ✓ | ✓ | bumps `sim.elapsed`, only while a player exists |
| `tick.update_food` | ✓ | ✓ | ✓ | spoils each larder toward zero at its own `spoils` rate |
| `tick.metabolize` | ✓ | ✓ | ✓ | eats at the ration rate (food → vigor, clamped at `max`), or starves vigor down on an empty larder; `FoodRanOut` once, on the frame the larder empties |
| `tick.resolve_busy` | ✓ | ✓ | ✓ | ticks work in progress and dispatches its finish half at completion (`WorkDone`, `WorkLost`), then drops the `Busy` |
| `tick.track_reach` | ✓ | | | `RecipeInReach` once on the false→true edge of an Act I good's `needs` (`capital.needsMet`); the seen-set is `Sim.reach_seen`, by catalog index, so tab/filter/sort rebuilds never re-announce and a lost prerequisite re-arms it |
| `passerby.passerby` | ✓ | | | advances the passerby's clock (`market.tick`), `Arrived` / `Departed` |
| `generators.generators` | ✓ | ✓ | ✓ | matures every owned, enabled generator by `dt` (`capital.run_generators`) |
| `merchant.merchant` | | ✓ | | the merchant's visit clock (`market.tickMerchant`), `Arrived` / `Departed`; a return clears the lots taken (`Sim.merchant.taken`). In Act III the standing Exchange replaces the cart |
| `tick.mark_dead` | ✓ | ✓ | ✓ | tags `Dead` at `vigor ≤ 0`, `Died` |
| `tick.despawn_dead` | ✓ | ✓ | ✓ | reaps them |
| `run.detect_death` | ✓ | ✓ | ✓ | no player left: requests `game_over` |
| `curtain.detect_shelter` | ✓ | | | requests `act_two`, `ActEnded` |
| `curtain.detect_exchange` | | ✓ | | requests `act_three` |
| `condition.condition` | ✓ | ✓ | ✓ | writes each agent's `Condition` band after everything that moved vigor; `BandCrossed` once, on the crossing |
| `outlook.outlook` | ✓ | ✓ | ✓ | writes each agent's `Outlook` |
| `quotes.quotes` | ✓ | ✓ | ✓ | writes each agent's `Quotes` |
| `log.log` | ✓ | ✓ | ✓ | turns the facts written since its last run into `Log` lines |

`title` and `game_over` have no `update` set: before a run and after it, only `new_run` runs.

**The curtain is the UI's, not a state.** The host `Resources` keeps a `CurtainState` beside
`MenuState`. `build_ui` hears `ActEnded` on the curtain's own cursor and opens it, which pauses
playback the way the menu does, so the world, already crossed into Act II by `cross_curtain`,
holds still while the player reads. The last beat's Continue closes it and restores the pause
state; the next frame routes to the Act II page over the live world. `build_ui` routes on the
state: the title while the host's `Route` or the state says so (Quit to menu leaves a live run
paused behind the title), the curtain while it is open, the game-over screen in `game_over` or
when no player remains (the frame between `despawn_dead` and the transition), the Act I page in
`act_one`, the Act II page in `act_two` and `act_three`.

Naming convention: `update_<component_snake_case>` drives one component.

Band crossings — "You feel weak with hunger.", "You are starving." — are the `condition`
system's `BandCrossed`, from `Config.condition(frac)`, the single definition of the
ALIVE/WEARY/SPENT thresholds, applied in `rules/condition.refresh` alone.

## Actions and capital (`sim/rules/actions.zig`, `sim/rules/capital.zig`)

**An agent owns goods as counts, and everything it can do follows from them.** `comp.Goods`
is one count per record of the authored roster (below); zero is not owned. A verb is never
stored on the agent: `effects.verb` derives its effective terms from the base record and
the goods owned, so each agent's Forage has its own price once it owns sandals, and a good
is owned by exactly one agent and stacks only as a count. `comp.Granted` records what the
goods contribute to the body and larder, so those deltas stay relative.

### Actions

Innate verbs are the records flagged `innate`; every other verb exists while an owned good
`grant`s it or, for a verb that names a `tech`, once that technology is researched
(`actions.verbOf`). `actions.quote` is the one gate calculation: the verb's effective terms, the
quality a begin would lock (`yield_factor` over the agent's `Condition` band), and a `Standing`
of `ready`, `busy`, `energy` or `short` with the first unpayable line. It fills the verb slots
of `comp.Quotes`, which the tile and a future decider read, and `begin` asks it again at apply
time. An agent without a `Vigor` or a `Condition` has no quote.

**Labor resolves in two halves,** because actions take time:

- `begin` — refuse unless the quote is ready (one body, one act; energy strict; inputs
  payable), returning the `Refused.Reason`; pay the energy and the input lines upfront; lock
  `quality` at the *advertised* pre-payment band; refresh the agent's `Condition`; add
  `comp.Busy{ .doing = .{ .labor = index } }`; emit `WorkBegun`, `weary` when the toll crossed
  out of `alive`.
- `finish` — draw each output line at the locked quality (**the spread is the risk**, there
  is no separate success roll), deposit through `ledger.draw`, emit `WorkDone` with the
  receipt of what landed. A verb lost mid-task — the rod sold while fishing — finishes as
  nothing, `WorkLost`.

Both take a catalog index; `systems.resolve_busy` dispatches on the busy marker's tag.
The affordability gates are asymmetric on purpose — **energy is strict** (vigor must stay
above zero), **an item may be spent to exactly zero** (a `>=` gate would refuse every action
that costs no materials at all).

### Capital

Every buildable record goes through one path — `quote`, `begin`, `finish` — and what it does
once owned is its `effects`, interpreted by `effects.zig`: a grant, a scale or offset on a
verb's price or lines, a ceiling, a larder quality step, a spoilage factor. Generators are
the goods with `day` lines, intermediates the goods whose once-output is a lot of themselves;
neither is a category in code.

`capital.quote` answers for the BUILD row (through `comp.Quotes`) and the gate at once: the units owned, the `reach`
of the build order (the smallest held-over-needed across its once-inputs), and a `Standing`
in precedence order — `tech` (the technology the recipe waits on is not researched on the
agent's board), `needs` (the verb or tool a modifier works on is not held, so a chainsaw is
never offered without Split wood), `unlock` (the
shelter's standing conditions: an absolute current-vigor floor, a larder floor, a count of
good kinds owned — read at `begin` and not again, so a dip mid-build doesn't stop work already
paid for), `busy`, `energy`, `short`, `ready`.

**Ownership moves through four doors and settles the same way each time.** `finish` adds the
built lot; `acquire` adds a traded one; `release` takes units, spares first; `break_one` is
`release` with `GoodBroke`. Each emits `GoodsChanged` when the count moves. On the way in from zero and on the way out to zero they
*settle*: `effects.apply` moves the body and larder by the delta of what the owned goods now
contribute — a raised ceiling fills what it adds, a lowered one only clamps. **Only the
first unit carries the effect**: a second pair of sandals
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
take materials back from — and on an idle body, with `nothing_to_cancel`.

`run_generators` ticks every owned good with `day` lines on every agent: if this tick's
slice of the upkeep is payable, pay it and deposit the same slice of the flow. Both are
authored **per in-game day** and scaled by the frame's dt, so a flow reads as a trickle.

`goodsOwned` counts **kinds** — four pairs of sandals are never four goods built;
`ownsMilestone` is what `detect_shelter` reads; `capacity` sums the housing of what is owned.

## Passerby and barter (`sim/rules/market.zig`, `sim/rules/barter.zig`)

**The passerby is sim state, not UI.** `market.Encounter` lives on `Sim` as a clock-driven
machine `absent → approaching → present → departed → absent`, ticked by `market.tick` from
the `passerby` system off the
sim clock (never a calendar day). Each arrival bumps a monotonic `id` and refills a finite
satchel of `Ware`s (food, materials, fish_hook, whetstone); stock does not regenerate until
the next visit. `dealable()` is `phase == .present`, the only gate the UI reads, so hiding the
strip cannot change whether a passerby is here.

**One transfer grammar.** A `Line{item, qty}` and a fixed-cap `Bundle` express both sides of
any deal; a `Quote` carries the offer's stable `id`, the encounter `rev` it was captured
under, its `Direction`, give/receive bundles, remaining `stock`, and
`next_unit` — what the *following* unit of a sell would fetch, shown before confirmation.
`Quote.refusal` is the single revalidation everyone shares, in precedence order: `departed`,
then `stale` (the passerby changed), then `sold_out`, then `unaffordable`; every refusal has
player-readable copy.

**Sell prices diminish.** `sell_value(ware, n)` is a geometric decline `base·ratio^n` clamped
to a positive floor, authored per ware: Food `2.5 / 0.75 / 0.5`, Materials `1.5 / 0.6 /
0.25`, the tools `~6–8 / 0.3 / 1.0`. The floor is the anti-domination guarantee — selling
always beats discarding, and the first units pay well — while the satchel and the visit
window cap how much can be dumped at the top price.

**`barter.resolve` is all-or-nothing.** The `barter` handler calls it for each `Barter`
intent. It revalidates the quote plus give-side ownership before touching anything, then moves
both bundles: Food/Materials on the inventory components, a sold good through
`capital.release` (its effect leaves with the last unit), a bought good through
`capital.acquire` (its effect lands once; a repeat is stock), the satchel decremented, and one
`Traded{ .with = .passerby }` emitted with the materials moved. A failed check mutates nothing
and returns the `Refused.Reason`, a quote's `market.Refusal` mapped onto it by name
(`barter.reasonOf`). `market` stays world-free; `barter` is the only place a `Quote` meets an
entity.

## The authored roster (`sim/data/roster.zig`, `data/`)

The labor verbs, the capital goods and the technologies are data: `data/actions.zon`,
`data/goods.zon` and `data/technologies.zon`, parsed at load by `std.zon.parse` into one
`roster.Catalog`, which is what the sim runs on (`actions.zig`, `capital.zig`, `effects.zig`)
and the pages read. No component type stands for a verb, a good or a technology: an agent
holds goods as counts and research as one state per tile, and everything else is derived from
the records. The files are the contract new content is written against.

**One id space.** A record's id is plain snake case — `forage`, `hatchet`, `charcoal` — and
the file is its kind. Resources, actions and goods share the space: a reference resolves by
lookup, and a collision is a load error. Resources are the `Resource` enum in code, not data,
because each one is structural (a stockline, a palette hue, a board wedge) and has its own
behavior (food spoils, coin settles); a line names one by its tag name.

**Lines.** Every quantity is a `Line { item, n, kind = .fixed, sd, per = .once }`: an item and
an amount, drawn when `kind` is not `.fixed`, settled `once` (an input at begin, an output at
completion) or authored per `day` for a collectable generator. A generator carries a cycle
`generator { energy, hours, vigor = 0 }`: enabled cycles accumulate hours without occupying
`Busy`; collection pays the low energy cost and the complete cycle-scaled upkeep, then realizes
all day outputs and optional direct Vigor restoration atomically. Turning one off preserves its
progress and consumes nothing. A record's ordinary `requires { energy, hours }` remains the
body-and-time build price, plus its `input` and `output` lists. An intermediate is a good whose
once-output is a lot of itself.

**Effects.** What owning a good does is a list from a fixed vocabulary: `grant` a verb;
`scale` or `add` a verb's `energy`, `hours`, or a named `input`/`output` line;
`vigor_ceiling`; `food_quality`; `spoil_scale`. A `family { name, rank }` says a better tool
supersedes a weaker one; `needs` names the verb a modifier works on; `unlock`, `capacity` and
`milestone` are the shelter's. `copy` carries the player's words — the BUILD effect sentence,
the rail's short form, the receipt line.

**Technologies.** A tile of the research board is a `Technology { id, name, short, act, coord,
cost, initial, effect, enables }`: a `short` board label of a few capitals, an axial `coord` the ring and wedge derive from, a research
`cost` as once-lines, and the `initial` state the act opens on (`locked`, `available`,
`researched`). Technologies have an id space of their own — a tile is never an item, and only
a good's or a verb's `tech` names one — so a recipe and the technology that opens it may share
a name. Per agent the board is `comp.Research`, one `TechState` per catalog index, seeded at the
curtain by `Research.entry`; a recipe that names a `tech` quotes `tech` until that state reads
`researched`, and a verb that names one is held from then on, as a grant would hold it.

**Acts.** Every record carries the first `act` it exists in (a resource knows its own in
code), and a reference may never reach forward. The Act I surfaces — the ACTIONS grid, the
BUILD list and its total, the reach announcements — read records of act 1 only, so later
content is authored into the same files without leaking back; the Act II pages
(`pages/act_two/`) read the records of act 2.

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
components — the Act II ones opened at the curtain, none for coin until the simulation
recognizes a medium of exchange — plus `comp.Goods` counts for a good item, with
`short`/`pay`/`draw` over a list
of lines. Per agent that leaves `Goods` (a count per catalog index) and `Granted`; the
catalog itself sits on `sim.Resources` as `catalog`, so a system declares `*const roster.Catalog`.

**Validation.** `roster.load` refuses a file whole: a parse error carries its line and
column, a shape or cross-reference failure its `Rule` and the offending id — an unknown item
or target, a later-act reference, a grant on an innate verb, a modifier on a verb the good
neither needs nor grants, a rank or milestone collision, a drawn input, a day line on an
action, a recipe or verb waiting on no technology, a tile on the foundation or on another's
coordinate, more records than the per-agent containers hold (`max_goods`, `max_techs`). The
shipped files are compiled in (`roster.shipped`, wired in `build.zig`) and parsed through the
same path, so `zig build test` validates the real content.

**Live reload (`reload.zig`).** A `data/` directory in the working directory — beside
`assets/` — overrides the shipped files one by one: `Resources.init` loads through
`roster.loadData`, and a broken file there starts the game on the shipped copy with the reason
in the console. While the game runs, `reload.Watch` looks at the files' modification times
twice a second from the main loop, and a change re-parses them between frames. A load that
fails keeps the catalog and logs why, in full to the console and in one line to the event
log. A load that succeeds is swapped in: each agent's goods and research, the work in
progress and the reach seen-set move to the new catalog indices by id, a record the files no
longer hold takes its count and any work on it with it, and every agent resettles its body and
larder. Rows that repeat are keyed by the record's id, so focus survives a reload that reorders
a file.

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

`src/` is the host: the program, its resources, the library root and the test roots, with the game's palette and design tokens. `palette.zig` and `tokens.zig` stay here rather than in `pages/` because they import `ui_client/` by relative path and the host `res.zig` carries the palette's resource hues: a file under `pages/` belongs to the executable module, and one file cannot sit in two modules.

| File | Holds |
|---|---|
| `main.zig` | `App`, the event loop, and the frame's one `sim.schedule.tick` |
| `root.zig` | the `ha` library root: re-exports `sdl`, `ui`, `ui_client`, `UiCtx`, `font`, `palette`, `tokens`, `res` (the host resources) and `sim` (the simulation root) |
| `test_ui.zig` | the test root of the UI layer alone (engine + host binding, no game content) |
| `font.zig` | `Fonts`, a lazy size → `ttf.Font` cache. One font per point size |
| `res.zig` | the host `Resources`: `platform`, `input`, `view`, `playback`, `menu`, `curtain`, `route`, `title`, `settings`, `saves`, the host registries (`cursor`, `commands`, `semantics`, `announcements`, `a11y`, `motion`, `tween`), and `game: sim.Resources`, the simulation's resources embedded whole |
| `palette.zig` | the game's palette — the ten `Theme` roles, the terminal ground, and the six resource hues |
| `tokens.zig` | the non-color design tokens, in logical px |
| `ecs/` | the ECS engine package: `World(comps, tags)`, the queries, `Events`, `run`, `States`, `Schedule` (see `ecs/README.md`) |

`sim/` is the simulation: its root, the schema, the resources a system may reach, and the ECS bound to them.

| File | Holds |
|---|---|
| `root.zig` | the `sim` namespace: re-exports every file below as `sim.comp`, `sim.tag`, `sim.res`, `sim.ecs`, `sim.events`, `sim.log`, `sim.baselines`, `sim.state` (with `GameState` and `States`), `sim.schedule`, and declares the four folders as nested structs, `sim.systems.*`, `sim.rules.*`, `sim.kernel.*`, `sim.data.*`; also the module root of the `test-sim` build step, which compiles the simulation with no UI host and no SDL |
| `components.zig` / `tags.zig` | component and tag types — **only** `pub const <Name> = struct {…}`, since `World` enumerates them at comptime |
| `res.zig` | `sim.Resources { sim, config, time, catalog, events, states }`: exactly what a system may reach. `Sim` carries the log, the reach seen-set, the passerby encounter, the merchant visit, the stubbed neighbours, the Exchange and `population`, the stand-in until ACT2-01; `Config`, `Time`, `Band` (the `comp.Condition` enum) and `hours_to_secs` live here; `random()` is a `std.Random` over `sim.prng` |
| `ecs.zig` | this game's `World` (the engine's over `components.zig` and `tags.zig`), the system params and `run` over that `World` and `sim.Resources`, with the `Const` forms; `Events` (the engine's store over `events.zig`), `EventWriter(T)` and `EventReader(T, id)` |
| `events.zig` | the intents and facts, `Refused.Intent` and `Refused.Reason`, `Who`, and `ReaderId`: every public struct is an event, `DebugPoke` (the template audit harness's poke of one component) among them |
| `state.zig` | `GameState` and `States`, the engine's state resource over it |
| `schedule.zig` | `schedule`, the systems per state in the order they run, and `tick`, the host's one call per frame |
| `log.zig` | `Log`, a 64-entry ring buffer of toned event lines; refuses an over-long line whole. Leaf module |
| `baselines.zig` | the fresh-agent baseline, read from the component defaults |

`sim/systems/` holds the systems the schedule runs.

| File | Holds |
|---|---|
| `tick.zig` | the tick systems, in tick order |
| `condition.zig` | the `condition` system, the one writer of `comp.Condition` |
| `outlook.zig` | the `outlook` system, the one writer of `comp.Outlook`, and the BODY projection's pure math (`project`) |
| `quotes.zig` | the `quotes` system, the one writer of `comp.Quotes`, and `fill`, one agent's quotes |
| `labor.zig` | the `BeginLabor` handler |
| `build.zig` | the `BeginBuild` and `CancelBuild` handlers |
| `generators.zig` | the `ToggleGenerator` and `CollectGenerator` handlers, and the `generators` update system |
| `ration.zig` | the `SetRation` handler |
| `barter.zig` | the `Barter` handler |
| `merchant.zig` | the Coin Merchant's lots (a stand-in, ACT2-14), its visit system and the `MerchantDeal` handler |
| `research.zig` | the `Research` handler: the board and the ledger's one writer for a research |
| `exchange.zig` | the Exchange's price, its `lifecycle` and `ringFour` reads (the card reads them too), and the `RaiseExchange` handler |
| `neighbours.zig` | the reserve table (a stand-in), `heldItem`, and the `NeighbourDeal` handler that settles both sides of a deal |
| `passerby.zig` | the passerby's update system |
| `run.zig` | the run's lifecycle: `spawn_player`, `new_run`, `begin_run`, `detect_death`, and the opening line |
| `curtain.zig` | the act boundaries: `detect_shelter`, `cross_curtain`, `detect_exchange` |
| `debug.zig` | the `DebugPoke` handler, `poke`: sets one component of an agent for the debug page; never refused, and a missing component changes nothing |
| `log.zig` | the log system: every fact into its `Log` line |

`sim/rules/` holds the functions a system calls: a gate, a payment, a deposit, an interpretation. A rule that writes takes `*World` from the system that calls it. A rule that only reads (`capital.quote`, `capital.ownsMilestone`, `actions.holds`, `ledger.balance`, `migration.actOf`, …) takes `*const World`: a pure function over the world is a read, so the UI build may call it as well, and the compiler is what tells the two apart, since `get` through a `*const World` yields `?*const T`.

| File | Holds |
|---|---|
| `actions.zig` | per-agent labor: `quote`, `begin`/`finish`, `verbOf`, `yield_factor` |
| `condition.zig` | `refresh`: the condition band from the vigor, the one caller of `Config.condition`, and the crossing it made |
| `capital.zig` | the build path, ownership and settling, the generator system |
| `effects.zig` | the interpreter: a verb's effective terms from the catalog and the owned goods; the body/larder delta |
| `ledger.zig` | where a line meets holdings: the `Resource` → inventory-component switch, good counts, `short`/`pay`/`draw` |
| `barter.zig` | atomic resolution of a quote against the world |
| `market.zig` | the passerby encounter, wares, bundles, quotes, refusals, and the sell-value schedule; the merchant's visit clock and the lots taken in a visit |
| `neighbours.zig` | the neighbours' stub book: the deterministic stand-in market Act II's MARKET view shows and `systems/neighbours.zig` settles with |
| `research.zig` | the research board's progression: the adjacency rule and atomic research resolution over the catalog and `comp.Research` |

`sim/kernel/` holds pure math over values; a kernel imports only `std`.

| File | Holds |
|---|---|
| `dist.zig` | the distribution engine (normal / poisson / uniform / exponential / fixed) + `stats` for the p10–p90 band, and `kindLabel` for the glyphs' spoken names |
| `hex.zig` | pointy-top axial hex topology: coordinates, rings, neighbours, wedges and classification. Pure; imports only `std` |

`sim/data/` holds the authored roster and its lifecycle: the loader, the live reload, the cross-act migration.

| File | Holds |
|---|---|
| `roster.zig` | the authored roster: the record grammar for verbs, goods and technologies, the ZON loader and validator. Reaches only `std` and `dist`, since `sim/res.zig` carries it |
| `reload.zig` | live reload: the `data/` watch, and the swap that carries index-keyed state to a new catalog by id |
| `migration.zig` | the Act I → II curtain, run by `cross_curtain`: Biomass from Materials, the other Act II stocks opened, the board's entry state, the version stamp; the cross-act cost parity test |

`pages/` is game content: the screens, the template shelf, and the helpers only a page or a template reads.

| File | Holds |
|---|---|
| `root.zig`, `act_one/`, `act_two/`, `templates/` | the screens (`prepare`, the fixture harness's world work between the tick and the build; `build_ui`, which routes on the state over a `*const World`; `play_game`; `gameover`; `act_one_end`, the curtain over a world already in Act II, opened on `ActEnded`; the Act II shell in `act_two/`), the fixture harness (`fixture.zig`), and the template shelf |
| `eating.zig` | the Eating Policy math: slider value ↔ rate, the word ladder, per-act coverage/recovery |
| `query.zig` | the catalog query parser |
| `hex_pixel.zig` | the hex pixel transform the research board paints with: axial → pixel, the six vertex offsets, pixel → hex, and the point-in-hex test |

Every file under `sim/` imports its siblings by relative path, and nothing in `sim/` imports the host (`res.zig`), `ui_client/` or SDL; the `test-sim` build step, rooted at `sim/root.zig`, is what holds that true. The UI engine is a package of its own, `src/ui/`, which `build.zig.zon` names as a path dependency; `build.zig` hands it to `ha` and to the UI tests as the module `ui`, and runs its tests in both test steps. The ECS engine `src/ecs/` is a package the same way, imported as `ecs`, with its tests run in every test step.

`dist`'s `.fixed` kind is exempt from the `scaleOf` 0.2 floor — every action leaves one yield slot at a fixed zero, and without the exemption each draw silently deposited +0.2.

## Assets

- `data/actions.zon`, `data/goods.zon`, `data/technologies.zon` — the authored roster,
  compiled in by `build.zig`, and read from `data/` at startup and whenever a file changes.
- `assets/fonts/` — TTF variants; `JetBrainsMonoNL-Regular.ttf` is the one loaded.
- `assets/icons.png` — a 2×2 sheet of 512px capital-good icons, sampled by
  `ui_client.icon_sprite`. Currently unused.
- `assets/hello.png` — test image.
