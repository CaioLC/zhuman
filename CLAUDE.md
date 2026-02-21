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

**Human Action** is a Zig/SDL3 interactive application framework centered on a custom UI layout engine.

### Main Loop (`src/main.zig`)

The application runs at 60 FPS using SDL3. Each frame calls:
1. `events()` — processes SDL3 events (quit, resize, keyboard, mouse)
2. `update()` — advances game objects (Counter, Timer) with delta time
3. `update_ui()` — recalculates UI node positions and updates SDL3 text surfaces
4. `render()` — walks the UI node tree and draws everything

`setup_ui()` builds the initial UI tree at startup. `text_node()` is a helper for creating text-based nodes with an SDL3 TTF surface.

### UI Layout Engine (`src/ui.zig`)

The core of the project. Nodes form a tree where each `Node` has:
- An `Anchor` enum — either one of 9 fixed positions (top_left, center, bottom_right, etc.) relative to the parent, or `relative` meaning the **parent** controls its position via `ChildrenAlign`
- A `ChildrenAlign` mode that determines how `relative`-anchored children are arranged: `horizontal`, `vertical`, `centered`, and their `_wrapped` and `_reverse` variants
- A `size` and optional SDL3 `surface` for rendering

**Key distinction:** Nodes anchored at a fixed point (`top_left`, `center`, etc.) are *independent* — they position themselves relative to their parent. Nodes with `relative` anchor are *dependent* — they are positioned by their parent's `ChildrenAlign` logic. `add_child()` automatically classifies and places new children in the correct list.

Position resolution happens recursively via `set_global_pos()` → `set_indep_global_pos()`. The `collect()` method flattens the tree into a render list. `get_id()` finds a node by ID.

### Supporting Modules

- `src/time.zig` — `Counter` (incremental) and `Timer` (countdown) utilities, updated with delta time each frame
- `src/font.zig` — Font color constants (e.g., `font.white`)
- `src/root.zig` — Library root that re-exports `sdl`, `ui`, `time`, `font`

### Assets

- `assets/fonts/` — Kenney TTF font variants (Mini Square used at 24pt)
- `assets/hello.png` — Image asset
