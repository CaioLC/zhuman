# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build run     # Build and run the application
zig build test    # Run unit tests (whole library)
zig build test-ui # Run just the UI-layer tests (engine + host binding, minus game content)
zig build         # Build only
```

`test-ui` compiles the reusable UI layer (`src/ui/` + `src/ui_client/`) in isolation — a
faster loop that skips the game content (`main.zig`, `systems.zig`, `src/pages/`). As of
2026-07-08 all three of `zig build`, `zig build test`, and `zig build test-ui` are green.

Requires Zig 0.15.2+. Dependencies (SDL3, SDL3 TTF) are fetched automatically via `build.zig.zon`.

## Architecture

**Human Action** is a Zig/SDL3 application aiming to become an **agent-based praxeology simulation** — emergent economic/social behavior from a population of purposeful AI agents acting under scarcity (the name nods to Ludwig von Mises). The intended shape is an **incremental/accumulator game** (Cookie-Clicker-like): start alone, starved and cold; end with billions of humans and petawatts of energy. See the `project_game_design_accumulator` memory for the full design.

Today it is *early gameplay on a custom foundation*: a bespoke immediate-mode UI layout engine plus a Bevy-style sparse-set ECS. The first slice is the **lone actor under scarcity** (Robinson Crusoe economics — one actor, no exchange, no money yet). The resource model (**redesigned 2026-06-23**, see the `project_game_design_accumulator` memory) splits survival from accounting:

- **Energy** is the *unit of work* — the **price** of every action, not a stock you hold. It's paid from a *source*; today that source is your body (vigor), later it's harnessed external energy (the chainsaw → engine → petawatts arc).
- **Vigor** (`comp.Vigor { v, max }`) is the human energy *source* that pays every action's price, and **`vigor == 0` is death**. Action output *quality* scales by `vigor/max`, so a tired actor produces below standard.
- **Food** (`comp.InventoryFood { v, quality, spoils }`) is a perishable larder — produced by foraging/fishing, consumed **continuously by the metabolism** at the player-set ration rate (see below), and it spoils.
- **Materials** (`comp.InventoryMaterial { v }`) is the fungible, durable stockpile — the early "number-go-up" score *and* the currency spent to build capital (one bucket on purpose; typed materials wait for the market).

**(Redesigned 2026-07-07, re-redesigned 2026-08-15):** `Satiety` and passive vigor regen went
first (2026-07-07, replaced by an active `eat` action); then eating stopped being an action at
all: **`systems.metabolize`** consumes the larder continuously — food converts to vigor (scaled
by `quality`, clamped at `max`) at a rate the player sets as a *standing policy*
(`comp.Metabolism.setting`: ration ½× / normal / feast 2×, `base_rate` 1.5 food/day at normal),
and an **empty larder starves vigor down** (4/day) — the drain that finally makes death fire.
`actions.action_eat` is gone.

The player performs options that pay an energy price (from vigor) for an uncertain food/materials
yield, while the metabolism ticks against the larder the whole time. This encodes the two
praxeological margins: *labor vs leisure* (working spends vigor; it refills only through the
metabolism's continuous eating, whose *rate* is the player's standing choice — ration and stay
weak, feast and burn the stock) and *now vs later* (act now for food/materials, or invest
materials + labour into capital goods). Death at `vigor == 0` is total — a "start over" wipes everything accumulated. There
is deliberately **no world/space** — everything is UI. The decision is split `decide → act` (the
player is the decider today; sim AI deciders feed the same options later). The UI node tree is
rebuilt from scratch every frame using a per-frame arena allocator.

> **Status note (2026-07-08):** the actions/capital redesign's downstream (`main.zig`,
> `systems.zig`, the UI) has been brought back to a **clean compile** — `Satiety`,
> `Population`, the `Action`/`Good` const-array catalogs, `Capital{ owned, durability,
> progress }`, and passive vigor trickle are gone from the code, not just planned away. The
> HUD was rebuilt **lean** on the new model (see Main Loop); the M4 catalog browser and the
> capital-goods tray were **shelved** — deleted, to be redesigned on the per-agent-component
> model later. A few asides below still name pre-redesign mechanics as *history*; those are
> flagged inline.

### Main Loop (`src/main.zig`)

`App` owns all state. `App.init()` handles SDL/window setup only. `App.setup()` is called once after `App` is stable on the stack — it initialises the font, `Resources`, the ECS `World` (spawning the player actor via `spawn_player` — `spawn_agent` builds one entity with `Vigor` + `InventoryFood` + `InventoryMaterial` + the `actions_bundle` action components, then `spawn_player` tags it `Player`), the per-frame arena, and the UI context (`UiCtx`, safe because internal pointers are set after the struct address is fixed). `spawn_player` is reused on "start over".

The `ui_*` screen builders and `build_ui` no longer live in `main.zig` — they moved to
**`src/pages/`** (its own folder inside `main.zig`'s module, reached by a plain relative import;
*not* under `ui_client/` and *not* on the `ha` library surface — see the UI section for why).
`main.zig` now owns only `App`, the event loop, the sim tick, `spawn_agent`/`spawn_player`, and
`draw_scanlines`. Actions and capital are ECS-native per-agent components (see **"Actions &
Capital"**), not `main.zig` catalogs; the lean HUD enumerates them by querying the agent's own
action components rather than indexing a shared array.

**Catalog browser (M4) — shelved:** the fullscreen `ui_catalog` list (search / hide-can't-do / cheapest-richest-a-z sort / category chips over the action & capital catalogs) was **removed** in the 2026-07-08 lean rebuild — it was built on the deleted const-array catalogs and the `resolve_action`/`build_capital` act-steps. It'll return as a second *presentation* of the per-agent-component model once that model's UI is designed. The `widgets.text_input` it drove stays in the palette but is currently unused by any screen (so `main.zig`'s text-input event handling is dormant, not dead).

The lean HUD chrome: the left status column shows the run **day** (`Day N`, from `Time.elapsed / secs_per_day`, advanced by `advance_clock` only while the actor lives), a `Resources` panel — opening with a 3-line ASCII **vitals figure** (`figure_glyphs` → weary/ok/robust from the frame's warmth; `fig_dead` on the game-over screen) beside a sine-pulsed **heartbeat** readout (`heartbeat_color`, freezes when the run clock stops), then **Vigor** (`v/max`), **Food** (`v`, quality, spoil rate) and **Materials** — and an **event log** (newest-first, from `Resources.log`, each line recolored by its `Tone` via `log_tone_color`, in a `widgets.scroll_view` so the whole 64-entry ring buffer is reachable by mouse wheel). The actor's **condition word** (`actor_status` → ALIVE / WEARY / SPENT, by vigor fraction) is pinned top-right. The centered panel is tabbed **ACTIONS / BUILD**. ACTIONS holds one wrapping row of tiles — one per labor verb the agent actually *holds* (innate Forage / Scavenge; Split wood / Fish / Check traps / Hunt appear the frame their tool finishes), each priced `-energy -materials hours` with its p10–p90 band scaled by `yield_factor` — plus the `ration_dial` (eating is a standing policy, not an action). BUILD holds the 15-good capital roster on four captioned, wrapping shelves (UNLOCK / UPGRADE / HEALTH / INSTALL — `capital_shelf` in `play_game.zig`), every tile wired to the real build path through the comptime-generic `capital_good_tile` (which superseded the one-off `fish_rod_tile` when the roster landed). Big counters (Materials) render through `fmt_num` (`1.2k` / `3.4M`).

**Visual identity (M5):** the whole HUD is colored from `src/theme.zig`'s `Theme` — `cold`/`warm` palette poles blended by `theme.lerp(compute_warmth(...))`, resolved once per frame in `build_ui` onto `Resources.theme` (default `theme.cold`) so every widget reads `ctx.res.theme.*` (fg/acc/dim/warn/danger/line/line2/panel/bg) instead of a fixed color — a rested actor reads warm, a spent one cold. `compute_warmth` (now in `src/pages/`) is currently just the vigor fraction (`vigor.v / vigor.max`) — the satiety/capital inputs it once blended went away with those mechanics, to be reworked when capital returns to the HUD. The font is monospace (`Kenney Mini Square Mono.ttf`); a `draw_scanlines` overlay (partial-alpha, needs the renderer's `.blend` mode set once in `App.init`) darkens every 4th pixel row on top of everything, last, each frame.

Each frame:
1. **Events** — SDL3 event poll writes host input into `resources.input`; a left-click calls `ui.mark(.clicked, x, y)`
2. **Mark** — `ui.mark(.hovering, x, y)` hit-tests last frame's interaction-slot rects and sets flags (iterates the slot pool — no tree walk)
3. **Update** — `ecs.run(&world, &resources, system)` advances sim systems
4. **Build UI** — `ui.beginFrame()`, arena reset, `build_ui()` (in `src/pages/`) constructs fresh node trees (reads cache + world, mutates components inline on interaction). It returns a `Trees{ trees: []const *Node }` (`ui_client/tree.zig`): a flat, arena-backed list of independent root trees drawn in order — the play/game-over screen plus any **floating overlays** (a tooltip/modal), each its own root outside the others' layout flow. Each `ui_*` builder (`ui_playgame`, `ui_gameover`) owns a fullscreen root (built via a local `ui_root`) and returns a single tree or a `.{ screen, overlay }` tuple; the engine's comptime `Node.collect` helper flattens those returns (a `*Node`, an `?*Node`, or a tuple of them) into the list
5. **Layout** — `set_global_pos()` on each root solves sizes (per-axis `SizeRule`: fixed/content/pct_of_parent/fit_children) then resolves all positions; pure (no host callback — content is host-measured at build into `data_*`). A root's screen position comes from its `Layout.origin_*` (0,0 for a fullscreen screen root; for the tooltip overlay, set via `with_origin` to float over the hovered icon — `ui_playgame` does a throwaway layout pass to size it, then centres it above the icon's last-frame `node.rect`)
6. **Stamp** — `ui.stamp_rects(root)` (per root) copies each queried node's resolved rect into its interaction slot, feeding next frame's mark (step 2) and `node.rect`/`rectOf` reads
7. **Render** — userland render loop in `main.zig` calls `ui_client.draw_tree()` per root in list order (later trees, e.g. the overlay, **on top**). `draw_tree` is a recursive pre-order paint (`ui_client/draw.zig`) that carries a **clip stack** from `Layout.overflow` and, per node, `inline for`s the feature `list` — dispatching each set `render_data` aspect to its feature's `draw`. List order is the z-order: fill → image → svg → text → **outline last**, so a hover/affordance ring shows over opaque image tiles. The `img` aspect carries a `Sprite` (`texture` + optional `src` cell of a sheet), not a bare color. Then `ui.endFrame()`

Key `App` fields: `resources: res.Resources`, `world`, `ui: ui_client.UiCtx`, `frame_arena` (reset each frame). No retained `prev_root` — the interaction slot pool bridges the frame boundary instead.

### UI Engine (`src/ui/`) and host binding (`src/ui_client/`)

A standalone, immediate-mode UI building language: the node tree is rebuilt every frame from the arena; persistence (text caches, interaction state) lives in a key-addressed cache. The engine is generic (`Ctx(StateNs, IntFlags, Res)` + `Node(RenderData)`) and imports nothing from the game — including rendering, which is host policy: core stores the tree + node `render_data` and exposes traversal (`root.iterate()` for one tree's subtree; `Node.collect` to flatten a builder's return shape — a `*Node`, `?*Node`, or tuple of them — into the frame's root list), but draws nothing. **Where node state lives is decided by one axis — does it outlive the frame?** The node is rebuilt every frame, so it only holds *frame-local* state (`render_data`); anything persistent lives in a pool keyed by `node.key`, reached lazily via `node.state(u, T)` (cached `TextData`, an svg raster) or `query` (interaction slots) — the node holds no handle, only its key. `src/ui_client/` is the host binding, split by concern: `ctx_binding.zig` (the concrete types — `UiCtx = ui.Ctx(UiState, Interaction, Resources)`, `Node = ui.Node(RenderData)`, `Sprite` + `icon_sprite`), `features/` (the paint-feature registry — one module per aspect co-locating its `RenderData` field, optional pooled `State`, its `attach` mixin re-exported as `data_text`/`data_img`/`data_sprite`/`data_svg`, and its `draw`; an ordered `list` is the z-order and `assertFeature` keeps `RenderData` from drifting), `draw.zig` (the render walk — a recursive pre-order paint carrying a clip stack, dispatching each set aspect to its feature's `draw`), `tree.zig` (the `Trees` frame-return wrapper; the flattening `collect` moved onto the engine's `Node`), and `widgets.zig` (the widget functions — `label`, `progress_bar`, `button`, `icon_button`, `img`, `panel`, `tooltip`, `scroll_view`, `modal`, `text_input`) that own a node's whole subtree — graph, keyed data, color, and layout (`tooltip`/`modal` each build their own root for the overlay layer rather than taking a parent). `button` takes an `enabled` flag driving its state color (dim when disabled, bright on hover, soft idle otherwise); `progress_bar` takes a fill `Color`; `panel` is a titled, bordered, padded container the caller appends content into (returns the outer node, content flows vertically under the title). `scroll_view` is a fixed-size, clipped viewport over a `fit_children` content column: wheel-scrolls while hovered into a persisted `ScrollState.offset` (folded into `content.layout.scroll_y`, which `place` uses to translate the content's children — see `Layout.scroll_x/scroll_y` in `src/ui/README.md`), clamped against *last frame's* content height the same way the hover tooltip reads a prior-frame rect; a track + thumb rides beside it once content overflows (no drag yet). `modal` is a fullscreen scrim root behind a centered content box (mirrors `tooltip`'s own-root shape, sized to the window instead of floating at a point); it's a shell only — dismiss-on-click-outside and any "input capture" guarding of what's still built underneath is the call site's job (host policy, since hit-testing is a flat, occlusion-unaware slot scan), not something the widget enforces. `text_input` is a bordered, fixed-width field over a persisted `UiState.TextInputState` buffer (keyed like `ScrollState`); focus is host-global (`Resources.focused_text`), since SDL delivers `.text_input`/backspace as raw keyboard events rather than routed to a widget — `main.zig`'s event loop mutates the focused field's buffer directly (via the same key the widget computes) and the widget itself only starts/stops SDL's text-input mode on its own focus transitions. The interaction-state palette lives in `widgets.zig` (host policy). `RenderData` is the host's render descriptor carried opaquely on every node — one *optional* field per paint feature: `text`/`fill`/`outline`/`svg` are each an *optional* `ui.Color` (present ⟹ draw that aspect in that color; `svg` tints the cached raster), and `img` is an optional `Sprite` (a `texture` + optional `src` sub-rect selecting one cell of a sprite sheet). All are frame-local visual state. **Clipping is not a `RenderData` aspect** — it moved to core `Layout.overflow` (`.visible`/`.clip`), read by `ui_client/draw.zig`'s recursive clip stack, because it's geometry the render walk *and* (eventually) hit-testing consume, not a paint the backend applies; the `.clip` node crops its subtree, orthogonal to `scroll_x/y` which translates children (a scroll viewport composes both). Adding a feature (opacity…) needs no engine change — a module + a `list` entry + a `RenderData` field; `ui.Color` is a reusable engine POD (RGBA, defaults white). A pooled feature `State` that owns a resource (the svg raster `Texture`) declares `deinit`, which the cache's eviction hook calls when the node's slot is dropped, so it doesn't leak. Nodes are built with core `Node.create` / `Node.pcreate` (create + bind to parent, finalizing the key). `build_ui` reads top-to-bottom as **globals → queries → node graph**: the host hand-builds the structural nodes and configures each one inline at creation, then calls widget functions for the content; there's no separate deferred layout pass. Interaction flags (`Interaction`) and the render descriptor (`RenderData`) are host-defined types passed into the engine.

**See [`src/ui/README.md`](src/ui/README.md) for the full architecture** — Node/features, the key-cache (pools + handles), interaction (slot-based hit-testing, transient vs latched flags, lazy slots), layout (`Anchor` + `Flow` — flexbox-style `dir`/`wrap`/`reverse`/`main`/`cross` — + inter-child `gap`, per-node `padding`), how to write a widget, and the roadmap (autolayout, sprites).

### ECS (`src/ecs.zig`, `src/world.zig`)

A [Bevy](https://bevyengine.org)-inspired ECS over a sparse-set `World` (the ergonomics are modelled on Bevy; the storage is comptime-Zig, not Rust archetypes — see the `ecs.zig` module doc).

- **World**: one `SparseSet` per component/tag type, generated at comptime from the public decls of `components.zig` / `tags.zig`. API: `spawn(bundle)` (bundle = tuple of component **instances** + bare **tag types**), `add`, `remove`, `get`, `has`, and `despawn(e)` (clears `e` from every storage; ids are never recycled — `next_id` only climbs).
- **System params** (declared as a system fn's parameter types, built by `ecs.run` via comptime introspection): `Query(.{…})` iterates matches; `Single`/`MaybeSingle` expect exactly-one / zero-or-one. Inside the param tuple: bare component types are **fetches** (drive iteration, yield `*T`); `With(T)`/`Without(T)` filter; `Maybe(T)` yields `?*T`; and `Entity` yields the entity id (Bevy-style — doesn't drive iteration). A system may also take `*Resources` or `*World` directly.
- **Structural changes** (`add`/`remove`/`despawn`/`spawn`) currently go through a raw `*World` system param. A Bevy-style deferred `Commands` buffer is intentionally **not** built yet — see the rationale + trigger in memory (`project_commands_deferred`). Two consequences to respect when writing systems: (1) mutating the storage you're iterating is unsafe — collect ids first, then apply (see `despawn_dead`); (2) an entity that can be despawned must be read with `MaybeSingle`, not `Single`, or the UI build will panic once it's gone.
- **Survival/death pipeline** (run in this order each frame): `advance_clock` bumps the run clock (`Time.elapsed`, only while a player exists) → `update_food` spoils the larder toward zero at its per-larder `spoils` rate → `metabolize` consumes the larder at the agent's ration rate (food → vigor, clamped at `max`) or, on an **empty larder, starves vigor down** at 4/day, pushing edge-crossing lines to the log ("Your food has run out." / "You feel weak with hunger." / "You are starving.") → `resolve_busy` ticks any act in progress and, at completion, dispatches its finish half (deposit + receipt, or a capital grant) and drops the `Busy` (collect-then-apply, like `despawn_dead`) → `mark_dead` (queries `Entity, Vigor`, takes `*World` + `*Resources`) tags `Dead` at `vigor ≤ 0` and pushes the death line → `despawn_dead` (queries `Entity, Dead`) reaps it; once the actor is gone the UI (which fetches it with `MaybeSingle`) shows the "start over" screen. `actions.gather` deducts its cost (energy from `Vigor`, materials from `InventoryMaterial`; strict energy gate — labor alone can't kill), so **starvation is the one path to death**, and it fires for real since 2026-08-15. The pre-redesign `update_satiety` / `update_vigor` / `update_population` systems are gone (today's `metabolize` is new, not that satiety-era one).

### Actions & Capital (`src/actions.zig`, `src/capital.zig`)

**Redesigned 2026-07-07; compiling since the 2026-07-08 tidy-up.** Actions and capital goods are no longer const-array catalogs owned by `main.zig` — each one
an agent can perform or own is its own **typed component living directly on that agent's entity**,
not an array-indexed catalog row or a separate entity of its own. This gives every agent (the player
today, sim deciders later) individualized costs/yields for free — two agents can each hold their own
`ActionForage` with different `requires`/`yields` — and it settles capital ownership the same way
(see below).

- **Actions** — the Act One roster (filled out 2026-08-24): innate `comp.ActionForage` /
  `ActionScavenge`, and capital-unlocked `ActionFish` / `ActionChopWood` / `ActionCheckTraps` /
  `ActionHunt`. Each embeds a `requires:
  Requires { energy, materials, hours }` (the price) and `yields: Yields { food, materials }` (the reward,
  **both `dist.Dist`**, sampled at resolution time — the spread *is* the risk, no separate success
  roll). `Requires`/`Yields` are deliberately **not `pub`**: they're meaningless as standalone
  components, and `World`'s comptime `Storages` scan only sees a file's *public* decls when
  reflecting across files (verified empirically this session), so keeping them private stops a
  wasted `SparseSet` from being generated for either — at the cost that any *other* file can't name
  `Requires`/`Yields` to construct one directly. (`capital.zig`'s old archetype consts used to do
  exactly that and wouldn't compile; the 2026-07-08 tidy-up **removed** them rather than making the two
  types `pub`, so the private-shape decision stands.)
  Each action owns a distinct **risk texture** — all five `dist.Kind`s are in play (Scavenge
  exponential on both yields: mostly scraps, occasional jackpot; Check traps uniform; Hunt
  big-poisson) — and Check traps / Hunt are the first actions with `requires.materials > 0`
  (bait/ammo: produced goods as inputs). Note `dist`'s `.fixed` kind is exempt from the `scaleOf`
  0.2 floor since 2026-08-24 — a fixed-0 "no yield on this side" (every action's unused slot) used
  to silently deposit +0.2 per draw.
  `actions.actions_bundle` is the manually-maintained list of the *innate* action-component types
  (**Forage + Scavenge** — what a bare-handed human can do; every other verb is granted by an
  Unlocker capital good, see Capital below. Scavenge is the only innate *materials* source, so it's
  what bootstraps the first tool: the ladder starts with a lottery and climbs into steady work),
  spliced into `World.spawn`'s bundle via `++` (a *nested* tuple element is **not** auto-flattened
  by `spawn` — verified via a scratch repro — so nesting it directly is a compile error).
  Labor resolves in **two halves since 2026-08-16** (actions take time — `Requires.hours`, a
  fourth price field, no default on purpose): `actions.begin_labor` is the click half — refuse if
  `Busy` (one body, one act) or unaffordable (energy strict — vigor stays > 0; materials to
  exactly 0; the old `>=` materials gate silently blocked every zero-materials action), pay
  upfront, lock `quality` (`yield_factor` at the *advertised* pre-pay vigor), and add
  `comp.Busy{ doing, total, remaining, quality }` — while `finish_labor` is the completion half
  (sample `Yields` at the locked quality → deposit → log the receipt: "You gathered 2 food.",
  `.dim` "You gathered nothing." on a rounded-to-zero draw), dispatched by
  `systems.resolve_busy` when the timer runs out via `Busy.Doing` + `actions.doing_of` (the
  runtime name of a comptime action type — the `actions_bundle` manual-mapping idiom). Dying
  mid-task loses the work: paid, undelivered, `Busy` despawns with the agent. Both are
  parameterized by `comptime ActionT: type` so each action stays its own queryable component
  type while sharing resolution logic. `actions.action_eat` was **removed 2026-08-15**: eating
  moved onto the continuous metabolism loop (`systems.metabolize` + `comp.Metabolism`) with a
  player-set ration rate — eating is a standing policy now, not an action; the HUD's
  `ration_dial` sets it.
- **Capital** — the 15-good Act One roster (filled out 2026-08-24), all of it **buildable
  end-to-end**, in three behavioral variants sharing one build-cost shape and one build path.
  `capital.begin_build`/`finish_build`/`break_good` are comptime-parameterized over the good
  exactly as `begin_labor` is over the action (the gate/pay/start half is identical for all
  fifteen; only `grant`/`revoke` differ), with `build_fish_rod`/`finish_fish_rod`/`break_fish_rod`
  kept as named wrappers. `begin_build` checks the same gates as labor (not owned, not `Busy`,
  energy strict, materials to exactly 0 — the `has` check first is load-bearing, `SparseSet.add`
  doesn't guard dupes), pays the good's catalog-default `requires` (hours included) and starts a
  timed build; `finish_build` adds the component, runs its `grant`, and logs the receipt.
  `capital.prereq_of` declares a good's **prerequisite component** (Work gloves and Chainsaw both
  target `ActionChopWood`, which only exists with the Hatchet) — gating the build *and* the tile,
  so a modifier can never be applied to a component that isn't there (that would panic in
  `getMany`). It's also the roster's only real tech-tree edge.
  An **Unlocker** (Fishing rod → Fish, Hatchet → Split wood, Wire snares → Check traps, Air rifle
  → Hunt) grants a target action component outright — owning the good is what makes the verb
  possible at all. An **`ActionModifier`** (Boots, Work gloves, Bicycle, Cookpot, Root cellar,
  Chainsaw, plus the health trio Bed / Pantry / Medicine chest) mutates an *existing* margin once,
  at build and at break — an action's `Requires`/`Yields`, the larder's `quality`/`spoils`, or the
  vigor ceiling — `capital.apply_*`/`remove_*` pairs are that
  creation/destruction side effect, scaling the target's `.s`/`.sd` (or `Requires`) together rather
  than replacing them, so a boost preserves the distribution's shape. The health pairs are relative
  (`+=`/`-=`) and *fill what they add* (apply bumps `v` with `max`), so `v/max` — what the warmth
  theme, the status word and `yield_factor` all read — never dips on an upgrade, and a future aging
  system decrementing `max` composes underneath. The Chainsaw is the Act II teaser: chop energy
  ×0.3 but `requires.materials += 1` (fuel) — the first substitution of external energy for muscle.
  A **`Generator`** (Garden bed, Chicken coop; `Fireplace` was retired 2026-08-24, its role folded
  into the Cookpot) instead runs continuously: it carries **two** prices — `requires` is the build
  order, `upkeep` is the per-tick drain — and `capital.run_generator` pays the upkeep and deposits
  the yields every tick it can afford, mirroring labor's gates one level up. `upkeep` and `yields`
  are authored **per in-game day** and scaled by the frame's dt, so a flow reads as a trickle (a
  discrete daily harvest, which would restore poisson's lumpiness, is a later refinement).
  `capital.run_generators` is the system: an
  `inline for` over the manually-maintained `capital.generator_bundle` (same idea as
  `actions_bundle`), one `Query` per type. That list is manual, not derived, because "every
  component type tagged Generator" is a fact about *types*, not entities — the ECS only answers
  instance-level questions ("does entity E have component T"), so there's no runtime query for a
  type-level category. (An alternative was considered — each type self-declaring its category via a
  marker decl, the same trick `ecs.zig`'s `With`/`Without`/`Maybe` use for `_filter_kind` — and
  deferred in favor of matching the existing `actions_bundle` idiom.) The labor action functions are
  wired — the HUD's action tiles call `actions.action_*` on click — and `run_generators` **is** in
  the sim tick since 2026-08-24 (after `resolve_busy`), now that generators are buildable.
  **Capital ownership:** a good is always owned by exactly one agent — never communal, never
  stackable (no owning two Fishing Rods) — by putting each good's component directly on the owning
  agent's entity: both properties fall out of the sparse-set's own structural guarantee (at most one
  instance of a component type per entity) rather than being runtime-checked bookkeeping. This is
  **decided and fully realized**: all fifteen goods build through it end-to-end
  (BUILD tab tile → `begin_build` → timed work → `finish_build` → components on the agent),
  and the old `sandals`/`fishing_rod`/`axe`/`fireplace` "spawn a separate entity" archetype
  consts were **removed** in the 2026-07-08 tidy-up (they named the private `Requires` and never
  compiled). Build is instant one-click for now — per-agent build *progress* (building X/Y over
  time) and durability/decay are still open.
- **`ecs.getMany(world, entity, comptime params)`** — `Query`'s non-iterating sibling, for
  known-entity multi-component fetches (`gather` and `run_generator` each pull 3–4 components off
  one already-known agent this way). Panics on a missing required component (the entity was expected
  to already qualify) rather than degrading to `?*T`; `With`/`Without` are a compile error, since
  there's no entity set to filter.

### Supporting Modules

- `src/components.zig` / `src/tags.zig` — ECS component & tag types. Only `pub const <Name> = struct {…}` type decls allowed (the `World` enumerates them at comptime, over a file's *public* decls only when reflecting cross-file — verified empirically, which is why the shared `Requires`/`Yields` shapes below are deliberately private). Components: `Label` (`{ v: []const u8 }`, a display name), `Vigor` (human energy source, **0 = death**; `{ v, max }` — scales labor quality in two levels via `actions.yield_factor`, refilled only by the metabolism loop), `InventoryFood` (perishable larder; `{ v, quality, spoils }`), `InventoryMaterial` (fungible durable stockpile; `{ v }`), `ActionForage` / `ActionScavenge` (innate) and `ActionFish` / `ActionChopWood` / `ActionCheckTraps` / `ActionHunt` (unlocked by capital) — per-agent typed actions, each `{ requires: Requires, yields: Yields }`, `Busy` (`{ doing, total, remaining, quality }` — the one act in progress; costs paid at begin, yield at completion, quality locked at the click; its `Doing` enum names every labor verb *and* every build), and the 15 capital goods: Unlockers `FishRod` / `Hatchet` / `WireSnares` / `AirRifle`, modifiers `Boots` / `WorkGloves` / `Bicycle` / `Cookpot` / `RootCellar` / `Chainsaw` / `Bed` / `Pantry` / `MedicineChest` (each `{ requires }` only — the build price), and Generators `GardenBed` / `ChickenCoop` (`{ requires, upkeep, yields }` — build order, per-tick drain, per-day flow). `Fireplace` was retired 2026-08-24. Tags: `Player`, `Created`, `Dead`, `Idle` (capital that couldn't pay this round — not currently set by anything), `Generator` / `ActionModifier` (capital's two behavioral categories), `Food` / `Comfort` / `Tool` / `WoodCutting` (category tags, still being filled in). `Satiety`, `Materials`, `Capital{ owned, durability, progress }`, and `Population` from the pre-redesign model are gone.
- `src/world.zig` — sparse-set ECS `World` (see the ECS section above)
- `src/ecs.zig` — `ecs.run(world, res, system)` + the Bevy-style param machinery, including `getMany` (see the ECS section + the module doc)
- `src/actions.zig` — per-agent labor actions (innate `action_forage` / `action_scavenge`; unlocked `action_fish` / `action_chop_wood` / `action_check_traps` / `action_hunt`) and the manually-maintained `actions_bundle` list of *innate* actions. Eating is not an action (see `systems.metabolize`). See "Actions & Capital" above.
- `src/capital.zig` — the generic build path (`begin_build` / `finish_build` / `break_good`, comptime-parameterized over the good; `buildable_bundle`, `doing_of_good`, `prereq_of`/`prereq_met`, `good_name`, and the per-good `grant`/`revoke` switches), the `ActionModifier` `apply_*`/`remove_*` pairs, and the `Generator` running system (`generator_bundle`, `run_generator`, `run_generators` — wired into the tick 2026-08-24); the old separate-entity build archetypes were removed 2026-07-08. See "Actions & Capital" above.
- `src/systems.zig` — sim systems, run in this order: `advance_clock` (run clock), `update_food` (spoils the larder), `metabolize` (continuous eating at the ration rate; starvation drain on an empty larder — **new 2026-08-15**, unrelated to the deleted satiety-era system of the same name), `resolve_busy` (ticks work in progress; dispatches completion via `Busy.Doing`), and the death systems `mark_dead` / `despawn_dead`. Convention: `update_<component_snake_case>` drives one component. The pre-redesign `update_satiety` / `update_vigor` / `update_population` were removed with their mechanics.
- `src/font.zig` — `TextData` (text buffer the UI caches and renders); leaf data module
- `src/log.zig` — `Log`, a fixed-capacity ring buffer of toned event lines (`Tone`, `Entry`) held on `Resources`; the HUD's event feed. Leaf data module (no imports)
- `src/theme.zig` — `Theme` (9 named color roles) + the `cold`/`warm` poles + `lerp(t)` blending them together; game-specific art direction (host-owned, not `src/ui/`). See "Visual identity (M5)" above
- `src/res.zig` — `Resources`, the host bundle held by `Ctx` as `*Res` and passed to systems. Grouped by **who writes it**: `platform` (font, renderer, window, textures — set at init, read only by the UI), `input` and `time` (the event loop, once per frame), `sim` (the run: `elapsed`, `log`, `tutorial_done`, `prng` — `sim.reset()` starts a fresh run, deliberately carrying the prng over so runs don't replay the same luck), `config` (tuning; `secs_per_day` — outside `sim` so a start-over can't discard a player setting), and `view` (this frame's resolved `theme`, recomputed in `build_ui`; nothing here persists across frames). `focused_text` is still top-level and belongs on the UI `Ctx`. `res.random()` is the sim's single source of chance (uncertain action outcomes today; AI deciders later).
- `src/pages/pages.zig` — the game's `ui_*` screen builders + `build_ui` (game *content*, in `main.zig`'s module, not the `ha` library; imports `ha` for engine/host types and `main.zig` for shared spawn/config). See Main Loop.
- `src/root.zig` — library (`ha`) root, re-exports `sdl`, `ui`, `ui_client`, `comp`, `tag`, `log`, `dist`, `theme`, `res`, `world`, `ecs`, `systems`, `actions`, `capital`. `build.zig` also makes the module import *itself* as `ha`, so library-internal files (`components`/`actions`/`capital`) can use `@import("ha")`.

### Assets

- `assets/fonts/` — Kenney TTF font variants (Mini Square used at 24pt)
- `assets/hello.png` — test image asset
- `assets/icons.png` — capital-good icon sprite sheet (2×2 grid of 512px cells: fishing rod, sandals / bed, fireplace), sampled via `ui_client.icon_sprite`. Currently unused by the lean HUD (the capital-goods tray that drew from it was shelved); kept for when capital returns to the UI.

## Design & roadmap

The game's design — the vision, the two pillars, the locked decisions and the Act structure — is [`docs/design.md`](docs/design.md). What's next, and everything scoped but not yet built, is [`docs/roadmap.md`](docs/roadmap.md).
