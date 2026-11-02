# The simulation as an ECS

**A draft specification, being built.** This is the shape the simulation takes once every game
rule runs from the schedule and nothing outside `src/sim/` holds a mutable world: the engine as
a package, the events the deciders write, the states the schedule routes on, and the components a
system derives for everyone else to read. It describes the intended shape the way
[`feat-script-lang.md`](feat-script-lang.md) does; the order it is built in is at the end, and
[`roadmap.md`](roadmap.md) tracks it.

Before this work the tick systems were systems, but the rules they shared were invoked from the
paint tier: a template holding `*World` called `actions.begin` the frame it saw a click, the Act
II page paid the Exchange and the research board itself, and a trade settled its two halves in
two tiers. The engine was bound to this game's `Resources`, which dragged the UI host and SDL into
every sim test. Steps 1 to 4 below have landed: the engine is a package, the simulation has its
own resources and folders, and every rule runs from a handler or tick system through events.
What nothing yet models is the run's states, so the curtain, the title and the game-over screen
are facts the main loop and the pages each re-derive, and the UI build still holds `*World`.

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

**`Events(comptime ns: type, comptime ReaderId: type)`.** One bounded ring per `pub const`
struct in `ns`, enumerated the way `World` enumerates components; a `pub` enum in `ns` is shared
vocabulary, not an event. Every event is plain data, fixed-size, with no slice or pointer
anywhere inside it, and a type that breaks this is a compile error naming it. The store is written
through `writer(T)` and read through a cursor:

- `push` appends with a store-wide monotonic id and returns whether it landed. A full ring
  refuses the push and counts it in `dropped(T)`; nothing is silently lost and a test can assert
  the count.
- `update()` runs once at the top of each tick and expires every event written before the
  previous tick began, so an event lives two ticks: the one it was written in and the next. The
  UI writes between ticks and its events are read by the handlers of the following tick. A system
  writes during a tick and a reader later in the same tick, or anywhere in the next, sees it.
- A reader yields the events after its own cursor and not yet expired. A system's cursor lives in
  the store, keyed by a `ReaderId` the simulation declares, one enum tag per scheduled reader, so
  a reader that runs every tick sees each event exactly once, two readers of one type stay
  independent by name, and a handler test needs no schedule. The UI reads with a `u64` cursor it
  keeps in its own state, through `readerAt(T, &cursor)`.

The system params are `EventWriter(T)` and `EventReader(T, id)`; a handler spells
`EventReader(BeginLabor, .labor)`, and its signature states what it consumes.

**`States(comptime S: type)`.** A resource holding `current` and `next: ?S`. A system requests a
transition with `set(s)`; the schedule applies it at the top of the following tick, running the
leaving state's `on_exit` set, then the entering state's `on_enter` set, once each. A request
for the state already current is a restart and runs both sets the same way. `in(s)` is the read.
`current` defaults to the enum's first tag, so a `sim.Resources{}` begins on the title.

**`Schedule(comptime S: type, comptime sets: anytype)`.** The ordered systems, declared once,
per state. Systems differ in signature, so a set is a tuple of functions, not a slice:

```zig
pub const schedule = Schedule(GameState, .{
    .title     = .{ .handle = .{ new_run } },
    .act_one   = .{ .on_enter = .{ begin_run },
                    .handle = .{ labor, build, cancel, generators_toggle, generators_collect, ration, barter, new_run },
                    .update = .{ advance_clock, update_food, metabolize, resolve_busy, track_reach, passerby, generators, mark_dead, despawn_dead, detect_death, detect_shelter, log } },
    .act_two   = .{ .on_enter = .{ cross_curtain },
                    .handle = .{ labor, build, cancel, generators_toggle, generators_collect, ration, merchant_deal, research, raise_exchange, neighbour_deal, new_run },
                    .update = .{ advance_clock, update_food, metabolize, resolve_busy, generators, merchant, mark_dead, despawn_dead, detect_death, detect_exchange, log } },
    .act_three = .{ /* act_two's sets without the merchant's clock and detect_exchange */ },
    .game_over = .{ .handle = .{ new_run } },
});
```

Step 6 adds the derived writers `condition`, `outlook` and `quotes` to each `update` set just
before `log`. A state the table does not name has empty sets; a field that is not a state, or a
set with another name, is a compile error.

`tick(world, res)` does, in order: `events.update()`; apply a pending transition; run the current
state's `handle` set; if `time.dt > 0`, run its `update` set. The split is what pausing means:
intents apply while the menu is open, so a slider does not snap back, while nothing that spends
or detects time runs. The host loop calls `tick` once per frame and nothing else. The order a
set declares is the order it runs, and a test asserts the orders this document names: `log` is
last in every `update` set, `new_run` is in every `handle` set, and no handler is in an `update`
set.

## The simulation: `src/sim/`

```
src/
  main.zig  root.zig  test_ui.zig  font.zig  res.zig  palette.zig  tokens.zig    the host
  ecs/                                                  the engine package
  sim/
    root.zig            the `sim` namespace: systems, rules, kernel, data as nested structs; the test-sim root
    components.zig  tags.zig  events.zig  state.zig
    res.zig             sim.Resources { sim, config, time, catalog, events, states }
    ecs.zig             World, Query, Single, MaybeSingle, getMany, Events, run over this game's types
    schedule.zig        the schedule above, and `tick`
    systems/            what the schedule calls, one file per concern
    rules/              actions, capital, effects, ledger, barter, market, research, neighbours
    kernel/             dist, hex topology
    data/               roster, reload, migration
    log.zig
  pages/                + eating, query, hex_pixel (the research board's pixel math)
  ui_client/  ui/       unchanged
```

`palette.zig` and `tokens.zig` stay in the host rather than moving to `pages/`: a Zig file
belongs to one module, the library's `res.zig` reads the palette, and `src/pages/` is in the
executable module. Sim files import each other by relative path and never the library.

**`sim.Resources`** holds exactly what a system may reach: `sim: Sim`, `config: Config`,
`time: Time`, `catalog: Catalog`, `events: Events(events_ns, ReaderId)`, `states: States(GameState)`.
`hours_to_secs` and `random()` move with it. The host's `Resources` embeds it as `game` and keeps
`Platform`, `Input`, the registries, `playback`, `menu`, `route`, `title`, `settings`, `saves` and
`view`. A sim test builds `sim.Resources{}` whole; nothing in it is `undefined`.

**`GameState`** is `enum { title, act_one, act_two, act_three, game_over }`, in `sim/state.zig`.
The transitions, each a system:

- `new_run`, a handler in every state's `handle` set, reads `NewRun` and requests `act_one`.
  `begin_run`, `act_one`'s `on_enter`, retires any living player, spawns the new one, resets
  `Sim` and emits `RunBegun`, which the log words as the opening line. The spawn moves from
  `main.zig` into the simulation with it.
- `detect_shelter`, in `act_one`'s `update` set, requests `act_two` the tick the player owns the
  Act I milestone and emits `ActEnded{ .act_one }` in the same breath. The fact belongs to the
  detector, not to an `on_exit` set: a restart also leaves Act I, and the act did not end.
  `cross_curtain`, `act_two`'s `on_enter`, runs `migration.migrate_to_act_two` on the player.
- `detect_death`, after `despawn_dead` in each act's `update` set, requests `game_over` when no
  player remains.
- `detect_exchange`, in `act_two`'s `update` set, requests `act_three` once `Sim.exchange`
  stands. Act III's sets are Act II's without the merchant's clock, which is today's gate on
  that system written as a state.

The curtain is not a state. It is the UI's response to `ActEnded`: the host's `Resources` keeps
a `CurtainState` beside `MenuState`, the page build hears the fact with the curtain's own cursor
and opens it, and it pauses playback the way the menu does, so the world holds still while the
player reads. Its last beat's button is Continue, which closes the curtain and resumes; the next
frame's route is the Act II page over the live, migrated world. Nothing starts over there.
`game_over` is a state because it is terminal: no agents, nothing to tick, one way out. `title`
is a state because the run has not begun; it is distinct from the host's `Route`, which says
whether the title screen is showing, since Quit to menu leaves a live run paused behind it.
`Playback.paused` stays a zero delta on the host, not a state.

**Events** (`sim/events.zig`). Intents, written by the UI or a decider: `BeginLabor{agent, ai}`,
`BeginBuild{agent, gi}`, `CancelBuild{agent}`, `ToggleGenerator{agent, gi}`,
`CollectGenerator{agent, gi}`, `SetRation{agent, rate}`, `Barter{agent, quote, lots}`,
`Research{agent, ti}`, `RaiseExchange{agent}`, `MerchantDeal{agent, lot, lots}`,
`NeighbourDeal{agent, neighbour, give, take}`, `NewRun{}`. Facts, written by systems and the
rules they call: `Refused{agent, intent, reason}`, `WorkBegun{agent, doing, weary, energy, paid,
act}`, `WorkDone{agent, doing, receipt, owned, act}`, `WorkLost`, `BuildCancelled{agent, gi,
refund, act}`, `GoodBroke`, `Collected{agent, gi, receipt, vigor, act}`, `BandCrossed{agent,
from, to}`, `FoodRanOut{agent}`, `Died{agent}`, `GoodsChanged{agent}`, `RecipeInReach{agent,
gi}`, `Arrived{who}`, `Departed{who}`, `Traded{agent, with, direction, biomass_moved, lot, lots,
act}`, `Researched{agent, ti, newly}`, `ExchangeRaised{agent}`, `NeighbourSettled{agent,
neighbour}`, `RunBegun{}`, `ActEnded{act}`. A fact is semantic and carries what its line needs:
a bounded `Receipt` of item and quantity lines (`rules/ledger.zig`), a bitmask of the tiles a
technology opened, the act whose words the agent speaks. So `systems/log.zig`, last in the
`update` set, takes only `Sim`, the catalog and the store, never the world, and is the one reader
that turns facts into `Log` lines. A rule that refuses returns the `Refused.Reason`; the handler
emits it. The UI reads the facts it shows with its own cursors.

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
&res.game)` once. The housed check, the route check and the Act II gate are gone from it, and
so is the spawn at launch: the world is empty until `NewRun`. A run left behind the title by
Quit to menu is paused, so its `update` set does not run; a gate on the route is not needed.

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
| `gameover.zig`, `title.zig` call `app.start_over` | `NewRun`; the title also sets the route and unpauses, host state it owns |
| `act_one_end.zig`'s last beat calls `app.start_over` | the curtain closes (`CurtainState`), and the state machine has already moved on |
| `debug_page.zig` pokes components mid-build | `DebugPoke` |

`build_ui` routes on the state: the title while `route` or the state says so, the curtain while
`CurtainState` is open, the game-over screen in `game_over` or when no player remains, the Act I
page in `act_one`, the Act II page in `act_two` and `act_three`. A page that derives the act from
`Migrated` or `Sim.exchange` reads the state instead.

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
   `new_run`, `begin_run`, `detect_shelter`, `cross_curtain`, `detect_death`,
   `detect_exchange`; `NewRun`, `RunBegun`, `ActEnded`; the main loop makes one call; the
   curtain pauses through playback and Continue leads into Act II live.
6. **Derived components.** `Condition`, then `Outlook` retiring `body.zig`, then `Quotes`
   retiring the per-tile quote calls.
7. **`*const World`** into the build, `DebugPoke`, the boundary rule written down.

## Open

- `rules/market.zig` and `rules/neighbours.zig` are both markets. A rename waits for ACT2-01,
  when the neighbours stop being a stub.
- Change detection on components (Bevy's `Changed<T>`) is not built. Derived writers recompute
  for every agent every tick; the trigger to add it is a measurable cost, not a population size.
