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

**Design tokens are encoded once (KIT-01).** Colors split by *where a role belongs*: the ten
foundation roles are on `Theme` (`bg`/`panel`/`line`/`line2`/`dim`/`fg`/`acc`/`warn`/`danger`
and the KIT-01 addition **`good`** — success/gain, the semantic counterpart to `danger`), and
the game's finalized values live in `src/palette.zig`. Colors the engine has no concept of stay
out of `Theme`: the terminal **ground** and the six **resource/sector** hues (Food/Water/Fuel/
Metal/Minerals/Biomass) are game content in `palette.zig`, carried on `View` (`view.ground`,
`view.resources`) and installed each frame by `build_ui`. The non-color scalars — page padding,
the gap ladder, the hairline width, the control-height ladder, the rail widths, and re-exports
of the typography sizes (`ui_client/type.zig`) and functional-transition durations
(`ui_client/tween.zig`) — are named once in `src/tokens.zig`, so a call site cites
`tokens.pad_page` / `tokens.gap.section` / `tokens.control.h_std` rather than a bare literal.
All token scalars are *logical* px/seconds; the one logical→device multiply stays downstream
(`type.toDevice` / `view.dp` / `paint.hairline`).

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
  follows that same contract. The registry currently contains `TextState` (a bounded owned buffer + the px to render at — `update` copies a source in full or **refuses it as a whole** past `TextState.cap`, setting a
  `refused` flag and rendering nothing rather than a silently cut / mid-codepoint tail (TEXT-01); a `wrap_width` of 0 keeps the fast single-line path, a positive value opts the node into constrained word-wrapped multiline via `features/wrap.zig` (TEXT-02) while an `overflow` cell clips/ellipsizes a fixed width (TEXT-03) and `tracking` sets device-px letter-spacing (TEXT-04), and `orientation` rotates a single-line label 90° counter-clockwise at blit for the collapsed rail (TEXT-06). Since **TEXT-05** it also **owns a cached GPU texture** (`tex` + `cache_key`): **every** accepted variant — single-line (tracked or not), wrapped, `.clip`, and `.ellipsis`, including the tracked combinations — rasterizes into **one composite white texture** the first time it is drawn, caches the uploaded composite keyed by every render-affecting input, and re-blits it — tinted at draw, so color is not a key dimension (nor is orientation, a final-blit transform) — instead of re-rasterizing every frame; no variant re-rasterizes on a cache hit. The composite is generated atomically (`renderComposite`) into a scoped render-target texture with the renderer's target/clip/draw-color/blend snapshotted and restored, so a failed generation caches nothing and retries; it declares `deinit` like `SvgState` so the eviction hook frees the texture exactly once), `ScrollState`,
  `TabsState`, `StepState`,
  `TextInputState`, `LineState`, `GeometryState`, `BuildViewState` and `SvgState`. `LineState` and `GeometryState` are the ones that carry
  *variable-length* data — a polyline's points, and an indexed triangle mesh's vertices/indices — since `RenderData` holds a single payload
  per feature and coordinates don't fit in a tint; fixed capacity keeps them POD (a mesh too large for the cap is refused whole, so an over-budget shape draws nothing rather than a torn mesh). `SvgState` and `TextState` own a GPU texture, so they declare `deinit` and the cache's
  eviction hook frees it when the node disappears. The pure cache-key/decision/lifecycle logic for `TextState`'s texture lives SDL-free in `features/text_cache.zig` (with a deterministic fake backend), so hit/miss/invalidation/reset/prune/reuse/growth is unit-tested without a graphics context. Feature `State` types live *here*, not
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

**Consistent button semantics (KIT-03).** Every stock button (`widgets.button`,
`icon_button`) follows one contract: the **whole outer box owns the interaction** and the
label/icon is content; a **disabled** button cannot activate — it is not registered for focus
(so keyboard Enter/Space can never reach it) and any pointer `.clicked` that lands on it while
disabled is **consumed** at the widget, so it neither reports to its caller nor bubbles to an
ancestor; the **pressed** state is visible (`.held` lifts the ink to `acc`); and **keyboard
activation matches pointer activation** because Enter/Space map to `command.activate`, which
`markKey`s the focused control's `.clicked` — the very same flag a pointer release produces.
A **nested** cancel/close inside a row activates by consuming `.clicked` (`El.consume`), which
clears the flag on itself *and* its ancestors so the row doesn't also act — while leaving
`hovering` untouched, so the ancestor stays hovered. Colors are single-sourced: the button
resolves the KIT-02 `style.btn_primary` / `btn_icon` fragment and paints its border and ink
from that one result, so the resting/hover/held/focus/disabled mapping can never drift between
variants.

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

## Transition/tween state (`tween.zig`)

RENDER-08 adds a small **host-layer tween registry** for the prototype's few *functional*
transitions — the Holdings column/gap collapse (`120ms`), a stock token's font change (`90ms`),
and the board's opacity/stroke changes (`100–110ms`, named `holdings_s`/`stock_token_s`/`board_s`
as seconds). It is a deliberately tiny **value provider**, not a general timeline engine and not
a node feature: a consumer keys a scalar `Tween` by a **stable node/domain id** (a `u64`, the
same stable-key discipline the interaction/focus/semantic registries use, so a tween survives
reorder/filter/rebuild), `main` advances all tweens once per frame by the frame `dt`, and the
consumer reads `registry.value(id, fallback)` to drive a size, gap, opacity, or font px.
`retarget(id, to, duration)` **interrupts/reverses from the current value** — a half-open rail
glides back from where it is rather than snapping and re-animating — while a brand-new id sits
at its target (a control's first appearance is its state, not a transition). It **obeys reduced
motion** by routing through the INPUT-10 `motion.Policy`: when reduced motion is on, a tween
reports its end value immediately (the transition snaps, the functional end state always
reached). Fixed-capacity and non-allocating (a full table drops a new id, so its `value` returns
the fallback target — snap, never crash); `Resources.tween` holds it inline and `main` projects
the motion policy onto it each frame. Pure and SDL-free (the caller supplies `dt`), so
interpolation, interrupt/reverse, reduced-motion snap, and stable-key independence are unit-tested
without a renderer or a clock. The named consumers (Holdings KIT-05, StockToken KIT-12, board
BOARD-05) read this when they land.
## Frame-local view metrics (`view.zig`)

VIEW-01 computes a `ViewMetrics` once per frame in `build_ui`'s prologue and stores it on
`Resources.view.metrics`. Everything responsive reads it. It keeps **two scales apart**: the
**DPI scale** (`dpi_scale` = drawable pixels ÷ window coordinates) is the crispness factor set
onto `View.scale`, so text opens the font at the right device size (`type.toDevice`) and
hairlines snap to whole device pixels (RENDER-06) — it does *not* change layout, which is
solved in logical (window-coordinate) space; and the **responsive class**, derived from the
logical width against the prototype's `760/560/440` breakpoints, drives the layout branches
(VIEW-04) and the framed/centered terminal (VIEW-03). `compute(logical_w, logical_h,
pixel_density)` is pure and SDL-free (the prologue supplies the window's coordinate size and
`getPixelDensity`, degrading to the reference metrics on a query error), so the reference-fit,
centering, and breakpoint math are unit-tested without a window. `terminal` is the terminal
rect in logical px — capped at the `900×820` reference and centered when framed (wider than
760), else the full window; `width_class.atMost(.w560)` is the natural stacked-breakpoint test,
and `metrics.framed()` gates the outer terminal chrome.

**One logical→device scaling helper (VIEW-02).** The layout is solved in **device pixels** (the
space the renderer draws), so every authored dimension is a *logical* px value multiplied by the
frame scale exactly once, through `view.dp(logical, scale)` — the single conversion point. The
El/style seams call it: `El.with_size` (`.fixed` extents), `with_gap`, `with_offset`,
`with_wrap`/`with_cell` (text measurement widths), and `style.apply` (padding/gap). Fonts route
through the sibling `type.toDevice`, and hairlines through `paint.hairline` — the same scale.
The fullscreen root and modal scrim size to the drawable px (`metrics.px_w/px_h`), and pointer
coordinates are multiplied by `dpi_scale` at one seam in `main` (`pointerAt`) so hit geometry
(device px) matches. **Values read back from stamped geometry** (`.rect`, a parent's resolved
`size.*.fixed`) are already device px and must use `El.with_size_px` (no re-scaling) — the few
prior-frame-geometry sites (the action-tile underbar, the ration-dial pulse, the page content
box) do. **Not** scaled: simulation values and camera percentages are not dimensions. At DPI 1
(`scale == 1`) every conversion is identity, so production is unchanged; the scale becomes
load-bearing on a high-DPI display.

**Centered terminal workspace (VIEW-03).** The `pages/templates/terminal.zig` shell is what a
screen builds inside: it reads `metrics` and, when **framed** (logical width > 760), fills the
window with the near-black terminal **ground** (`#090806`) and places a `metrics.terminal`-sized
box — capped at `900×820` and centered — with a soft drop shadow (RENDER-05 `shadow.drop`), a
hairline border, its own `bg`, and **clipped** internals, returning the inner box for the screen
to fill. At **≤760** the terminal is the whole window (no ground/shadow/border/cap) — the
prototype's full-width mode. `play_game`/`gameover`/`act_one_end` build into the returned content
box. The terminal rect is scaled to device px once here.

**Responsive branches (VIEW-04).** Screens and templates read `metrics.width_class.atMost(.w560)`
(and `.w440`, `.w760`) to branch on the prototype's stacked breakpoints. What is wired today:
the HUD page padding tightens to `10px` at ≤560, and the optional "Act I ·" run-context label is
dropped at ≤560 (the functional Day counter always stays — reachability preserved). The page
grid is already a single stacked column, so ≤760 stacking is inherent. The remaining prototype
branches — the two/one action-column counts, hiding the BUILD effect/cost columns, and stacking
the trade-dialog actions — attach to their templates when those land (KIT-15/17/18/21, the board
BOARD-*) using the same `width_class.atMost` test; they have no consumer to branch yet.

**Resize without state loss (VIEW-05).** Because the UI is immediate-mode — `build_ui`'s
prologue recomputes `ViewMetrics` every frame and the tree is rebuilt from the arena — a
resize needs no relayout hook: layout, clip, and scroll limits recompute for free, and all
per-view state (focus, tab selection, query/sort/collapse, scroll offset) survives because it
lives in keyed pools addressed by stable `node.key`, not in the discarded tree. The one real
hazard is the **one-frame clickable ghost**: the event stage routes pointer hits against the
*previous* frame's stamped rects, so right after a resize a click could land where a control
*was*. `main` guards it — a `window_resized`/`window_pixel_size_changed` event sets a
`geometry_stale` flag and cancels any in-flight gesture; while set, pointer **activation**
(press → click) is suppressed, and the flag is cleared right after the frame re-stamps at the
new size. So a click during the stale frame is dropped rather than routed to a ghost, and
normal interaction resumes the moment geometry is fresh. Camera clamping is deferred with its
consumer (the board is not built).

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
pub const list = .{ fill, image, svg, geometry, line, text, outline };  // back → front
```

**The list's order is the z-order** — outline last, so a hover ring shows over an opaque
tile. Adding a visual is one module + one `list` entry + one `RenderData` field, with no
engine change; `assertFeature` turns a drifted descriptor into a build error rather than a
silently undrawn aspect.

**`geometry` — colored triangles and honest thick polylines (RENDER-03).** Backed by SDL's
`renderGeometry`, it draws untextured per-vertex-colored triangle meshes: a convex-polygon
fill (a hex body, a marker) and a thick polyline with correct **miter joins** (bevel fallback
past the miter limit) and butt/square **caps** (a hex rail, a distribution curve, a slider
diamond, a diagonal indicator). It is the second *variable-length* feature after `line`: a
mesh's vertex/index count does not fit in a `RenderData` payload, so the vertices live in a
pooled `GeometryState` and the payload (`?Geometry`) carries only a per-mesh `opacity`
multiplier (the RENDER-07 dimming hook). Points are **node-local unit-square** coords like
`line`, so a shape survives resize/zoom; `draw` maps them to device px through the node's box,
converts each per-vertex `Color` to SDL's float `FColor` with opacity folded into alpha, and
submits one indexed draw (the RENDER-01 `.blend` baseline makes vertex alpha composite, and
the render walk's clip stack crops the triangles). The tessellation math —
`fillConvex`/`fillConvexMulti` fan triangulation and `strokePolyline` — lives **SDL-free** in
`features/geometry_tess.zig` with a bounded `Mesh` builder that **refuses an over-capacity mesh
as a whole** (no torn triangle), so the whole fan/join/cap surface is unit-tested without a
graphics context. `El.polygon` / `El.polyline` are the fluent builders. `line.zig`'s
first-segment-normal thick approximation is **not** yet retired — that waits until the board
migrates onto this feature (roadmap RENDER-03).

**Linear-gradient composition (RENDER-04).** The same feature draws an explicit linear
gradient: `El.gradient(dir, stops, opacity)` fills the node box along `.horizontal`/`.vertical`
through an ordered list of `{ pos, color }` stops, tessellated (`fillGradient`) into a quad
strip whose per-vertex colors `renderGeometry` interpolates. It is deliberately narrow — the
two axis-aligned directions and explicit stops the prototype uses, **not** a CSS gradient
grammar. Two stops at the **same** position make a **hard split** (the eating-slider track:
`acc` then `line2`); a `tint → transparent` pair (an `a = 0` end stop) makes a **wash** (a
milestone/state fade), the transparent end compositing over what is under it via the RENDER-01
`.blend` baseline. Stops carry a full `Color`, so alpha rides along. The named consumers (the
range slider KIT-10/KIT-19, the milestone component KIT-20) are not built yet, so this ships
the primitive and its stops explicitly, tested SDL-free.

Clipping is *not* a feature. It is `Layout.overflow` in the engine, because it is geometry
two consumers read (the render walk, and eventually hit-testing), not a paint the backend
applies.

## The render walk (`draw.zig`)

`draw_tree(u, root)` runs per root tree, in list order — later trees paint on top. Each
node is a recursive pre-order paint carrying a clip stack: apply the inherited clip,
`inline for` the feature list dispatching every set aspect to its `draw`, then narrow the
clip for the subtree if this node is `.clip`. The traversal and the clip stack live here;
the primitives live with their features, so adding a visual never edits this file.

**Alpha-blending policy (RENDER-01).** The renderer's draw blend mode is set to `.blend`
explicitly — once at renderer creation (`main.zig`), and again at the top of every
`draw_tree` so the baseline is self-healing after a device reset. SDL's default is `.none`
(source *replaces* destination, ignoring `a`), which would render a translucent hover row,
modal scrim, dimmed/locked tile, or wash fully opaque; `.blend` makes the geometry
primitives every feature paints (`fill`/`outline`/`line` via `renderFillRect`/`renderLines`)
alpha-composite against what is under them. Texture features carry their own per-texture
blend mode: `svg`, `img`, and the cached `text` composite each set `.blend` before their
tinted blit, so a tint's `a` (a dimmed icon, a translucent label) composites consistently
rather than depending on a texture's creation default. The text compositor's render-target
pass (`renderComposite`) snapshots and restores the draw blend mode, so it never disturbs
this baseline. Colors carry alpha in their `a` byte (`Color` is SDL's `pixels.Color`), so a
translucent aspect is authored, not a separate feature. The dev `mock.zig` showcase carries
a "Blending" fixture — a translucent row-hover tint, a backdrop scrim over a bright block, a
dimmed locked tile, and a stacked-band wash — that reads correctly only when blending is on.

**Crisp hairlines at scale (RENDER-06).** A one-logical-pixel border, outline, focus ring, or
rail must stay a crisp whole-device-pixel line at any DPI scale, or it anti-aliases into a
blurry 1–2px smear and adjacent columns/rails **shimmer** as their sub-pixel coverage shifts.
`paint.hairline(logical_w, scale)` rounds a hairline width to a whole number of device px
(floored at 1), and `paint.snap(device_coord)` puts a hairline edge on a whole-pixel boundary.
The `outline` feature snaps its box edges and bar thickness through these; the `line` feature
snaps its stroke width. Today `View.scale` is `1`, so both are identity for integer-authored
geometry (production is unchanged); they become load-bearing when VIEW-01 feeds a real
fractional DPI factor. Pure and SDL-free, tested at scale ≠ 1.
**Per-node visual opacity (RENDER-07).** A node carries an optional `render_data.opacity`
(0..1, default 1) — *not* a paint feature but a render-walk modulation. `draw_node` carries an
inherited opacity down the tree (alongside the clip stack), multiplies each node's own opacity
into it, folds the product into **every** feature's paint alpha (`paint.applyOpacity` for the
color features, `setAlphaMod` for `img`, the combined mesh alpha for `geometry`), and inherits
the product to the children. So a whole subtree dims at once — a board tile filtered out, a
disabled control — **without recomputing any child's color**; the caller sets one
`El.with_opacity(x)`. Opacity is **purely visual**: hit-testing (`mark`/interaction) never
reads it, so a dimmed node's clickability is unchanged — state logic decides that separately.



## Shadow / backdrop composition (`shadow.zig`)

SDL has no blur, so the prototype's soft drop shadows (`box-shadow: 0 16px 80px #000a` on the
terminal, `0 18px 80px #000d` on a dialog, `0 4px 14px #0008` on a popup) are approximated by
a small **bounded stack of translucent-black rectangles** (RENDER-05) — each a little wider
and more offset than the last, at low alpha, building a soft penumbra without a real gaussian.
Deliberately understated: flat black translucency, no rounded corners, no gloss. The pure,
SDL-free `shadow.layers(Spec)` turns a prototype-style `{ offset_y, blur, base_alpha, count }`
into ordered `Layer`s (outermost widest/faintest → inner tightest/darkest, each carrying the
full drop offset, alpha divided across the layers so they *sum* to the intended darkness) and
is unit-tested without a renderer. `shadow.drop(...)` is the thin `El` emitter: call it before
building a box so the layers paint under it (siblings paint in child order); the RENDER-01
`.blend` baseline composites them. `shadow.backdropColor(ground)` is the modal/dialog scrim —
the near-black terminal ground at the prototype's `0xd9` alpha, for the fullscreen root a modal
already builds. The named consumers (the centered terminal VIEW-03, the dialog/popup shadows
KIT-08/09, the modal backdrop KIT-08) wire this in when they land.

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

**The primitive fragment library (KIT-02).** `style.zig` ships the shared vocabulary of
*look* every template composes from, so a call site names an intent, not a color: surfaces
(`panel`, `section_heading`), the button family (`btn_primary`/`btn_secondary`/`btn_text`/
`btn_icon`/`btn_link` — a shared `btn_ink` maps published state → color: `dim` disabled,
`acc` on held/hover/focus-visible, else the variant's resting ink), `tab`/`chip`/`tag`,
semantic state text (`state_good`/`state_warn`/`state_danger`/`state_muted`, the KIT-01 roles
including `good`), interaction chrome (`row_hover`, `focus_ring` — drawn **only** on
`.focus_visible`, never bare hover — `disabled_chrome`, `selected_chrome`, `provisional` the
dim-dashed placeholder box), and small chrome (`meter_track`/`meter_fill`, `progress_fill`,
`legend_dot(.food)` keyed to the six `view.resources` hues). The **stateful** ones are the
`fn(*UiCtx, *Node) Style` form — they read the node's published `Interaction` bits
(`publishControlState` sets `disabled`/`focus_visible`/`selected`/…) and return the chrome for
that state; the **static** ones are plain values. Every color is a `Theme` *role*, never a
literal, so these live in the foundation (they encode role/interaction policy, not the game's
values); precedence is the caller's — a later tuple fragment overrides one variant field.

Presence follows the layer. **Decoration** aspects (`fill`, `outline`) are present iff set.
**Content** aspects are present because content was given, so unset style falls back to a
default — which is why a `text` leaf is visible with no styling at all. Applying a `font`
to a text node re-measures the string at that size and stores the px on the text state, so
`draw` renders at it. On a node with no text, `font`/`text` are inert and a debug assert
catches the mistake; `Style` stays uniform rather than typed per widget so tuple
composition stays free.

The style payload carries every *render-affecting look* an aspect has, each an optional
field that folds last-non-null-wins (RENDER-02). For text that is `text` (glyph ink), `font`
(logical size), `tracking` (em letter-spacing), and `transform` (case) — the TEXT-04
typography contract. For a texture aspect it is `tint`: a set `tint` recolors a present `svg`
raster (rasterized white, tinted at blit — the same model as the `text` composite), so a
template styles an icon's color through the fold instead of assigning `render_data.svg`
directly. `text` (glyph ink) and `tint` (texture ink) are separate fields on purpose, so one
tuple can carry both and neither shadows the other; `tint` no-ops on a node with no svg, and
because it is not typography it does not trip the inert-typography assert. **`wrap` and
`overflow` are deliberately *not* style fields.** They set a text node's *measurement
constraint* (its reserved box), which is placement, not look — so they stay imperative on
`El` (`with_wrap` / `with_cell`), the same rule the whole placement layer follows. Adding
them to `Style` would be exactly the "turn style into placement" the design forbids; a later
`with_style(.{ font })` re-measures at whatever constraint `El` already set.

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

### Constrained multiline text (TEXT-02)

A text node is single-line by default (`TextState.wrap_width == 0`) — one `renderTextSolid`
over the content box, the fast path dense rows pay nothing for. `El.with_wrap(max_w)` (or
the `el.textWrapped` sugar) opts a node into **constrained multiline**: it stores an explicit
maximum content width and re-measures, so the node reports the wrapped `width`×`height` and
renders exactly those lines.

The line breaking lives in `features/wrap.zig` as a **pure, allocation-free** routine
`wrapLines`, parameterized by a small `Measurer` (`width`/`prefixBytes`) so it stays
callback-free at the engine boundary *and* SDL-free to test. `features/text.zig` backs the
`Measurer` with the live font, and **both** `attach` (measure) and `draw` (render) run the
*same* routine over the same metrics — so the reserved box and the drawn glyphs cannot drift,
the TEXT-01 "measure and draw read one source" invariant extended to N lines. The algorithm
is greedy word wrap: it packs space-separated words while the line fits, breaks on `\n`
(`\n\n` yields a genuine empty line), collapses run-of-space at breaks, and hard-breaks a
single over-long word on **codepoint boundaries** via `TTF_MeasureString` (always ≥ 1
codepoint, so tiny positive widths terminate and never split UTF-8). It deliberately does **not**
use SDL's own `renderTextSolidWrapped`/`GetStringSizeWrapped`, which do not guarantee
measured-lines == rendered-lines and whose over-long-word handling is not this deterministic
hard-break. Height is `line_count * font.getLineSkip()`; the reported `baseline` is the *last*
line's descent, so a wrapped block still baseline-aligns as the final line in a row.

Wrap is **placement, not style** (it sets a measurement constraint), so it is imperative like
`with_size`; a later `with_style(.{ font })` re-measures through the same shared routine and
re-wraps at the same width. `wrap_width` stays **POD** (spans are recomputed, never stored),
so the pool contract is unchanged and TEXT-01's `cap = 256` **whole-refusal** is preserved — a
too-long source is still refused whole and reserves a zero box, wrapping or not. The explicit
width is the seam VIEW-01's `ViewMetrics` will later feed; today `log_view` passes the scroll
column width and `act_one_end` passes an explicit dialog prose width.

### Single-line overflow cells (TEXT-03)

Where a label must live in a slot of an **explicitly allocated width** — a catalog name
column, a status readout in a narrow tile — `El.with_cell(mode, cell_w)` opts the node into a
single-line *cell* with an explicit overflow discipline. It sets `TextState.overflow`
(`.visible` / `.clip` / `.ellipsis`) and `overflow_width` (a **required nonnegative** cell
width; `0` is a legal zero-width cell), clears `wrap_width` (a cell is single-line; wrapping
and overflow are mutually exclusive, and wrapping wins if both are somehow set), and
re-measures — placement, not style, exactly like `with_wrap`.

The point is **geometry**: `remeasure` writes `data_width = overflow_width`, so the node's
layout box *and* hit box are the allocated cell, **never** the unbounded glyph width — a
widening label can never shove its neighbors, and a shorter one still reserves its column;
`data_height`/`baseline` still come from the font, so a cell baseline-aligns like a plain
label. Only the *visible glyphs* are bounded:

- **`.clip`** — `draw` blits the whole accepted string, but scopes the SDL renderer clip to
  the intersection of the *prior* clip and the cell, then **restores the prior clip in a
  `defer`, including on error**. It snapshots both `getClipEnabled` and `getClipRect`, because
  the SDL binding reports an enabled zero-area clip as `null`, just like disabled clipping;
  preserving the enable bit keeps a fully clipped ancestor fully clipped instead of widening
  it to the text cell. Restoring that normalized prior state also means a cell nested in an ancestor `.clip` like a scroll viewport never leaks outside it. This is
  done in the feature because the engine's `Layout.overflow = .clip` crops a node's *children*,
  and a text leaf paints its own glyphs before that narrowing; the cell also sets that layout
  flag so any decoration subtree and hit-testing get the same box.
- **`.ellipsis`** — `draw` recomputes the pure, SDL-free `wrap.ellipsisFit` (deterministic, one
  source of truth for measure and render): if the string fits it draws whole; else, with the
  glyph budget `cell_w − ellipsis_width` (the ellipsis `"\u{2026}"` width is **font-measured**),
  it draws the longest **codepoint-aligned** prefix that fits plus the ellipsis. A budget `≤ 0`
  (cell narrower than the ellipsis) draws **nothing** — never a glyph wider than the allocated
  cell, never a split codepoint. If a live SDL font measurement fails, the renderer returns
  without drawing that cell.

Both modes keep `overflow` **POD** (the fit is recomputed, never stored), so the pool contract
is unchanged and TEXT-01's `cap = 256` **whole-refusal** is preserved — a refused string draws
nothing and reserves the cell (or zero) box, cell or not. `.visible` + 0 is the unchanged
fast/wrapped path. Integrated at two representative sites: `capital_row`'s name column
(`.ellipsis` at its fixed column width) and `mock`'s heartbeat readout (`.clip` at 64px).

### Rotated collapsed-rail copy (TEXT-06)

The collapsed Holdings rail carries its `HOLDINGS` label set vertically, reading
bottom-to-top — a 90° counter-clockwise turn. `TextState.orientation` names the only two
axis-aligned orientations the product uses: `.horizontal` (every ordinary label) and
`.counter_clockwise_90`. `El.with_orientation(...)` sets it (clearing the incompatible
single-line `wrap`/overflow-cell constraints first, since the rail label is one line) and
re-measures; `El.vertical()` is the convenience spelling for the counter-clockwise mode.
A bounded enum, not an arbitrary angle, is deliberate: 90° is an exact width/height swap, so
its bounding box stays axis-aligned and no broader non-rectangular hit-geometry policy is
needed.

Orientation is a **final-blit transform, not a composite-pixel input**. The glyphs still
rasterize into the TEXT-05 upright white composite exactly as horizontal text does, so
orientation is *not* a cache-key dimension — switching a node between horizontal and vertical
reuses the same cached texture with no glyph re-raster or re-upload. `remeasure` applies a
pure axis transform (`orientMetrics`) to the upright metrics: horizontal keeps them, and
counter-clockwise swaps width/height and zeroes the baseline (a vertical control label does
not participate in horizontal row-baseline alignment). Because the engine stamps that swapped
node box, **the layout box, the focus outline, and the rectangular hit target are the rotated
footprint** — layout, focus, and hit geometry agree with the rendered pixels by construction,
never rotated independently. At blit, the upright `w×h` texture is centered on the swapped
`h×w` content box and drawn with SDL's `renderTextureRotated` at 270° clockwise (= 90°
counter-clockwise) about its own center, landing the final pixels exactly on the oriented box.
The placement is pure geometry (`blitPlacement`), tested SDL-free. The `mock` showcase carries
a 36×124 collapsed-rail stand-in whose `.vertical()` `HOLDINGS` label reads bottom-to-top at
the prototype's 9px / 0.09em collapsed-rail density.

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
