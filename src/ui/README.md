# UI Engine

A small **immediate-mode UI building language** in Zig. The node tree is rebuilt
from scratch every frame; persistence (text caches, interaction state, …) lives
in a key-addressed cache, not in the tree. Heavily inspired by Ryan Fleury's
[UI series of posts](https://www.dgtlgrove.com) but adapted to personal preferences
and Zig idiomatic code.

## Design philosophy

- **Immediate mode.** Widgets are *functions called during build*, not retained
  objects you wire once and mutate. A widget always returns its most outward `*Node`; you read
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
Ctx(comptime StateNs: type, comptime IntFlags: type, comptime Res: type)  // the per-frame builder
Node(comptime RenderData: type)                                           // the tree atom
```

- `StateNs` — a namespace of the render-state types the host wants cached (one
  `Pool(T)` is generated per declaration).
- `IntFlags` — the host's interaction-flag type (a packed struct of defaulted
  bools, e.g. `hovering`, `clicked`, `active`). The engine stores it opaquely in
  the keyed interaction store and **never reads its meaning**; it must declare
  `pub const transient = [_][]const u8{ … }` naming the fields the engine zeroes
  each frame (the rest latch). Both the vocabulary *and* the transient/latched
  split are host policy.
- `Res` — the host's resource bundle (fonts, renderer, input, …). The engine
  holds a `*Res` opaquely and never touches its fields; only host code does.
- `RenderData` — the host's render descriptor, carried on every node as `render_data`:
  which draw aspects to paint this frame **and the inline payload each needs** (e.g.
  `text`/`fill`/`outline`, each an *optional* `Color` — present ⟹ draw that aspect
  in that color). The engine stores it opaquely and **never reads it** — it's pure
  render *policy* the host's render walk switches on. This is the extensibility seam:
  add a field to give every node a new draw aspect with **no engine change/recompile**.
  Must be default-constructible (`.{}`) — the engine seeds it at `init`. (Frame-local:
  rebuilt from scratch each frame, like the node itself.) Named *Data*, not *Flags*,
  because the fields carry payloads (a `Color`), not bare bits.

The host supplies, *one layer up* (today `src/widgets.zig` + `src/res.zig`):
the concrete bindings `pub const UiCtx = ui.Ctx(UiState, Interaction, Resources)`
and `pub const Node = ui.Node(RenderData)`, the `Interaction` type, the widget
functions, the build-time measurement + the render loop, and `Resources` itself. To
lift this into its own project, take `src/ui/` as-is; `widgets.zig`/`res.zig` are
the template for how a host binds it. (The engine type is `Ctx`; the host names its
binding `UiCtx`.)

## Module map

| File | Responsibility |
|---|---|
| `root.zig` | `Node` (the tree atom) + `Iterator` (zero-alloc pre-order walk) + the `stamp_rects` post-layout walk. Re-exports everything. |
| `ctx.zig` | `Ctx(StateNs, IntFlags, Res)` — per-frame builder state: pools, `*Res`, arena, frame counter, and the interaction store (keyed `{flags, rect}` slots + `mark`/`stampRect`). |
| `cache.zig` | `Pool(T)` slot-map (handles + free-list), `Pools(ns)` generator, `key`/`key_i` hashing. |
| `geometry.zig` | `Rect` + pure `contains(x, y)`. Leaf, no deps. |
| `color.zig` | `Color` (RGBA POD, defaults white) + `scaled`. A reusable utility type the host puts in its `RenderData`; not a `Node` field, and the engine never interprets it. Leaf, no deps. |
| `features/size.zig` | `Size` + per-axis `SizeRule` — pure data: rules, padding, resolved box, host-measured `data_*`. |
| `features/layout.zig` | `Layout` (`Anchor` + `ChildrenAlign`) + the whole solve: sizing passes + `set_global_pos`/placement. |

## The frame lifecycle

The host loop drives the engine in a fixed order (`src/main.zig`):

```
1. poll events            → write host input (Resources.input)
2. ui.mark(flag, x, y)    → event stage: hit-test last frame's slot rects, set flags
3. ui.beginFrame()        → frame += 1
4. arena.reset()          → last frame's tree dies
5. build_ui(&ui, …)       → construct a fresh node tree (widgets read cache + world)
6. root.set_global_pos()  → solve sizes (per-axis rules) + resolve every position
7. ui.stamp_rects(root)   → copy each queried node's rect into its interaction slot
8. host render walk       → host iterates the tree (root.iterate()) and draws
9. ui.endFrame()          → prune untouched cache slots, then clearTransient
```

The one-frame delay is inherent and intentional: at the event stage (step 2) this
frame's geometry doesn't exist yet, so `mark` hit-tests the rects stamped after the
*previous* frame's layout (step 7). The interaction **slot pool** — not a retained
node tree — is what carries that geometry across the frame boundary.

## Where node state lives (the one rule)

A node is **arena-allocated and rebuilt from scratch every frame**, so it can only
ever hold *frame-local* state. Anything that must survive the reset lives in a **pool
keyed by `node.key`** — the node holds, at most, the *handle* to it. That single
axis — *does this outlive the frame?* — decides where everything goes, and keeps the
mechanisms from multiplying:

| State | Home | Lifetime | Job |
|---|---|---|---|
| `render_data` | on the node | **frame-local** | which aspects to draw + the inline payload each needs (a `Color`) |
| `data` (handle) | on the node → into a pool | content is **persistent** | this node's access path to its cached render state (`TextData`) |
| interaction (`Slot{flags,rect}`) | pool, keyed by `node.key` | **persistent** | input state; reached via `query`/`mark`, never stored on the node |

The node never holds persistent data *directly* — persistence is **always** a pool
slot keyed by `node.key`. `render_data` is the one frame-local payload (color folds in
here); `data` is the door to the persistent render-state pool; interaction is the other
persistent, key-addressed store. Interaction can't fold into `render_data` precisely
because they're opposite lifetimes: `render_data` is rebuilt each frame, while an
interaction slot **must** persist (the rect stamped after frame N's layout is what
frame N+1's event stage hit-tests, and `active` latches). Interaction's sibling is
`TextData` — both are persistent and key-addressed — not `render_data`.

## Node & features

A `Node` is the atom (generic over the host's `RenderData`):

```zig
Node(RenderData) {
    id: []const u8,           // human-readable, for debugging
    parent, children,
    data: ?u32,               // handle into a render-state pool (e.g. TextData); null = no render state
    key: u64,                 // stable identity → the node's slot in every cache pool (hash of parent key + id)
    render_data: RenderData,  // host render descriptor (policy): aspects + inline payload; engine never reads it
    size:  Size,              // per-axis SizeRule + padding + resolved box + measured data_*; defaulted at create
    layout: Layout,           // positional: anchor + children alignment; defaulted at create
}
```

Builder methods (`with_size`, `with_layout`) chain at construction; `add_child` —
and `pcreate`, which creates + binds in one call — wire the tree. **Every node is a
box:** `size`/`layout` are non-optional, defaulted at `create` (a `fit_children` box
anchored `top_left`/`horizontal`) and overridden where a widget wants otherwise, so
the layout passes never branch on "does this node have a box." The one optional
payload left is `data` (a node may cache nothing). `render_data` is a host-defined
descriptor the engine carries but never interprets — the render loop switches on its
fields (text vs sprite vs a fill/outline color), and a set aspect doubles as the
discriminant for `data`: a present `text` ⟹ resolve `data` through the `TextData`
pool, a present `sprite` ⟹ the sprite pool, so no separate data-kind union is needed.

## The key-cache: pools + handles

`cache.zig` is the persistence substrate. One `Pool(T)` per cached type, each a
slot-map:

- **Keys are a rolling hash.** `key(seed, id) = Wyhash(seed, id)`; `key_i` folds a
  loop index. A node's key is `key(parent.key, id)`, threaded automatically by
  `add_child`, which re-keys the child's whole subtree on attach (`rekey`) — so
  identity is structural, deterministic across runs, and **independent of wiring
  order** (assemble a subtree first, attach it later, the keys resolve the same).
  (Chosen over path-strings, which allocate per node per frame.)
- **Handles, not pointers.** `acquire(k)` returns a `u32` index; dereference
  through the live pool at point of use. A pool growing/reallocating never
  dangles anyone — store the index, never a `*T` across another `acquire`.
- **Never compact.** Pruned slots become holes in a free-list; live indices are
  stable for a slot's lifetime. No generation counters: the tree is ephemeral
  (handles re-fetched every frame), so no handle ever spans a removal.
- **Prune at the frame boundary.** A slot not *touched* (acquired) this frame is
  freed next `endFrame`. Touch = stay alive.

## Interaction: hit-testing slots

Every node carries a `key` (set at `create`, finalized on attach), so any node is
queryable — there's no separate opt-in. A node *participates* in hit-testing only when something
`query`s it (that's what keeps its interaction slot alive). **The flag vocabulary is
host-defined**, exactly like `RenderData`: the host passes its `Interaction` struct
as the `IntFlags` parameter, and the engine stores it opaquely — it owns neither the
field names nor what they mean. Today's host (`widgets.zig`):

```zig
pub const Interaction = packed struct {  // a flag SET — any combo can be on at once
    hovering: bool = false,
    clicked:  bool = false,
    active:   bool = false,

    pub const transient = [_][]const u8{ "hovering", "clicked" };  // engine zeroes these each frame
};
```

The **transient/latched split is host policy too**: `clearTransient` (run in
`endFrame`) reads the host's `transient` field-name list and zeroes only those
fields. Fields *not* listed latch — they persist across frames until the host clears
them. Here `hovering`/`clicked` are recomputed every frame; `active` latches. Add a
field (`dragging`, `focused`) by editing the host struct — no engine change.

The interaction store is a `Pool(Slot)` where `Slot = { flags, rect }`. A slot exists
only for a key that's been `query`'d, and it carries that node's last laid-out rect —
so **hit-testing iterates the live slots, never the node tree**:

- **`ui.mark(flag, x, y)` (mechanism, event stage):** loops the live slots and sets
  `flag` on each whose stored `rect.contains(x, y)`. **O(interactive)**, not O(all).
  `flag` is comptime-checked against the host's `Interaction` fields
  (`std.meta.FieldEnum`); the point is passed *in* (mouse/touch/gamepad — the engine
  never asks where from). Each interactive node is flagged independently (not the
  whole ancestor stack — there's no tree to walk).
- **`ui.stamp_rects(root)` (after layout):** walks the laid-out tree and copies each
  *already-queried* node's rect into its slot (`stampRect` no-ops for keys with no
  slot). This is what feeds the next frame's `mark`.

**Host (policy):** defines the vocabulary, decides the conditions, and reads the
result. The host reads `node.query(u)` (a read-through query returning the host's
`Interaction` struct) and writes `if (btn.query(u).clicked)`. The only place input is
read is the host's event stage and its widgets — the generic engine stays
input-agnostic.

### Persistence bridge & lazy slots

The tree is reset every frame, so interaction can't live on nodes. The **slot pool**
is the bridge: rects are stamped into it after layout, and flags are written into it
at the event stage — both survive the arena reset, so no `prev_root` is retained.

Slots are **lazy**: a store slot exists only after `acquire` — called by
`interactionOf` (a `query` *read*) or `setFlag` (a direct write). `stampRect`,
`rectOf`, and `mark` only ever touch *existing* slots, so a node nobody queries gets
no slot, no rect, and no hit-test — cost ≈ (queried nodes), not node count. `rectOf`
(via `node.rect`) reads back the slot's last-stamped rect without creating one — for
positioning one node relative to where another was drawn last frame. A slot stays alive
only while *touched* (acquired) each frame:

- A node not `query`'d this frame is pruned at `endFrame`, dropping straight out of
  next frame's hit-test set.
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
- **`gap`** — space inserted *between* adjacent flowed children along the flow axis
  (and between the rows/columns of the `_wrapped` variants); not before the first or
  after the last, and not for the proportional `centered*` aligns. A `fit_children`
  parent grows to include the gaps. Defaults to 0; set with `Layout.init(..).with_gap(n)`.
  Per-node **`Size.padding`** (inset around a node's content, already on every box) is
  the orthogonal knob — gap spaces siblings, padding insets a box's own content.
- **`origin`** — a *root's* screen position (where its top-left lands). Defaults to
  (0,0), so the main tree fills from the corner. The host can render **multiple roots**
  (`root.set_global_pos()` + `root.iterate()` per tree) and float a second one — an
  overlay/tooltip layer — anywhere on screen by giving its root an origin:
  `Layout.init(.top_left, ..).with_origin(x, y)`. A root rendered last draws on top, and
  being a separate tree it stays out of the main tree's flow/sizing. To anchor an overlay
  to an existing node, read that node's prior-frame rect with **`node.rect(ctx)`**
  (→ `Ctx.rectOf(key)`, the rect `stamp_rects` recorded last frame) and derive the origin.

### Sizing

Every node picks a `SizeRule` **per axis** (mandatory — width and height size
independently): `fixed`, `content`, `pct_of_parent`, or `fit_children`. The
*intrinsic content size* is host policy — the host **measures it at build** (text
metrics, a sprite's dims) and stores it on the node as `data_width`/`data_height`;
the `content` rule sizes to those, and the host renderer draws to them. The *rule*
that turns that seed / parent / children into the final box is core. The whole
solve is **pure** — no host callback, no `ctx`. `set_global_pos` runs three passes:

1. **`recalculate_size`** (bottom-up) — resolve `fixed`/`content`/`fit_children`;
   `pct_of_parent` takes a provisional = its measured content size.
2. **`resolve_pct`** (top-down) — finalize `pct_of_parent` against *definite*
   parents. `fit_children` is the only **indefinite** rule, so a `%` under a
   `fit` parent has no definite base and falls back to `content` (→ the node's
   `data_*`, or a safe **0** when it has no measured content).
3. **`place`** (top-down) — assign global positions; pure geometry.

Because the engine never measures anything, `set_global_pos` takes no `ctx` at
all. (The callback-in-the-size-pass would only earn its place once content sizing
becomes *constraint-dependent* — wrapped text, where height depends on the
resolved width. We don't do that yet.) Still pending (Roadmap): `range`/`max_of`
combinators and the `strictness`-weighted sibling distribution.

## Writing a widget

Build a node, wire it into the tree (which finalizes its `key`), then layer state
onto it. **Order matters:** keyed data (`data_text`) addresses the cache by
`node.key`, so the node must be attached *first*. Layout is key-free, so it's set
inline right where the node is built — in the widget fn for content nodes, at the call
site for the structural ones the host hand-builds.

```zig
// Create + bind to a parent in one call (core). The child's key becomes
// key(parent.key, id); add_child re-keys the whole subtree, so this is order-safe.
const node = try Node.pcreate(u.arena, id, parent);

// Feature mixin: cache + measure text, content-size the node, flag it for rendering.
// Apply AFTER wiring, so node.key is final.
pub fn data_text(u, node, text) !void {
    const idx = u.cache(node.key, TextData);         // handle into the TextData pool
    u.pool(TextData).get(idx).update(text);          // copy text into the cached slot
    node.data = idx;
    const tw, const th = u.res.font.getStringSize(text); // host measures, at build
    // …content-size node.size with data_width/height = tw/th…
    node.render_data.text = .{};                     // present (white) ⟹ render walk draws text
}

// read interaction off the node (read-through: allocates/keeps the slot). Any
// keyed node is queryable, so a text node doubles as a button:
//   const counter = try Node.pcreate(u.arena, "counter", center_div);
//   try data_text(u, counter, "Counter: 0");
//   if (counter.query(u).clicked) { ... }
```

The root has no parent, so the host builds it with `Node.create(u.arena, "root")`
(seed falls back to the `0` base); every descendant threads off it via `pcreate` /
`add_child`.

A host `build_ui` (see `main.zig`) reads top-to-bottom as **globals → queries →
node graph**: pull the frame's window dims and ECS state up front, then build the tree.
The host hand-builds the structural nodes (`root`, a `center_div`) with `create`/
`pcreate`, configuring each one's `size`/`layout` inline right after it's created; every
content node is a widget function (`label`, `progress_bar`, `button`, `panel`) that owns its whole subtree
— graph, keyed data, *and* layout. There's no separate deferred layout pass: each node
is fully configured where it's built. Each widget returns its outermost `*Node`, so the
build site reads interaction off it (`if (counter.query(u).clicked) …`) and feeds it
data (a formatted string, a `frac`) — both stay at the call site because they're the
data source, not the widget's concern. The solve (`set_global_pos`) runs once afterward
over the finished tree.

Add a data type to `UiState` to make a node cacheable; add a flag to `Interaction`
to give it new interactive behaviour.

**Rendering is entirely host-side.** The engine has no draw feature — it stores
the tree + node `data`/`render_data` and exposes `root.iterate()` (a zero-alloc
pre-order cursor). The host loop *is the renderer*; it lives at the call site
(`main.zig`), not behind an engine wrapper, and picks whatever backend it likes
(SDL, GPU, CPU). Each aspect is an *optional* payload — unwrap it, and the value is
the color to paint in:

```zig
var it = root.iterate();
while (it.next()) |node| {
    if (node.render_data.fill)    |c| draw_fill(u, node, c);    // c: the fill color
    if (node.render_data.outline) |c| draw_outline(u, node, c);
    if (node.render_data.text)    |c| draw_text(u, node, c);    // resolve node.data → TextData, blit in c
}
```

**Sizing is host-measured too.** The engine has no size callback either — the
host measures content at build (`data_text` asks the font for the text's px
extent) and stores it on the node's `Size` as `data_width`/`data_height`.
The `content` rule sizes to those and `draw_text` draws to them, so the whole
solve is pure and `set_global_pos` takes no `ctx`. Widgets read `u.res` (the host
binding) when they measure; the *generic* engine code never does.

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

- **Autolayout sizing** (Track B): base `SizeRule`s (`fixed`/`content`/
  `pct_of_parent`/`fit_children`), per-axis, with the bottom-up + top-down solve
  and the definite/indefinite fallback — **done** (see *Sizing* above). Still to
  land: `range`/`max_of` combinators, and a `strictness: f32` driving a
  violation-resolution pass that distributes slack/overflow among siblings.
- **Sprites:** dropped with the old `Data`; reintroduce as a widget fn + a state
  type registered in `StateNs` when needed.
- **Interactables-only marking — done.** The event stage (`ui.mark`) now iterates
  the live interaction slots, each carrying its node's rect, so hit-testing is
  O(interactive), not O(all) — no tree walk. The one O(all) pass left is
  `stamp_rects` (it reads geometry that only exists on the tree); it could drop to
  O(interactive) by having `query` push nodes onto a per-frame list, at the cost of
  threading that list through `Ctx`.
- **Full extraction:** the engine is now **callback-free** — rendering and sizing
  are host loops/data, not engine-invoked `*anyopaque` callbacks, so that
  type-erasure wart is gone. Lifting `src/ui/` into its own repo is mostly
  packaging now; `widgets.zig`/`res.zig` stay the host-binding template.
