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

**Screens lay out; templates paint.** A screen places nodes — `div`, `spacer`, `item`, the
`with_size`/`with_flow`/`with_gap`/`with_layout` chain — and composes the shelf, and that is
all it does with `El`. A styled node or a text leaf is a template's, down to the one-line
readouts (`pages/templates/copy.zig`: the catalog summary, the empty-list message, a curtain's
headline and lede), because a style chosen in a screen is art direction the shelf cannot see
and the next screen copies or drifts from. `tools/boundary_check.sh` fails on `with_style` or a
text node in any file under `src/pages/` outside `templates/`; the debug page (the template
audit harness) paints by design and are exempt.

The foundation owns the **roles** a widget paints from; the game owns the **values**. So
`text` and `svg` may default a node's ink to `res.view.theme.fg` without reaching upward —
`Theme` is this layer's own type, with its own defaults.

**Design tokens are encoded once.** Colors split by *where a role belongs*: the ten
foundation roles are on `Theme` (`bg`/`panel`/`line`/`line2`/`dim`/`fg`/`acc`/`warn`/`danger`
and **`good`** — success/gain, the semantic counterpart to `danger`), and
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
  `refused` flag and rendering nothing rather than a silently cut / mid-codepoint tail; a `wrap_width` of 0 keeps the fast single-line path, a positive value opts the node into constrained word-wrapped multiline via `features/wrap.zig` while an `overflow` cell clips/ellipsizes a fixed width and `tracking` sets device-px letter-spacing, and `orientation` rotates a single-line label 90° counter-clockwise at blit for the collapsed rail. It also **owns a cached GPU texture** (`tex` + `cache_key`): **every** accepted variant — single-line (tracked or not), wrapped, `.clip`, and `.ellipsis`, including the tracked combinations — rasterizes into **one composite white texture** the first time it is drawn, caches the uploaded composite keyed by every render-affecting input, and re-blits it — tinted at draw, so color is not a key dimension (nor is orientation, a final-blit transform) — instead of re-rasterizing every frame; no variant re-rasterizes on a cache hit. The composite is generated atomically (`renderComposite`) into a scoped render-target texture with the renderer's target/clip/draw-color/blend snapshotted and restored, so a failed generation caches nothing and retries; it declares `deinit` like `SvgState` so the eviction hook frees the texture exactly once), `ScrollState`,
  `TabsState`, `StepState`,
  `TextInputState`, `LineState`, `GeometryState` and `SvgState`, plus the templates' logical states (`TabsState`, `SelectState`, `DisclosureState`, `SliderState`, `RailState`, `CatalogState`, `TradeState`, `ModalState`). `LineState` and `GeometryState` are the ones that carry
  *variable-length* data — a polyline's points, and an indexed triangle mesh's vertices/indices — since `RenderData` holds a single payload
  per feature and coordinates don't fit in a tint; fixed capacity keeps them POD (a mesh too large for the cap is refused whole, so an over-budget shape draws nothing rather than a torn mesh). `SvgState` and `TextState` own a GPU texture, so they declare `deinit` and the cache's
  eviction hook frees it when the node disappears. The pure cache-key/decision/lifecycle logic for `TextState`'s texture lives SDL-free in `features/text_cache.zig` (with a deterministic fake backend), so hit/miss/invalidation/reset/prune/reuse/growth is unit-tested without a graphics context. Feature `State` types live *here*, not
  in their feature module, because `UiState` is scanned to generate the pools and a feature
  already imports this file — declaring state in the feature would be an import cycle; each
  feature re-exports it as `pub const State` to keep the contract readable.
  Per-view state lives on the node that is always built and is handed down by pointer — the
  Act I surface holds BUILD's catalog state and search editor, so hiding the tab prunes
  nothing (see *Who owns a template's state* under the `El` handle). `retain_child` remains
  for an owner that keeps a hidden direct child's slot alive without hoisting it.
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

**Consistent button semantics.** Every button (the `button` template and the icon
controls built on `El`) follows one contract: the **whole outer box owns the interaction** and
the label/icon is content; a **disabled** button cannot activate — it is not registered for
focus (so keyboard Enter/Space can never reach it) and any pointer `.clicked` that lands on it
while disabled is **consumed** at the control, so it neither reports to its caller nor bubbles
to an ancestor; the **pressed** state is visible (`.held` lifts the ink to `acc`); and
**keyboard activation matches pointer activation** because Enter/Space map to
`command.activate`, which `markKey`s the focused control's `.clicked` — the very same flag a
pointer release produces. A **nested** cancel/close inside a row activates by consuming
`.clicked` (`El.consume`), which clears the flag on itself *and* its ancestors so the row
doesn't also act — while leaving `hovering` untouched, so the ancestor stays hovered. Colors
follow the state→role mapping — `dim` when disabled, `acc` on held/hover/focus-visible,
else the resting ink — which the `style.btn_*` fragments encode for any control that composes
them.

## Ordered pointer routing and overlays

Every pointer event reaches the interaction store through the engine's reverse paint-order
walk. Hover and primary press use capture-aware `mark`/`markTarget`; every primary up
routes `.released` before geometric click validation; every SDL wheel event routes
`.wheel` at its own pointer position. Scroll views require their viewport's routed
`.wheel` flag before consuming the frame model's accumulated x/y delta, so mere hover no
longer authorizes unrelated scroll containers. Capture, when present, wins before geometry
for all four routed event types.

Opaque independent overlays participate by querying their root. `modal` queries both the
fullscreen scrim and dialog; because roots are stamped in the same order they draw, listing
them after the screen blocks covered controls for hover, press, release, wheel, and click
without `modal_open` guards. Geometry-only or intentionally transparent overlays must opt out
explicitly with `pass_through`.

**Overlay controls on `El`.** `modal` adds a **focus trap**: it calls
`ctx.beginFocusScope()` before the caller builds the dialog's focusables, and because a modal
is stamped last, everything registered after that call is the trapped suffix — `moveFocus`
(Tab/Shift+Tab) then cycles only within the dialog and can never land on a control the scrim
covers (the scope carries into the next frame's traversal in `focus.zig`; a frame with no
modal has ordinary whole-frame traversal). The shell also owns the open edge: a pooled
`ModalState` on its root records the key focused on the frame the dialog first builds and
reports `first_open`; the game's `modal.dismissed`, the dialog's end-of-build step, focuses
the primary control on that frame (else the first control in the trap, `focusFirstInScope`)
and re-requests the opener on the closing frame. The slot is pruned with the dialog, so every
open starts clean.
`tooltip` is now **pass-through** (`setPassThrough`): despite being stamped last it takes no
pointer hit, so it never intercepts input to the control it describes; `clampToTerminal` keeps
it inside the terminal rect. `text_input` remains backed by the authoritative `editor.zig`
`LineEditor` model.

## Scripted input replay and keyboard journeys (`replay.zig`, `journey.zig`)

Everything above the SDL event poll is pure: `PointerActivation`, `command.fromKeyEvent`, and the
engine's `markTarget`/`markKey`/`moveFocus` family are value transforms over the slot and focus
pools, not SDL calls. `replay.zig` lifts that lower half of `main.zig`'s event loop into one
reusable, SDL-free driver — `Driver.feed` takes a scripted pointer/key/text/wheel `Event`, updates
the `Input` model, and runs the same activation + command + event-stage order the game does — so an
interaction state machine is regression-tested by stamping the slots it probes, scripting input, and
reading interaction flags back. Clipboard-bound editor commands are recognized but not executed (no
window); pixel rendering stays out. `journey.zig` builds keyboard-only Act I/II journeys (QA-14/15)
on top: its `Scene` runs the build→`endFrame`→event-stage cadence so focus traversal always reads a
completed frame's registered order, and the journeys assert Tab/Shift+Tab, roving arrows, Enter
activation, Escape dismissal, the `/` search shortcut, and range-owner arrows reach every control
without a pointer. Both live in `test-ui`; the matching rendered screens are seeded by the
deterministic fixtures in `pages/fixture.zig` for the screenshot/eyeball pass.

## Visual interaction state ownership

The host vocabulary separates pointer facts from semantic facts. Main republishes `held`
on the stable press key while primary input remains down, `dragging` once
`PointerActivation` crosses 4px (including release-position movement), and `captured` on
the exact `Ctx` capture owner. These are transient like hover/press/release/click; button,
action, build-row, tab, ration, filter, and cancel chrome can react to held immediately.
The scroll view captures its thumb on primary press, preserves the exact
press origin even when motion shares the same SDL event batch, maps pointer travel to the
clamped offset, applies the release position, and owner-releases. Capture-first routing keeps
it dragging beyond its narrow track; focus loss/cancellation, lost ownership,
disappearing overflow, and prune repair all terminate safely. `ThresholdDrag` exposes the
same strict `>4` logical-pixel boundary as `PointerActivation`: a drag-capable control can
capture immediately while emitting no movement before threshold, and the activation state
suppresses the tile/control click generated by a crossed gesture.

`CursorState` resets to default each frame and accepts paint-order requests from hovered
controls. Buttons/chips use pointer, disabled actions use not-allowed, text fields use
text, and scroll thumbs use grab/grabbing. `PlatformCursors` owns the SDL system handles,
falls back to the default when a shape is unavailable, and maps both grab variants to
SDL's `move` cursor because SDL 3 exposes no distinct grab/grabbing shapes. The vocabulary
also includes horizontal-resize.

`ControlState` carries `disabled`, `focused`, `focus_visible`, `selected`, and `checked`.
`publishControlState(ctx, key, state)` writes all five—including false—on every build.
Authority stays elsewhere: enabled/affordability/readiness and row classification decide
disabled; the focus registry decides text-input focus; `TabsState` and `CatalogState`
decide tab/filter state; simulation `Metabolism.rate` decides the eating-policy slider's
position.
The interaction slot is their cross-widget visual/semantic projection, never an
independent toggle. Current desktop policy visibly outlines every focused control, so
`focused` and `focus_visible` are both true.

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

`semantics.zig` is a fully host-side accessibility model — the source the accessibility
bridge reads, **not** a second source of truth. The generic `src/ui` engine knows
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
they already call `publishControlState` (`text_input`/`modal`, and game `tabs`/`slider`
/`build_list`/`capital_row`/`action_tile`/the modal header and offer rows). Honest
limitations: `describeIconButton` and `describeProgressBar` take a caller-supplied name
because a glyph or a bar has no string of its own, and `expanded` is owned only by the dialog
shell.

## Accessibility bridge (`a11y.zig`)

`a11y.zig` is the host-side **bridge** that consumes the semantic model — it never
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

The Windows UIA seam is a narrow `Provider` vtable
(`getRoot`/`elementFromKey`/`mapRole`/`raiseFocus`/`raiseAnnouncement`) — exactly what a
`WM_GETOBJECT`-answering `IRawElementProviderFragmentRoot` needs. The default `NoopProvider`
implements it as inert sinks (no element, custom role id `0`, no-op raises), so the whole
bridge runs and is tested with no platform surface, and a real provider slots in without the
bridge, `src/ui`, or the semantics source changing.

`Capabilities` is an honest report of what this build ships:
`keyboard`/`visible_focus`/`non_color_state`/`live_region_plumbing` are `true`, and
`screen_reader_export` is **`false`**. This build
exports no live screen-reader tree because a UIA provider must hook the SDL-owned window's
`WndProc` to answer `WM_GETOBJECT`, and `zig-sdl3` 0.1.6 does not implement
`SDL_SetWindowsMessageHook` (only the X11 hook exists); hand-rolled subclassing or forking
the vendored binding are the risky, policy-leaking dependencies this layer forbids. Genuine
HTML/ARIA parity is therefore unavailable and is not claimed. All Windows/platform policy
stays here in `ui_client`; `src/ui` remains accessibility-unaware.

## Reduced-motion policy (`motion.zig`)

`motion.zig` holds a one-bit host-side **reduced-motion policy** that decides whether *optional*
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
eating-policy slider position are *functional determinate progress/simulation readouts* — they remain
visible under reduced motion, unchanged. The one genuinely decorative clock-driven
oscillation goes through `Policy.phase` (no shipped screen draws one today); under
reduced motion it freezes its sine phase to the `0.5` midpoint. Optional
transitions go through the tween registry (below), which snaps them through the policy's
**snap gate**, `Policy.snap(T, to, value)` — the end state `to` when reduced motion is on,
the caller's interpolated `value` otherwise. `src/ui` stays motion-unaware.

## Transition/tween state (`tween.zig`)

`tween.zig` is a small **host-layer tween registry** for the prototype's few *functional*
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
motion** by routing through the `motion.Policy`: when reduced motion is on, a tween
reports its end value immediately (the transition snaps, the functional end state always
reached). Fixed-capacity and non-allocating (a full table drops a new id, so its `value` returns
the fallback target — snap, never crash); `Resources.tween` holds it inline and `main` projects
the motion policy onto it each frame. Pure and SDL-free (the caller supplies `dt`), so
interpolation, interrupt/reverse, reduced-motion snap, and stable-key independence are unit-tested
without a renderer or a clock. Its consumers are the **Holdings/BODY rail**
(`pages/templates/rail.zig`) and the Act I workspace's inter-column gap, which follows the
same policy: the rail keys a tween by its own node id and rides the width
between `tokens.rail.collapsed` (36) and `tokens.rail.expanded` (252) over `tokens.dur_rail_s`
(120ms), so a toggle animates and a mid-transition re-toggle reverses smoothly; the collapse bit
itself lives in a keyed `RailState` pool (distinct rails → separate ACTIONS/BUILD memories; a
rail built with `force_collapsed` overwrites only its own bit), and the vertical restore
affordance is a chevron over a `.vertical`-fit label.
## Frame-local view metrics (`view.zig`)

`view.zig` computes a `ViewMetrics` once per frame in `build_ui`'s prologue and stores it on
`Resources.view.metrics`. Everything responsive reads it. It keeps **two scales apart**: the
**DPI scale** (`dpi_scale` = drawable pixels ÷ window coordinates) is the crispness factor set
onto `View.scale`, so text opens the font at the right device size (`type.toDevice`) and
hairlines snap to whole device pixels — it does *not* change layout, which is
solved in logical (window-coordinate) space; and the **responsive class**, derived from the
logical width against the prototype's `760/560/440` breakpoints, drives the layout branches
and the framed/centered terminal. `compute(logical_w, logical_h,
pixel_density)` is pure and SDL-free (the prologue supplies the window's coordinate size and
`getPixelDensity`, degrading to the reference metrics on a query error), so the reference-fit,
centering, and breakpoint math are unit-tested without a window. `terminal` is the terminal
rect in logical px — capped at the `900×820` reference and centered when framed (wider than
760), else the full window; `width_class.atMost(.w560)` is the natural stacked-breakpoint test,
and `metrics.framed()` gates the outer terminal chrome.

**One logical→device scaling helper.** The layout is solved in **device pixels** (the
space the renderer draws), so every authored dimension is a *logical* px value multiplied by the
frame scale exactly once, through `view.dp(logical, scale)` — the single conversion point. The
El/style seams call it: `El.with_size` (`.fixed` extents), `with_gap`, `with_offset`,
`text_fit` (text measurement widths), and `style.apply` (padding/gap). Fonts route
through the sibling `type.toDevice`, and hairlines through `paint.hairline` — the same scale.
The fullscreen root and modal scrim size to the drawable px (`metrics.px_w/px_h`), and pointer
coordinates are multiplied by `dpi_scale` at one seam in `main` (`pointerAt`) so hit geometry
(device px) matches. **Values read back from stamped geometry** (`.rect`, a parent's resolved
`size.*.fixed`) are already device px and must use `El.with_size_px` (no re-scaling) — the few
prior-frame-geometry sites (the action-tile underbar and the page content box) do. **Not** scaled: simulation values and camera percentages are not dimensions. At DPI 1
(`scale == 1`) every conversion is identity, so production is unchanged; the scale becomes
load-bearing on a high-DPI display.

**Centered terminal workspace.** The `pages/templates/terminal.zig` shell is what a
screen builds inside: it reads `metrics` and, when **framed** (logical width > 760), fills the
window with the near-black terminal **ground** (`#090806`) and places a `metrics.terminal`-sized
box — capped at `900×820` and centered — with a soft drop shadow (`shadow.drop`), a
hairline border, its own `bg`, and **clipped** internals, returning the inner box for the screen
to fill. At **≤760** the terminal is the whole window (no ground/shadow/border/cap) — the
prototype's full-width mode. `play_game`/`gameover`/`act_one_end` build into the returned content
box. The terminal rect is scaled to device px once here.

**One shell, region descriptors.** `terminal.zig` also exports `shell(ctx, opts)` —
the single region skeleton every screen composes into, built on top of `terminal` (the chrome
is unchanged). A screen passes a `ShellOptions` descriptor (its `act` identity, responsive
`page_pad`/`section_gap`, and which optional regions it wants) and gets back a `Regions` struct
of `El` handles to fill: always `header` (thin top strip) and `body` (the growing main
surface), plus optional `rail`, `market`, `activity`, and a bottom-anchored `footer` —
each `null` unless requested. The interior is laid out in the prototype's arrangement (header ·
optional strips · a grid row of `rail | body` · footer), so a screen never hand-builds that
graph again — Act I turns on `footer` and composes HOLDINGS, its strips and its tabs inside its
own workspace; Act II turns on `rail` and `footer`. A tab strip is never a shell region: in
both acts it is the first row of the surface it switches. **Overlay roots (tooltip/modal) stay the screen's own top-layer
roots**, deliberately *not* children of the terminal box, so they float above the clip and can
cover any control; the shell owns only the in-terminal regions. `play_game`/`gameover`/
`act_one_end` all build through `shell` now.

**Responsive branches.** Screens and templates read `metrics.width_class.atMost(.w560)`
(and `.w440`, `.w760`) to branch on the prototype's stacked breakpoints. The branches in place:
the HUD page padding tightens to `10px` at ≤560, and the optional "Act I ·" run-context label is
dropped at ≤560 (the functional Day counter always stays — reachability preserved); the action
grid drops from two columns to one at ≤440; a BUILD row hides its time column at ≤560 and its
effect column at ≤440, recomputing its width so the visible lanes stay aligned. The page grid
is already a single stacked column, so ≤760 stacking is inherent.

**The trade dialog.** The Act I HUD opens `trade_dialog` as its own overlay root (drawn last,
over the shell) when the Passerby strip's Hail is clicked and the `market.Encounter` is
`present`. Its `TradeState` (mode + per-mode selection +
an `open` lifecycle flag) rides on the *stable* market-strip node so it survives the frame-arena
rebuild; the dialog takes that state by pointer rather than owning it on the transient modal box.
Offers are built in the page from live `market.Quote`s (buys from the passerby's satchel, sells
from the diminishing schedule), and a confirmed offer routes to `barter.resolve` — so the header,
Holdings rail, and log refresh the same frame because they read live world state after the resolve.

**Resize without state loss.** Because the UI is immediate-mode — `build_ui`'s
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
normal interaction resumes the moment geometry is fresh.

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

**`geometry` — colored triangles and honest thick polylines.** Backed by SDL's
`renderGeometry`, it draws untextured per-vertex-colored triangle meshes: a convex-polygon
fill (a hex body, a marker) and a thick polyline with correct **miter joins** (bevel fallback
past the miter limit) and butt/square **caps** (a hex rail, a distribution curve, a slider
diamond, a diagonal indicator). It is the second *variable-length* feature after `line`: a
mesh's vertex/index count does not fit in a `RenderData` payload, so the vertices live in a
pooled `GeometryState` and the payload (`?Geometry`) carries only a per-mesh `opacity`
multiplier (the dimming hook). Points are **node-local unit-square** coords like
`line`, so a shape survives resize/zoom; `draw` maps them to device px through the node's box,
converts each per-vertex `Color` to SDL's float `FColor` with opacity folded into alpha, and
submits one indexed draw (the `.blend` baseline makes vertex alpha composite, and
the render walk's clip stack crops the triangles). The tessellation math —
`fillConvex`/`fillConvexMulti` fan triangulation and `strokePolyline` — lives **SDL-free** in
`features/geometry_tess.zig` with a bounded `Mesh` builder that **refuses an over-capacity mesh
as a whole** (no torn triangle), so the whole fan/join/cap surface is unit-tested without a
graphics context. `El.polygon` / `El.polyline` are the fluent builders. `line.zig`, the
older first-segment-normal approximation, has no callers left (roadmap CLEAN-07 deletes it).

**Linear-gradient composition.** The same feature draws an explicit linear
gradient: `El.gradient(dir, stops, opacity)` fills the node box along `.horizontal`/`.vertical`
through an ordered list of `{ pos, color }` stops, tessellated (`fillGradient`) into a quad
strip whose per-vertex colors `renderGeometry` interpolates. It is deliberately narrow — the
two axis-aligned directions and explicit stops the prototype uses, **not** a CSS gradient
grammar. Two stops at the **same** position make a **hard split** (the eating-slider track:
`acc` then `line2`); a `tint → transparent` pair (an `a = 0` end stop) makes a **wash** (a
milestone/state fade), the transparent end compositing over what is under it via the
`.blend` baseline. Stops carry a full `Color`, so alpha rides along. The `slider` template
draws its split track with it and `milestone_goal` its wash; the tessellation is tested
SDL-free.

Clipping is *not* a feature. It is `Layout.overflow` in the engine, because it is geometry
two consumers read (the render walk, and eventually hit-testing), not a paint the backend
applies.

## The render walk (`draw.zig`)

`draw_tree(u, root)` runs per root tree, in list order — later trees paint on top. Each
node is a recursive pre-order paint carrying a clip stack: apply the inherited clip,
`inline for` the feature list dispatching every set aspect to its `draw`, then narrow the
clip for the subtree if this node is `.clip`. The traversal and the clip stack live here;
the primitives live with their features, so adding a visual never edits this file.

**Alpha-blending policy.** The renderer's draw blend mode is set to `.blend`
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
translucent aspect is authored, not a separate feature.

**Crisp hairlines at scale.** A one-logical-pixel border, outline, focus ring, or
rail must stay a crisp whole-device-pixel line at any DPI scale, or it anti-aliases into a
blurry 1–2px smear and adjacent columns/rails **shimmer** as their sub-pixel coverage shifts.
`paint.hairline(logical_w, scale)` rounds a hairline width to a whole number of device px
(floored at 1), and `paint.snap(device_coord)` puts a hairline edge on a whole-pixel boundary.
The `outline` feature snaps its box edges and bar thickness through these; the `line` feature
snaps its stroke width. At DPI 1 both are identity for integer-authored geometry; a
high-DPI display's fractional `View.scale` is what makes them load-bearing. Pure and SDL-free,
tested at scale ≠ 1.
**Per-node visual opacity.** A node carries an optional `render_data.opacity`
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
a small **bounded stack of translucent-black rectangles** — each a little wider
and more offset than the last, at low alpha, building a soft penumbra without a real gaussian.
Deliberately understated: flat black translucency, no rounded corners, no gloss. The pure,
SDL-free `shadow.layers(Spec)` turns a prototype-style `{ offset_y, blur, base_alpha, count }`
into ordered `Layer`s (outermost widest/faintest → inner tightest/darkest, each carrying the
full drop offset, alpha divided across the layers so they *sum* to the intended darkness) and
is unit-tested without a renderer. `shadow.drop(...)` is the thin `El` emitter: call it before
building a box so the layers paint under it (siblings paint in child order); the
`.blend` baseline composites them. `shadow.backdropColor(ground)` is the modal/dialog scrim —
the near-black terminal ground at the prototype's `0xd9` alpha, for the fullscreen root a modal
already builds. The framed terminal draws its drop shadow through `drop`.

## Five-pass profiling

The desktop loop uses the engine's profiled layout variant, sums its three solve timings
across roots, then times aggregate `stamp_rects` and `draw_tree` loops. A generic
`FrameProfiler` reports average/max microseconds and stamping share every 600 frames.
Presentation, simulation, event polling, and UI construction are intentionally outside
this diagnostic: the question is whether stamping is material relative to the other four
UI tree passes. Representative worst-case capture remains QA-17; absent that evidence,
the existing paint-order stamp walk stays unchanged. A development smoke capture on the
Act I screen put stamping well under 1% of the five measured passes — evidence against a
speculative rewrite, not a worst-case result.

## Content: elements and the `El` handle (`elements.zig`)

An element creates a node and sets *what is in it* — nothing else. Every constructor
returns an **`El`**: `{ ctx, node }`, a handle that carries the ctx so style and placement
chain onto it, and so a child names only its id and its content:

```zig
const header = try root.div("header");
_ = header.with_layout(.top_left)                        // its own anchor in the parent
          .with_flow(.{ .dir = .row, .cross = .center }) // how its children arrange
          .with_gap(6);
_ = try header.text("title", "BUILD").with_style(.{ h1, red }); // style — a fragment fold
```

**A method on `El` describes this one node; a function describes a composition.** The
content leaves are methods on the parent handle — `div`, `text`, `image`, `sprite`, `svg`,
`line`, `polygon`, `polyline`, `gradient` — with `item(id, i)` for a repeated child keyed by
its index (no id formatted per iteration) and `spacer(id, w, h)` for an empty fixed box that
is never queried and so never hittable — plus the placement, look, behaviour and state
methods below. `root(ctx, id)` is the one free constructor, because a root has no parent
handle to hang off (fullscreen, sized to the live window, the only non-`.relative` one).
Anything that creates more than one node or returns holes for a caller to fill — every
template in `pages/templates/`, and `text_input`/`modal`/`tooltip` here — is a function
taking its parent `El` first and no `ctx`; it reads `parent.ctx` when it needs the host.
Content leaves default to `.relative`, so flowed layout is the zero-config case. `.get()`
drops to the raw `*Node` for geometry reads, or for handing a root to the render walk.
`El.prior_geometry()` explicitly reads the last stamped global
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

**`control(opts)` is the one control lifecycle** (`control.zig`): focus registration (global
or under a roving group), activation, consumption of a disabled click, focus acquisition on
click, `ControlState` and semantic publication, the cursor request — once, for the node it is
called on, returning the node's interaction read after publication. The caller keeps its
enabled gate, its accessible name and role, and the chrome it paints from the result. Every
control in the templates goes through it, so the button contract holds by construction rather
than by each template remembering it. A composition that changes selection or expansion on the
click reads `query()` first and passes the new fact in, so the published bit is current on the
click frame.

Three more hooks name things the raw node left implicit. `track()` is the keep-alive read:
query a node only so it owns a slot and its rect is stamped — a scroll view's content probe,
the modal scrim and box, the tooltip. `state(T)` is the node's pooled slot, the home of a
template's logical state unless the caller passes a pointer. `retain_child(id, T)` keeps a
hidden direct child's slot alive from its always-built owner, without building the child.

**Who owns a template's state.** Every stateful template takes an optional pointer: null and
it owns the slot on its own node; a pointer and the caller owns it — the tab strip's `active`,
a select's `value`, a disclosure's `expanded`, the rail's `collapsed`, a scroll view's
`ScrollState`, the catalog's `CatalogState`. A view that is only sometimes built keeps its state
on the node that is always built and passes pointers down: the Act I surface holds BUILD's
catalog state and search editor, so hiding the tab prunes nothing. A pointer from `state(T)`
is valid for the frame as long as no slot of the same type is acquired after it (the pool may
grow); handing it to children that acquire other types is safe. The text field is the one
template that takes an owner handle rather than a pointer, because the host routes keys and
text into its editor by key: the field registers itself and the owner's key with the command
registry, and `main` looks the model up through `editorKeyOf`.

**Where geometry is read.** Prior-frame rects, pass-through probes, device-pixel sizing,
pointer capture and direct focus or cursor requests live only inside a component that owns
geometry or a host service, never in an ordinary page or template: `scroll_view` (its content
probe and thumb), `action_tile` (the progress underbar from the prior tile rect — a percent
rule cannot size it, because the tile is content-sized), `milestone_goal` (the wash and state
rail, likewise), `slider` (the lane rect, capture, press-time focus, the drag cursor),
`terminal` (the centered box in device px), `tabs` (its group node), `capital_row` (a row's
sub-action relation), `eating_policy` (the richer slider value), `select` (the popup's hover
cursor), `catalog_controls` (the Escape focus restore), the game's `modal` (dismissal
consumption), the foundation's `modal`, `tooltip` and `text_input`, and the debug page's
tooltip fixture (placed and clamped by its prior-frame size, as a production tooltip is).
`tools/boundary_check.sh` greps the known spellings of these reads — its `inventory` pattern —
and fails when one appears in a file outside that list; it also fails outright on lifecycle
wiring, a formatted loop id or key arithmetic in any page or template. It checks spellings,
not types, so a new way to read geometry is added to its pattern rather than assumed caught.

`UiCtx` also exposes singular stable-key pointer capture. A drag-capable widget captures
its queried key on press, lets subsequent `mark` calls route motion/release flags to that
owner outside its box, then owner-releases; the event layer cancels capture and pending
activation on platform cancellation or window-focus loss. Disappearing owners are pruned
automatically. This is still generic mechanism: host `PointerActivation` owns pointer
identity and click suppression, while `ui_client.drag` owns concrete math. The scroll view's
thumb and the slider capture and owner-release; `ThresholdDrag` shares the strict `>4px`
boundary with pointer activation.

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

**The primitive fragment library.** `style.zig` ships the shared vocabulary of
*look* every template composes from, so a call site names an intent, not a color: surfaces
(`panel`, `section_heading`), the button family (`btn_primary`/`btn_secondary`/`btn_text`/
`btn_icon`/`btn_link` — a shared `btn_ink` maps published state → color: `dim` disabled,
`acc` on held/hover/focus-visible, else the variant's resting ink), `tab`/`chip`/`tag`,
semantic state text (`state_good`/`state_warn`/`state_danger`/`state_muted`, the roles
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
field that folds last-non-null-wins. For text that is `text` (glyph ink), `font`
(logical size), `tracking` (em letter-spacing), and `transform` (case) — the
typography contract. For a texture aspect it is `tint`: a set `tint` recolors a present `svg`
raster (rasterized white, tinted at blit — the same model as the `text` composite), so a
template styles an icon's color through the fold instead of assigning `render_data.svg`
directly. `text` (glyph ink) and `tint` (texture ink) are separate fields on purpose, so one
tuple can carry both and neither shadows the other; `tint` no-ops on a node with no svg, and
because it is not typography it does not trip the inert-typography assert. **`wrap` and
`overflow` are deliberately *not* style fields.** They set a text node's *measurement
constraint* (its reserved box), which is placement, not look — so they are a creation
parameter of the leaf: `text_fit(id, str, fit)` takes a `TextFit` union (`.free`, `.wrap`,
`.cell`, `.vertical`), exactly one per leaf by construction, the same rule the whole
placement layer follows. Adding them to `Style` would be exactly the "turn style into
placement" the design forbids; a later `with_style(.{ font })` re-measures at whatever fit
the leaf was created with.

**Placement is deliberately not a fold.** A `Placement` partial with `row`/`col`/`fill`
presets was built and then removed: it was a second vocabulary shadowing the engine's own
`Layout`/`Size`, and every value had to be restated in it. Placement is now written
straight onto the node through `El`'s `with_layout` / `with_flow` / `with_gap` / `with_offset` /
`with_size` / `with_overflow`. Style composes because a button's look is genuinely built
from reusable pieces; placement does not, because a node sits in exactly one place.

## Color: roles here, values in the game (`theme.zig`)

`Theme` is ten named roles — `bg`, `panel`, `line`, `line2`, `dim`, `fg`, `acc`, `warn`,
`danger`, `good` — and **every one is defaulted**, to a plain greyscale plus four conventional
semantic hues. That default exists so the layer is complete on its own: a content leaf
needs ink, and requiring a palette before anything renders would make an unstyled node
invisible. The defaults are deliberately not anyone's visual identity, so a screen that
forgets to install a palette looks unfinished rather than subtly wrong.

A game supplies values by assigning a whole `Theme` onto `res.view.theme`; this layer
never learns those palettes exist. Here that is `ha.palette` (`src/palette.zig`), whose
`theme` values are art direction and live outside this folder.
Templates name `uic.Theme` / `uic.Color` for the *types* and read the live values off
`ctx.res.view.theme` — none of them imports the palette module.

The typography contract lives in `type.zig` as one role table — body `14`, small `11`,
heading `21` at `−0.04em`, and the uppercase eyebrow `11` at `+0.07em` — all regular weight,
with `−0.025em` tracking elsewhere; the unstyled default is defined *from* `body`, so
"unstyled" and "explicitly body" cannot drift, and `style.body/small/heading/eyebrow` are its
fragment projections (`h3` aliases `heading`; `h1`/`h2` are display sizes above the
contract). `toDevice` is the single logical→device multiply for a font size, and
`deviceTracking` rounds letter-spacing to whole device pixels, which is what keeps measure
and draw bit-identical. SDL_ttf has no letter-spacing, so tracking is applied per codepoint
cluster in the host's own measure/draw walk — glyphs rasterize one cluster at a time, which,
with the ligature-free font build, is what rules ligatures out. `font.zig` is the backend — a
lazy size-to-font cache keyed by device px — and owns no typography; `Fonts.init` takes the
size to pre-warm. The face is JetBrains Mono NL; its provenance and license are in
`docs/fonts.md`.

`theme.zig` is a **leaf**: it imports only `sdl3`, never the engine or `ctx_binding`. That
is what lets `res.zig` hold a `Theme` on `View` with no import cycle — `res.zig` → this →
`sdl3`, and nothing points back. It also carries the color math (`mix`, `rgb`) that a
palette blend and a pulsing readout both need.

## Fonts

`res.platform.font` is a `Fonts` — a lazy `size → ttf.Font` cache (`at(px)`,
`measure(text, px)`), one loaded font per point size, because `TTF_SetFontSize` clears the
glyph cache on every call and rescaling a loaded pixel font is lossy. A text leaf measures
at `font.default_px`; a resolved `font` fragment re-measures at its size.

### Constrained multiline text

A text node is single-line by default (`TextState.wrap_width == 0`) — one `renderTextSolid`
over the content box, the fast path dense rows pay nothing for. `text_fit(id, str, .{ .wrap = max_w })` opts a node into **constrained multiline**: it stores an explicit
maximum content width and re-measures, so the node reports the wrapped `width`×`height` and
renders exactly those lines.

The line breaking lives in `features/wrap.zig` as a **pure, allocation-free** routine
`wrapLines`, parameterized by a small `Measurer` (`width`/`prefixBytes`) so it stays
callback-free at the engine boundary *and* SDL-free to test. `features/text.zig` backs the
`Measurer` with the live font, and **both** `attach` (measure) and `draw` (render) run the
*same* routine over the same metrics — so the reserved box and the drawn glyphs cannot drift,
the "measure and draw read one source" invariant extended to N lines. The algorithm
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
so the pool contract is unchanged and the `cap = 256` **whole-refusal** is preserved — a
too-long source is still refused whole and reserves a zero box, wrapping or not. The width is
a logical value scaled once through `view.dp`; `log_view` passes its column width and
`act_one_end` its dialog prose width.

### Single-line overflow cells

Where a label must live in a slot of an **explicitly allocated width** — a catalog name
column, a status readout in a narrow tile — `text_fit(id, str, .{ .cell = .{ .mode, .width } })` opts the node into a
single-line *cell* with an explicit overflow discipline. It sets `TextState.overflow`
(`.visible` / `.clip` / `.ellipsis`) and `overflow_width` (a **required nonnegative** cell
width; `0` is a legal zero-width cell), clears `wrap_width` (a cell is single-line; wrapping
and overflow are mutually exclusive, and wrapping wins if both are somehow set), and
re-measures — placement, not style, exactly like a wrap fit.

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
is unchanged and the `cap = 256` **whole-refusal** is preserved — a refused string draws
nothing and reserves the cell (or zero) box, cell or not. `.visible` + 0 is the unchanged
fast/wrapped path. Integrated at representative sites such as `capital_row`'s name column
(`.ellipsis` at its fixed column width) and the log's stamp column (`.clip`).

### Rotated collapsed-rail copy

The collapsed Holdings rail carries its `HOLDINGS` label set vertically, reading
bottom-to-top — a 90° counter-clockwise turn. `TextState.orientation` names the only two
axis-aligned orientations the product uses: `.horizontal` (every ordinary label) and
`.counter_clockwise_90`. The `.vertical` text fit selects it — a fit is one of wrap, cell or
vertical by construction, so there is no competing constraint to clear — and re-measures.
A bounded enum, not an arbitrary angle, is deliberate: 90° is an exact width/height swap, so
its bounding box stays axis-aligned and no broader non-rectangular hit-geometry policy is
needed.

Orientation is a **final-blit transform, not a composite-pixel input**. The glyphs still
rasterize into the upright white composite exactly as horizontal text does, so
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
The placement is pure geometry (`blitPlacement`), tested SDL-free. The collapsed rail's
`HOLDINGS` label reads bottom-to-top at the prototype's 9px / 0.09em collapsed-rail density.

## Frame assembly (`tree.zig`)

`build_ui` returns `Trees` — a flat `[]const *Node` of independent root trees, laid out and
drawn in order, and so is what every page returns: its roots in draw order, a dialog's root
listed after the shell it covers (the trade dialog hands its root back in its result).
`oneRoot` wraps a single-root page. `Node.collect`, the engine's flattening of a tuple-shaped
return, remains available but no page needs it.

## Foundation compositions (`text_input.zig`, `modal.zig`, `tooltip.zig`)

The three compositions the foundation owns because they bind host services no template should
reach for: `text_input` (the `editor.zig` model, SDL text input, the command registry's
text/search owner), `modal` (a scrim root, the Escape owner, the focus trap, the dialog
semantics) and `tooltip` (a pass-through root plus `clampToTerminal`). Each is a free function
over `El` — taking its parent handle, or building its own root — and returns `El` handles, so
its output feeds the next call like any template's. The game's `pages/templates/modal.zig`
wraps the shell with its chrome and dismissal result; the debug page proves the tooltip.
