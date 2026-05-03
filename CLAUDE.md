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

`App` owns all state. `App.init()` handles SDL/window setup only. `App.setup()` is called once after `App` is stable on the stack — it initialises fonts, resources, game objects, and persistent UI nodes (safe because all internal pointers are set after the struct address is fixed).

Each frame:
1. **Events** — SDL3 event poll; clicks are queued as `PendingClick`
2. **Update** — advances `Objects` (counters, timers) and formats their `TextData`
3. **Build UI** — arena reset, `build_ui()` constructs a fresh node tree
4. **Layout** — `root.set_global_pos()` resolves all positions
5. **Dispatch** — queued click hit-tested against the tree
6. **Render** — `ui.render()` walks the tree and draws

`App` fields:
- `obj: Objects` — game state + `TextData` for each display value
- `ui_widgets: UIWidgets` — persistent leaf nodes (El, Button)
- `resources: res.Resources` — font, renderer, window (passed as `*anyopaque` ctx to layout/render)
- `frame_arena` — reset each frame; used for all ephemeral node allocations

### UI System (`src/ui/`)

#### Node (`src/ui/root.zig`)

The atomic unit. Each `Node` has two independent feature sets:

- **`size: ?Size`** — intrinsic identity: `calc` function, `data_width/height`, `width/height`, `padding`. Set once at widget init, never touched in layout.
- **`layout: ?Layout`** — positional context: `anchor`, `children_align`, `_global_x/y`. Set each frame in `build_ui`.

Nodes are either **persistent** (leaf nodes stored in `UIWidgets`, no children) or **ephemeral** (container nodes arena-allocated each frame with children added per frame).

Builder methods: `with_size`, `with_layout`, `with_onclick`, `with_render`, `with_data`.

Free functions: `dispatch_click(root, mx, my, button)`, `render(root, ctx)`.

#### Features (`src/ui/features/`)

- `size.zig` — `Size`, `Padding`, `static_calc_size`, `recalculate_size`
- `layout.zig` — `Layout`, `Anchor`, `ChildrenAlign`, `ChildrenPosInfo`, `set_global_pos` and all layout algorithms
- `clickable.zig` — `OnClick`, `ClickEvent`, `MouseButton`
- `renderable.zig` — `OnRender`
- `root.zig` — re-exports all of the above

`Anchor`: 9 fixed positions (`top_left`, `center`, `top_right`, etc.) or `relative` (parent controls position via `ChildrenAlign`). Fixed-anchor nodes position themselves; `relative` nodes are positioned by their parent's `ChildrenAlign` logic.

`ChildrenAlign`: `horizontal`, `vertical`, `vertical_right`, `centered`, `centered_wrapped`, and their `_wrapped`/`_reverse` variants.

### Widget System (`src/widgets.zig`)

Three levels of abstraction:

**Features** — raw builder calls on `Node` (`with_size`, `with_onclick`, etc.)

**Primitives** — single persistent node, set up once in `App.setup()`:
- `El.init(id, data, data_type)` — minimal renderable: size + render + data
- `Button.init(id, on_click, data, data_type)` — `El` + onclick

`DataType` enum selects the render/size function pair: `.text` (dynamic `TextData`), `.text_static` (`TextDataStatic`), `.sprite` (future).

**Components** — functions returning `*Node` (ephemeral, arena-allocated). Take persistent leaf nodes + any needed params, build a mini node tree, return its root. Called inside `build_ui` and composed via `add_child`:
```zig
try root.add_child(fa, try widgets.slider(fa, &w.track, &w.thumb, layout));
```

`UIWidgets` stores only primitives (El, Button). Components are stateless functions.

### Supporting Modules

- `src/time.zig` — `Counter` (f32 accumulator), `Timer` (countdown), `Accumulator(T)` (generic)
- `src/font.zig` — `TextData` (dynamic text + SDL surface cache), `TextDataStatic` (fixed text), color constants
- `src/res.zig` — `Resources` struct (font, renderer, window); shared context passed as `*anyopaque` to all render/size callbacks
- `src/root.zig` — library root, re-exports `sdl`, `ui`, `widgets`, `time`, `font`, `res`

### Assets

- `assets/fonts/` — Kenney TTF font variants (Mini Square used at 24pt)
- `assets/hello.png` — Image asset
