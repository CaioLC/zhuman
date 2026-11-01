# The simulation as an ECS

**A draft specification, being built.** This is the shape the simulation takes once every game
rule runs from the schedule and nothing outside `src/sim/` holds a mutable world: the engine as
a package, the events the deciders write, the states the schedule routes on, and the components a
system derives for everyone else to read. It describes the intended shape the way
[`feat-script-lang.md`](feat-script-lang.md) does; the order it is built in is at the end, and
[`roadmap.md`](roadmap.md) tracks it.

Today the tick systems are systems, but the rules they share are invoked from the paint tier: a
template holding `*World` calls `actions.begin` the frame it sees a click, the Act II page pays
the Exchange and the research board itself, and a trade settles its two halves in two tiers. The
engine, `ecs.zig` and `world.zig`, is bound to this game's `Resources`, which drags the UI host
and SDL into every sim test. Nothing models the run's states, so the curtain, the title and the
game-over screen are five unrelated facts the main loop and the pages each re-derive.

## The model

Three words, each with one meaning:

- A **system** is a function the schedule calls with system params. Systems are the only code
  that holds `*World`. There are tick systems, which spend time, handler systems, which read
  events, and transition systems, which run once on entering or leaving a state.
- A **rule** is a function a system calls: a gate, a payment, a deposit, an interpretation. Rules
  take `*World` from the system that calls them and are never reached from the UI.
- A **read** is a pure function over values, or a component a system derived. The UI reads
  components through `*const World` and calls kernels; it does not call rules.

The player and an AI decider are the same thing to the simulation: a writer of intent events. The
UI build reads the world, writes events, and mutates nothing. A rule that today returns a result
to the click site returns it as an event instead, and the UI reads the outcome next frame.

## The engine: `src/ecs/`

A package of its own, `ecs`, named in `build.zig.zon` as a path dependency beside `ui` and
imported as `@import("ecs")`. It imports nothing but `std` and its own files; the boundary check
holds it to that as it holds `src/ui/`. It knows no component, no resource and no game.

**`World(comptime comps: type, comptime tags: type)`.** The sparse-set world, generic over the two
namespaces it enumerates. The API is today's: `spawn`, `add`, `get`, `has`, `remove`, `despawn`,
`storageOf`. `get` takes its world pointer as `anytype`: through `*World` it yields `?*T`, through
`*const World` it yields `?*const T`.

**`run(world, res, comptime system)`.** Generic over the world and the resources type. The
injectable groups are derived from the fields of whatever struct `res` points at, with today's two
guards: struct-typed fields only, and distinct types. A system may take `*World`, the whole
resources struct, a group as `*T` or `*const T`, a query, or an event param.

**Queries take the world pointer type first.** `Query(*World, .{…})` yields `*T` entries,
`Query(*const World, .{…})` yields `*const T`. `Single`, `MaybeSingle` and `getMany` follow the
same rule. The simulation instantiates them once in `sim/ecs.zig`, so a system still spells
`Query(.{ comp.Vigor, With(tag.Player) })`, and the UI gets the const forms under a `Const`
prefix.

**`Events(comptime ns: type)`.** One bounded ring per `pub const` struct in `ns`, enumerated the
way `World` enumerates components. Every event is plain data, fixed-size, with no slice into an
arena. The store is written through `writer(T)` and read through a cursor:

- `push` appends with a monotonic id. A full ring refuses the push and counts it in `dropped`;
  nothing is silently lost and a test can assert the count.
- `update()` runs once at the top of each tick and expires every event older than the previous
  tick, so an event lives two ticks: the one it was written in and the next. The UI writes
  between ticks and its events are read by the handlers of the following tick. A system writes
  during a tick and a reader later in the same tick, or anywhere in the next, sees it.
- A reader yields the events after its own cursor and not yet expired. A system's cursor lives in
  the store, keyed by the system's position in the schedule, so a reader that runs every tick sees
  each event exactly once. The UI reads with a cursor it keeps in its own state.

The system params are `EventWriter(T)` and `EventReader(T)`. A handler's signature states what it
consumes.

**`States(comptime S: type)`.** A resource holding `current` and `next: ?S`. A system requests a
transition by setting `next`; the schedule applies it at the top of the following tick, running
the leaving state's `on_exit` set, then the entering state's `on_enter` set. `in(s)` is the read.

**`Schedule(comptime S: type)`.** The ordered systems, declared once, per state:

```zig
pub const schedule = Schedule(GameState){
    .title     = .{ .handle = &.{ new_run } },
    .act_one   = .{ .handle = &.{ labor, build, cancel, generators_toggle, generators_collect, ration, barter, new_run },
                    .update = &.{ clock, larder, metabolize, work, reach, passerby, generators, condition, outlook, quotes, death, log },
                    .on_exit = &.{ act_ended } },
    .act_two   = .{ .on_enter = &.{ cross_curtain },
                    .handle = &.{ labor, build, cancel, generators_toggle, generators_collect, ration, research, exchange, merchant_deal, neighbour_deal, new_run },
                    .update = &.{ clock, larder, metabolize, work, generators, merchant, condition, outlook, quotes, death, log } },
    .act_three = .{ /* act_two's sets without the merchant's clock */ },
    .game_over = .{ .handle = &.{ new_run } },
};
```

`tick(world, res)` does, in order: `events.update()`; apply a pending transition; run the current
state's `handle` set; if `time.dt > 0`, run its `update` set. The split is what pausing means:
intents apply while the menu is open, so a slider does not snap back, while nothing that spends
or detects time runs. The host loop calls `tick` once per frame and nothing else. The order a
set declares is the order it runs, and a test asserts the orders this document names.

## The simulation: `src/sim/`

```
src/
  main.zig  root.zig  test_ui.zig  font.zig  res.zig    the host
  ecs/                                                  the engine package
  sim/
    root.zig            the `sim` re-exports and test root
    components.zig  tags.zig  events.zig  state.zig
    res.zig             sim.Resources { sim, config, time, catalog, events, states }
    ecs.zig             World, Query, Single, MaybeSingle, getMany, run over this game's types
    schedule.zig        the schedule above
    systems/            what the schedule calls, one file per concern
    rules/              actions, capital, effects, ledger, barter, market, research, neighbours
    kernel/             dist, hex topology
    data/               roster, reload, migration
    log.zig
  pages/                + eating, query, palette, tokens; the research board owns hex pixel math
  ui_client/  ui/       unchanged
```

**`sim.Resources`** holds exactly what a system may reach: `sim: Sim`, `config: Config`,
`time: Time`, `catalog: Catalog`, `events: Events(events_ns)`, `states: States(GameState)`.
`hours_to_secs` and `random()` move with it. The host's `Resources` embeds it as `game` and keeps
`Platform`, `Input`, the registries, `playback`, `menu`, `route`, `title`, `settings`, `saves` and
`view`. A sim test builds `sim.Resources{}` whole; nothing in it is `undefined`.

**`GameState`** is `enum { title, act_one, act_two, act_three, game_over }`. The curtain is not a
state: Act I ends when the shelter stands, `detect_shelter` sets `next = .act_two`, `act_ended`
emits `ActEnded{ .act_one }` on exit, and `cross_curtain` runs the migration on entry. The curtain
dialog is the UI's response to that event, and it pauses playback the way the menu does, so the
world holds still while the player reads. `game_over` is a state because it is terminal: no
agents, nothing to tick, one way out. `title` is a state because the run has not begun.
`Playback.paused` stays a zero delta on the host, not a state.

**Events** (`sim/events.zig`). Intents, written by the UI or a decider: `BeginLabor{agent, ai}`,
`BeginBuild{agent, gi}`, `CancelBuild{agent}`, `ToggleGenerator{agent, gi}`,
`CollectGenerator{agent, gi}`, `SetRation{agent, rate}`, `Barter{agent, quote, lots}`,
`Research{agent, ti}`, `RaiseExchange{agent}`, `MerchantDeal{agent, lot, lots}`,
`NeighbourDeal{agent, neighbour, give, take}`, `NewRun{}`. Facts, written by systems:
`Refused{intent, reason}`, `WorkBegun`, `WorkDone{agent, doing, receipt}`, `BandCrossed{agent,
from, to}`, `FoodRanOut{agent}`, `Died{agent}`, `GoodsChanged{agent}`, `Researched{agent, ti}`,
`ExchangeRaised`, `Arrived{who}`, `Departed{who}`, `ActEnded{act}`. Every log line a system
pushes today becomes a fact event, and `systems/log.zig`, last in the `update` set, is the one
reader that turns facts into `Log` lines. The UI's live announcer reads the same facts with its
own cursor.

**Handlers** are one file per intent family in `systems/`, each calling the rule it already has:
`labor.zig` calls `actions.begin`; `build.zig` calls `capital.begin` and `cancel_build`;
`research.zig` calls `board.research` and pays the ledger in the same function, so the board and
the ledger have one writer; `exchange.zig` holds the cost table and the unlock rule;
`merchant.zig` holds the lots and the visit clock, and the stock remaining in a visit lives on
`Sim.merchant`, not in a UI slot; `neighbours.zig` holds the reserve table, seeds the stub book,
and settles both sides of a deal in one function. A handler that refuses emits `Refused` and
changes nothing. Stand-in data a handler needs, the Exchange cost, the merchant's lots, the
reserve, lives in that handler's file, documented as a stand-in with its roadmap item. The
population stand-in is `Sim.population`, read by the Exchange rule and the header alike, and
replaces `Sim.exchange.population`.

**Derived components** have one writer each, a system late in the `update` set, and no other
source of truth:

- `Condition` is the band, written beside `metabolize`; `BandCrossed` is a comparison with the
  previous value, and `cfg.condition` is called in one place.
- `Outlook{ food_days, recovery }` replaces `body.project`; `outlook.zig` is its writer.
- `Quotes` holds a `Standing` and the effective terms per verb and per recipe, written after the
  ledger settles; the tile, the BUILD row and a decider read the same answer, and `actions.quote`
  and `capital.quote` become the rule that fills it.

The writer of a derived component is idempotent: running it twice on an unchanged world changes
nothing, and a test says so.

**Rules** keep their names and signatures. `rules/market.zig` holds the passerby and merchant
state types and their pure step functions, because `Sim` holds the state and must not import a
system. `rules/research.zig` is today's `grid/board.zig`. `rules/neighbours.zig` is the stub
book's type and valuation until ACT2-01 dissolves it into components. The kernels import only
`std`.

## The host and the UI

`main.zig` computes `time.dt`, polls the roster watch, and calls `sim.schedule.tick(&world,
&res.game)` once. The housed check, the route check and the Act II gate are gone from it.

The UI build takes `*const World`. A template that writes a component stops compiling. The
pages read `ctx.res.game.sim`, `ctx.res.game.config`, `ctx.res.game.catalog` with direct field
access, and write only through `ctx.res.game.events.writer(T)`. Every site that mutates today
becomes an event:

| Today | Event |
|---|---|
| `actions_section.zig` calls `actions.begin` | `BeginLabor` |
| `build_list.zig` calls `capital.begin` / `cancel_build` | `BeginBuild` / `CancelBuild` |
| `generator_section.zig` calls `toggle_generator` / `collect_generator` | `ToggleGenerator` / `CollectGenerator` |
| `household.zig` writes `met.rate` | `SetRation` |
| `play_game.zig` calls `barter.resolve` and reads `.ok()` | `Barter`, then `Refused` or the world |
| `act_two/page.zig` pays research and raises the Exchange | `Research`, `RaiseExchange` |
| `coin_merchant.zig` moves both sides | `MerchantDeal` |
| `market_view.zig` settles the neighbour, the page settles the player | `NeighbourDeal` |
| `gameover.zig`, `title.zig`, `act_one_end.zig` call `app.start_over` | `NewRun` |
| `debug_page.zig` pokes components mid-build | `DebugPoke` |

Fixtures set the world up before the build with the mutable handle they already hold.

## Tests

- Engine: a const query yields `*const T` and a write through it is a compile error (a
  `refAllDecls`-style negative test is not possible, so the README states it and the UI build's
  signature proves it); events expire after two ticks, refuse on overflow and count the refusal,
  and a scheduled reader sees each event once; a transition runs `on_exit` then `on_enter` once;
  `handle` runs while `dt == 0` and `update` does not.
- `test-sim`: a build step compiling `src/ecs/` and `src/sim/` with no `ui_client` and no SDL.
  Its existence is the dependency rule.
- The schedule's orders, asserted against the lists in this document.
- Every handler: refuses without mutating, applies the rule when ready, and emits what it says.
- Every derived writer: idempotent.
- Today's tests move with their files unchanged.

## Documentation that changes

`src/README.md` gains the three words and the schedule, loses the "not an ECS system" footnotes
and the module map's flat list for one grouped by folder. `src/ecs/README.md` is the engine's.
`CLAUDE.md` adds `test-sim`, the `ecs` package to *Layers*, and the rule that the UI holds
`*const World`. `tools/boundary_check.sh` extends tier 3 to `src/ecs/`. The
`project_commands_deferred` memory is superseded: events are the deferral, and `Commands` for
structural changes stays deferred on the same trigger.

## Size and order

Seven steps, each one compiling commit with its README and CLAUDE.md edits, all three test
targets and the boundary check green. Review stops after steps 1, 4 and 5, which fix the engine
API shapes the later steps build on.

1. **The engine as a package.** `World(comps, tags)`, `run` generic over the resources type,
   queries over `*World` or `*const World`; `src/ecs/` with its manifest, wired beside `ui`;
   `src/world.zig` and `src/ecs.zig` become the instantiations so every call site compiles
   unchanged; boundary tier 3 covers it.
2. **`sim.Resources`.** Split out of the host's and embedded as `game`; the rename at the call
   sites; sim tests build it whole; the `test-sim` step.
3. **The folders.** The moves above, `hex` split into topology and pixel math, `body.zig` and
   `eating.zig` to where they are read; nothing else changes.
4. **Events.** `Events`, `EventWriter`, `EventReader` in the engine; `sim/events.zig`; handlers
   one intent family at a time, labor first and the ration slider last; the facts and
   `systems/log.zig`; the merchant stock onto `Sim.merchant`.
5. **States and the schedule.** `States`, `Schedule`, `sim/state.zig`, `sim/schedule.zig`;
   `detect_shelter`, `act_ended`, `cross_curtain`, `new_run`; the main loop makes one call; the
   curtain dialog pauses through playback.
6. **Derived components.** `Condition`, then `Outlook` retiring `body.zig`, then `Quotes`
   retiring the per-tile quote calls.
7. **`*const World`** into the build, `DebugPoke`, the boundary rule written down.

## Open

- After the curtain, does Continue lead into Act II live, or does the last beat start over as
  today while Act II stays fixture-only? The state machine supports both; the product decides.
- `rules/market.zig` and `rules/neighbours.zig` are both markets. A rename waits for ACT2-01,
  when the neighbours stop being a stub.
- Change detection on components (Bevy's `Changed<T>`) is not built. Derived writers recompute
  for every agent every tick; the trigger to add it is a measurable cost, not a population size.
