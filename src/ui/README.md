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
Node(comptime RenderFlags: type)                                          // the tree atom
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
- `RenderFlags` — the host's render-flag type (a packed struct of defaulted bools,
  e.g. `.text`, `.border`, `.inactive`). Carried on every node; the engine stores
  it opaquely and **never reads it** — it's pure render *policy* the host switches on.

The host supplies, *one layer up* (today `src/widgets.zig` + `src/res.zig`):
the concrete bindings `pub const UiCtx = ui.Ctx(UiState, Interaction, Resources)`
and `pub const Node = ui.Node(RenderFlags)`, the `Interaction` type, the widget
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

## Node & features

A `Node` is the atom (generic over the host's `RenderFlags`). It composes optional
*feature* fields rather than subclassing:

```zig
Node(RenderFlags) {
    id: []const u8,            // human-readable, for debugging
    parent, children,
    data: ?u32,               // handle into a render-state pool (e.g. TextData); null = no render state
    key: ?u64,                // stable identity → the node's slot in every cache pool; null = caches nothing
    render_flags: RenderFlags, // host render flags (policy); engine never reads them
    size:  ?Size,             // per-axis SizeRule + padding + resolved box + measured data_*
    layout: ?Layout,          // positional: anchor + children alignment
}
```

Builder methods (`with_size`, `with_layout`, `add_child`) chain at
construction. Behaviour varies by *which feature fields a widget wires*, not by
flags — each field carries its payload (e.g. the per-axis size rules), and the engine
gates on presence (`if (node.size) |s| ...`), exactly where Fleury gates on
bits. `render_flags` is the one exception: a host-defined flag *set* the engine
carries but never interprets — the render loop switches on it (text vs sprite vs a
payload-less modifier like `border`). The set flag also doubles as the
discriminant for `data`: `.text` ⟹ resolve `data` through the `TextData` pool,
`.sprite` ⟹ the sprite pool, so no separate data-kind union is needed.

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

## Interaction: hit-testing slots

Every node built through `container` carries a `key`, so any node is queryable —
there's no separate opt-in. A node *participates* in hit-testing only when something
`query`s it (that's what keeps its interaction slot alive). **The flag vocabulary is
host-defined**, exactly like `RenderFlags`: the host passes its `Interaction` struct
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
`interactionOf` (a `query` *read*) or `setFlag` (a direct write). `stampRect` and
`mark` only ever touch *existing* slots, so a node nobody queries gets no slot, no
rect, and no hit-test — cost ≈ (queried nodes), not node count. A slot stays alive
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

A widget composes a base **`container`** (a fresh node with identity, a default size,
and a `relative` layout, attached to its parent) plus zero or more *feature mixins*
that layer state onto it — mirroring how a `Node` composes optional feature fields:

```zig
// Base: every node gets its key here, hashed from the PARENT's key + id, so identity
// is structural (no seed threaded by hand). Universal identity → queryable by anyone.
pub fn container(u, parent, id) !*Node {
    const node = try Node.create(u.arena, id);
    node.key = ui.key(parent.key orelse 0, id);      // seed = parent identity
    _ = node.with_size(ui.Size.init(.fit_children, .fit_children, null))
            .with_layout(ui.Layout.init(.relative, null));
    try parent.add_child(u.arena, node);
    return node;
}

// Feature mixin: cache + measure text, content-size the node, flag it for rendering.
fn add_text_data(u, node, text) !void {
    const idx = u.cache(node.key.?, TextData);       // handle into the TextData pool
    u.pool(TextData).get(idx).update(text);          // copy text into the cached slot
    node.data = idx;
    const tw, const th = u.res.font.getStringSize(text); // host measures, at build
    // …set node.size to .content with data_width/height = tw/th…
    node.render_flags = .{ .text = true };           // how the render walk draws it
}

// Widgets = container + features. They differ by intent, not mechanism.
pub fn label(u, parent, id, text) !*Node {            // static text
    const node = try container(u, parent, id);
    try add_text_data(u, node, text);
    return node;
}
pub fn button_with_text(u, parent, id, text) !*Node { // container + text, queryable
    const node = try container(u, parent, id);
    try add_text_data(u, node, text);
    return node;
}

// read interaction off the node (read-through: allocates/keeps the slot):
//   const btn = try button_with_text(u, root, "ok", "OK");
//   if (btn.query(u).clicked) { ... }
```

The root has no parent, so the host seeds it once (`root.key = ui.key(0, "root")`);
every descendant threads off it automatically.

Add a data type to `UiState` to make a node cacheable; add a flag to `Interaction`
to give it new interactive behaviour.

**Rendering is entirely host-side.** The engine has no draw feature — it stores
the tree + node `data`/`render_flags` and exposes `root.iterate()` (a zero-alloc
pre-order cursor). The host loop *is the renderer*; it lives at the call site
(`main.zig`), not behind an engine wrapper, and picks whatever backend it likes
(SDL, GPU, CPU):

```zig
var it = root.iterate();
while (it.next()) |node| {
    if (node.render_flags.text) draw_text(u, node);   // resolve node.data → TextData, blit
    // if (node.render_flags.border) draw_border(node);  // one branch per RenderFlags aspect
}
```

**Sizing is host-measured too.** The engine has no size callback either — the
host measures content at build (`add_text_data` asks the font for the text's px
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
