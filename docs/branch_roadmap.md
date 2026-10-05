# Zig-first semantic UI branch roadmap

> **Temporary branch document.** This is a special-case roadmap for the semantic composition branch. It exists beside [`roadmap.md`](roadmap.md) to focus this branch, does not replace the product roadmap, and should be deleted after its completed work and any remaining future work have been reconciled back into the canonical roadmap and present-tense architecture documentation.

The branch goal is to design and prove a semantic middle layer in Zig before building any UI scripting language. The existing engine, frame-local tree, keyed pools, layout solver, renderer, input routing, and feature registry remain the backend. This branch replaces repetitive composition and control wiring with a stable, data-oriented Zig contract that a future runtime language can consume without exposing raw `Node`/`El` mechanics.

The core rule is:

> **Every abstraction must first make a real Zig composition simpler. A scripting runtime is a later consumer of the proven contract, not the mechanism used to discover it.**

## Why this branch exists

### Audit basis and diagnosis

This direction follows a post-mortem of all 43 files under `src/pages/templates/`, every `src/pages/*.zig` page, the production code under `src/ui/` and `src/ui_client/`, the frame host in `src/main.zig`, UI tests, and the relevant prototype references. `zig build test-ui` and `zig build test` were green at the audit baseline. The problem is therefore not that the UI backend is generally broken or lacks capability.

The backend is stronger than its current authoring experience. It already has a coherent frame-local tree, keyed persistent pools, layout, paint/hit-order agreement, clipping, pointer capture, feature dispatch, text caching, focus, semantics, and modal infrastructure. The recurring cost appears one layer above those mechanisms: pages and templates repeatedly assemble backend protocols to express concepts that are semantically ordinary.

That missing middle layer has several consequences:

- A button is visually simple but authoring one correctly requires knowledge of focus, interaction consumption, semantic publication, cursor policy, disabled behavior, and prior-frame input state.
- A conditional or reordered view can preserve state, but only when authors understand private structural keys and pool lifetime well enough to reconstruct identity manually.
- Scroll regions, progress marks, tooltips, tables, and overlays leak geometry, pass-through, root collection, or responsive synchronization into otherwise declarative page code.
- The coexistence of stock widgets and `El` templates creates two partial authoring dialects instead of one composition vocabulary.
- Every leaked backend detail would become a scripting-language feature or FFI rule if a runtime were designed first.

The intended correction is not a replacement engine. It is a host-side semantic contract that turns existing mechanisms into concepts page authors actually mean: layout groups, content, controls, keyed collections, state owners, tables, scroll regions, and portals.

### Why Zig comes before scripting

Zig is the shortest path for discovering this contract because the real pages, host services, types, tests, and domain adapters already live there. Building and migrating ordinary Zig compositions first provides direct evidence about which abstractions remove repetition and which merely rename it. Static types also make control results, state ownership, identity, and descriptor boundaries explicit while those decisions are still changing.

Starting with a scripting runtime would force two uncertain designs at once: the semantic UI model and the language/runtime that expresses it. It would risk stabilizing raw `El`/`Node` details as script-visible behavior, adding parser/VM complexity to every iteration, and mistaking language convenience for a sound composition contract. This branch instead proves the lowerable, data-oriented contract first. A later runtime should be able to describe the same operations and consume the same host services; it should not require a second UI architecture.

### Relationship to the frame lifecycle

The semantic layer participates in the existing immediate rebuild lifecycle; it does not hide or reorder it:

```text
route input against prior stamped geometry
        ↓
beginFrame and create Compose
        ↓
rebuild semantic handles into the frame-local El/Node tree
        ↓
layout, stamp geometry/paint order, and draw all roots/portals
        ↓
endFrame, publish lifecycle results, and prune persistent pools
```

`Compose` owns only frame-scoped authoring concerns such as structural paths, semantic diagnostics, resolved responsive values, and portal collection. Existing engine/client pools continue to own persistent interaction, cache, geometry, focus, and backend state. Semantic handles are therefore cheap frame values, not retained objects, and explicit state owners bridge logical UI state across rebuilds without retaining the visual tree.

### Proposed source shape

The initial module split should keep concerns inspectable rather than building one replacement widget file:

```text
src/ui_client/compose/
    root.zig          facade and public exports
    ui.zig            Compose lifetime and finish
    identity.zig      structural IDs and keyed paths
    layout.zig        containers and logical dimensions
    text.zig          semantic text/image leaves
    control.zig       shared control lifecycle and results
    state.zig         state owners and bindings
    responsive.zig    width-class data and resolution
    portal.zig        top-layer collection and ownership
    scroll.zig        geometry-encapsulated scrolling
    table.zig         shared schemas, rows, and cells
    inspect.zig       traces and authoring diagnostics
```

This layout is a starting hypothesis, not an obligation to preserve empty files. Modules should split or merge based on implementation evidence while the public concepts and dependency direction remain stable.

### Implementation strategy

Use a walking skeleton followed by complete vertical slices:

1. Lock the current frame lifecycle, units, identity behavior, diagnostics, and performance baseline before adding convenience APIs.
2. Build the smallest end-to-end facade: one root, semantic layout/content handles, inspection output, and a migrated debug fixture.
3. Prove one control through its entire lifecycle before multiplying control types. Pointer, keyboard, disabled, focus, semantics, cursor, nested consumption, and visual state must travel through the same path.
4. Prove keyed identity and explicit state ownership on conditional and reordered content, especially the hidden BUILD catalog, before offering broad state convenience.
5. Add portals, scroll/progress geometry encapsulation, responsive descriptors, and tables only as required by the Trade and BUILD slices.
6. Migrate product surfaces end to end, keeping old and new paths side by side long enough to compare behavior, semantics, layout dumps, screenshots, and lifecycle state.
7. Freeze and document the public data contract only after the migrations expose its real requirements; then write the future-runtime mapping without implementing that runtime.
8. Remove duplicate helpers only after their consumers have migrated, reconcile unresolved work into `roadmap.md`, and delete this branch document.

Every slice should leave the repository usable and keep the old escape path available. Success is measured by deleted protocol knowledge at page/template call sites, not by the number of new wrappers. If an abstraction cannot simplify a real migration, preserve correct identity/state behavior, remain inspectable, and lower to runtime-representable data, it is not ready to become public API.

## 0. Scope, precedence, and branch constraints

### Relationship to the product roadmap

When this branch roadmap and [`roadmap.md`](roadmap.md) overlap:

1. `roadmap.md` remains authoritative for product behavior, simulation rules, prototype parity, economic design, later acts, and release acceptance.
2. This document is authoritative only for the branch's semantic UI composition architecture, migration sequence, and branch-local completion gates.
3. Present-tense implemented architecture still belongs in [`../src/README.md`](../src/README.md), [`../src/ui/README.md`](../src/ui/README.md), and [`../src/ui_client/README.md`](../src/ui_client/README.md). Completed branch tasks update those documents in the same slice.
4. A branch task may replace a composition mechanism named as current baseline in `roadmap.md`, but it must not weaken product behavior or erase working engine/client capabilities.
5. Before deleting this file, move unresolved work back to `roadmap.md`; do not leave a second hidden backlog in code comments or TODOs.

### Layer ownership

The target dependency direction is:

```text
Zig pages and game components
        ↓
src/ui_client/compose/       semantic composition contract
        ↓
El + ui_client features      host rendering/input policy
        ↓
Node / Ctx / pools / layout  generic engine mechanism
        ↓
SDL renderer and platform input
```

- `src/ui/` remains generic and imports no SDL, game type, theme value, or composition vocabulary.
- `src/ui_client/` continues to own rendering, input, accessibility, focus projection, logical-to-device conversion, and host controls.
- New semantic composition code lives under `src/ui_client/compose/` unless implementation evidence identifies a better host-layer name.
- `src/pages/templates/` continues to own game-specific reusable compositions and wording.
- `src/pages/` continues to project authoritative domain state and apply/queue user intent.
- Simulation modules remain unaware of UI types.

### Existing mechanisms to preserve

Do not replace working foundations merely to make the public API look new:

- Frame-arena node trees and structural stable keys.
- Typed keyed pools, handle-not-pointer access, pruning, and eviction.
- Last-frame geometry, paint-order hit testing, clipping, topmost occlusion, pass-through probes, bubbling, and pointer capture.
- Existing layout solve and sizing primitives.
- Multi-root rendering for overlays.
- The feature registry and `RenderData` conformance checks.
- Text measure/draw agreement and texture caching.
- Focus registry, roving focus, modal scope, semantic registry, announcement channel, reduced-motion policy, and command routing.
- Authoritative simulation operations and page-level domain projection.

### Branch non-negotiables

- [ ] **ZUI-01 — Preserve all repository layer boundaries.** The composition layer may call `ui_client` and re-export selected engine vocabulary, but it must not pull SDL or game policy into `src/ui/`.
- [ ] **ZUI-02 — Keep the three build gates green after every slice.** Required commands are `zig build test-ui`, `zig build test`, and `zig build`. Do not bypass tests or weaken existing targets.
- [ ] **ZUI-03 — Keep the old authoring path available during migration.** `El`, raw widgets, and existing templates remain usable until their replacement slice lands and all consumers migrate. Remove obsolete paths only in the cleanup phase.
- [ ] **ZUI-04 — Provide explicit raw escape hatches.** Semantic handles expose deliberate `rawEl()`/`rawNode()` access for custom board geometry and experiments. Escape hatches may bypass layout sugar, but not the shared control lifecycle for ordinary controls.
- [ ] **ZUI-05 — Keep the public semantic core data-oriented.** Prefer enums, tagged unions, descriptors, stable IDs, slices, and typed results. Avoid making the core depend on arbitrary Zig callbacks, `anytype` style tuples, raw pointers, or comptime-only game types that a future runtime could not represent.
- [ ] **ZUI-06 — Do not begin the scripting runtime on this branch.** No parser, VM, bytecode, hot reload, script FFI, or script standard library is required. The branch ends with a documented runtime mapping onto the proven Zig contract.

## 1. Problems this branch must remove

The Act I audit found that the backend mechanisms are coherent but the middle layer repeatedly reconstructs them by hand. The semantic layer is successful only if it removes these concrete burdens:

- Controls repeat focus registration, query/consumption, focus acquisition, state publication, semantic publication, cursor selection, and visual-state resolution.
- Stable string IDs behave as an implicit state schema, including manually reconstructed descendant paths such as the hidden BUILD catalog/editor retention chain.
- Prior-frame geometry and `pass_through` are exposed to ordinary component authors for scroll, progress, tooltips, and layout spacers.
- `ui_client/widgets.zig` and `El` templates form two authoring dialects with different style, layout, and scaling behavior.
- Logical/device-pixel distinctions are easy to violate through raw `Size.initFixed`, geometry read-back, and `_px` methods.
- Responsive calculations can be duplicated between related components, as in BUILD table headers and rows.
- Sibling controls disagree about whether they report activation or directly mutate domain state.
- Pages/templates must manually collect overlay roots and coordinate modal lifecycle.
- Stack formatting buffers and ad hoc text assembly obscure otherwise clean domain projection.

The branch is not complete merely because `row()` and `column()` exist. It is complete when migrated pages no longer need to understand these backend protocols.

## 2. Target Zig contract

### Frame facade and handles

The intended authoring shape is a frame facade plus small value handles, not a retained class hierarchy:

```zig
var ui = Compose.init(ctx);
const root = try ui.root("play", .{});
const body = try root.column("body", .{
    .width = .grow,
    .gap = 12,
    .padding = .all(16),
});
try body.text("title", "BUILD", .{ .role = .heading2 });
return ui.finish(root);
```

Expected public concepts:

```text
Compose
Container / Row / Column / Stack
Text / Image
ControlResult
StateOwner / StateRef
List / ListItem
Scroll
Table / TableRow
Portal / Dialog / Tooltip
Responsive(T)
```

Handles remain small values carrying the frame facade and underlying `El`/node identity. They do not own heap allocations or outlive the frame unless explicitly documented as stable state handles.

### Layout vocabulary

The semantic layer should expose at least:

- `box`, `row`, `column`, and `stack`.
- `spacer` and `divider` that are non-interactive by construction.
- `list` with keyed items.
- Logical padding, gap, size, alignment, overflow, and visibility.
- Semantic text roles, tones, wrapping, and cell overflow.
- One authored unit system: logical pixels.

Ordinary composition must not call `el.div`, `with_flow`, `pass_through`, `view.dp`, or `with_size_px` directly.

### Control contract

A semantic control owns its complete host lifecycle and returns semantic events:

```zig
const build = try row.button("build", .{
    .label = "Build →",
    .enabled = recipe.ready,
    .tone = .primary,
});
if (build.activated) try intents.append(recipe.intent);
```

The shared control lifecycle owns:

- Focus registration and repair.
- Pointer and keyboard activation.
- Disabled activation consumption.
- Focus acquisition and focus-visible state.
- Cursor request.
- `ControlState` publication.
- Semantic role/name/value/state publication.
- Common hover/held/focus/disabled visual-state resolution.
- Nested-action consumption while preserving ancestor hover.

Controls report intent; they do not mutate ECS/domain state. Pages or game adapters translate a `ControlResult` into typed application intent or call an authoritative operation.

### Identity contract

Identity is structural and explicit:

```zig
try parent.row("header", .{});
try list.item(.index(i));
try list.item(.key(recipe.id));
```

Required rules:

- Duplicate sibling IDs produce a debug diagnostic with the structural path.
- Repeated stateful content uses a stable domain key, not filtered/sorted position.
- Local display strings are not identity.
- Component authors do not hash keys manually.
- State identity can be distinct from visual node identity where a hidden/rebuilt control must preserve logical state.

### State contract

State is divided explicitly:

1. Domain state: ECS/simulation, owned outside the composition layer.
2. Logical UI state: active tabs, disclosure, query/sort, modal selection, owned by declared semantic state owners or controlled bindings.
3. Backend state: text/SVG caches, interaction slots, stamped geometry, pointer capture, owned by existing engine/client pools.

The semantic API must document when state survives, resets, or follows a changed key. Hidden views must not retain state by reconstructing private descendant paths.

### Units contract

- Public authored dimensions are logical pixels.
- Conversion to device pixels occurs exactly once inside the client/composition boundary.
- Simulation quantities and percentages are never dimensions.
- Geometry read-back remains device-space backend data and is encapsulated inside components that require it.
- Ordinary authors never choose between `with_size` and `with_size_px`.

### Responsive contract

Related components share responsive descriptors rather than duplicating arithmetic:

```zig
.visible = .wider_than(.w440)
```

Tables, headers/rows, dialogs, and catalogs consume the same resolved descriptor for a frame. Width-class branching remains explicit and native; this branch does not create CSS media queries.

### Portal contract

Dialogs, tooltips, menus, and popovers are explicit portals. The composition layer owns root collection, draw order, modal occlusion, focus scopes, initial focus, dismissal, focus restoration, and terminal clamping. Pages should finish one composition rather than manually return `{ root, overlay }`.

## 3. Dependency spine

Implement and validate in this order:

1. Contract and lifecycle safety.
2. Frame facade and semantic layout primitives.
3. Shared control lifecycle and standard controls.
4. Structural identity and explicit state ownership.
5. Portals and geometry-dependent components.
6. Responsive descriptors and table composition.
7. Complete vertical migrations.
8. Public-contract freeze and runtime-readiness review.
9. Cleanup, hardening, and reconciliation into the canonical roadmap.

Critical dependencies:

- Control migration depends on a single lifecycle helper and stable identity.
- Hidden BUILD state migration depends on explicit state ownership.
- Dialog migration depends on portal collection and control lifecycle.
- Catalog migration depends on keyed lists, state bindings, scroll, responsive descriptors, and tables.
- A future scripting runtime depends on every public semantic descriptor being representable as runtime data; it does not block any task in this document.

## 4. Contract and baseline hardening

- [ ] **ZUI-07 — Record the semantic composition architecture.** Add a concise present-tense design section to `src/ui_client/README.md` when the first facade lands: responsibilities, dependency direction, frame lifetime, state ownership, identity, units, and escape hatches. Keep this roadmap future-facing.
- [ ] **ZUI-08 — Lock the frame lifecycle with an integration test.** Exercise event routing against prior stamped geometry, `beginFrame`, rebuild, layout, stamp, draw-order publication, and `endFrame` pruning. Reordering the host loop must fail a focused test rather than silently disabling hit testing.
- [ ] **ZUI-09 — Audit and repair scaling inconsistencies before exposing the facade.** Route remaining raw stock-widget fixed dimensions, scrollbar widths/speeds, icon sizes, and drag thresholds through the same logical-unit policy or explicitly classify them as device-space backend values. Add DPI `1`, `1.5`, and `2` coverage.
- [ ] **ZUI-10 — Capture a branch performance/state baseline.** Record representative Act I node count, live interaction slots, persistent pool sizes, and average/max layout/stamp/draw timings. Use it to reject semantic wrappers that cause unbounded node or state growth.
- [ ] **ZUI-11 — Add structural identity diagnostics.** Detect duplicate sibling/path IDs in debug builds and report the full semantic/component path. Cover loops, conditionally inserted children, and portal roots.

## 5. Frame facade and semantic layout

- [ ] **ZUI-12 — Add `src/ui_client/compose/` and the frame facade.** `Compose.init(ctx)` owns per-frame semantic bookkeeping and portal collection; `finish(root)` returns the existing tree representation. It does not own renderer/platform lifetime.
- [ ] **ZUI-13 — Add lightweight semantic handles.** Implement `Container`, `Row`, `Column`, and `Stack` as frame-local value wrappers over `El`. Child constructors are methods so call sites stop repeating `ctx` and parent.
- [ ] **ZUI-14 — Add semantic layout primitives.** Implement `box`, `row`, `column`, `stack`, `spacer`, and `divider`; normalize useful defaults and make layout-only primitives non-interactive by construction.
- [ ] **ZUI-15 — Add semantic text/image leaves.** Support typography role, tone, wrapping, ellipsis/clip cells, orientation, opacity, image/SVG content, and accessible decorative/content distinction without exposing raw style tuples for common cases.
- [ ] **ZUI-16 — Preserve deliberate escape hatches.** Every general container can expose raw `El`/`Node` for custom geometry, but document that raw access forfeits semantic diagnostics for the mutated concern.
- [ ] **ZUI-17 — Prove the facade on the debug/template page.** Rebuild a bounded fixture section with only semantic layout/leaves, compare its node/layout dump and screenshot, and retain the old fixture until parity is demonstrated.

## 6. Shared control lifecycle

- [ ] **ZUI-18 — Implement one internal control lifecycle.** Centralize focus registration, query/consumption, focus acquisition, `ControlState`, semantics, cursor, and interaction-derived visual state. The helper remains host-side and does not introduce callbacks into `src/ui/`.
- [ ] **ZUI-19 — Define standard semantic control results.** At minimum expose `activated`, `hovered`, `held`, and `focused`; specialized controls expose typed changes/dismissals. Results are frame values and contain no raw interaction flags.
- [ ] **ZUI-20 — Unify text and icon buttons.** Replace the page-template/stock-widget split with one semantic button family. Icon controls require an accessible name; disabled controls cannot focus, activate, or leak activation to ancestors.
- [ ] **ZUI-21 — Migrate tabs and disclosure.** Preserve roving focus, selection/expanded state, keyboard activation, and semantics while eliminating direct focus/state publication from their templates.
- [ ] **ZUI-22 — Migrate select and slider.** Keep their pure models, pointer capture, keyboard commands, semantic values, and disabled behavior; composition authors provide values/options rather than route commands or geometry.
- [ ] **ZUI-23 — Migrate text input.** Preserve the existing editor model, UTF-8 behavior, clipboard commands, refusal visibility, focus ownership, clear affordance, and search registration behind a semantic field API.
- [ ] **ZUI-24 — Normalize action ownership.** Primitive controls report semantic events. Game adapters such as action/build/trade components apply domain operations. Eliminate sibling APIs where some controls mutate through `act_fn` while others return `clicked`.

## 7. Structural identity and state ownership

- [ ] **ZUI-25 — Add a public semantic `Id`/key vocabulary.** Support named children, loop indices for genuinely positional content, and stable domain keys. Internally compose structural identity without author-managed hashing or formatted temporary IDs.
- [ ] **ZUI-26 — Add keyed list composition.** `list.item(.key(domain_id))` preserves per-item focus/state through reorder/filter operations and emits duplicate-key diagnostics.
- [ ] **ZUI-27 — Add explicit state owners/bindings.** A semantic component can acquire logical state from a declared owner separate from its current visual node. Document controlled and uncontrolled forms for tabs, disclosure, sliders, selects, text fields, and dialogs.
- [ ] **ZUI-28 — Define conditional-view state behavior.** State survives while its declared owner remains, resets when the owner disappears, and intentionally restarts when its key changes. Do not retain entire frame trees.
- [ ] **ZUI-29 — Remove the hidden BUILD descendant-key reconstruction.** Replace `retainBuildCatalog`'s cross-file key path with an explicit catalog/search state owner or controlled bindings. Rename/refactor of visual children must no longer reset hidden state silently.
- [ ] **ZUI-30 — Test state lifetime exhaustively.** Cover hide/show, reorder, filter, key change, owner disappearance, pooled hole reuse, focused-control disappearance, and independent ACTIONS/BUILD state.

## 8. Portals and geometry-dependent components

- [ ] **ZUI-31 — Add portal collection to `Compose`.** A portal declares an independent top-layer root while `finish` preserves existing multi-root draw/stamp order. Ordinary pages no longer manually collect optional overlays.
- [ ] **ZUI-32 — Add a semantic dialog.** Own backdrop, centered/clamped shell, focus trap, initial focus policy, Escape/close/Leave/outside dismissal, modal pointer blocking, and opener focus restoration. Dialog content remains ordinary semantic composition.
- [ ] **ZUI-33 — Add semantic tooltip and popover primitives.** They anchor to semantic handles, clamp to the terminal, preserve top-layer clipping, and never intercept input unless explicitly interactive.
- [ ] **ZUI-34 — Encapsulate scroll geometry.** A semantic `Scroll` owns last-frame content probing, pass-through state, offset clamp, wheel routing, draggable thumb capture, first-frame behavior, DPI handling, and responsive release of nested scrolling.
- [ ] **ZUI-35 — Encapsulate progress/underbar geometry.** Callers provide a normalized value and placement; the component owns width calculation and prior-frame geometry. Action/build components do not read their old rects.
- [ ] **ZUI-36 — Remove ordinary backend geometry calls from migrated code.** Migrated pages/templates must not call `priorGeometry`, `rect`, `setPassThrough`, `with_size_px`, or pointer-capture plumbing except inside approved semantic component implementations or custom board geometry.

## 9. Responsive descriptors and tables

- [ ] **ZUI-37 — Add data-oriented responsive values.** Support explicit width-class-dependent visibility, density, layout direction, and selected dimensions. Resolution occurs once per frame/context and remains native Zig data, not CSS.
- [ ] **ZUI-38 — Add a typed table schema.** A schema declares stable column IDs, labels, widths, visibility, alignment, and overflow. Header and rows consume the same resolved schema.
- [ ] **ZUI-39 — Implement semantic table/row/cell handles.** Support header generation, keyed rows, text cells, secondary labels, semantic row state, nested action cells, and ellipsis without exposing synchronized-width arithmetic to callers.
- [ ] **ZUI-40 — Migrate the BUILD table.** Replace duplicated `visibleColumns`/`contentWidth` and inline row width calculations with one Recipe schema. Verify header/body alignment at `900`, `760`, `560`, and `440` logical widths.
- [ ] **ZUI-41 — Keep the first table deliberately narrow.** Do not implement a spreadsheet, arbitrary grid-placement language, resizable columns, or virtualized data model unless a migrated product screen demonstrates the need.

## 10. Vertical migration slices

Migrate complete behavior slices, not isolated constructors. A slice lands only when input, focus, state, semantics, responsive behavior, and visuals work through the new layer.

- [ ] **ZUI-42 — Migrate the debug/template audit page.** Use it to prove composition syntax, diagnostics, semantic inspection, and visual parity without domain risk.
- [ ] **ZUI-43 — Migrate BUILD catalog end to end.** Cover controls, query/sort state, keyed rows, hidden-view persistence, responsive table, scroll/reset, nested Build/Cancel actions, and Shelter outside filtering.
- [ ] **ZUI-44 — Migrate the Trade dialog end to end.** Cover portal roots, focus trap/restoration, tabs, selection, disabled/refusal states, live holdings, typed confirmation result, and dismissal.
- [ ] **ZUI-45 — Migrate ACTIONS and activity composition.** Normalize action controls to report intent, encapsulate progress geometry, preserve enabled/running semantics, and retain the two/one-column responsive layout.
- [ ] **ZUI-46 — Migrate header, stock tokens, runline, Holdings, and rail.** Exercise tooltips, stable text cells, collapse state, vertical text, transitions, and shared responsive layout.
- [ ] **ZUI-47 — Migrate game-over and Act I curtain pages.** Confirm simple pages become materially smaller and do not need raw root/layout/modal mechanics.
- [ ] **ZUI-48 — Audit every remaining page/template call site.** Standard UI uses `compose`; approved raw calls are documented custom rendering/geometry exceptions. No ordinary control manually wires focus, semantics, cursor, or activation.

### Migration boundary check

After a file migrates, it should not directly call the following except through an approved low-level/custom-geometry block:

```text
registerFocus
requestFocus
publishControlState
semantics.publish
consumeFlag
setPassThrough
priorGeometry / rect
with_size_px
capturePointer / releasePointerCapture
collect optional overlay roots
```

Add a lightweight repository check if it can distinguish composition implementations from page/template consumers without brittle false positives.

## 11. Inspection, diagnostics, and runtime readiness

- [ ] **ZUI-49 — Add an inspectable semantic trace.** A fixture/debug mode can emit component path, stable identity, role, state owner, logical props, resolved layout rect/clip, focus/control state, semantics, and portal ownership. Diagnostics include source/component context where Zig can provide it.
- [ ] **ZUI-50 — Diagnose invalid authoring contracts.** At minimum report duplicate IDs, missing accessible names, invalid table cells/columns, illegal state ownership, non-finite sizes/values, and unsupported nested portal/control combinations. Prefer visible debug failure over silent state aliasing.
- [ ] **ZUI-51 — Review public descriptors for runtime representation.** Every public primitive/control/composite option should lower into values representable by a future AST/bytecode: enums, unions, scalars, strings, stable IDs, slices, bindings, and semantic events.
- [ ] **ZUI-52 — Separate comptime convenience from the data core.** Zig may offer generic/typed wrappers, but document the lower data-oriented operation each wrapper invokes. A future interpreter should not need to emulate Zig `anytype` or call arbitrary function pointers.
- [ ] **ZUI-53 — Write the future runtime mapping.** Document how script components, keyed loops, state, controls, events, portals, responsive values, and host models would map onto the proven Zig API. Record unresolved language questions without implementing them.

## 12. Verification and acceptance

### Automated gates

- [ ] **ZUI-QA-01 — Keep all build gates green.** Run `zig build test-ui`, `zig build test`, and `zig build` after every implementation slice and at final verification.
- [ ] **ZUI-QA-02 — Add focused composition tests.** Cover facade lifetime, handle parenting, logical-unit conversion, structural IDs, duplicate diagnostics, keyed lists, state owners, conditional state, and portal ordering.
- [ ] **ZUI-QA-03 — Add complete control lifecycle tests.** For each standard control verify pointer and keyboard activation, disabled behavior, focus acquisition/traversal/repair, semantic publication, cursor, nested consumption, and disappearance.
- [ ] **ZUI-QA-04 — Add state and migration tests.** Cover BUILD hide/show state, query/sort/scroll preservation, reorder by domain key, modal opener restoration, and no stale state after owner removal.
- [ ] **ZUI-QA-05 — Add responsive/table tests.** Resolve and compare layouts at `900`, `760`, `560`, and `440`; assert table header/row column sets and widths are identical.
- [ ] **ZUI-QA-06 — Add DPI tests.** Exercise logical dimensions, hit geometry, text cells, scroll thumbs, progress, dialogs, and pointer conversion at scale `1`, `1.5`, and `2`.

### Deterministic UI review

- [ ] **ZUI-QA-07 — Compare migrated fixture screenshots.** Capture old/new states at reference, narrow, and high-DPI sizes before deleting old implementations. Explain intentional differences.
- [ ] **ZUI-QA-08 — Compare semantic and layout dumps.** Verify roles/names/states, focus order, portal order, clips, and stable IDs rather than relying only on pixels.
- [ ] **ZUI-QA-09 — Run keyboard-only migrated journeys.** Navigate ACTIONS/BUILD, query/sort, start/cancel builds, open/select/confirm/dismiss trade, collapse/restore Holdings, and return focus correctly.
- [ ] **ZUI-QA-10 — Run pointer conflict journeys.** Verify nested cancel consumption, modal background blocking, drag suppression, tooltip pass-through, clipped-row rejection, scroll capture, and resize stale-geometry protection.

### Performance and lifecycle

- [ ] **ZUI-QA-11 — Compare against the branch baseline.** Semantic handles must not cause unbounded persistent allocation, interaction-slot growth, state-slot growth, or an unexplained material increase in node count/layout/stamp/draw time.
- [ ] **ZUI-QA-12 — Exercise repeated lifecycle churn.** Repeatedly switch tabs, filter/reorder catalogs, open/close portals, collapse rails, resize, and rebuild keyed lists; verify cache eviction, focus/capture cleanup, and absence of stale hittable slots.
- [ ] **ZUI-QA-13 — Verify domain provenance.** Migrated UI still derives every changing value from authoritative domain/catalog/quote state and applies operations only through authoritative simulation entry points.

## 13. Cleanup and canonical-roadmap reconciliation

- [ ] **ZUI-CLEAN-01 — Retire duplicate raw widgets only after all consumers migrate.** Remove duplicate button/panel/scroll/modal/tooltip/text-input paths and obsolete barrel exports while preserving genuinely lower-level feature helpers.
- [ ] **ZUI-CLEAN-02 — Remove superseded composition templates/helpers.** Delete redundant spacer helpers, duplicated control wiring, manual overlay result structs, descendant-retention key paths, and stale action callback variants.
- [ ] **ZUI-CLEAN-03 — Make `compose` the documented authoring path.** Update `src/ui_client/README.md`, `src/README.md`, examples, and template comments. Keep raw APIs documented as backend/escape-hatch surfaces rather than the normal page language.
- [ ] **ZUI-CLEAN-04 — Reconcile `roadmap.md`.** Mark or rewrite canonical tasks affected by the new middle layer, move any unfinished branch work there, and ensure no contradiction remains about the composition model.
- [ ] **ZUI-CLEAN-05 — Delete this temporary branch roadmap.** Delete `docs/branch_roadmap.md` only after completed architecture is documented present-tense and every unresolved item has an explicit home in `roadmap.md`.

## 14. Explicit non-goals

These are not branch completion requirements:

- A custom scripting language, parser, interpreter, VM, bytecode format, hot reload, or script debugger.
- Replacing `src/ui` with a retained DOM/component tree.
- A CSS parser, selector engine, cascade, media-query language, or general web layout engine.
- A general spreadsheet/grid system beyond demonstrated catalog table needs.
- Moving domain simulation, quote resolution, or ECS mutation into the composition layer.
- Making every visual primitive semantic; custom board geometry remains allowed through raw escape hatches.
- Arbitrary callbacks or direct script-callable Zig pointers in the public contract.
- Premature virtualization or layout optimization without measured need.
- Rewriting proven engine caches, feature dispatch, hit testing, focus, or text rendering merely to align naming.

## Definition of done

This branch is complete only when all non-cleanup implementation and acceptance items are checked and evidenced:

1. `src/ui_client/compose/` is the preferred Zig authoring API and preserves the generic engine/client/page boundaries.
2. Normal composition uses semantic rows, columns, stacks, text, lists, controls, scroll, tables, and portals without direct backend wiring.
3. Standard controls own focus, activation, disabled behavior, semantics, cursor, and visual interaction state through one lifecycle.
4. Authored dimensions use one logical-pixel contract; DPI and pointer geometry remain aligned.
5. Repeated content has stable structural/domain identity with duplicate diagnostics.
6. Logical state has explicit ownership and conditional views preserve it without descendant-key reconstruction.
7. Dialogs/tooltips/popovers use portal collection and correct focus/input ordering without page-managed overlay roots.
8. Scroll/progress components encapsulate ordinary prior-frame geometry and pass-through mechanics.
9. BUILD header/rows use one responsive table schema and cannot drift.
10. The debug page, BUILD catalog, Trade dialog, ACTIONS/activity surface, header/Holdings rail, game-over, and Act I curtain have completed vertical migrations or an explicitly reviewed reason to remain raw.
11. Migrated page/template code contains no manual ordinary-control lifecycle wiring.
12. `zig build test-ui`, `zig build test`, and `zig build` are green; DPI/breakpoint, keyboard, pointer-conflict, lifecycle, semantic, screenshot, and performance checks are recorded.
13. The public data-oriented contract has a documented mapping for a future runtime language, but no scripting runtime was required to obtain a substantially better Zig authoring experience.
14. Completed architecture is documented present-tense, unresolved work is reconciled into `roadmap.md`, and this temporary file is ready to be deleted.
