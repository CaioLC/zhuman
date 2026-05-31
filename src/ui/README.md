# UI Engine

A small **immediate-mode UI building language** in Zig. The node tree is rebuilt
from scratch every frame; persistence (text caches, interaction state, …) lives
in a key-addressed cache, not in the tree. Adapted from Ryan Fleury's
[*UI Part 3: The Widget Building Language*](https://www.dgtlgrove.com/p/ui-part-3-the-widget-building-language)
— we take his **key-cache persistence** and **immediate-mode** ideas and **reject
his flags bitmask** in favor of per-widget functions + a node's optional feature
fields.

## Design philosophy

- **Immediate mode.** Widgets are *functions called during build*, not retained
  objects you wire once and mutate. A widget returns its `*Node`; you read
  interaction off it and act inline — `if (btn.query(u).clicked) counter = 0;` —
  no callbacks, no command queue.
- **The tree is ephemeral; the cache is persistent.** Every frame the tree is
  arena-allocated fresh. Anything that must survive between frames (a text
  surface, a widget's interaction state) is stored in a `Pool(T)` keyed by a
  stable hash, and addressed by a `u32` handle — never a raw pointer.
- **Mechanism vs policy.** The engine provides *mechanism* (store geometry, walk
  the tree, hit-test a point, flag a node). What that means — what a "click" is,
  what to do about it, where input comes from — is *policy* and lives in the host.
  **The generic engine never reads the host's `Resources`.**

## Extraction boundary (this folder is the reusable part)

Everything in `src/ui/` is **engine** and imports nothing from the game. It's
parametrized so the host plugs its own types in:

```zig
Ui(comptime StateNs: type, comptime Res: type)
```

- `StateNs` — a namespace of the state types the host wants cached (one
  `Pool(T)` is generated per declaration).
- `Res` — the host's resource bundle (fonts, renderer, input, …). The engine
  holds a `*Res` opaquely and never touches its fields; only host callbacks do.

The host supplies, *one layer up* (today `src/widgets.zig` + `src/res.zig`):
the concrete binding `pub const Ui = ui.Ui(UiState, Resources)`, the widget
functions, the render/size callbacks, and `Resources` itself. To lift this into
its own project, take `src/ui/` as-is; `widgets.zig`/`res.zig` are the template
for how a host binds it.

## Module map

| File | Responsibility |
|---|---|
| `root.zig` | `Node` (the tree atom) + free tree-walks: `render`, `mark_at`. Re-exports everything. |
| `ui.zig` | `Ui(StateNs, Res)` — per-frame builder state: pools, `*Res`, arena, frame counter, interaction store. |
| `cache.zig` | `Pool(T)` slot-map (handles + free-list), `Pools(ns)` generator, `key`/`key_i` hashing. |
| `geometry.zig` | `Rect` + pure `contains(x, y)`. Leaf, no deps. |
| `interaction.zig` | `Interaction` flag set + `Flag` enum. Leaf, no deps. |
| `features/size.zig` | `Size` (intrinsic: calc fn, width/height, padding), `recalculate_size`. |
| `features/layout.zig` | `Layout` (`Anchor` + `ChildrenAlign`), `set_global_pos` and the placement algorithms. |
| `features/renderable.zig` | `OnRender` callback wrapper. |

## The frame lifecycle

The host loop drives the engine in a fixed order (`src/main.zig`):

```
1. poll events            → write host input (Resources.input)
2. mark_at(prev_root, …)  → event stage: flag last frame's tree from this frame's input
3. ui.beginFrame()        → frame += 1
4. arena.reset()          → last frame's tree dies
5. build_ui(&ui, …)       → construct a fresh node tree (widgets read cache + world)
6. root.set_global_pos()  → resolve every node's position
7. render(root, &ui)      → draw
8. ui.endFrame()          → prune untouched cache slots, then clearTransient
   (retain root as prev_root for next frame's step 2)
```

The one-frame delay is inherent and intentional: at build time (step 5) this
frame's geometry doesn't exist yet, so interaction is marked against the
*previous* frame's laid-out tree (step 2, before the reset).

## Node & features

A `Node` is the atom. It composes optional *feature* fields rather than
subclassing:

```zig
Node {
    id: []const u8,          // human-readable, for debugging
    parent, children,
    state: ?u32,             // handle into a render-state pool (e.g. TextData); null for containers
    interaction_key: ?u64,   // opt-in interaction identity; null = non-interactive
    size:  ?Size,            // intrinsic: calc fn, width/height, padding
    layout: ?Layout,         // positional: anchor + children alignment
    on_render: ?OnRender,    // draw callback
}
```

Builder methods (`with_size`, `with_layout`, `with_render`, `add_child`) chain at
construction. Behaviour varies by *which feature fields a widget wires*, not by
flags — each field carries its payload (the calc fn, the draw fn), and the engine
gates on presence (`if (node.on_render) |r| ...`), exactly where Fleury gates on
bits.

## The key-cache: pools + handles

`cache.zig` is the persistence substrate. One `Pool(T)` per cached type, each a
slot-map:

- **Keys are a rolling hash.** `key(seed, id) = Wyhash(seed, id)`; `key_i` folds a
  loop index. Every widget computes `k = key(seed, id)` as its identity and passes
  `k` as the seed to its children, so identity is structural and deterministic
  across runs. (Chosen over path-strings, which allocate per node per frame.)
- **Handles, not pointers.** `acquire(k)` returns a `u32` index; dereference
  through the live pool at point of use. A pool growing/reallocating never
  dangles anyone — store the index, never a `*T` across another `acquire`.
- **Never compact.** Pruned slots become holes in a free-list; live indices are
  stable for a slot's lifetime. No generation counters: the tree is ephemeral
  (handles re-fetched every frame), so no handle ever spans a removal.
- **Prune at the frame boundary.** A slot not *touched* (acquired) this frame is
  freed next `endFrame`. Touch = stay alive.

## Interaction: marking the tree

Interaction is **opt-in** (only a node with an `interaction_key` participates) and follows the
mechanism/policy split strictly.

```zig
Interaction = packed struct { hovering, clicked, active: bool }  // a flag SET — any combo
```

- `hovering` / `clicked` are **transient** — recomputed every frame, wiped by
  `clearTransient` in `endFrame`.
- `active` is **latched** — set on a transition, persists across frames until the
  host clears it.

**Core (mechanism):** `mark_at(u, node, flag, x, y)` walks the tree and, for every
keyed node whose live rect `contains(x, y)`, calls `u.setFlag` — writing the flag
into the keyed interaction store. The point is passed *in*; the engine never asks
where it came from. (Containment semantics: nested nodes all under the point are
all flagged — the ancestor stack, like CSS `:hover`.)

**Host (policy):** decides the conditions and reads the result. `button` sets an
`interaction_key` and returns the node; the host reads `node.query(u)` (a
read-through query) and writes `if (btn.query(u).clicked)`.
The only place input is read is the host's event stage and its widgets — the
generic engine stays input-agnostic (works for mouse, touch, gamepad, anything).

### Persistence bridge & lazy slots

The tree is reset every frame, so marks can't live on nodes. The host keeps
`prev_root` across the boundary; the event stage marks it *before* the reset; this
frame's build reads flags back from the keyed store by key.

Slots are **lazy**: a store slot exists only after `acquire` — called by `setFlag`
(a mark *hit*) or `interactionOf` (a *read*). There is no per-node stamping, so
cost ≈ (nodes hit) + (nodes read), not node count. A slot stays alive only while
*touched* each frame:

- Marks touch at the pre-increment frame number, reads at post-increment — so a
  hit-but-**unread** slot is pruned that same iteration (a hover nobody observes
  costs one transient slot for one frame).
- **Consequence for `active`:** latched state persists *only while the widget is
  read every frame* (reads keep the slot alive). Stop reading a node → its slot is
  pruned → `active` is lost. For normal widgets (read each frame in build) this is
  exactly right.

## Layout

Two orthogonal axes, both Unity-inspired:

- **`Anchor`** — 9 fixed presets (`top_left` … `bottom_right`, `center`) that a
  node uses to place *itself* within its parent (≈ Unity RectTransform anchors),
  plus `relative` (the parent places it).
- **`ChildrenAlign`** — how a parent places its `relative` children: `horizontal`,
  `vertical`, `vertical_right`, `centered`, their `_wrapped`/`_reverse` variants.
  (≈ Unity Layout Groups.)

`set_global_pos` resolves positions top-down; `recalculate_size` runs bottom-up
first. **Today layout only *places* boxes** whose sizes are mostly fixed —
containers don't yet negotiate size from their children (see Roadmap · autolayout).

## Writing a widget

A widget is a function that takes `(u, parent, seed, id, …)`, self-serves any
persistent state from the cache, builds an ephemeral node, and attaches itself:

```zig
fn make_text(u, parent, seed, id, text) !struct { *Node, u64 } {
    const k = ui.key(seed, id);
    const idx = u.cache(k, TextData);          // handle into the TextData pool
    u.pool(TextData).get(idx).update(text);    // copy text into the cached slot
    const node = try ui.Node.create(u.arena, id);
    _ = node.with_size(ui.Size.init(&text_calc_size, null));
    _ = node.with_render(ui.OnRender.init(&text_render));
    _ = node.with_layout(ui.Layout.init(.relative, null));
    node.state = idx;
    try parent.add_child(u.arena, node);
    return .{ node, k };                        // hand the key back so callers needn't re-hash
}

// Every widget returns its *Node (uniform). Interactive ones also set a key.
pub fn label(u, parent, seed, id, text) !*Node {
    const node, _ = try make_text(u, parent, seed, id, text);
    return node;
}

pub fn button(u, parent, seed, id, text) !*Node {
    const node, const k = try make_text(u, parent, seed, id, text);
    node.interaction_key = k;                  // opt-in: now markable & queryable
    return node;
}

// read interaction off the node (read-through: allocates/keeps the slot):
//   const btn = try button(u, root, s, "ok", "OK");
//   if (btn.query(u).clicked) { ... }
```

Render/size callbacks receive the ctx as `*anyopaque`, cast it to `*Ui`, and
resolve their own state via `node.state` — supplying the concrete type
themselves. They may read `u.res` (the host binding); the *generic* engine code
never does.

## Design decisions (the short version)

- **Reject flags; use feature fields + widget functions.** Our `Node` already
  has typed `?Feature` fields that carry payloads — strictly better than a bit.
  `UIWidgets`/`El`/`Button`/`DataType` were dissolved into widget functions.
- **Persistence = pools + handles**, keyed by rolling hash. No generation
  counters; never compact.
- **Build is a world-mutating step at one fixed schedule slot.** Immediate mode
  reads input inline, so the old `OnClick` + `dispatch_click` indirection is gone.
  No command queue by default (it would reintroduce what immediate mode removes);
  add one per-action only if validation/replay/networking ever needs it.
- **Input lives in the host's `Resources`**, not in `Ui` — one source of truth
  shared by the UI and any ECS systems.
- **Anchors + Layout Groups for macro composition; autolayout for interiors** is
  an additive, orthogonal track — not web-style layout.

## Roadmap / not yet

- **Autolayout sizing** (Track B): `ChildrenSum` / `PercentOfParent` `Size.calc`
  variants, a `strictness: f32`, and one violation-resolution pass between sizing
  and positioning. A bounded extension of `recalculate_size`, not a rewrite.
- **Sprites:** dropped with the old `Data`; reintroduce as a widget fn + a state
  type registered in `StateNs` when needed.
- **Interactables-only marking:** `mark_at` currently walks the whole tree and
  skips unkeyed nodes. For large trees, collect keyed nodes into a flat per-frame
  list and iterate that instead — O(interactive) rather than O(all).
- **Full extraction:** the render/size ctx is still `*anyopaque` (cast to `*Ui`
  by host callbacks). When this becomes a standalone library, consider making the
  callback ctx generic to drop the type-erasure.
