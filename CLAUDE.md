# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build run    # Build and run the application
zig build test   # Run unit tests
zig build        # Build only
```

Requires Zig 0.15.2+. Dependencies (SDL3, SDL3 TTF) are fetched automatically via `build.zig.zon`.

## Architecture

**Human Action** is a Zig/SDL3 application aiming to become an **agent-based praxeology simulation** — emergent economic/social behavior from a population of purposeful AI agents acting under scarcity (the name nods to Ludwig von Mises). The intended shape is an **incremental/accumulator game** (Cookie-Clicker-like): start alone, starved and cold; end with billions of humans and petawatts of energy. See the `project_game_design_accumulator` memory for the full design.

Today it is *early gameplay on a custom foundation*: a bespoke immediate-mode UI layout engine plus a Bevy-style sparse-set ECS. The first slice is the **lone actor under scarcity** (Robinson Crusoe economics — one actor, no exchange, no money yet). The resource model (**redesigned 2026-06-23**, see the `project_game_design_accumulator` memory) splits survival from accounting:

- **Energy** is the *unit of work* — the **price** of every action, not a stock you hold. It's paid from a *source*; today that source is your body (vigor), later it's harnessed external energy (the chainsaw → engine → petawatts arc).
- **Vigor** (`comp.Vigor { v, max }`) is the human energy *source* that pays every action's price, and **`vigor == 0` is death**. Action output *quality* scales by `vigor/max`, so a tired actor produces below standard.
- **Food** (`comp.InventoryFood { v, quality, spoils }`) is a perishable larder — produced by foraging/fishing, spent by actively eating, and it spoils.
- **Materials** (`comp.InventoryMaterial { v }`) is the fungible, durable stockpile — the early "number-go-up" score *and* the currency spent to build capital (one bucket on purpose; typed materials wait for the market).

**(Redesigned 2026-07-07):** `Satiety` and passive vigor regen are gone. There's no more hunger
ceiling clamping `Vigor` — instead, an **active** `eat` action (`actions.action_eat`) converts
stored `Food` directly into `Vigor`, scaled by the food's `quality`. This also reverses
`docs/roadmap.md`'s earlier "no active rest/eat, passive trickle only" locked decision — see
"Actions & Capital" below for the full shape of this redesign.

The player performs options that pay an energy price (from vigor) for an uncertain food/materials
yield, or actively eats to refill vigor. This encodes the two praxeological margins: *labor vs
leisure* (working spends vigor and lowers yields; vigor is refilled only by spending a turn eating,
not passively) and *now vs later* (act now for food/materials, or invest materials + labour into
capital goods). Death at `vigor == 0` is total — a "start over" wipes everything accumulated. There
is deliberately **no world/space** — everything is UI. The decision is split `decide → act` (the
player is the decider today; sim AI deciders feed the same options later). The UI node tree is
rebuilt from scratch every frame using a per-frame arena allocator.

> **Status note (2026-07-07):** the paragraphs below (Main Loop, HUD chrome, the ECS
> survival/death pipeline, Supporting Modules) describe the *pre-redesign* shapes in some
> places — `Satiety`, `Population`, the `Action`/`Good` const-array catalogs, and
> `Capital{ owned, durability, progress }` — which this session's refactor replaced (see
> "Actions & Capital" below). `main.zig` and `systems.zig` haven't been updated to match
> the new component shapes yet, so the app doesn't currently build; that tidy-up is
> explicitly parked until this refactor (still under manual review) is finished. Treat any
> mention of those four names below as historical, not current fact.

### Main Loop (`src/main.zig`)

`App` owns all state. `App.init()` handles SDL/window setup only. `App.setup()` is called once after `App` is stable on the stack — it initialises the font, `Resources`, the ECS `World` (spawning the player actor via `spawn_player` — one entity with `Vigor` + `Satiety` + `Food` + `Materials` + `Capital`, tagged `Player`), the per-frame arena, and the UI context (`UiCtx`, safe because internal pointers are set after the struct address is fixed). `spawn_player` is reused on "start over".

Actions and capital goods are no longer const-array catalogs living in `main.zig` — as of this
session's refactor they're ECS-native per-agent components; see **"Actions & Capital"** below for
the current shape. The paragraphs that used to describe `main.zig`'s `actions`/`capital` arrays,
`resolve_action`, `plan_payment`, and `build_capital` here have been retired along with those
arrays — `main.zig`'s UI/act wiring for both hasn't been updated to the new component shapes yet
(see the status note above), so there's nothing current left to document at the `main.zig` layer
until that pass lands.

**Catalog browser (M4):** a "Browse catalog" button beside Actions and beside Capital Goods opens `ui_catalog`, a fullscreen list over that catalog — `build_ui` routes to it instead of `ui_playgame` while open. Search (case-insensitive substring, via a new `widgets.text_input`), a hide-can't-do toggle (+ hide-owned for capital), a cheapest/richest/a-z sort, and category chips (not a sidebar — see roadmap M4 for why) filter/order the rows; each row funnels its ACT/BUILD button through the same `resolve_action`/`build_capital` the inline HUD uses, not a parallel mechanism. The browser's open/closed state lives on a *fixed* interaction key (`ui.key(0, "…_browse_open")`, not a node-derived one) since the button that opens it, `build_ui`'s routing check, and its own "‹ BACK" button never build the same node in the same frame — a node-derived key would get pruned the instant the screen that builds it isn't shown.

The HUD chrome around these: the left status column shows the run **day** (`Day N`, from `Time.elapsed / secs_per_day`, advanced by `advance_clock` only while the actor lives), the `Resources` panel — opening with a 3-line ASCII **vitals figure** (`figure_kind` → weary/ok/robust, from hunger/exhaustion first, then warmth; `fig_dead` on the game-over screen) beside a sine-pulsed **heartbeat** readout (`heartbeat_color`, freezes when the run clock stops) — and an **event log** (newest-first, from `Resources.log`, each line recolored by its `Tone` via `log_tone_color`, held in a `widgets.scroll_view` so the whole run's history — up to the log's 64-entry ring buffer, not just the last few lines — is reachable by mouse wheel); the actor's **condition word** (`actor_status` → ALIVE / HUNGRY / EXHAUSTED / STARVING, colored by severity) is pinned top-right. Actions, capital commit/completion, and death each push a toned line to the log. Big counters (Materials) render through `fmt_num` (`1.2k` / `3.4M`) so the accumulator stays readable. The Resources panel also shows **Population** (`count`/`capacity`, M6's progression spine — see below); crossing 2 pushes a one-time "Act I complete" log line (guarded by `Population.crossed`), since the actual second agent is M8's job.

**Visual identity (M5):** the whole HUD is colored from `src/theme.zig`'s `Theme` — `cold`/`warm` palette poles blended by `theme.lerp(compute_warmth(...))`, resolved once per frame in `build_ui` onto `Resources.theme` (default `theme.cold`) so every widget reads `ctx.res.theme.*` (fg/acc/dim/warn/danger/line/line2/panel/bg) instead of a fixed color — a rested, fed, well-built actor reads warm; a cold, hungry, threadbare one reads cold. `compute_warmth` weights vigor (28%), satiety (40%), capital built (32%, capped at 8 goods) and a flat bonus for owning the Fireplace (`fireplace_idx`). The font is monospace (`Kenney Mini Square Mono.ttf`); a `draw_scanlines` overlay (partial-alpha, needs the renderer's `.blend` mode set once in `App.init`) darkens every 4th pixel row on top of everything, last, each frame.

Each frame:
1. **Events** — SDL3 event poll writes host input into `resources.input`; a left-click calls `ui.mark(.clicked, x, y)`
2. **Mark** — `ui.mark(.hovering, x, y)` hit-tests last frame's interaction-slot rects and sets flags (iterates the slot pool — no tree walk)
3. **Update** — `ecs.run(&world, &resources, system)` advances sim systems
4. **Build UI** — `ui.beginFrame()`, arena reset, `build_ui()` constructs fresh node trees (reads cache + world, mutates components inline on interaction). It returns a `Ui{ trees: []const *Node }`: a flat, arena-backed list of independent root trees drawn in order — the play/game-over screen plus any **floating overlays** (the hover tooltip), each its own root outside the others' layout flow. Each `ui_*` builder (`ui_playgame`, `ui_gameover`) owns a fullscreen root (built via `ui_root`) and returns a single tree or a `.{ screen, tooltip }` tuple; the comptime `collect` helper flattens those returns (a `*Node`, an `?*Node`, or a tuple of them) into the list
5. **Layout** — `set_global_pos()` on each root solves sizes (per-axis `SizeRule`: fixed/content/pct_of_parent/fit_children) then resolves all positions; pure (no host callback — content is host-measured at build into `data_*`). A root's screen position comes from its `Layout.origin_*` (0,0 for a fullscreen screen root; for the tooltip overlay, set via `with_origin` to float over the hovered icon — `ui_playgame` does a throwaway layout pass to size it, then centres it above the icon's last-frame `node.rect`)
6. **Stamp** — `ui.stamp_rects(root)` (per root) copies each queried node's resolved rect into its interaction slot, feeding next frame's mark (step 2) and `node.rect`/`rectOf` reads
7. **Render** — userland render loop in `main.zig`: `draw_tree()` runs `root.iterate()` per root in list order (later trees, e.g. the overlay, **on top**), drawing each node by its `render_data` aspects (e.g. `if (node.render_data.text) |c| widgets.draw_text(..., c)`). Order within a node is fill → image → text → **outline last**, so a hover/affordance ring shows over opaque image tiles. The `img` aspect carries a `Sprite` (`texture` + optional `src` cell of a sheet), not a bare color. Then `ui.endFrame()`

Key `App` fields: `resources: res.Resources`, `world`, `ui: widgets.UiCtx`, `frame_arena` (reset each frame). No retained `prev_root` — the interaction slot pool bridges the frame boundary instead.

### UI Engine (`src/ui/`) and widgets (`src/widgets.zig`)

A standalone, immediate-mode UI building language: the node tree is rebuilt every frame from the arena; persistence (text caches, interaction state) lives in a key-addressed cache. The engine is generic (`Ctx(StateNs, IntFlags, Res)` + `Node(RenderData)`) and imports nothing from the game — including rendering, which is host policy: core stores the tree + node `data`/`render_data` and exposes `root.iterate()`, but draws nothing. **Where node state lives is decided by one axis — does it outlive the frame?** The node is rebuilt every frame, so it only holds *frame-local* state (`render_data`); anything persistent lives in a pool keyed by `node.key` (cached `TextData`, reached via the `data` handle; interaction slots, reached via `query`). `src/widgets.zig` is the host's concrete binding (`UiCtx = ui.Ctx(UiState, Interaction, Resources)`, `Node = ui.Node(RenderData)`) plus the feature mixins (`data_text`; `data_img` for a whole texture, `data_sprite` for one sheet cell — the latter takes a `Sprite`, built via `icon_sprite`), draw primitives (`draw_text`/`draw_fill`/`draw_outline` take the color to paint in, `draw_texture` blits a `Sprite`), and widget functions (`label`, `progress_bar`, `button`, `icon_button`, `img`, `panel`, `tooltip`, `scroll_view`, `modal`, `text_input`) that own a node's whole subtree — graph, keyed data, color, and layout (`tooltip`/`modal` each build their own root for the overlay layer rather than taking a parent). `button` takes an `enabled` flag driving its state color (dim when disabled, bright on hover, soft idle otherwise); `progress_bar` takes a fill `Color`; `panel` is a titled, bordered, padded container the caller appends content into (returns the outer node, content flows vertically under the title). `scroll_view` is a fixed-size, clipped viewport over a `fit_children` content column: wheel-scrolls while hovered into a persisted `ScrollState.offset` (folded into `content.layout.scroll_y`, which `place` uses to translate the content's children — see `Layout.scroll_x/scroll_y` in `src/ui/README.md`), clamped against *last frame's* content height the same way the hover tooltip reads a prior-frame rect; a track + thumb rides beside it once content overflows (no drag yet). `modal` is a fullscreen scrim root behind a centered content box (mirrors `tooltip`'s own-root shape, sized to the window instead of floating at a point); it's a shell only — dismiss-on-click-outside and any "input capture" guarding of what's still built underneath is the call site's job (host policy, since hit-testing is a flat, occlusion-unaware slot scan), not something the widget enforces. `text_input` is a bordered, fixed-width field over a persisted `UiState.TextInputState` buffer (keyed like `ScrollState`); focus is host-global (`Resources.focused_text`), since SDL delivers `.text_input`/backspace as raw keyboard events rather than routed to a widget — `main.zig`'s event loop mutates the focused field's buffer directly (via the same key the widget computes) and the widget itself only starts/stops SDL's text-input mode on its own focus transitions. The interaction-state palette lives in `widgets.zig` (host policy). `RenderData` is the host's render descriptor carried opaquely on every node: the `text`/`fill`/`outline` aspects are each an *optional* `ui.Color` (present ⟹ draw that aspect in that color), `img` is an optional `Sprite` (a `texture` + optional `src` sub-rect selecting one cell of a sprite sheet), and `clip` is a bare `bool` (present+true ⟹ the host's render walk crops that node's subtree to its own box — see `draw_tree`'s clip stack in `main.zig`). All are frame-local visual state, so they ride on the descriptor rather than a separate field. Adding an aspect (opacity…) needs no engine change; `ui.Color` is a reusable engine POD (RGBA, defaults white). Nodes are built with core `Node.create` / `Node.pcreate` (create + bind to parent, finalizing the key). `build_ui` reads top-to-bottom as **globals → queries → node graph**: the host hand-builds the structural nodes and configures each one inline at creation, then calls widget functions for the content; there's no separate deferred layout pass. Interaction flags (`Interaction`) and the render descriptor (`RenderData`) are host-defined types passed into the engine.

**See [`src/ui/README.md`](src/ui/README.md) for the full architecture** — Node/features, the key-cache (pools + handles), interaction (slot-based hit-testing, transient vs latched flags, lazy slots), layout (`Anchor` + `ChildrenAlign` + inter-child `gap`, per-node `padding`), how to write a widget, and the roadmap (autolayout, sprites).

### ECS (`src/ecs.zig`, `src/world.zig`)

A [Bevy](https://bevyengine.org)-inspired ECS over a sparse-set `World` (the ergonomics are modelled on Bevy; the storage is comptime-Zig, not Rust archetypes — see the `ecs.zig` module doc).

- **World**: one `SparseSet` per component/tag type, generated at comptime from the public decls of `components.zig` / `tags.zig`. API: `spawn(bundle)` (bundle = tuple of component **instances** + bare **tag types**), `add`, `remove`, `get`, `has`, and `despawn(e)` (clears `e` from every storage; ids are never recycled — `next_id` only climbs).
- **System params** (declared as a system fn's parameter types, built by `ecs.run` via comptime introspection): `Query(.{…})` iterates matches; `Single`/`MaybeSingle` expect exactly-one / zero-or-one. Inside the param tuple: bare component types are **fetches** (drive iteration, yield `*T`); `With(T)`/`Without(T)` filter; `Maybe(T)` yields `?*T`; and `Entity` yields the entity id (Bevy-style — doesn't drive iteration). A system may also take `*Resources` or `*World` directly.
- **Structural changes** (`add`/`remove`/`despawn`/`spawn`) currently go through a raw `*World` system param. A Bevy-style deferred `Commands` buffer is intentionally **not** built yet — see the rationale + trigger in memory (`project_commands_deferred`). Two consequences to respect when writing systems: (1) mutating the storage you're iterating is unsafe — collect ids first, then apply (see `despawn_dead`); (2) an entity that can be despawned must be read with `MaybeSingle`, not `Single`, or the UI build will panic once it's gone.
- **Survival/death pipeline** (run in this order each frame): `advance_clock` bumps the run clock (`Time.elapsed`, only while a player exists) → `update_satiety` drains hunger → `metabolize` converts `Food`→`Satiety` (passive eating, flat full-ration `metabolism_rate`) → `update_food` spoils the larder → `update_vigor` trickles `Vigor.v` up but **clamps it to the hunger ceiling** `max × satiety_frac` (so a falling satiety drags vigor down) → `update_population` grows/shrinks `Population.count` toward `capacity` on sustained surplus / starvation (roadmap M6; `capacity` itself is written each frame by `main.zig`'s catalog-aware `compute_capacity`, same split as `Vigor.trickle`) → `mark_dead` (queries `Entity, Vigor`, takes `*Resources`) tags `Dead` at `vigor ≤ 0` and pushes the death line to the log → `despawn_dead` (queries `Entity, Dead`) reaps it. The player's actions in `build_ui` produce food/materials and spend vigor. This is the live game loop, not a demo — the actor's death ends the run. **(Pre-redesign — see the status note above; this pipeline hasn't been rewritten yet for the `Satiety`/`Population`-free model.)**

### Actions & Capital (`src/actions.zig`, `src/capital.zig`)

**Redesigned 2026-07-07**, settled architecture but not yet a working build (see the status note
above). Actions and capital goods are no longer const-array catalogs owned by `main.zig` — each one
an agent can perform or own is its own **typed component living directly on that agent's entity**,
not an array-indexed catalog row or a separate entity of its own. This gives every agent (the player
today, sim deciders later) individualized costs/yields for free — two agents can each hold their own
`ActionForage` with different `requires`/`yields` — and it settles capital ownership the same way
(see below).

- **Actions** — `comp.ActionForage` / `ActionFish` / `ActionChopWood` each embed a `requires:
  Requires { energy, materials }` (the price) and `yields: Yields { food, materials }` (the reward,
  **both `dist.Dist`**, sampled at resolution time — the spread *is* the risk, no separate success
  roll). `Requires`/`Yields` are deliberately **not `pub`**: they're meaningless as standalone
  components, and `World`'s comptime `Storages` scan only sees a file's *public* decls when
  reflecting across files (verified empirically this session), so keeping them private stops a
  wasted `SparseSet` from being generated for either — at the cost that any *other* file can't name
  `Requires`/`Yields` to construct one directly (a real, currently-unresolved tension: `capital.zig`'s
  archetype consts below still do this and won't compile as written; making the two types `pub` to
  fix it would reintroduce the wasted-`SparseSet` problem it avoided in the first place).
  `actions.actions_bundle` is the manually-maintained list of every action-component type, spliced
  into `World.spawn`'s bundle via `++` (a *nested* tuple element is **not** auto-flattened by
  `spawn` — verified via a scratch repro — so nesting it directly is a compile error).
  `actions.gather` is the one shared "act" step (check affordability → sample `Yields` → deposit)
  that all three call through, parameterized by `comptime ActionT: type` so each action stays its
  own queryable component type while sharing resolution logic — note it currently checks
  affordability but doesn't deduct the cost from `Vigor`/`InventoryMaterial` before depositing the
  yield, a known gap, not yet decided whether/how to close. `actions.action_eat` is the new
  **active** eat action (food adds straight to `Vigor`, scaled by `quality`) enabled by this
  session's Satiety removal.
- **Capital** splits into two behavioral variants, by tag not by type (both share the same
  build-cost shape): an **`ActionModifier`** (Sandals, Fishing rod, Axe) mutates a target action's
  `Requires`/`Yields` once, at build and at break — `capital.apply_*`/`remove_*` pairs are that
  creation/destruction side effect, scaling the target's `.s`/`.sd` (or `Requires`) together rather
  than replacing them, so a boost preserves the distribution's shape. A **`Generator`** (Fireplace,
  `comp.Fireplace`) instead runs continuously: given its own `requires`/`yields` (the same shape as
  an action's), `capital.run_generator` drains/deposits it every tick it can afford — mirroring
  `gather`'s shape exactly, one level up — and `capital.run_generators` is the system: an
  `inline for` over the manually-maintained `capital.generator_bundle` (same idea as
  `actions_bundle`), one `Query` per type. That list is manual, not derived, because "every
  component type tagged Generator" is a fact about *types*, not entities — the ECS only answers
  instance-level questions ("does entity E have component T"), so there's no runtime query for a
  type-level category. (An alternative was considered — each type self-declaring its category via a
  marker decl, the same trick `ecs.zig`'s `With`/`Without`/`Maybe` use for `_filter_kind` — and
  deferred in favor of matching the existing `actions_bundle` idiom.) Neither `run_generators` nor
  the action functions are wired into any per-frame call site yet.
  **Capital ownership:** a good is always owned by exactly one agent — never communal, never
  stackable (no owning two Fishing Rods) — by putting each good's component directly on the owning
  agent's entity: both properties fall out of the sparse-set's own structural guarantee (at most one
  instance of a component type per entity) rather than being runtime-checked bookkeeping. This is
  **decided but only half-migrated**: `comp.Fireplace` already follows it, but the
  `sandals`/`fishing_rod`/`axe`/`fireplace` consts in `capital.zig` are still the *old* "spawn a
  separate entity" archetype bundles (build cost + label + category tag) — migrating them to
  per-agent components is the next piece of this refactor, not yet started.
- **`ecs.getMany(world, entity, comptime params)`** — `Query`'s non-iterating sibling, for
  known-entity multi-component fetches (`gather` and `run_generator` each pull 3–4 components off
  one already-known agent this way). Panics on a missing required component (the entity was expected
  to already qualify) rather than degrading to `?*T`; `With`/`Without` are a compile error, since
  there's no entity set to filter.

### Supporting Modules

- `src/components.zig` / `src/tags.zig` — ECS component & tag types. Only `pub const <Name> = struct {…}` type decls allowed (the `World` enumerates them at comptime, over a file's *public* decls only when reflecting cross-file — verified empirically, which is why the shared `Requires`/`Yields` shapes below are deliberately private). Components: `Label` (`{ v: []const u8 }`, a display name), `Vigor` (human energy source, scales action quality, **0 = death**; `{ v, max }` — no passive regen since the 2026-07-07 redesign, see "Actions & Capital"), `InventoryFood` (perishable larder; `{ v, quality, spoils }`), `InventoryMaterial` (fungible durable stockpile; `{ v }`), `ActionForage` / `ActionFish` / `ActionChopWood` (per-agent typed actions, each `{ requires: Requires, yields: Yields }`), `Fireplace` (a `Generator`-category capital good, same `{ requires, yields }` shape, ticked continuously instead of on click). Tags: `Player`, `Created`, `Dead`, `Idle` (capital that couldn't pay this round — not currently set by anything), `Generator` / `ActionModifier` (capital's two behavioral categories), `Food` / `Comfort` / `Tool` / `WoodCutting` (category tags, still being filled in). `Satiety`, `Materials`, `Capital{ owned, durability, progress }`, and `Population` from the pre-redesign model are gone.
- `src/world.zig` — sparse-set ECS `World` (see the ECS section above)
- `src/ecs.zig` — `ecs.run(world, res, system)` + the Bevy-style param machinery, including `getMany` (see the ECS section + the module doc)
- `src/actions.zig` — per-agent labor actions (`action_forage` / `action_fish` / `action_chop_wood`, `action_eat`) and the manually-maintained `actions_bundle` list. See "Actions & Capital" above.
- `src/capital.zig` — capital-good archetypes, the `ActionModifier` apply/remove pairs, and the `Generator` running system (`generator_bundle`, `run_generator`, `run_generators`). See "Actions & Capital" above.
- `src/systems.zig` — sim systems. Convention: `update_<component_snake_case>` drives one component (`update_satiety`, `update_food`, `update_vigor`, `update_population`), plus `advance_clock` (run clock), `metabolize` (food→satiety) and the death systems (`mark_dead`, `despawn_dead`). **Pre-redesign — see the status note above; not yet rewritten for the current component shapes.**
- `src/font.zig` — `TextData` (text buffer the UI caches and renders); leaf data module
- `src/log.zig` — `Log`, a fixed-capacity ring buffer of toned event lines (`Tone`, `Entry`) held on `Resources`; the HUD's event feed. Leaf data module (no imports)
- `src/theme.zig` — `Theme` (9 named color roles) + the `cold`/`warm` poles + `lerp(t)` blending them together; game-specific art direction (host-owned, not `src/ui/`). See "Visual identity (M5)" above
- `src/res.zig` — `Resources` (font, renderer, window, `time` incl. `elapsed` game-seconds for the day clock, input incl. `wheel_y`, `prng`, `log` the event feed, `theme` — this frame's resolved `Theme`, recomputed in `build_ui` — and `focused_text`, which `text_input` field currently owns keyboard text, if any); the host bundle, held by `Ctx` as `*Res` and passed to systems. `res.random()` is the sim's single source of chance (uncertain action outcomes today; AI deciders later)
- `src/root.zig` — library root, re-exports `sdl`, `ui`, `widgets`, `comp`, `tag`, `font`, `log`, `dist`, `theme`, `res`, `world`, `ecs`, `systems`, `actions`, `capital`

### Assets

- `assets/fonts/` — Kenney TTF font variants (Mini Square used at 24pt)
- `assets/hello.png` — test image asset
- `assets/icons.png` — capital-good icon sprite sheet (2×2 grid of 512px cells: fishing rod, sandals / bed, fireplace). All four cells are used; the **Axe** and **Saw** goods reuse the sandals and fireplace cells as **placeholders** until their own art exists (flagged `PLACEHOLDER` in the `capital` catalog).

## TODO / Deferred

The forward redesign plan — population-as-spine, autonomous-agent Act II, the text-forward terminal identity, and the M0–M8 milestone sequence — lives in [`docs/roadmap.md`](docs/roadmap.md); the imported design prototype is in `design/`. The near-term items below are scoped but not yet built (see also the `project_game_design_accumulator` memory):

- **Ration selector** — a full / ½ / ¼ control scaling `metabolism_rate` so the player can tighten the belt and stretch a thin larder; today metabolism is a flat full ration.
- **Generalized capital decay** — all capital wears, not just power tools: durable goods (a bed, a fireplace) should degrade on a slow trickle and need maintenance, the way food spoils fast. Today only external-energy tools wear (by use).
- **Progress-ring polish** — a glanceable in-progress build indicator on the capital icon (an underbar or bottom-up fill); today the only cue is the hover tooltip's `building X/Y e`.
- **Responsive layout** — the Resources/Log column (`top_left`) and the Actions/Capital column (`center`) can visually overlap at some window sizes/aspect ratios: independent anchors don't collision-avoid each other, they just place from their own point and let `fit_children` grow however large it grows. Confirmed pre-existing (reproduces on `ba3230e`, before the M5 visual-identity work), not a M5 regression. Fixing it properly needs a responsive layout pass (reflow/shrink columns to the live window size, not just anchor+grow) — a chunk of its own, not a quick tweak.
- **Catalog favorites/pins** — the M4 browser's search/filter/sort don't include a favorites star or a pinned-items shelf (the design prototype's `☆`/`★` toggle). Needs its own persisted per-item state (a bitset, like `Capital.owned`, keyed by catalog index) — a separable unit of work.
- **SparseSet memory scaling** — `world.zig`'s `SparseSet(T)` allocates three `[MAX_ENTITIES]`-sized arrays (`dense_ids`, `dense_values`, `sparse`) per component type, regardless of how many entities actually carry `T` — cost is `num_types × MAX_ENTITIES`, not occupancy. Harmless at today's scale (1 agent, ~10 types); becomes real once the capital catalog grows into the hundreds and/or `MAX_ENTITIES` has to grow to fit more agents (entity ids are never recycled, so `MAX_ENTITIES` is actually a lifetime-spawn cap, not a live-population one — its own related landmine). The fix, when it's needed: size the dense arrays to occupancy (an allocator-backed growable array instead of a fixed one), and back the `sparse` index with a hashmap for "cold" (rarely-owned) component types while hot/near-universal ones (`Vigor`, `InventoryFood`) keep the current flat-array design — a per-type storage policy decided once, where `Storages(ns)` builds each `SparseSet(T)`. Contained to two files: `world.zig` (the storage swap) and `ecs.zig` (`Query`'s driver fast-path reaches into `.dense_ids`/`.dense_values`/`.len` directly at `ecs.zig:137,147,178,181` — those three spots would need to go through method calls instead of raw field access). Verified via `grep` that no call site outside those two files touches `SparseSet` fields directly, so nothing in game/system code would need to change.
