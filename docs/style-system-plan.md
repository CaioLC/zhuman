# Style-system redesign — plan

Status: **in progress** (started 2026-07-09). Design converged over a design-first
discussion; this doc is the agreed plan and the phase tracker.

## The core idea

A node's rendering is composed from **four orthogonal layers**:

- **Content** — *what* (text / image / svg). The only layer an element owns.
- **Style** — *how it looks* (colors, font size, visual padding).
- **Layout** — *where / how children arrange* (anchor, children-align, gap, size rules).
- **Behavior** — *interaction* (clicked / hover / focus / scroll).

Style becomes a **composable fragment system** resolved at build; widgets shrink to
pure content ("elements"); frequently-used compositions live on a curated `templates/`
shelf. No engine change, no new persistence — this is host-side authoring built on the
existing `render_data`. `RenderData` stays as the resolver's frame-local output target
(the "packed flags" idea is dropped as unnecessary).

## Decisions

### 1. Style = a flat struct of optionals, folded from a tuple

```zig
pub const Style = struct {
    font:    ?f32 = null,
    text:    ?Color = null,   // Color = sdl.pixels.Color (host alias)
    fill:    ?Color = null,
    outline: ?Color = null,
    padding: ?ui.Padding = null,
};
```

- Color is *just fields* — no role/Paint union.
- Named presets (`h1`, `h2`, `red`, …) are values; a fragment **may also be a function**
  `fn(ctx, *Node) Style`.
- `resolve(spec: anytype) Style` folds a tuple `.{ h1, red }` left→right, **last non-null
  field wins** (`merge`), calling any function fragments. One mechanism covers static
  presets (`h1`), themed colors (need `ctx.res.theme`), and interaction-aware chrome
  (need `node.query`).

### 2. Resolve at build; presence follows content

- `apply(ctx, node, style)` (+ per-content helpers) resolve the tuple, write colors into
  `render_data`, measure text at the resolved font, set padding/size — all at build.
- **Content-driven aspects** (text/img/svg) are present because content was given; unset
  style fields fall back to **defaults** (`font → DEFAULT_FONT`, `text → theme.fg`).
- **Decoration aspects** (fill/outline) are present *iff* set; unset → absent.

### 3. Failure modes: uniform `Style` + debug-assert

- Forgetting style is safe by construction — defaults fill in, content stays visible.
- Fill-under-a-covering-image is harmless (occluded, or an intentional backdrop for a
  transparent sprite) — not policed.
- The one real footgun — a style field no present aspect consumes (`font`/text color on a
  node with no text) — is caught by `std.debug.assert` in `apply` (compiles out in
  release). Uniform `Style` is kept (not typed-per-widget) so tuple composition stays free.

### 4. `ui.Color` → SDL color

- Delete `src/ui/color.zig`; `src/ui/root.zig` drops the `Color` re-export (core never
  used it — cleaner extraction boundary).
- Host aliases `Color = sdl.pixels.Color` in **one place** so we don't spell `sdl.*`
  everywhere and can swap later.
- SDL detail (verified): `pixels.Color = SDL_Color`; `ttf.Color` is a *separate* struct
  with `.toSdl()`. `setDrawColor` takes `pixels.Color`, `renderTextSolid` takes
  `ttf.Color`. So the alias is `pixels.Color`, and `text.zig` converts at its single
  `renderTextSolid` boundary (`sdl.ttf.Color{ .r=c.r, … }`).
- `Color.lerp` / `scaled` / `white` become **free functions** where color lives (the
  color leaf module). The Theme's whole-palette `lerp(t)` keeps its name; the *color*
  blend gets a distinct name (`mix`) to avoid the clash.
- **Cycle constraint:** `theme.zig` is imported by `res.zig`, which is imported by
  `ui_client` — so the `Color` alias + color math must live in a **leaf** module that
  imports only `sdl3` (theme.zig itself qualifies once it drops its `ui` import).

### 5. Multi-size font

- `font.zig` + `res.font` hold **one `TTF_Font` per point size** (can't cleanly rescale a
  loaded pixel font); measure/render with the size-matched handle so `h1/h2/h3` work.

### 6. Purist foundation + `el`

- Elements own **only content**: `text` / `image` / `svg`, no baked style or layout.
- **Layout presets** (`row`/`col`/`fit`) are composable `Layout` values, same fold trick.
- `el(ctx, parent, id, content, style, layout)` applies all three layers in one terse
  call; layers stay orthogonal.
- **Behavior:** interaction→color lives in function-style-fragments; non-style behavior
  (scroll offset, focus, `.clicked`) stays call-site reads or small value-returning
  helpers (agnostic ones may live in the foundation).

## Tiering

| Tier | Folder | Nature | Contents |
|---|---|---|---|
| Engine | `src/ui/` | imports nothing | Node, cache, layout solve (delete `color.zig`) |
| Foundation | `src/ui_client/` | game-agnostic, theme-blind | content leaves, `Style`/`resolve`/`apply`, layout presets, `el`, feature registry, draw walk, agnostic behavior primitives |
| Templates | `src/pages/templates/` | game-specific, theme-aware | composed `button`/`panel`/`scroll_view`/`modal`/`tooltip`/`text_input`, vitals figure, `action_button`, `heartbeat`, `actor_status` |
| Screens | `src/pages/` | game content | `build_ui`, `play_game`, `gameover` |

`templates/` mirrors `ui_client/features/`: a `root.zig` re-exporting one module per
template. Rename `ui_client/widgets.zig` → `elements.zig`; the `Style`/`resolve`/`apply`
machinery gets its own `ui_client/style.zig`.

## Phases (keep each buildable)

1. **Color swap** — ✅ **done** (2026-07-09). Deleted `ui/color.zig`; `theme.zig` is now the
   color leaf (`Color = sdl3.pixels.Color`, an `rgb()` palette helper, and `mix()` replacing
   `Color.lerp`; dropped the unused `white`/`scaled`). `RenderData` + the four color features
   (`text`/`fill`/`outline`/`svg`) use `cb.Color`; `text.zig` converts to `ttf.Color` at its
   `renderTextSolid` boundary. `ui_client` re-exports `Color`. `templates.zig`/`pages/root.zig`
   use `ha.theme.Color`/`ha.theme.mix`. All three targets green; orphaned `pages/pages.zig`
   left untouched (not compiled — manual-review territory).
2. **Font multi-size** — ✅ **done** (2026-07-09). New `src/font.zig` (`Fonts`): a lazy
   `size → sdl.ttf.Font` cache (`at(px)` / `measure(text, px)`), because `TTF_SetFontSize`
   clears the glyph cache each call — one font per size keeps each hot. Re-exported as
   `ha.font`; `App.font` and `Resources.font` now hold `Fonts` (main routes through `ha.font`,
   not a relative import, to avoid a duplicate exe-module type). `text.zig` measures/renders
   through the backend at `font.default_px` (24) for now — behavior-preserving; Phase 3 threads
   the per-node px. All three targets green. (No runtime-visible change yet — GUI verification
   waits for Phase 3, when distinct sizes actually render.)
3. **Style system** — ✅ **done** (2026-07-09). New `src/ui_client/style.zig`: the composition
   machinery. `Style` (partial) + `merge` + `resolve` fold (a fragment is a `Style` value **or**
   a `fn(*UiCtx,*Node) Style`, plus nested tuples; last-non-null-wins). Typography presets
   `body`/`h1`/`h2`/`h3` (font-only; colors are game-side). `Placement` (partial over
   `Layout`+`Size`) + presets `row`/`col`/`fit`/`fill`/`center`/`clip` + `gap(n)`/`fixed(w,h)`
   + `resolve_placement` + `apply_placement`. Re-exported as `uic.style`; 4 unit tests
   (proven to run). **Rescope:** `el` + writing *style* onto a node moved to Phase 4 — both are
   entangled with content (text must be re-measured at the resolved `font`), so they belong with
   the content leaves, not in this content-agnostic machinery layer. Placement application *is*
   content-agnostic and shipped here.
4. **`elements` + `el`** — ✅ **done** (2026-07-09). Decided **B primary, `el` sugar**. New
   `src/ui_client/elements.zig`: pure content leaves `text`/`image`/`sprite`/`svg` (create a node,
   set content, *no* style/placement) + `el(content, style, placement)` sugar over
   `leaf + apply + apply_placement`, with content as a `Content` union. Added `style.apply`
   (decorations/padding unconditionally; for a text node, recolor + re-measure at the resolved
   `font`; debug-assert inert `font`/`text` on a non-text node) and the `flow` placement preset.
   Threaded per-node size: `TextState` gained `px` — the `text` feature's `attach` sets the default,
   `apply` overrides it, `draw` renders at it. **Additive, not a rename:** `elements.zig` is a *new*
   file; `widgets.zig` stays live (pages still use it) and is retired in Phase 7 — so the exe stays
   green every phase. `apply` unit-tested (decoration path); leaf/font paths compile via
   `refAllDecls` and are exercised at runtime in Phase 6. All three targets green.
5. **`templates/` shelf** — ✅ **done** (2026-07-09). New `src/pages/templates/` (barrel +
   one module each): `button`, `panel`, `scroll_view`, `figure`, `action_button`, `status`
   (`actor_status`/`heartbeat_color`) — each rebuilt as a themed composition of the foundation
   (`elements` + `style.apply`/`apply_placement`), owning no machinery. Scoped to what the target
   HUD uses; the shelved five (progress_bar/icon_button/modal/tooltip/text_input) are deferred until
   the HUD calls for them. The old `pages/templates.zig` is left orphaned (untouched WIP), superseded
   by the folder.
6. **Mock showcase** — ✅ **done** (2026-07-09). Instead of rewiring the mid-redesign screens, built
   `src/pages/mock.zig` — a showcase exercising the whole stack — and routed `build_ui` to it,
   commenting out the `play_game`/`gameover` dispatch (both screens + `templates.zig` now orphaned,
   untouched). **Verified in the running app** (grim screenshot): H1>H2>H3>body render at distinct
   sizes, themed color roles, and every template (`button` enabled/disabled, `panel`, `scroll_view`,
   `figure`+heartbeat, `action_button` against the live player, `actor_status`). No crash. Rewiring the
   *real* `play_game`/`gameover` onto the new stack is the user's HUD redesign, out of this plan's scope.
7. **Cleanup (deferred)** — delete `widgets.zig` + old re-exports, and `pages/templates.zig`, once the
   user's HUD redesign moves `play_game`/`gameover` onto the new stack (their parked versions still
   import the old widgets, so removing them now would block restoration).

## Minor details to settle during impl

Content as a tagged-union arg to `el` vs separate `text()/image()` builders; the exact
preset set + `DEFAULT_FONT` value (art direction); whether `svg` tint stays a distinct
field.
