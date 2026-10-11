# UI composition branch roadmap

> **Temporary branch document.** It exists beside [`roadmap.md`](roadmap.md) to focus the
> `feat/ui-composition` branch, does not replace the product roadmap, and is deleted once its
> completed work is documented present-tense and every unresolved item has a home in
> `roadmap.md`.

The branch consolidates UI composition onto one authoring path. The engine, the frame-local
tree, the keyed pools, the layout solve, the renderer, input routing and the feature registry
stay as they are. `El` grows into the composition contract, `widgets.zig` is retired, and no new
composition module is added.

The one rule:

> **Every abstraction must first make a real Zig composition simpler.**

## Why this branch exists

### Diagnosis

The backend is stronger than its authoring experience. The engine has a coherent frame-local
tree, keyed pools with init and prune, layout, paint-order hit testing, clipping, pointer
capture, focus, semantics, text caching and multi-root rendering. The cost sits one layer up:
templates and pages reassemble those mechanisms by hand to express ordinary things. The shapes
are few and they repeat:

| Shape | Where it shows |
|---|---|
| The control ritual: register focus, query, consume a disabled click, request focus, read focus, publish control state, request the cursor, publish semantics | about twenty sites across sixteen templates, with drift between them |
| `ctx, parent` on every constructor and every template | every call site |
| Loop ids formatted into the arena | fourteen sites |
| A local `spacer` function with a pass-through box | six files |
| A hidden view retained by rebuilding a five-deep key chain across four files | `act_one_surface` for BUILD |
| Two scroll components that differ by gutter, reset and the narrow-width release | `scroll_view`, `catalog_viewport` |
| Column arithmetic duplicated inside one file | `capital_row` |
| Text-only constraints exposed as methods on every content leaf | `with_wrap`, `with_cell`, `with_orientation` |
| Two authoring dialects, one of them stale | `widgets.zig` beside the `El` templates |

The ceremony is around the engine's primitives, not in them. `query` is a one-line read of a
plain struct, and the stateful style fragments depend on exactly those flags; it stays the
primitive.

### One authoring path

`El` is already the lingua franca: parents are taken as `El`, templates return `El`, and the
handle carries `ctx`. The branch grows it along one rule and otherwise leaves the model alone:

- **A method on `El` describes this one node:** its content and how to construct it, its
  placement, its look, a behaviour refinement, or its state slot.
- **A function describes a composition:** anything that creates more than one node or returns
  holes for a caller to fill. It takes a parent `El` first and has no `ctx` parameter. Game
  templates under `src/pages/templates/` and the foundation's own compositions in
  `src/ui_client/` (scroll, text input, modal, tooltip) are all functions.

Mini-assembled subtrees are not the composition unit. The engine can re-key a detached subtree
on attach, but every keyed thing (text measurement, interaction, state, focus, semantics)
addresses a pool by the node's final key, so a detached template could not report a click. The
deferred bind that would fix it is the retained-mode step the engine refuses.

### The frame lifecycle

The composition contract participates in the existing immediate rebuild; nothing is hidden or
reordered:

```text
route input against prior stamped geometry
        ↓
beginFrame
        ↓
build the page: El handles over the frame-local Node tree
        ↓
layout, stamp geometry and paint order, draw every root in list order
        ↓
endFrame, publish lifecycle results, prune persistent pools
```

`UiCtx` owns the arena, the frame counter, the typed pools, interaction slots, focus and
pointer capture. `Resources` owns the host registries (semantics, commands, cursor, tween,
input) and the per-frame `ViewMetrics`. Handles are frame values; persistent UI state lives in
the pools and is reached by key.

## 0. Scope and constraints

### Relationship to the product roadmap

`roadmap.md` stays authoritative for product behaviour, simulation rules, prototype parity and
release acceptance. This document is authoritative only for the branch's composition changes
and their order. Completed work is documented present-tense in
[`../src/ui_client/README.md`](../src/ui_client/README.md) in the same slice. Before this
file is deleted, unresolved work moves to `roadmap.md`.

### Layer ownership

```text
src/pages/                   screens: project domain state, act on interaction inline
src/pages/templates/         game compositions: functions over El
src/ui_client/               El, elements, style fold, features, controls, foundation compositions
src/ui/                      Node / Ctx / pools / layout: generic mechanism
SDL renderer and platform input
```

`src/ui/` stays generic and imports no SDL, game type, theme value or composition vocabulary.
Simulation modules stay unaware of UI types.

### Mechanisms to preserve

Frame-arena node trees and structural keys; typed keyed pools with handle-not-pointer access,
init on occupancy and pruning; last-frame geometry, paint-order hit testing, clipping,
pass-through probes, bubbling and pointer capture; the layout solve and sizing rules;
multi-root rendering; the feature registry and `RenderData` conformance; text measure/draw
agreement and texture caching; the focus registry, roving focus, modal scope, semantic
registry, announcements, reduced motion and command routing; authoritative simulation
operations.

### Non-negotiables

- [ ] **ZUI-01 — Preserve the layer boundaries.** Nothing in `src/ui/` names SDL, the game, or
  the composition vocabulary.
- [ ] **ZUI-02 — Keep the three build gates green after every slice.** `zig build test-ui`,
  `zig build test`, `zig build`.
- [ ] **ZUI-03 — One authoring path.** `widgets.zig` is retired first, not last. No new
  composition module is added beside `elements.zig`.

## 1. Problems this branch removes

- Controls repeat focus registration, query and consumption, focus acquisition, state
  publication, semantic publication, cursor selection and visual-state resolution, and drift:
  the template button does not consume a disabled click while the widget button does, tabs have
  no disabled path, offer rows and selects consume.
- Every constructor and template repeats `ctx` and `parent`.
- Loop ids are formatted into the arena; BUILD rows are keyed by sort position, so a row's
  focus and state jump on re-sort.
- Hidden BUILD state survives only by a cross-file key chain that any id rename silently breaks.
- `modal_body` lets `tabs` own the mode and copies it into the trade state when they differ:
  two sources of truth for one value.
- Prior-frame geometry and pass-through reach ordinary template code through local spacer
  helpers.
- Two scroll components and a duplicated column computation drift independently.
- Text-only constraints are methods on every content leaf, with exclusivity enforced by each
  setter clearing the others.
- Sibling templates disagree on whether they call a domain operation or return the activation.

The branch is complete when migrated pages and templates no longer carry any of these.

## 2. Target contract

### The `El` surface

```text
Content     div  text  text_fit  image  sprite  svg  line  polygon  polyline  gradient
Structure   item(id, i)  spacer(id, w, h)
Placement   with_layout  with_flow  with_gap  with_size  with_size_px  with_offset  with_offset_px  with_overflow
Look        with_style  with_opacity
Behaviour   query  consume  pass_through  hit_test  control(opts)  track()
State       state(T)  retain_child(id, T)
Raw         get  prior_geometry
```

`root(ctx, id)` stays a free function because it has no parent. Removed: the free-function
leaf constructors, `textWrapped`, the `el` sugar, `with_wrap`, `with_cell`, `with_orientation`
and `vertical`.

Placement stays chained and imperative. A placement options struct was built once and removed
because it shadowed the engine's `Layout` and `Size` and restated every value.

### Content leaves and the text fit

A text leaf's measurement constraint is a creation parameter, like a sprite's pixel size:

```zig
pub const TextFit = union(enum) {
    free,                                          // measured glyph box, single line
    wrap: f32,                                     // max width, multiline
    cell: struct { mode: Overflow, width: f32 },   // single line, allocated width, clip or ellipsis
    vertical,                                      // one line, rotated 90° counter-clockwise
};

pub fn text(self: El, id: []const u8, str: []const u8) !El;                  // .free
pub fn text_fit(self: El, id: []const u8, str: []const u8, fit: TextFit) !El;
```

Exactly one fit per leaf, by construction. `TextState` may store the union in place of its
three fields so `remeasure` switches on one tag. A later `font` fragment still re-measures at
the same fit.

### Units

Authored dimensions are logical pixels, scaled once at the `El` and style seams
([VIEW-02](../src/ui_client/README.md)). Device-pixel setters and geometry read-back are
component-internal; the boundary check in §5 keeps them there.

### Controls

`El.control(opts)` owns the complete host lifecycle for the node it is called on:

- focus registration and repair, or roving registration under a group
- pointer and keyboard activation through the one shared `.clicked`
- consumption of a disabled activation, so it neither reports nor bubbles
- focus acquisition on click, and the focus-visible projection
- cursor request
- `ControlState` publication, including every false
- semantic role, name, value and state publication
- nested consumption that preserves ancestor hover

```zig
const q = outer.control(.{ .enabled = enabled, .name = label, .role = .button });
```

Options: `enabled`, accessible `name`, `role`, and optional `selected`, `checked` and
`roving_group`. The result is the same interaction struct `query` returns, read after
publication, so `q.clicked`, `q.hovering`, `q.held`, `q.focused` and `q.focus_visible` are the
flags the style fragments already read.

The call site acts inline on the flag. Build is a world-mutating step at one fixed schedule
slot and there is no command queue (`src/ui/README.md`, design decisions). One convention
follows: a template never takes a domain function as a parameter. `action_tile` returns its
activation like `capital_row` does; the caller calls the simulation.

The button template after migration is the acceptance shape:

```zig
pub fn button(parent: El, id: []const u8, label: []const u8, enabled: bool) !El {
    const th = parent.ctx.res.view.theme;
    const outer = try parent.div(id);
    _ = outer.with_flow(.{ .dir = .row }).with_size(.fit_children, .fit_children);
    const q = outer.control(.{ .enabled = enabled, .name = label, .role = .button });
    const c = if (!enabled) th.dim else if (q.held or q.hovering or q.focused) th.acc else th.fg;
    _ = try outer.text("lbl", label).with_style(.{ style.body, style.pad_sym(8, 4), Style{ .text = c } });
    _ = outer.with_style(.{Style{ .outline_color = c }});
    return outer;
}
```

Seven lifecycle lines gone, and the disabled-click consumption the template currently forgets
arrives with the helper. Acceptance is a table, control by behaviour (pointer click, Enter or
Space, disabled click consumed, focus on click, cursor, semantics), that holds for every
migrated control.

`track()` is the keep-alive read for a node queried only so its rect is stamped: scroll
content probes, the tooltip box, the modal box.

### Identity

- Named children keep `key(parent.key, id)`. Repeated children use `parent.item(id, i)`, which
  folds the index through the engine's existing `key_i`; the loop body builds into the returned
  box.
- Repeated stateful content keys by a stable domain index, never by filtered or sorted
  position. BUILD rows key by recipe index.
- Display strings are not identity. Nobody hashes or formats a key by hand.
- Duplicate sibling ids are a debug diagnostic with the structural path (roadmap BASE-06).

### State

Persistent UI state lives in the typed pools on `UiCtx`, addressed by node key, reached
through `el.state(T)`. A slot not touched in a frame is pruned at its end; a changed key is a
fresh slot with `init` defaults. Those are the survive, reset and restart rules, documented in
[`../src/ui/README.md`](../src/ui/README.md).

The convention that keeps a hidden view's state alive without key reconstruction:

- Every stateful template takes an optional state pointer. Null means it owns the slot on its
  own node, as today. Non-null means the caller owns it.
- A view that is sometimes not built has its state owned by the node that is always built,
  which passes pointers down. BUILD's catalog state and search editor move onto the surface
  node; `retainBuildCatalog` is deleted. The trade dialog already works this way through the
  market strip node.
- Where hoisting is unnatural, the template that owns the child ids exports a retain function
  beside its builder, so the chain lives in the one file that can rename it.

### Responsive and the BUILD table

`ViewMetrics` is the resolved responsive descriptor, computed once per frame; templates branch
on `width_class.atMost`. The BUILD header and rows read one column array local to
`capital_row.zig`, each entry carrying id, width and the narrowest width class it survives. The
row's inline duplicate of that arithmetic is deleted. No layer-wide descriptor type, no table
handle: there is one consumer.

### Roots and overlays

A page returns its roots as a list in draw order. `Node.collect` already flattens a slice or a
tuple into the frame's root list, and list order is paint order and hit order, so a dialog
listed last covers the screen by construction. A template that builds its own root hands it to
its caller in its result; `trade_dialog` returns its root in `Result` and the page tree structs
with an optional overlay go away. A side channel for deep templates is added only if threading
a root upward ever hurts.

The modal template owns initial focus and opener restore. A pooled state on its own root
records the opener on the frame it first builds (the focused key, or an opener the caller
passes) and requests focus on the primary control; `dismissed`, which runs during the closing
frame, re-requests the opener. The slot is pruned once the dialog stops building. The focus
trap, scrim occlusion, Escape registration and inside-click consumption stay as they are.

Tooltip keeps its pass-through and terminal clamp, moves with the widget retirement, and
returns its root. Popover has no consumer.

### Geometry inside components

Prior-frame reads, pass-through and device-pixel sizing are allowed inside a component that
owns geometry, and nowhere else. One scroll component replaces `scroll_view` and
`catalog_viewport`, with the gutter width, the reset flag and the narrow-width release as
options. The progress underbar and the milestone wash keep their prior-frame read: their
parents are content-sized, and the solver resolves a percent rule only under a definite parent.
Resolving a percent rule for an out-of-flow child of a content-sized parent is possible, since
out-of-flow children never feed the fit, but it is engine work and optional.

## 3. Dependency spine

1. Retire `widgets.zig`.
2. `El` additions: child constructors, the `ctx` drop, `text_fit`, `item`, `spacer`, `state`,
   `retain_child`, `track`.
3. `El.control` and the control migrations.
4. Identity and state: row keys, the pointer convention, the BUILD hoist, the duplicate-key
   diagnostic.
5. Geometry components: the scroll merge, the approved prior-frame sites, the column schema.
6. Roots list and dialog focus.
7. Vertical migrations, documentation, reconciliation into `roadmap.md`, delete this file.

Each step leaves the repository usable. Success is measured by deleted protocol knowledge at
call sites, not by new wrappers.

## 4. Tasks

### Step 1 — retire the widget path

- [x] **ZUI-04 — Delete `widgets.zig`.** Its two live callers are the search field in
  `catalog_controls` and the shell in `templates/modal.zig`. `text_input`, `modal` and
  `tooltip` become `El`-based functions; `label`, `img`, `progress_bar`, `button`,
  `icon_button`, `panel` and `scroll_view` are already superseded. Remove the barrel re-exports
  and the test import.
  - Done: `ui_client/text_input.zig`, `modal.zig`, `tooltip.zig` (functions over `El`, still
    on the `(ctx, parent, …)` signature until ZUI-05). The `button` template gained the
    disabled-click consumption the widget had and the template lacked. The debug page has a
    `tooltip` entry. Verified by screenshot: search field, tooltip, trade dialog.

### Step 2 — `El` additions

- [x] **ZUI-05 — Child constructors as methods, `ctx` dropped everywhere.** The nine leaves move
  onto `El`; every leaf and every composition takes a parent `El` first. Delete the free leaf
  functions, `textWrapped` and the `el` sugar.
  - Done: about 350 leaf calls and 90 composition signatures and their call sites, across
    every template, page and foundation composition. Root builders (`root`, `terminal`,
    `shell`, `modal`, `tooltip`, `trade_dialog`) keep `ctx` because they have no parent.
- [x] **ZUI-06 — `text_fit` and the `TextFit` union.** Remove `with_wrap`, `with_cell`,
  `with_orientation` and `vertical`; migrate the fourteen constrained-text sites. Optionally
  store the union on `TextState`.
  - Done on the `El` surface: `TextFit` with a `clip`/`ellipsis`-only cell mode, fourteen
    sites migrated, README sections for TEXT-02/03/06 updated. `TextState` still holds the
    three fields; folding them into the union is a `text.zig` refactor left for a later pass.
- [x] **ZUI-07 — `item` and `spacer`.** Replace the fourteen formatted loop ids and the six local
  spacer functions. A spacer is non-interactive by construction.
  - Done. `Node.pcreate_i` stores the index on the node so `rekey` folds it through `key_i`;
    `El.item` wraps it. `El.spacer` is a plain fixed box: an unqueried node has no interaction
    slot, so the old pass-through declarations on spacers were redundant and are gone.
- [x] **ZUI-08 — `state`, `retain_child` and `track`.** Thin wrappers over what `Node` and `Ctx`
  already have, so templates stop dropping to `.get()` for them.
  - Done. The six keep-alive reads say `track()`; fifteen `.get().state(ctx, T)` hops are
    `state(T)`; `view_nav.retain` is `retain_child`.
- [x] **ZUI-09 — Prove the additions on the debug page.** The template audit page is the first
  migrated consumer.
  - Done through ZUI-05 to 08: the audit page builds every template through the new surface
    and was screenshot after each slice, alongside the live page.

### Step 3 — controls

- [x] **ZUI-10 — `El.control`.** One host-side lifecycle helper returning the published
  interaction. No callbacks into `src/ui/`.
  - Done: `ui_client/control.zig`. Options carry the enabled gate, accessible name, role,
    selected/checked/expanded, a spoken value, owned sub-controls, a roving group, a focus
    override and the hover cursor.
- [x] **ZUI-11 — Migrate every control site.** Button, tabs, disclosure, select, slider, text
  input, the three controls in `capital_row`, the action tile, the modal header, footer and
  offer rows, the catalog sort toggle, the rail toggle, the market strip link, the milestone
  action and the debug index. The behaviour table holds for all of them.
  - Done, plus the stock token readout, the zoom buttons and the milestone disclosure. Sites
    that change selection or expansion on the click read `query()` first so the published
    bit is current on the click frame. What stays manual, by design: the slider's press-time
    focus and captured-drag cursor, the text field's outside-press focus clear, the tab
    strip's group node, a build row's sub-action relation (published after its cancel exists),
    the catalog's Escape focus restore, the select popup's hover cursor, the text field's
    pointer-only clear glyph, and the eating policy's richer slider value (an in-place update
    of the slider's published node, since the wording depends on the value the slider lands on).
- [x] **ZUI-12 — No domain functions in template signatures.** `action_tile` and
  `action_button` return the activation; `actions_section` calls the simulation.
  - Done, `action_card` included. The section keeps a verb table of component, id, label
    and simulation operation, and places each tile by index parity across its two lanes.

### Step 4 — identity and state

- [x] **ZUI-13 — Key BUILD rows by recipe index.** Per-row focus and state survive re-sort and
  filtering.
  - Done with ZUI-07: `capital_row` takes the recipe's catalog index and builds into
    `parent.item("r", index)`.
- [x] **ZUI-14 — Optional state pointer on every stateful template.** Tabs, disclosure, select,
  slider, text input, scroll, catalog controls, rail. `modal_body` passes the trade state's
  mode to `tabs` and stops copying.
  - Done. The slider was already value-controlled. The text field takes an owner handle rather
    than a pointer, because the host routes keys and text into the editor by key: the command
    registry now records each field's editor key and `main` looks the model up through it.
    The catalog's selects are controlled by its state, which also fixes the sort resetting
    whenever the sort row was reopened.
- [x] **ZUI-15 — Hoist BUILD's catalog state and search editor onto the surface node.** Delete
  `retainBuildCatalog`.
  - Done. The surface touches both slots every frame and passes them down through
    `build_section` and `build_list`; no key arithmetic remains in templates.
- [x] **ZUI-16 — Duplicate-key diagnostic.** Debug builds report a duplicate sibling or path id
  with the structural path. This is roadmap BASE-06; land it here or point there.
  - Done in the engine: `add_child` panics in Debug and ReleaseSafe on a sibling with the same
    key, naming the path (`root/panel/row[3]`), because two nodes with one key would share
    every pooled slot. The detector and path writer are pure and tested; the live page and the
    audit fixtures build clean.
- [x] **ZUI-17 — State lifetime tests for what the pool tests do not cover.** Hide and show
  through the pointer convention, reorder by domain key, a focused control disappearing,
  independent ACTIONS and BUILD state.
  - Done at the engine level: an indexed child keeps its key across sibling order and
    re-keying, and the duplicate detector is covered. The template-level journeys (hide and
    show through a pointer, a focused control disappearing, independent ACTIONS and BUILD
    state) need a `Resources` without SDL to drive a template, which does not exist; they are
    the keyboard and pointer journeys of ZUI-QA-05/06 until roadmap QA-08 lands input replay.

### Step 5 — geometry components

- [ ] **ZUI-18 — One scroll component.** Gutter, reset and the narrow-width release as options;
  the generic view and the catalog viewport become one function.
- [ ] **ZUI-19 — Approved prior-frame sites.** The underbar, the milestone wash, the slider
  thumb, the scroll probe and the terminal box are listed as the component-internal geometry
  readers; nothing else reads a rect.
- [ ] **ZUI-20 — BUILD column schema.** One column array in `capital_row.zig` read by header and
  rows; delete the inline duplicate. Verify header and body alignment at the `900`, `760`,
  `560` and `440` widths.

### Step 6 — roots and dialogs

- [ ] **ZUI-21 — Pages return a list of roots.** `trade_dialog` returns its root in `Result`;
  delete the out-parameter and the page tree structs.
- [ ] **ZUI-22 — Modal owns initial focus and opener restore.** Pooled state on the modal root;
  restore in `dismissed`.

### Step 7 — migrations and reconciliation

- [ ] **ZUI-23 — Complete vertical migrations.** BUILD catalog; the Trade dialog; ACTIONS and
  the activity strip; header, stock tokens, runline, Holdings and rail; game-over and the Act I
  curtain. A slice lands only when input, focus, state, semantics, responsive behaviour and
  visuals all work through `El`.
- [ ] **ZUI-24 — Audit every remaining call site** against §5. Approved raw sites are the ones
  ZUI-19 lists, documented where they sit.
- [ ] **ZUI-25 — Document and reconcile.** `src/ui_client/README.md` describes the `El` contract
  present-tense (updated in the same pass as each slice); `roadmap.md` receives any unresolved
  item; this file is deleted.

## 5. Migration boundary check

After a file migrates it does not call the following, except inside a component ZUI-19 lists:

```text
registerFocus / registerRovingFocus
requestFocus / isFocused
publishControlState
semantics.publish
consumeFlag
setPassThrough / pass_through
priorGeometry / rect / prior_geometry
with_size_px / with_offset_px / view.dp
capturePointer / releasePointerCapture
allocPrint(ctx.arena, "...{d}")
ha.ui.key( / retainState(
```

A lightweight repository check greps for these outside the approved files.

## 6. Verification

- [ ] **ZUI-QA-01 — Gates.** The three build commands after every slice.
- [ ] **ZUI-QA-02 — Composition tests.** `ctx`-free handles, `text_fit` exclusivity, `item`
  keys, non-interactive spacers, a later root painting and hitting over an earlier one, the
  pointer convention.
- [ ] **ZUI-QA-03 — Control helper tests.** Pointer and keyboard activation, disabled
  consumption, focus acquisition, traversal and repair, semantic publication, cursor, nested
  consumption, disappearance. Tested once on the helper, not per control.
- [ ] **ZUI-QA-04 — State and migration tests.** BUILD hide and show, query, sort and scroll
  preservation, reorder by recipe index, modal opener restoration, no stale state after the
  owner is gone.
- [ ] **ZUI-QA-05 — Keyboard-only journeys.** ACTIONS and BUILD, query and sort, start and
  cancel a build, open, select, confirm and dismiss a trade, collapse and restore Holdings.
- [ ] **ZUI-QA-06 — Pointer-conflict journeys.** Nested cancel consumption, modal background
  blocking, drag suppression, tooltip pass-through, clipped-row rejection, scroll capture,
  resize stale-geometry protection.

DPI and breakpoint coverage at scales `1`, `1.5` and `2` is independent hardening and lives in
`roadmap.md`.

## 7. Non-goals and rejected roads

Not required by this branch:

- A scripting language, parser, interpreter, bytecode, hot reload or script debugger.
- Replacing `src/ui` with a retained DOM or component tree.
- A CSS parser, selector engine, cascade, media-query language or general web layout engine.
- A spreadsheet or grid system beyond the one BUILD column array.
- Moving simulation, quote resolution or ECS mutation into templates.
- Making every visual primitive semantic; custom board geometry stays raw through `get()`.

Roads tried or considered and rejected, so nobody re-proposes them:

- **A separate composition layer with its own handle types** (`Compose`, container, list,
  table, state-owner types): a third dialect beside `El` and the widgets; every concept mapped
  onto an existing mechanism.
- **A command queue or intent list returned from controls:** immediate mode acts inline, and the
  engine README records no command queue by default.
- **A placement options struct** (`.{ .width = .grow, .gap = 12 }`): a second vocabulary over
  `Layout` and `Size`, built once and removed.
- **Mini-assembled subtrees as the composition unit:** key-addressed state needs the final key,
  and the deferred bind that would fix it is the retained-mode step.
- **Hiding `query` behind a result type with renamed flags:** the style fragments read the raw
  flags, and the four proposed names were four of them.
- **A layer-wide responsive descriptor type:** one consumer.

## Definition of done

1. `widgets.zig` is gone and no composition module exists beside `elements.zig`.
2. The §5 check is green outside the approved component files.
3. No formatted loop ids, no cross-file key chains, no copied selection state.
4. One scroll component and one BUILD column schema.
5. `zig build test-ui`, `zig build test` and `zig build` are green; the journeys in §6 pass.
6. `src/ui_client/README.md` describes the contract present-tense, `roadmap.md` is reconciled,
   and this file is deleted.
