# UI Building-Language Migration — Implementation Plan

> Actionable, ordered build plan for Track A. **Rationale & decisions** live in
> `docs/ui-building-language-plan.md` — read that for *why*; this file is the *what/how*.
> Each step is staged to **compile and run on its own** → one commit per step.
> Verify each step with: `zig build`, `zig build test`, `zig build run`.

## Locked decisions (summary — see design doc for reasoning)
- **Reject Fleury's flags.** Behavior lives in widget *functions* + the node's `?Feature` fields.
- **`UIWidgets`/`El`/`Button`/`DataType` dissolve** into cache-backed widget functions.
- **Persistence = pools + handles.** One `Pool(T)` per cached type; `ui.cache(key, T) → u32` index.
  Slot-map with free-list (never compact); no generation counters (handles re-fetched each
  frame, prune at frame boundary).
- **`node.data: ?*anyopaque` → `node.state: ?u32`** (type-erased handle). `with_data` removed.
  Render/size callbacks resolve `ui.pool(T).get(node.state)`, supplying `T` themselves.
- **Keying = rolling hash:** `key(seed, id) = Wyhash.hash(seed, id)`; `key_i` folds a loop index.
  Rule: every widget fn takes `(seed, id)`, computes its own `k`, passes `k` as the seed to
  its children. `u64` at the pool boundary; `node.id` kept as a readable string for debug.
- **Context/reach:** `Ui` holds `*Resources` (one-directional, no cycle). Render/size ctx =
  `*Ui` (read-only). Build threads `*World` + `*Ui` explicitly; called directly at a fixed slot.
- **Clicks (Fork 2):** immediate-mode `Comm` read inline at build; build is a world-mutating
  system; no command queue. `OnClick`/`dispatch_click` deleted.
- **`Ui`/`Pools` are parametrized** over a state-registry namespace, bound concretely in
  `src/root.zig` (keeps generic `ui` from importing `font`; avoids circular dep).
  - *Refinement during impl:* `Ui` is parametrized over **both** `StateNs` **and** the `Res`
    type (`ui.Ui(StateNs, Res)`), so the generic `ui` module imports neither `font` nor `res`.
    The concrete binding `pub const Ui = ui.Ui(UiState, Resources)` lives in **`widgets.zig`**
    (re-exported from `root.zig` as `ha.Ui`), and the text render/size callbacks will move
    there in Step 2 so `font.zig` stays a leaf data module (breaks the font↔ui cycle).

---

## Step 0 — Clean the tree (Track C)
- [x] Commit or discard the `zig fmt` whitespace diff in `src/main.zig` + `.claude/settings.local.json`.
- *Commit:* `chore: zig fmt`

## Step 1 — Cache substrate (additive; build & output unchanged)
Nothing is wired into rendering yet, so this cannot change visible behavior.

- [x] **New `src/ui/cache.zig`:**
  - `pub fn key(seed: u64, id: []const u8) u64` (Wyhash); `pub fn key_i(seed, id, i: usize) u64`.
  - `pub fn Pool(comptime T: type) type`:
    - `slots: std.ArrayList(struct { value: T, key: u64, touched: u64 })`
    - `free: std.ArrayList(u32)`
    - `index: std.AutoHashMapUnmanaged(u64, u32)`  (key → slot)
    - `acquire(alloc, key: u64, frame: u64) u32` — return existing slot (set `touched`) or
      reuse a hole / append a new slot; insert into `index`.
    - `get(idx: u32) *T`  (deref `slots.items[idx].value` — never hold across another `acquire`)
    - `prune(frame: u64)` — slots whose `touched != frame` → push idx to `free`, remove from `index`.
    - `deinit(alloc)`.
  - `pub fn Pools(comptime ns: type) type` — comptime struct of `Pool(T)` per decl in `ns`
    (mirror `World.Storages`), with `poolOf(comptime T) *Pool(T)`, `cache(key, T, frame) u32`,
    `pruneAll(frame)`, `deinit`.
- [x] **New `src/ui/ui.zig`:** `pub fn Ui(comptime StateNs: type) type` holding
  `res: *Resources`, `frame: u64`, `pools: Pools(StateNs)`, `gpa: Allocator` (persistent,
  for pools), `arena: Allocator` (per-frame node tree). Methods: `cache(key, T) u32`
  (→ `pools.cache(key, T, frame)`), `pool(T) *Pool(T)`, `beginFrame()` (`frame += 1`),
  `endFrame()` (`pools.pruneAll(frame)`), `deinit`.
- [x] **`src/ui/root.zig`:** re-export `cache` helpers + `Ui`.
- [x] **`src/root.zig`:** bind the concrete Ui where both `ui` and `font` are visible:
  ```zig
  pub const UiState = struct { pub const TextData = font.TextData; };
  pub const Ui = ui.Ui(UiState);
  ```
- [x] **`src/main.zig`:** construct the `Ui` instance in `App` (pass `&self.resources`, gpa,
  frame-arena allocator). Leave it dormant — not yet used by render. Add `deinit`.
- [x] **Tests in `cache.zig`:** same key twice → same idx; distinct keys → distinct idx;
  `prune` frees an untouched slot; a freed slot is reused on next `acquire`; a value written
  to slot A survives an `acquire` of key B that grows `slots` (pointer-stability via index).
- **Acceptance:** `zig build test` green; `zig build run` visually identical.
- *Commit:* `feat: ui key-cache (pools + handles), not yet wired`

## Step 2 — Data layer → pools+handles; ctx → `*Ui`; widget functions (output unchanged)
Coupled changes — land together.

- [x] **`src/ui/root.zig` — Node:** replace `data: ?*anyopaque` with `state: ?u32`; remove
  `with_data`. (Set `state` directly inside widget fns.)
- [x] **ctx value becomes `&ui`.** Keep callback signatures `*anyopaque`; they cast to `*Ui`
  instead of `*Resources`. No signature changes to `set_global_pos`/`render`/`Size.calc`/`OnRender`.
- [x] **`src/font.zig` — TextData:** `calc_size`/`render_text` cast ctx → `*Ui`; resolve
  `const td = ui.pool(TextData).get(node.state.?)`; draw via `ui.res.font` / `ui.res.renderer`.
- [x] **`src/widgets.zig`:** delete `El`, `Button`, `Data`, `DataType`, `wire_data_node`. Add:
  - `pub fn label(ui: *Ui, seed: u64, id: []const u8, text: []const u8) *Node` —
    `k = key(seed,id)`; `idx = ui.cache(k, TextData)`; `ui.pool(TextData).get(idx).update(text)`;
    create node from `ui.arena` with `id`, `with_size(TextData.calc_size)`,
    `with_render(TextData.render_text)`, set `node.state = idx`; return node.
  - `pub fn button(ui, seed, id, text, on_click) *Node` — `label` + `with_onclick`.
    (Click model still OnClick in this step; changes in Step 3.)
- [x] **`src/main.zig`:**
  - Delete `UIWidgets`, its `App` fields, `wire()`, and the persistent widget inits in `setup()`.
  - `build_ui` → builds inline by calling `label`/`button` with seeds from `ROOT_SEED`,
    composing via `add_child`. Read `world.get(player, Counter)` and pass the formatted string
    into the counter's `label`/`button` (replaces `ui_widgets.counter.data.text.update`).
  - Pass `&ui` as the ctx into `set_global_pos` and `render`.
  - Wrap the build in `ui.beginFrame()` … `ui.endFrame()`.
- **Acceptance:** `zig build test` green; `zig build run` visually identical to before.
- *Commit:* `feat: cache-backed widget functions; drop UIWidgets/El/Button`

## Step 3 — Comm + inline build; delete callbacks (Fork 2)
- [x] **Input:** in `main.zig`, feed mouse position + button-down into `ui.input` each frame
  (replaces `pending_click`). Add an `input` field to `Ui`.
- [x] **Rect persistence:** after `set_global_pos`, store each interactive node's resolved
  rect into its pool slot so next frame's build can hit-test last frame's rect.
  - *Sub-decision (decide here):* add `rect` to interactive widgets' state vs a shared small
    state pool keyed by widget key.
- [x] **`Comm`:** `pub const Comm = struct { clicked: bool, hovering: bool, ... }`;
  `ui.comm(key) Comm` looks up the widget's last-frame rect and tests it against `ui.input`.
- [x] **`button`:** drop the `on_click` param; return `Comm`.
- [x] **Delete:** `OnClick` usage, `dispatch_click` (`ui/root.zig`), `reset_counter` (`main.zig`),
  `pending_click`. Trim `clickable.zig` to just `MouseButton` (used by input) if anything remains.
- [x] **build:** `if (button(ui, s, "counter", txt).clicked) { c.v = 0; c.buffer = 0; }` —
    inline mutation of the `Counter` via `world.get`. `build` now takes `*World`.
- **Acceptance:** `zig build test` green; counter increments and resets on click in `zig build run`.
- *Commit:* `feat: immediate-mode comm + inline clicks; drop OnClick/dispatch`

### Decisions made during Step 3
- **Rect storage → shared `Rect` pool keyed by widget key** (not a field on per-widget state).
  `Node` gains `key: ?u64` (non-null only for interactive widgets); `capture_rects` walks the
  tree post-layout and writes each keyed node's rect into the `Rect` pool. `comm(u, k)` reads it.
- **Widgets attach to a parent** (`label`/`button` take `parent: *Node`, set `.relative`, and
  `add_child` themselves) rather than returning `*Node` for the caller to wire. This lets
  `button` return `Comm` for the intended inline `if ((try button(..)).clicked)` ergonomics.
- **`acquire` zero-initializes new slots** (`std.mem.zeroes`) so first-frame `comm` reads an
  empty rect (no false hit) and fresh `TextData` reads as empty.
- **`Node.on_click` removed; `Input` added to `Ui`.** `clickable.zig` trimmed to `MouseButton`.

---

## Risk / watch-list
- Pool memory lives on `gpa` (freed in `Ui.deinit`), NOT the frame arena.
- Widget fns allocate nodes from `ui.arena`; `App` already resets `frame_arena` each frame —
  confirm `Ui.arena` points at it.
- Never hold a raw `*T` from `pool.get()` across another `acquire` on the same pool (it may
  grow/realloc). Store the `u32` index; deref at point of use.
- Wyhash is deterministic across runs — keys are stable. Good.

## Out of scope (separate tracks)
- **Track B — autolayout sizing** (`ChildrenSum`, `PercentOfParent`, `strictness`, violation pass).
- **Sprites** — old `.sprite` stub dies with `Data`; reintroduce as a widget fn + state type later.
