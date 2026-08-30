# UI Host Binding (`ui_client`)

The layer where the generic UI engine meets this program. It supplies every type the
engine is parametrized over, owns rendering and text measurement, and provides the
content/style vocabulary screens are written in.

The engine itself is [`../ui/README.md`](../ui/README.md) — it imports nothing from here.
The game's screens are `../pages/`, which import this and not the engine.

## The four tiers

Everything UI in this repo sits on one ladder, and each rung may only reach downward:

| Tier | Folder | Knows about | Holds |
|---|---|---|---|
| Engine | `src/ui/` | nothing | `Node`, the key-cache, the layout solve, interaction slots |
| Foundation | `src/ui_client/` | the engine + SDL | the concrete bindings, paint features, the render walk, content elements, the style fold, the `Theme` roles |
| Templates | `src/pages/templates/` | the foundation + the live palette | pre-styled compositions: `button`, `panel`, `action_tile`, `ration_dial`, … |
| Screens | `src/pages/` | templates + the world | `build_ui`, `play_game`, `gameover` |

The foundation owns the **roles** a widget paints from; the game owns the **values**. So
`text` and `svg` may default a node's ink to `res.view.theme.fg` without reaching upward —
`Theme` is this layer's own type, with its own defaults.

## The four layers of a node

A node's appearance is composed from concerns that stay orthogonal:

- **Content** — *what is in it* (a string, a texture, an svg). The only layer an element owns.
- **Style** — *how it looks* (colors, font size, padding, gap). A declarative fragment fold.
- **Placement** — *where it sits and how its children arrange*. Imperative, written straight
  onto the engine's `Layout`/`Size`.
- **Behavior** — *interaction*. Read at the call site off the node (`.query().clicked`).

Style and placement are deliberately **not** the same mechanism; see *Style* below.

## Concrete bindings (`ctx_binding.zig`)

The single file where `ui` and `res` meet:

```zig
pub const UiCtx = ui.Ctx(UiState, Interaction, Resources);
pub const Node  = ui.Node(RenderData);
```

- **`UiState`** — the pool registry. One `Pool(T)` per declaration, keyed by `node.key`:
  `TextState` (buffer + the px to render at), `ScrollState`, `TabsState`, `TextInputState`,
  and `SvgState`. `SvgState` owns a GPU texture, so it declares `deinit` and the cache's
  eviction hook frees it when the node disappears. Feature `State` types live *here*, not
  in their feature module, because `UiState` is scanned to generate the pools and a feature
  already imports this file — declaring state in the feature would be an import cycle; each
  feature re-exports it as `pub const State` to keep the contract readable.
- **`Interaction`** — `hovering` / `clicked` / `active`, with `transient` naming the first
  two. The engine stores it opaquely; both the vocabulary and the transient/latched split
  are decided here.
- **`RenderData`** — one *optional* field per paint feature, each carrying that feature's
  payload: `text`/`fill`/`svg` are `?Color`, `outline` is `?Outline` (color + width +
  solid/dashed/dotted), `img` is `?Sprite` (a texture plus an optional sheet cell). Present
  ⟹ paint that aspect. Hand-written, kept honest by `features.assertFeature`.
- **`Color`** — the host color type (SDL's `pixels.Color`), aliased from `theme.zig` so the
  whole layer names one type.
- **`icon_sprite(res, col, row)`** — the one place that knows the icon sheet lives on
  `res.platform.icons` and how big a cell is.

## Paint features (`features/`)

A *feature* is one kind of thing a node can be, as a module co-locating its whole surface:

| Decl | Required | Job |
|---|---|---|
| `name` | yes | the `RenderData` field carrying its payload |
| `Payload` | yes | that field's type |
| `draw` | yes | paint one laid-out node, given the unwrapped payload |
| `State` | no | pooled, `node.key`-addressed persistence |
| `attach` | no | the build-time mixin: measure, size, set payload/state |

```zig
pub const list = .{ fill, image, svg, text, outline };  // back → front
```

**The list's order is the z-order** — outline last, so a hover ring shows over an opaque
tile. Adding a visual is one module + one `list` entry + one `RenderData` field, with no
engine change; `assertFeature` turns a drifted descriptor into a build error rather than a
silently undrawn aspect.

Clipping is *not* a feature. It is `Layout.overflow` in the engine, because it is geometry
two consumers read (the render walk, and eventually hit-testing), not a paint the backend
applies.

## The render walk (`draw.zig`)

`draw_tree(u, root)` runs per root tree, in list order — later trees paint on top. Each
node is a recursive pre-order paint carrying a clip stack: apply the inherited clip,
`inline for` the feature list dispatching every set aspect to its `draw`, then narrow the
clip for the subtree if this node is `.clip`. The traversal and the clip stack live here;
the primitives live with their features, so adding a visual never edits this file.

## Content: elements and the `El` handle (`elements.zig`)

An element creates a node and sets *what is in it* — nothing else. Every constructor
returns an **`El`**: `{ ctx, node }`, a handle that carries the ctx so style and placement
chain onto it.

```zig
const header = try el.div(ctx, root, "header");
_ = header.with_layout(.top_left)                        // its own anchor in the parent
          .with_flow(.{ .dir = .row, .cross = .center }) // how its children arrange
          .with_gap(6)
          .with_style(.{ h1, red });                     // style — a fragment fold
```

Leaves are `root` (fullscreen, sized to the live window, the only non-`.relative` one),
`div`, `text`, `image`, `sprite`, `svg`, plus `el(…, content, spec)` sugar pairing a leaf
with a style spec in one call. Content leaves default to `.relative`, so flowed layout is
the zero-config case. `.get()` drops to the raw `*Node` for geometry reads, or for handing
a root to the render walk.

**Why a handle rather than `*Node` methods:** applying a `font` re-measures the text, which
needs the font backend on `ctx`, and the engine's `Node` is deliberately ctx-agnostic. `El`
is also the layer's lingua franca — parents are taken as `El` and templates return `El`, so
one template's output feeds the next call with no unwrapping.

## Style: a fold of partials (`style.zig`)

`Style` is a partial — every field optional — so an unset field means "leave whatever an
earlier fragment or the default set". A **fragment** is a `Style` value, a nested tuple of
fragments, or a `fn(*UiCtx, *Node) Style`. `resolve` folds a spec left to right,
**last non-null wins**; `apply` writes the result onto the node.

The function form is what lets one mechanism cover all three cases: static presets (`h1`),
themed colors (they need `ctx.res.view.theme`), and interaction-aware chrome (a button's
hover color reads `node.query(ctx)` on the node it was just handed).

Presence follows the layer. **Decoration** aspects (`fill`, `outline`) are present iff set.
**Content** aspects are present because content was given, so unset style falls back to a
default — which is why a `text` leaf is visible with no styling at all. Applying a `font`
to a text node re-measures the string at that size and stores the px on the text state, so
`draw` renders at it. On a node with no text, `font`/`text` are inert and a debug assert
catches the mistake; `Style` stays uniform rather than typed per widget so tuple
composition stays free.

**Placement is deliberately not a fold.** A `Placement` partial with `row`/`col`/`fill`
presets was built and then removed: it was a second vocabulary shadowing the engine's own
`Layout`/`Size`, and every value had to be restated in it. Placement is now written
straight onto the node through `El`'s `with_layout` / `with_flow` / `with_gap` /
`with_size` / `with_overflow`. Style composes because a button's look is genuinely built
from reusable pieces; placement does not, because a node sits in exactly one place.

## Color: roles here, values in the game (`theme.zig`)

`Theme` is nine named roles — `bg`, `panel`, `line`, `line2`, `dim`, `fg`, `acc`, `warn`,
`danger` — and **every one is defaulted**, to a plain greyscale plus three conventional
semantic hues. That default exists so the layer is complete on its own: a content leaf
needs ink, and requiring a palette before anything renders would make an unstyled node
invisible. The defaults are deliberately not anyone's visual identity, so a screen that
forgets to install a palette looks unfinished rather than subtly wrong.

A game supplies values by assigning a whole `Theme` onto `res.view.theme`; this layer
never learns those palettes exist. Here that is `ha.palette` (`src/palette.zig`), whose
`cold`/`warm` poles and `lerp(t)` blend are art direction and live outside this folder.
Templates name `uic.Theme` / `uic.Color` for the *types* and read the live values off
`ctx.res.view.theme` — none of them imports the palette module.

The typography scale lives beside the roles: `default_font` (14) is what a text leaf renders
at when nothing styles it, and `body` is defined *from* it, so "unstyled" and "explicitly
body" cannot drift. `h3`/`h2`/`h1` step up from there. `font.zig` is the backend — a lazy
size-to-font cache — and owns no typography; `Fonts.init` takes the size to pre-warm.

`theme.zig` is a **leaf**: it imports only `sdl3`, never the engine or `ctx_binding`. That
is what lets `res.zig` hold a `Theme` on `View` with no import cycle — `res.zig` → this →
`sdl3`, and nothing points back. It also carries the color math (`mix`, `rgb`) that a
palette blend and a pulsing readout both need.

## Fonts

`res.platform.font` is a `Fonts` — a lazy `size → ttf.Font` cache (`at(px)`,
`measure(text, px)`), one loaded font per point size, because `TTF_SetFontSize` clears the
glyph cache on every call and rescaling a loaded pixel font is lossy. A text leaf measures
at `font.default_px`; a resolved `font` fragment re-measures at its size.

## Frame assembly (`tree.zig`)

`build_ui` returns `Trees` — a flat `[]const *Node` of independent root trees, laid out and
drawn in order. The flattening of a builder's return shape (a `*Node`, an `?*Node`, or a
tuple of them) into that list is `Node.collect`, an engine mechanism; this file only names
the wrapper so `pages/` can build against it.

## Not yet

- **`widgets.zig` is legacy and unreferenced.** The pre-`elements` palette (`label`,
  `button`, `panel`, `scroll_view`, `modal`, `tooltip`, `text_input`, …). Nothing outside
  this folder calls it any more — the screens moved onto templates — so it stays alive only
  through `root.zig`'s re-exports. Deleting it also drops the last copies of
  `scroll_speed`/`scrollbar_w`, which `pages/templates/scroll_view.zig` duplicates. Its
  `modal`, `tooltip` and `text_input` have no template equivalent yet, so those three want
  rebuilding on the foundation rather than plain deletion.
- **Responsive scale.** Every scalar here — the `body`/`h1` ladder, `pad`, `gap`,
  `stroke_w`, and the px sizes callers pass — is authored at one reference resolution and
  never adapts. See the `TODO(responsive-scale)` note in `style.zig` and the roadmap.
