# UI Building Language — Migration Plan & Discussion Log

> Status: **planning only, no code changes yet.** Captured 2026-05-29, updated 2026-05-30.
> Inspiration: Ryan Fleury, "UI Part 3: The Widget Building Language"
> (https://www.dgtlgrove.com/p/ui-part-3-the-widget-building-language)
> NOTE: we are *adapting* Fleury, not copying. We take his **key-cache persistence**
> and **immediate-mode** ideas, and **reject his flags architecture** (see Fork 4).

## Goal

Move the UI from the current **retained, manually-declared** model toward an
**immediate-mode building language adapted to this codebase**: widgets built inline every
frame, persistence handled by a key-cache, behavior composed from **per-widget functions +
the node's optional feature fields** (NOT Fleury's flags bitmask).

The trigger: dissatisfaction with the boilerplate of wiring UI elements — every
persistent widget today is (a) a named field in `UIWidgets`, (b) init'd in `setup()`,
(c) `wire()`'d, and (d) manually re-parented each frame in `build_ui`. Four touch-points
per widget, with a hard split between `setup` and `build_ui`.

---

## Current architecture (baseline, as of this discussion)

- `Node` (src/ui/root.zig) has two optional feature sets: `size: ?Size`, `layout: ?Layout`,
  plus `on_click`, `on_render`, `data: ?*anyopaque`.
- Persistent leaf widgets (`El`, `Button` in src/widgets.zig) stored as named fields in
  `UIWidgets`; ephemeral containers arena-allocated each frame in `build_ui`.
- `DataType` enum (`.text`, `.sprite`) selects render/size fn pairs.
- Clicks: `OnClick` fn pointer wired at `setup()`, fired in a separate `dispatch_click`
  pass after layout (e.g. `reset_counter`).
- Context: `*Resources` (font/renderer/window) threaded as `*anyopaque` into
  `set_global_pos` and `render`. **Build time receives no context.**
- ECS exists: systems take `*Resources` + `Query`/`Single`/`MaybeSingle` params,
  run via `ecs.run(&world, &resources, system)`. Only one system so far: `update_counter`.

---

## The three forks (resolved)

### Fork 1 — builder-state context → RESOLVED
Global-vs-explicit was never a real fork (codebase already uses explicit pointers). The
builder state (cache/pools + frame index + parent seed) lives in a `Ui` struct. Resolution
of *what reaches what*, by phase:

- **`Ui` holds `*Resources`** (one-directional, no cycle). Resources stays a leaf — we do
  NOT invert it to hold `*Ui`.
- **Render/size pass** (generic `ui` module callbacks): `ctx` = **`*Ui`** only. Reaches the
  pools (to resolve `node.state`) and Resources (font/renderer). **Read-only draw pass — no
  World access.** Immediate-mode dataflow: build reads World → writes cached state → render
  just draws the cached state, so render never needs World.
- **Build pass** (game-side widget fns, the Fork-2 system): **thread `*World` + `*Ui` as two
  explicit params** (decided over bundling a `Build` struct). Full read/write of World +
  Resources + cache happens here, in statically-typed game code — no `*anyopaque`.
- Build is a **single call site** at the fixed schedule slot — call `ui_build(&world, &ui)`
  directly; no need to route through `ecs.run`'s param extraction.

### Fork 2 — does UI build become a world-mutating system? → CONFIRMED YES
Immediate mode reads input inline at build time, collapsing the time/place gap the
callback existed to bridge. So `if (ui.button(...).clicked) c.v = 0;` replaces the
`OnClick` fn pointer + `dispatch_click` pass entirely.
**Decision (ratified):**
- UI build runs as a **system with `*World` read/write access** and mutates components inline.
- **No command/intent queue by default** — that would reintroduce the exact indirection
  immediate mode removes.
- Discipline: run the UI at **one fixed slot** in the schedule so mutations are ordered
  predictably relative to sim systems.
- Command queue only as a **per-action escape hatch** if a specific action later needs
  validation/replay/networking.
- Revisit if `build` becomes a wall of mutating `if`s (legibility loss — "what changes
  Money?" stops being answerable from the system list).

### Fork 3 — layout strategy → SYNTHESIS (keep both)
Current `Anchor` (9 presets + `relative`) = Unity **RectTransform anchors**;
`ChildrenAlign` = Unity **Layout Groups**. Both already reimplemented.
Fleury's **autolayout** (semantic size) is a different, orthogonal thing: it *negotiates*
sizes from content + parent + siblings via a constraint solve, where current layout only
*places* boxes whose sizes are mostly fixed (`recalculate_size` is post-order but
containers ignore their children — `left_panel` is hardcoded `initFixed(300,600)`).
**Decision:** keep anchors for macro composition (panels pinned to screen regions) and add
autolayout sizing for interiors. NOT web layout — centering stays as trivial as the
`center` anchor. This is a separate track from the building-language migration.

### Fork 4 — flags vs widget functions → REJECT FLAGS, USE FUNCTIONS
Fleury needs `WidgetFlags` because he has ONE uniform `Box` + a generic core that varies
behavior by reading bits. We don't: our `Node` already has optional feature fields
(`size`, `layout`, `on_click`, `on_render`) which are **strictly better than flags** — each
carries its *payload* (the handler, the calc fn), not just a bit. We already gate on them
exactly like Fleury gates on flags (`if (node.on_click) |oc| ...`).

**Decision:**
- **Drop flags entirely** — redundant with the `?Feature` fields we already have.
- Behavior-variation lives in **which widget function you call and what it wires**:
  `button()` wires bg+border+text render + on_click; `label()` wires text-only render.
  "DrawBorder" is not a flag and not a field — it's just what that widget's render callback
  draws. No flag-switch in any core.
- **`UIWidgets`, `El`, `Button`, `DataType` all dissolve into widget functions.**
- Tradeoff accepted: slightly more per-widget code than Fleury's thin flag-OR wrappers, in
  exchange for self-contained, readable widgets and no monolithic core. Right trade for a
  curated game-UI widget set (slider, dropdown, label, button); flags only win at hundreds
  of uniform variants.

### Widget-function model (the replacement for UIWidgets)
Complex elements (slider, dropdown) and leaves (label, button) are **functions** that:
1. take the `*Ui` context (+ an explicit key, + whatever value/state they bind),
2. **self-serve persistent state from the key-cache** (`ui.cache(key, T)`) — drag state,
   `TextData` surface cache, last-frame rect for hit-testing,
3. build an **ephemeral arena node-tree**, wiring the `?Feature` fields,
4. read input inline via `comm` and mutate the bound value/world (Fork 2),
5. return the root `*Node`, composed by the caller via `add_child`.

Before (today's pattern — persistent leaf nodes pre-wired in `UIWidgets`, passed in):
```zig
try root.add_child(fa, try widgets.slider(fa, &w.track, &w.thumb, layout));
```
After (self-serves persistent state from cache by key; sub-nodes created ephemerally):
```zig
try root.add_child(fa, slider(ui, "volume", &vol));
```

### Decisions for the widget-function model
1. **Cache shape → RESOLVED: pools + handles, one pool per type, comptime-selected.**
   `ui.cache(key, comptime T) Handle(T)` (a `u32` index), backed by a `Pool(T)` per type:
   ```zig
   fn Pool(comptime T: type) type {
       return struct {
           slots: std.ArrayList(struct { value: T, key: u64, touched: u64 }),
           free:  std.ArrayList(u32),   // free-list of holes, reused on insert
       };
   }
   ```
   A per-type `HashMap(u64 → u32 index)` maps key → slot. Rejected: uniform `Box` union (the
   monolith), and boxed pointers (works, but worse locality + reshapes `node.data` anyway).
2. **Keying & composition → RESOLVED: rolling hash with parent seed.**
   Chosen over path-strings (which allocate per node per frame). Key type at the pool
   boundary is `u64`; hashing happens once when the key is formed, never a string-compare.
   The human-readable `id` stays on `node.id` for debugging only.
   ```zig
   const ROOT_SEED: u64 = 0;
   fn key(seed: u64, id: []const u8) u64 { return std.hash.Wyhash.hash(seed, id); }
   fn key_i(seed: u64, id: []const u8, i: usize) u64 {            // loop instances
       return std.hash.Wyhash.hash(key(seed, id), std.mem.asBytes(&i));
   }
   ```
   **The rule:** every widget fn takes `(seed, id)`, computes `k = key(seed, id)` as its own
   identity (and pool key), and passes `k` as the seed to its children. Loops pass a unique
   per-iteration seed via `key_i(parent, "item", i)`.
   Properties: reparenting → new seed → new key → fresh state (usually desired). Escape hatch
   for state that must survive moves: use a fixed `key(ROOT_SEED, "global_id")` ignoring the
   parent seed (≈ Fleury's `###`).
3. **Pointer stability → RESOLVED: handles (slot map), not pointers.** Store an *index*, not a
   `*T`; dereference through the live pool (`pool.slots[i]`), so realloc-on-grow is a non-event
   (`ArrayList.items.ptr` is the single auto-updated base). Removal must **never compact** —
   freed slots become holes in the free-list, so live indices never move. **No generation
   counters needed**: the node tree is ephemeral (handles re-fetched each frame via `ui.cache`)
   and pruning happens at the frame boundary, so no live handle ever spans a removal — only
   intra-frame index stability is required, which holes-don't-move guarantees.
   (Distinct from *key* stability = deterministic hash, which is free.)
4. **Pruning semantics.** Untouched-this-frame → slot freed into the free-list next frame
   (closed dropdown loses its state — usually correct). Needs an opt-out only if some state
   must survive while not built.

### Struct & plumbing consequences of pools + handles
- **Remove `with_data` and `node.data: ?*anyopaque`.** Replace with `node.state: ?u32` — a
  type-erased handle (pool index). Set *internally* by the widget fn (which already got it
  from `ui.cache`), not via a public chainable builder.
- **Render/size callbacks resolve through the pool**, supplying the type themselves:
  `ui.pool(TextData).slots[node.state].value`. Node provides the *index*, callback the *type*.
- **`ctx` becomes `*Ui`** (which holds `*Resources`), threaded into `set_global_pos`/`render`
  so callbacks can reach the pools. This also gives build-time the context Fork 1 noted it lacked.
- Pure layout containers (row/panel, no persistent state) never call `ui.cache` → `state` stays
  `null`. The capability is universal; usage is opt-in per widget.

---

## Plan — three independent tracks

### Track A — Migrate to the building language (dependency-ordered)
1. **Frame index + key-cache foundation.** Add `u64` frame counter to main loop. Build `Ui`
   holding **per-type `Pool(T)` slot maps + per-type `HashMap(u64 → u32)`** (decisions #1, #3),
   keyed by deterministic `hash(parent_seed, id)`. `ui.cache(key, T) Handle(T)`. Free-list
   pruning at frame boundary. Thread `ctx` as `*Ui`. *Nothing visible changes — substrate.*
2. **Widget functions + cache-backed state (replaces the old "flags" step).** Dissolve
   `El`/`Button`/`DataType`/`UIWidgets` into widget functions that self-serve persistent
   state from the cache and build ephemeral node-trees (see Widget-function model above).
   Settle the keying/composition convention (open decision #2).
3. **Comm + inline build.** Add `comm_from(entry) → { clicked, hovering, … }` (hit-test moves
   *into* the widget fn, against last frame's cached rect). Delete `OnClick`,
   `reset_counter`, `dispatch_click`. UI runs as a world-mutating system (Fork 2).

### Track B — Autolayout sizing (independent; whenever)
1. Add `ChildrenSum` + `PercentOfParent` as `Size.calc` variants.
2. Add `strictness: f32` to `Size`.
3. Insert one **violation-resolution pass** between sizing and positioning: overflow shrinks
   children proportionally to strictness. Bounded extension of `recalculate_size`, not a rewrite.

### Track C — Housekeeping (trivial)
- Commit or discard the uncommitted cosmetic `zig fmt` diff in `main.zig` + the
  `settings.local.json` tweak, so the migration starts from a clean tree.

---

## Suggested first move (for next session)
Start **Track A · Step 1** (the key-cache). It's the substrate everything else needs and
changes nothing visible, so it's the safest first commit. Fork 2 is already confirmed, so
the path to Step 3 is unblocked.
