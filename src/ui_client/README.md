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
| Templates | `src/pages/templates/` | the foundation + the live palette | pre-styled compositions: `button`, `panel`, `action_tile`, `build_list`, `holdings`, … |
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

- **`UiState`** — the pool registry. One `Pool(T)` per declaration, keyed by `node.key`.
  A state with semantic defaults declares no-argument `init() T`; states without it
  explicitly use the engine's bitwise-zero fallback. Every fresh slot and reused hole
  follows that same contract. The registry currently contains `TextState` (a **64-byte** buffer + the px to render at — `update` clamps to it, so a
  longer string is truncated silently, and a node is one line either way), `ScrollState`,
  `TabsState`, `StepState`,
  `TextInputState`, `LineState`, `BuildViewState` and `SvgState`. `LineState` is the one that carries
  *variable-length* data — a polyline's points, since `RenderData` holds a single payload
  per feature and coordinates don't fit in a tint; fixed capacity keeps it POD. `SvgState` owns a GPU texture, so it declares `deinit` and the cache's
  eviction hook frees it when the node disappears. Feature `State` types live *here*, not
  in their feature module, because `UiState` is scanned to generate the pools and a feature
  already imports this file — declaring state in the feature would be an import cycle; each
  feature re-exports it as `pub const State` to keep the contract readable.
  Per-view state normally lives in one aggregate on an always-built shell. When a
  conditional child is the clearer owner, the shell may call `retainChildState` each
  hidden frame; this keeps only an existing typed slot and stops automatically with
  the shell. `BuildViewState` uses that path while ACTIONS hides the BUILD root.
- **`Interaction`** — pointer-derived hover/press/held/release/wheel/click/drag/capture,
  transient command dismissal, plus semantic disabled/focus/focus-visible/selected/checked
  projections. Pointer/command fields
  are transient; `publishControlState` writes every semantic field from its real owner
  each build, so no anonymous `active` latch exists.
- **`RenderData`** — one *optional* field per paint feature, each carrying that feature's
  payload: `text`/`fill`/`svg` are `?Color`, `outline` is `?Outline` (color + width +
  solid/dashed/dotted), `img` is `?Sprite` (a texture plus an optional sheet cell). Present
  ⟹ paint that aspect. Hand-written, kept honest by `features.assertFeature`.
- **`Color`** — the host color type (SDL's `pixels.Color`), aliased from `theme.zig` so the
  whole layer names one type.
- **`icon_sprite(res, col, row)`** — the one place that knows the icon sheet lives on
  `res.platform.icons` and how big a cell is.

## Frame input (`input.zig`)

`Resources.input` is an allocator-free host frame model rather than a set of SDL event
edges. `Input.beginFrame()` is the single reset boundary: it clears pointer delta and
wheel x/y, button press/release/click counts, key events, copied text, focus edges,
cancellation, and overflow reports while preserving pointer position/identity, held
buttons/keys, modifiers, and window focus.

The desktop event stage normalizes SDL mouse, touch, and pen identities into one active
pointer; records all five button states as pressed/held/released; distinguishes key
press/repeat/release with modifier snapshots; copies ephemeral UTF-8 text bytes; and
records focus gain/loss. Focus loss and platform/touch cancellation release every held
button/key and cancel engine pointer capture. Key events, held keys, and text use explicit
fixed capacities (`64`, `32`, and `256` bytes respectively); their overflow flags make
refusal observable without adding allocator ownership to `Resources`.

## Pointer activation (`activation.zig`)

`PointerActivation` converts primary-pointer edges into control semantics without moving
those semantics into generic `ui`. On down, main routes transient `.pressed` immediately
and stores the topmost stable key, pointer kind/ID, and origin. Motion farther than 4
logical pixels permanently classifies that gesture as a drag. A matching pointer release
emits one `.clicked` only when its geometric topmost key is still the pressed key; release
outside, target changes, drag, focus loss, touch cancellation, pointer mismatch, and a
second release are suppressed. SDL mouse events synthesized from touch are excluded from
this routing because direct finger events carry the real touch ID and would otherwise
process the gesture twice.

All build, action, tab/ration, nested cancel, Continue, and restart call sites still read
the one shared `.clicked` flag, so changing the event-stage policy migrates them together.
`.pressed` remains separately available for controls that need press-time behavior; text
input uses it to distinguish an inside press from an outside focus-clear.

## Ordered pointer routing and overlays

Every pointer event reaches the interaction store through the engine's reverse paint-order
walk. Hover and primary press use capture-aware `mark`/`markTarget`; every primary up
routes `.released` before geometric click validation; every SDL wheel event routes
`.wheel` at its own pointer position. Scroll views require their viewport's routed
`.wheel` flag before consuming the frame model's accumulated x/y delta, so mere hover no
longer authorizes unrelated scroll containers. Capture, when present, wins before geometry
for all four routed event types.

Opaque independent overlays participate by querying their root. `tooltip` queries its
popup box, and `modal` queries both the fullscreen scrim and dialog; because roots are
stamped in the same order they draw, listing them after the screen blocks covered controls
for hover, press, release, wheel, and click without `modal_open` guards. Geometry-only or
intentionally transparent overlays must opt out explicitly with `pass_through`.

## Visual interaction state ownership

The host vocabulary separates pointer facts from semantic facts. Main republishes `held`
on the stable press key while primary input remains down, `dragging` once
`PointerActivation` crosses 4px (including release-position movement), and `captured` on
the exact `Ctx` capture owner. These are transient like hover/press/release/click; button,
action, build-row, tab, ration, filter, and cancel chrome can react to held immediately.
The two production scroll views capture their thumb on primary press, preserve the exact
press origin even when motion shares the same SDL event batch, map pointer travel to the
clamped offset, apply the release position, and owner-release. Capture-first routing keeps
them dragging beyond the six-pixel track; focus loss/cancellation, lost ownership,
disappearing overflow, and prune repair all terminate safely. `ThresholdDrag` exposes the
same strict `>4` logical-pixel boundary as `PointerActivation`: future board/slider
consumers can capture immediately while emitting no movement before threshold, and the
activation state suppresses the tile/control click generated by a crossed gesture. The
Act II board and a production slider do not exist yet, so no game-only placeholder was
invented here.

`CursorState` resets to default each frame and accepts paint-order requests from hovered
controls. Buttons/chips use pointer, disabled actions use not-allowed, text fields use
text, and scroll thumbs use grab/grabbing. `PlatformCursors` owns the SDL system handles,
falls back to the default when a shape is unavailable, and maps both grab variants to
SDL's `move` cursor because SDL 3 exposes no distinct grab/grabbing shapes. The vocabulary
also includes horizontal-resize for the future slider.

`ControlState` carries `disabled`, `focused`, `focus_visible`, `selected`, and `checked`.
`publishControlState(ctx, key, state)` writes all five—including false—on every build.
Authority stays elsewhere: enabled/affordability/readiness and row classification decide
disabled; the focus registry decides text-input focus; `TabsState` and `BuildViewState`
decide tab/filter/check state; simulation `Metabolism.setting` decides ration selection.
The interaction slot is their cross-widget visual/semantic projection, never an
independent toggle. Current desktop policy visibly outlines every focused text field, so
its `focused` and `focus_visible` are both true; INPUT-06 may refine origin policy when
keyboard command routing lands.

## Focus binding

The engine owns focus identity, traversal order, roving groups, and lifecycle repair; this
layer maps SDL keys and registers owners. `command.zig` normalizes Tab/Shift+Tab, arrows,
Enter/Space, Escape, slash, Backspace/Delete, and Home/End. Main traverses global focus,
moves and activates roving choices, and emits `.clicked` for keyboard activation so call
sites share pointer guards. Buttons, actions, rows, nested cancel, goals, tabs, ration, and
build choices register enabled stable keys and publish visible focus; disabled targets are
skipped. Pointer completion requests the same focus identity.

The fixed `CommandRegistry` publishes each build's text/search and latest Escape owner for
the next event stage. A focused text owner consumes Escape first; otherwise the topmost
registered overlay/view receives transient `.dismissed`. Unhandled Escape does not quit;
only SDL quit/terminating does. Slash focuses the registered search field without inserting
its shortcut byte. Editing commands and SDL text bytes are gated to registered text owners.

## Single-line editing (`editor.zig`)

`ui_client` owns the authoritative host editor model; the generic `src/ui` engine knows
nothing about carets, selections, UTF-8, or a maximum length. `editor.LineEditor` (aliased
as `UiState.TextInputState`, so a `Pool` is still generated for it) holds a fixed
`max_query_bytes = 128` UTF-8 buffer plus byte-offset `caret`/`anchor` that always sit on
codepoint boundaries; `caret == anchor` means no selection. Every mutation is a method so
the rules are one place and testable without SDL: codepoint-wise `insert`, `deleteBackward`
/`deleteForward` (which delete the selection when present), `moveLeft`/`moveRight`/`home`
/`end` with a plain-vs-`extend` (anchored) distinction, `selectAll`, `clear`, and a
`cutSelection`/`selectionSlice` copy accessor.

Admissibility is one rule, `isSingleLineUtf8`: valid UTF-8 with no C0/C1/DEL controls and
no line breaks. Insertion and paste are validated against it and against `max_query_bytes`
*after* replacing the current selection, and are refused **as a whole** — never truncated
or stripped — setting the visible, non-silent `refused` latch that clears on the next
accepted edit. `command.zig` maps Shift+Left/Right/Home/End to the selection variants and
one-shot Ctrl+A/C/X/V to select-all/copy/cut/paste (Alt cancels the accelerator so plain
typing is never intercepted). `main.zig` only *routes*: SDL text bytes go through `insert`;
caret/selection/delete commands drive the focused registered owner's model; and the SDL
0.15.2 clipboard (`clipboard.hasText`/`getText` + `free`/`setText`) is bridged for
copy/cut/paste, with paste passing through the same whole-text validation. `text_input`
reads the model to render placeholder, a caret bar or guillemet-bracketed selection,
focus-visible chrome, a `danger` outline while `refused`, and a pointer "✕" clear
affordance; the keyboard clear is Ctrl+A then Backspace against the same model.

## Semantic model (`semantics.zig`)

INPUT-08 adds a fully host-side accessibility model — the source INPUT-09's platform
bridge will read, **not** a second source of truth. The generic `src/ui` engine knows
nothing about roles, labels, or announcements; everything here is keyed by the same stable
`node.key` the interaction/focus/command registries use, so a control's semantics can
never disagree with what it publishes through `publishControlState`.

A `SemanticNode` carries the stable `key`, a `Role`
(`button`/`icon_button`/`radio`/`checkbox`/`text_input`/`progress_bar`/`tile`/`group`
/`dialog`/`text`), an **owned** accessible `label` and an optional **owned** `value` text,
`SemanticState` (disabled/focused/selected/checked/expanded), stable-key `Relations`
(`controls` and `described_by`, bounded to `max_relations` with explicit overflow refusal),
and a `LiveRegion` policy (`off`/`polite`/`assertive`). Strings live in fixed `OwnedText`
buffers that copy the source bytes and **refuse an over-long value as a whole** (setting
`truncated`, keeping `len = 0`) rather than storing a silently cut prefix — the editor's
non-silent-refusal policy.

`SemanticRegistry` is the same double-buffer as `command.Registry`: `beginBuild` clears the
building buffer, `publish` appends nodes **in UI/control paint order**, and `endBuild`
swaps the completed build into the published `snapshot`. Because every node owns its
strings by value, the swap moves owned storage and the prior snapshot never borrows the
frame arena — a reader (the bridge) may hold it across the arena reset. Duplicate keys in
one build update the existing entry in place, preserving first-seen order (deterministic
update/order policy). Node overflow past the fixed cap and any per-field/relation refusal
are surfaced non-silently via `snapshotOverflow` / `snapshotFieldRefused` and the per-node
`truncated` flags; earlier nodes are preserved on overflow.

`AnnouncementChannel` is a bounded polite live-region queue with owned text, a monotonic
session `generation`, **consecutive-duplicate dedup** (the live-region contract: do not
re-announce the message already stated), and explicit `overflow` refusal for a full queue
or an over-long message. `drainThrough(gen)` compacts messages a reader has spoken. It is
presentation plumbing only — nothing here has authority over the simulation.

Lifecycle is wired like the command registry: `Resources` holds `semantics` and
`announcements`; `main` calls `semantics.beginBuild()` before `build_ui` and
`semantics.endBuild()` after `endFrame()`. Representative `describe*` helpers turn
authoritative widget/domain facts into a `SemanticNode`; controls call them right where
they already call `publishControlState` (stock `button`/`icon_button`/`progress_bar`
/`text_input`/`modal`, and game `tabs`/`ration_dial`/`build_list`/`capital_row`
/`action_tile`). Honest limitations: an icon button and a bare progress bar have no widget
string for a name (they publish an empty label; a named variant/domain helper supplies
one), `expanded` is owned only by the dialog shell, and no production board/search/modal
*consumer* exists yet — the model describes the controls that do exist.

## Accessibility bridge (`a11y.zig`)

INPUT-09 adds the host-side **bridge** that consumes the INPUT-08 model — it never
re-derives a semantic fact. `Bridge` has a deterministic, allocation-free lifecycle that
mirrors the registries: `init(provider)` installs a provider and goes `active`, per-frame
`poll(snapshot, overflow, field_refused, channel)` forwards this frame's published snapshot
to the provider as its tree root and drains the announcement channel, and `deinit()` goes
`inactive` (a guarded no-op `poll`). `poll` folds the registry's non-silent
`snapshotOverflow`/`snapshotFieldRefused` into the bridge's own status, then forwards every
announcement newer than a monotonic `spoken_generation` cursor and calls
`AnnouncementChannel.drainThrough` so the bounded queue never stays full. The bridge borrows
the snapshot only for the call and copies the last message into an owned `OwnedText` — it
holds no frame-arena or channel pointer across frames. `Resources` holds `a11y` (defaulting
to the inert `NoopProvider`); `main` polls it right after `semantics.endBuild()`.

The future Windows UIA seam is a narrow `Provider` vtable
(`getRoot`/`elementFromKey`/`mapRole`/`raiseFocus`/`raiseAnnouncement`) — exactly what a
`WM_GETOBJECT`-answering `IRawElementProviderFragmentRoot` needs. The default `NoopProvider`
implements it as inert sinks (no element, custom role id `0`, no-op raises), so the whole
bridge runs and is tested with no platform surface, and a real provider slots in without the
bridge, `src/ui`, or the semantics source changing.

`Capabilities` is an honest report of what this build ships:
`keyboard`/`visible_focus`/`non_color_state`/`live_region_plumbing` are `true` (all
exercised today — see INPUT-04/06/07), and `screen_reader_export` is **`false`**. This build
exports no live screen-reader tree because a UIA provider must hook the SDL-owned window's
`WndProc` to answer `WM_GETOBJECT`, and `zig-sdl3` 0.1.6 does not implement
`SDL_SetWindowsMessageHook` (only the X11 hook exists); hand-rolled subclassing or forking
the vendored binding are the risky, policy-leaking dependencies this layer forbids. Genuine
HTML/ARIA parity is therefore unavailable and is not claimed. All Windows/platform policy
stays here in `ui_client`; `src/ui` remains accessibility-unaware.

## Reduced-motion policy (`motion.zig`)

INPUT-10 adds a one-bit host-side **reduced-motion policy** that decides whether *optional*
transitions animate or **snap** — while functional progress, state changes, pointer/focus
cues, and the simulation always stay visible. `Policy { reduced_motion }` is resolved
**once at init** (`App.setup`, right after `Resources.init`), stored on `Resources.motion`,
and only *projected* onto `View.reduced_motion` in `build_ui`'s prologue each frame — so
there is no per-frame OS call.

Resolution precedence is total and non-panicking: an **explicit override** (env
`HA_REDUCED_MOTION`, or an injected bool) wins; else the **platform probe**; else a
deterministic **`false`** (motion allowed). `parseOverride` is case-insensitive and total —
`1/true/yes/on`→true, `0/false/no/off`→false, and **anything else (empty/whitespace/garbage)
is ignored** (`null`, falling through to the probe) so bad input never panics. The probe is
a narrow injectable `Probe` vtable (mirroring `a11y.Provider`): `PlatformProbe` does the
real query, `FixedProbe`/`nullProbe` keep every test SDL/OS-free.

On Windows the platform query calls `SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, …)`
**once** — the documented live-state "client area animation" flag (Settings → Accessibility
→ Visual effects → Animation effects), with `reduced_motion = !animations_enabled`. It links
against `user32` (already linked by the vendored SDL C build), so no `build.zig` change and
no registry read. SDL exposes no cross-platform reduced-motion abstraction, so on every
non-Windows target the probe deterministically reports `null`→`false` rather than pretending
a preference was read.

**Inventory and the functional/decorative split:** the action-tile underbar and the
ration-dial fill are *functional determinate progress/simulation readouts* — they remain
visible under reduced motion, unchanged. The one genuinely decorative clock-driven
oscillation is `status.heartbeat_color` (used only on the dev `mock.zig` showcase); under
reduced motion it freezes its sine phase to the `0.5` midpoint via `Policy.phase`. No
production optional transitions exist yet (no tween engine — that is RENDER-08), so the
policy ships a reusable **snap gate**, `Policy.snap(T, to, value)`, returning the end state
`to` when reduced motion is on and the caller's interpolated `value` otherwise, ready for
RENDER-08 to route every future optional transition through one policy check. `src/ui`
stays motion-unaware.

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
pub const list = .{ fill, image, svg, line, text, outline };  // back → front
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

## Five-pass profiling

The desktop loop uses the engine's profiled layout variant, sums its three solve timings
across roots, then times aggregate `stamp_rects` and `draw_tree` loops. A generic
`FrameProfiler` reports average/max microseconds and stamping share every 600 frames.
Presentation, simulation, event polling, and UI construction are intentionally outside
this diagnostic: the question is whether stamping is material relative to the other four
UI tree passes. Representative worst-case capture remains QA-17; absent that evidence,
the existing paint-order stamp walk stays unchanged. A bounded 600-frame desktop smoke
capture on 2026-09-07 (current Act I screen, development build) reported averages of
4.7µs intrinsic, 6.9µs relative/grow, 7.8µs placement, 8.2µs stamping, and 2370.5µs
drawing: stamping was 0.3% of these five measured passes (93.6µs max in that window).
This is evidence against a speculative rewrite, not a QA-17 worst-case result.

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
a root to the render walk. `El.prior_geometry()` explicitly reads the last stamped global
rect plus inherited clip (null before a slot is stamped). Its `Geometry` value converts
points/rects between global and node-local pixel space and exposes effective global/local
clips; use it for overlays, board math, zoom anchors, and drag thresholds instead of
manual coordinate subtraction.

Behavior refinements also chain on `El`. `pass_through()` removes a geometry-only probe
from hit testing; `hit_test(predicate)` installs a static host predicate with signature
`fn(ui.Rect, x, y) bool`. Core still checks pass-through, inherited clip, and the full
rectangle first. A false result falls through to the next painted slot, so a board can
supply hex containment without putting hex knowledge in the engine. The declaration is
frame-scoped and must not capture arena data; omitting it on the next build restores the
normal rectangular hit box.

For nested controls, `El.consume(.clicked)` observes and clears that typed flag on the
child and its stamped ancestors while preserving hover and unrelated flags. Descendants
consume before ancestor action decisions; ancestors re-query afterward. `capital_row`
uses this for its nested cancel control, so cancel no longer needs a manual `!cancelled`
guard to keep the containing build action from firing.

`UiCtx` also exposes singular stable-key pointer capture. A drag-capable widget captures
its queried key on press, lets subsequent `mark` calls route motion/release flags to that
owner outside its box, then owner-releases; the event layer cancels capture and pending
activation on platform cancellation or window-focus loss. Disappearing owners are pruned
automatically. This is still generic mechanism: host `PointerActivation` owns pointer
identity and click suppression, while `ui_client.drag` owns concrete math. Both production
scroll thumbs now capture and owner-release; `ThresholdDrag` shares the strict `>4px`
boundary for the future Act II board and slider, neither of which exists in production yet.

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
straight onto the node through `El`'s `with_layout` / `with_flow` / `with_gap` / `with_offset` /
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
`theme` values are art direction and live outside this folder.
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

## `widgets.zig`

The palette that predates `elements` — `label`, `button`, `panel`, `scroll_view`, `modal`,
`tooltip`, `text_input`. Nothing outside this folder calls it: the screens moved onto
`pages/templates/`, so it stays reachable only through `root.zig`'s re-exports. Retiring it is
in [`../../docs/roadmap.md`](../../docs/roadmap.md).
