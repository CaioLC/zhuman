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

**Human Action** is a Zig/SDL3 application built around a custom immediate-mode UI layout engine. The node tree is rebuilt from scratch every frame using a per-frame arena allocator.

### Main Loop (`src/main.zig`)

`App` owns all state. `App.init()` handles SDL/window setup only. `App.setup()` is called once after `App` is stable on the stack — it initialises the font, `Resources`, the ECS `World` (spawning the player entity), the per-frame arena, and the UI context (`UiCtx`, safe because internal pointers are set after the struct address is fixed).

Each frame:
1. **Events** — SDL3 event poll writes host input into `resources.input`; a left-click calls `ui.mark(.clicked, x, y)`
2. **Mark** — `ui.mark(.hovering, x, y)` hit-tests last frame's interaction-slot rects and sets flags (iterates the slot pool — no tree walk)
3. **Update** — `ecs.run(&world, &resources, system)` advances sim systems
4. **Build UI** — `ui.beginFrame()`, arena reset, `build_ui()` constructs a fresh node tree (reads cache + world, mutates components inline on interaction)
5. **Layout** — `root.set_global_pos()` solves sizes (per-axis `SizeRule`: fixed/content/pct_of_parent/fit_children) then resolves all positions; pure (no host callback — content is host-measured at build into `data_*`)
6. **Stamp** — `ui.stamp_rects(root)` copies each queried node's resolved rect into its interaction slot, feeding next frame's mark (step 2)
7. **Render** — userland render loop in `main.zig`: `root.iterate()` walks the tree and draws each node by its `render_flags` (e.g. `if (node.render_flags.text) widgets.draw_text(...)`); then `ui.endFrame()`

Key `App` fields: `resources: res.Resources`, `world`, `player`, `ui: widgets.UiCtx`, `frame_arena` (reset each frame). No retained `prev_root` — the interaction slot pool bridges the frame boundary instead.

### UI Engine (`src/ui/`) and widgets (`src/widgets.zig`)

A standalone, immediate-mode UI building language: the node tree is rebuilt every frame from the arena; persistence (text caches, interaction state) lives in a key-addressed cache. The engine is generic (`Ctx(StateNs, IntFlags, Res)` + `Node(RenderFlags)`) and imports nothing from the game — including rendering, which is host policy: core stores the tree + node `data`/`render_flags` and exposes `root.iterate()`, but draws nothing. `src/widgets.zig` is the host's concrete binding (`UiCtx = ui.Ctx(UiState, Interaction, Resources)`, `Node = ui.Node(RenderFlags)`) plus the keyed-data mixin (`data_text`), draw primitives (`draw_text`/`draw_fill`/`draw_outline`), and widget functions (`label`, `progress_bar`) that own a node's whole subtree — graph, keyed data, and layout. Nodes are built with core `Node.create` / `Node.pcreate` (create + bind to parent, finalizing the key). `build_ui` reads top-to-bottom as **globals → queries → node graph**: the host hand-builds the structural nodes and configures each one inline at creation, then calls widget functions for the content; there's no separate deferred layout pass. Interaction flags (`Interaction`) and render flags (`RenderFlags`) are host-defined types passed into the engine.

**See [`src/ui/README.md`](src/ui/README.md) for the full architecture** — Node/features, the key-cache (pools + handles), interaction (slot-based hit-testing, transient vs latched flags, lazy slots), layout (`Anchor` + `ChildrenAlign`), how to write a widget, and the roadmap (autolayout, sprites).

### Supporting Modules

- `src/components.zig` / `src/tags.zig` — ECS component & tag types (e.g. `Counter`, `Player`)
- `src/world.zig` — sparse-set ECS `World` (`spawn`, `add`, `get`)
- `src/ecs.zig` — `ecs.run(world, res, system)` + Bevy-style `Query`/`Single`/`MaybeSingle` params
- `src/systems.zig` — systems (e.g. `update_counter`)
- `src/font.zig` — `TextData` (text buffer the UI caches and renders); leaf data module
- `src/res.zig` — `Resources` (font, renderer, window, time, input); the host bundle, held by `Ctx` as `*Res` and passed to systems
- `src/root.zig` — library root, re-exports `sdl`, `ui`, `widgets`, `comp`, `tag`, `font`, `res`, `world`, `ecs`, `systems`

### Assets

- `assets/fonts/` — Kenney TTF font variants (Mini Square used at 24pt)
- `assets/hello.png` — Image asset
