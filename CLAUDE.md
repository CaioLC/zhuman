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

Today it is *early gameplay on a custom foundation*: a bespoke immediate-mode UI layout engine plus a Bevy-style sparse-set ECS. The first slice is the **lone actor under scarcity** (Robinson Crusoe economics — one actor, no exchange, no money yet). Two resources drive it: **energy** (the survival stock *and* accumulation currency — decays while idle, hitting 0 = perish) and **stamina** (how rested — gates the *quality* of action outcomes; energy yield scales by `stamina/max`). The player clicks from a menu of options, each paying an up-front cost for an uncertain yield. This encodes the two praxeological margins: *labor vs leisure* (working drains stamina and lowers yields; stamina recovers only by a passive trickle, so the choice is to keep working while drained or pause and let it refill) and *now vs later* (spend energy on an action now, or invest surplus in capital goods — tools that permanently improve an action, comforts that speed stamina recovery at the cost of energy upkeep). Death is total — a "start over" wipes everything accumulated. There is deliberately **no world/space** — everything is UI. The decision is split `decide → act` (the player is the decider today; sim AI deciders feed the same options later). The UI node tree is rebuilt from scratch every frame using a per-frame arena allocator.

### Main Loop (`src/main.zig`)

`App` owns all state. `App.init()` handles SDL/window setup only. `App.setup()` is called once after `App` is stable on the stack — it initialises the font, `Resources`, the ECS `World` (spawning the player actor via `spawn_player` — one entity with `Energy` + `Stamina`, tagged `Player`), the per-frame arena, and the UI context (`UiCtx`, safe because internal pointers are set after the struct address is fixed). `spawn_player` is reused on "start over".

The action catalog (`actions`, a const array of `Action{ label, energy_cost, stamina_cost, energy_yield, p_success }`) and its resolution live in `main.zig`: `build_ui` renders one `button` per option (its label shows the *effective* energy yield — owned tools folded in, then scaled by current stamina) and, on click, pays both costs, rolls the effective `p_success` against `resources.random()`, and applies the effective stamina-scaled yield. Stamina recovers only via the passive `update_stamina` trickle — there is no rest action. On death the actor is despawned; `build_ui` then shows a "Start over" button that calls `spawn_player`.

The capital catalog (`capital`, a const array of `Good{ label, energy_cost, stamina_cost, kind, … }`, `kind` ∈ `{ tool, comfort }`) is the *now-vs-later* investment. `build_ui` renders the catalog as a horizontal tray of icons sampled from a shared sprite sheet (`assets/icons.png`, cached on `Resources.icons`; each `Good` carries its `icon_x`/`icon_y` cell origin): an owned good is a static icon, an unowned one an `icon_button` (affordability-guarded on both costs, its hover/affordance ring drawn over the opaque tile). Cost/effect text is icon-only for now — a hover tooltip comes later. Buying pays energy + stamina and sets the good's bit in the actor's `Capital.owned` (a bitset; `bit`/`owns` helpers). A **tool** targets one action by index and folds its `yield_mult`/`prob_add` into that action's resolution. A **comfort** good bakes its `trickle_add`/`upkeep` into the actor's `Stamina.trickle`/`Energy.decay` at purchase, so the on-screen rates track it. Goods are one-time unlocks; `Capital` resets with the actor on "start over". This is the `decide → act` split with a human decider; an AI decider over the same catalog comes later.

Each frame:
1. **Events** — SDL3 event poll writes host input into `resources.input`; a left-click calls `ui.mark(.clicked, x, y)`
2. **Mark** — `ui.mark(.hovering, x, y)` hit-tests last frame's interaction-slot rects and sets flags (iterates the slot pool — no tree walk)
3. **Update** — `ecs.run(&world, &resources, system)` advances sim systems
4. **Build UI** — `ui.beginFrame()`, arena reset, `build_ui()` constructs a fresh node tree (reads cache + world, mutates components inline on interaction)
5. **Layout** — `root.set_global_pos()` solves sizes (per-axis `SizeRule`: fixed/content/pct_of_parent/fit_children) then resolves all positions; pure (no host callback — content is host-measured at build into `data_*`)
6. **Stamp** — `ui.stamp_rects(root)` copies each queried node's resolved rect into its interaction slot, feeding next frame's mark (step 2)
7. **Render** — userland render loop in `main.zig`: `root.iterate()` walks the tree and draws each node by its `render_data` aspects, unwrapping each optional payload (e.g. `if (node.render_data.text) |c| widgets.draw_text(..., c)`). Order is fill → image → text → **outline last**, so a hover/affordance ring shows over opaque image tiles. The `img` aspect carries a `Sprite` (`texture` + optional `src` cell of a sheet), not a bare color. Then `ui.endFrame()`

Key `App` fields: `resources: res.Resources`, `world`, `ui: widgets.UiCtx`, `frame_arena` (reset each frame). No retained `prev_root` — the interaction slot pool bridges the frame boundary instead.

### UI Engine (`src/ui/`) and widgets (`src/widgets.zig`)

A standalone, immediate-mode UI building language: the node tree is rebuilt every frame from the arena; persistence (text caches, interaction state) lives in a key-addressed cache. The engine is generic (`Ctx(StateNs, IntFlags, Res)` + `Node(RenderData)`) and imports nothing from the game — including rendering, which is host policy: core stores the tree + node `data`/`render_data` and exposes `root.iterate()`, but draws nothing. **Where node state lives is decided by one axis — does it outlive the frame?** The node is rebuilt every frame, so it only holds *frame-local* state (`render_data`); anything persistent lives in a pool keyed by `node.key` (cached `TextData`, reached via the `data` handle; interaction slots, reached via `query`). `src/widgets.zig` is the host's concrete binding (`UiCtx = ui.Ctx(UiState, Interaction, Resources)`, `Node = ui.Node(RenderData)`) plus the feature mixins (`data_text`; `data_img`/`data_sprite` for textures), draw primitives (`draw_text`/`draw_fill`/`draw_outline` take the color to paint in, `draw_texture` blits a `Sprite`), and widget functions (`label`, `progress_bar`, `button`, `icon_button`, `img`, `panel`) that own a node's whole subtree — graph, keyed data, color, and layout. `button` takes an `enabled` flag driving its state color (dim when disabled, bright on hover, soft idle otherwise); `progress_bar` takes a fill `Color`; `panel` is a titled, bordered, padded container the caller appends content into (returns the outer node, content flows vertically under the title). The interaction-state palette lives in `widgets.zig` (host policy). `RenderData` is the host's render descriptor carried opaquely on every node: the `text`/`fill`/`outline` aspects are each an *optional* `ui.Color` (present ⟹ draw that aspect in that color), and `img` is an optional `Sprite` (a `texture` + optional `src` sub-rect selecting one cell of a sprite sheet). All are frame-local visual state, so they ride on the descriptor rather than a separate field. Adding an aspect (opacity…) needs no engine change; `ui.Color` is a reusable engine POD (RGBA, defaults white). Nodes are built with core `Node.create` / `Node.pcreate` (create + bind to parent, finalizing the key). `build_ui` reads top-to-bottom as **globals → queries → node graph**: the host hand-builds the structural nodes and configures each one inline at creation, then calls widget functions for the content; there's no separate deferred layout pass. Interaction flags (`Interaction`) and the render descriptor (`RenderData`) are host-defined types passed into the engine.

**See [`src/ui/README.md`](src/ui/README.md) for the full architecture** — Node/features, the key-cache (pools + handles), interaction (slot-based hit-testing, transient vs latched flags, lazy slots), layout (`Anchor` + `ChildrenAlign` + inter-child `gap`, per-node `padding`), how to write a widget, and the roadmap (autolayout, sprites).

### ECS (`src/ecs.zig`, `src/world.zig`)

A [Bevy](https://bevyengine.org)-inspired ECS over a sparse-set `World` (the ergonomics are modelled on Bevy; the storage is comptime-Zig, not Rust archetypes — see the `ecs.zig` module doc).

- **World**: one `SparseSet` per component/tag type, generated at comptime from the public decls of `components.zig` / `tags.zig`. API: `spawn(bundle)` (bundle = tuple of component **instances** + bare **tag types**), `add`, `remove`, `get`, `has`, and `despawn(e)` (clears `e` from every storage; ids are never recycled — `next_id` only climbs).
- **System params** (declared as a system fn's parameter types, built by `ecs.run` via comptime introspection): `Query(.{…})` iterates matches; `Single`/`MaybeSingle` expect exactly-one / zero-or-one. Inside the param tuple: bare component types are **fetches** (drive iteration, yield `*T`); `With(T)`/`Without(T)` filter; `Maybe(T)` yields `?*T`; and `Entity` yields the entity id (Bevy-style — doesn't drive iteration). A system may also take `*Resources` or `*World` directly.
- **Structural changes** (`add`/`remove`/`despawn`/`spawn`) currently go through a raw `*World` system param. A Bevy-style deferred `Commands` buffer is intentionally **not** built yet — see the rationale + trigger in memory (`project_commands_deferred`). Two consequences to respect when writing systems: (1) mutating the storage you're iterating is unsafe — collect ids first, then apply (see `despawn_dead`); (2) an entity that can be despawned must be read with `MaybeSingle`, not `Single`, or the UI build will panic once it's gone.
- **Energy/death pipeline**: `update_energy` decays `Energy.v`→0 (the player's actions in `build_ui` push it back up); `update_stamina` trickles `Stamina.v` up passively; `mark_dead` (queries `Entity, Energy`) tags it `Dead` at zero; `despawn_dead` (queries `Entity, Dead`) reaps it. This is the live game loop, not a demo — the actor's death ends the run.

### Supporting Modules

- `src/components.zig` / `src/tags.zig` — ECS component & tag types. Only `pub const <Name> = struct {…}` type decls allowed (the `World` enumerates them at comptime). Components: `Energy` (survival stock + currency, decays, 0 = perish; `{ v, start, decay }` — `decay` in units/s, raised by capital upkeep), `Stamina` (bounded `0..max` capacity that scales action quality; `{ v, max, trickle }`), `Capital` (owned-goods bitset; `{ owned: u32 }`). Tags: `Player`, `Dead`.
- `src/world.zig` — sparse-set ECS `World` (see the ECS section above)
- `src/ecs.zig` — `ecs.run(world, res, system)` + the Bevy-style param machinery (see the ECS section + the module doc)
- `src/systems.zig` — sim systems. Convention: `update_<component_snake_case>` drives one component (`update_energy`, `update_stamina`), plus the death systems (`mark_dead`, `despawn_dead`)
- `src/font.zig` — `TextData` (text buffer the UI caches and renders); leaf data module
- `src/res.zig` — `Resources` (font, renderer, window, time, input, `prng`); the host bundle, held by `Ctx` as `*Res` and passed to systems. `res.random()` is the sim's single source of chance (uncertain action outcomes today; AI deciders later)
- `src/root.zig` — library root, re-exports `sdl`, `ui`, `widgets`, `comp`, `tag`, `font`, `res`, `world`, `ecs`, `systems`

### Assets

- `assets/fonts/` — Kenney TTF font variants (Mini Square used at 24pt)
- `assets/hello.png` — test image asset
- `assets/icons.png` — capital-good icon sprite sheet (2×2 grid of 512px cells: fishing rod, sandals / bed, fireplace)
