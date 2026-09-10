//! Implement Concrete Types for the Ui-Engine generic types

const std = @import("std");
const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const theme = @import("./theme.zig");
const Resources = @import("../res.zig").Resources;
const editor = @import("./editor.zig");

/// The host color type, re-exposed here so the whole `ui_client` layer names one `Color`
/// (SDL's `pixels.Color`) — the engine carries it opaquely on `RenderData` and never
/// reads it. Defined in `ui_client/theme.zig` (the color leaf); aliased here for the layer.
pub const Color = theme.Color;

/// Context Binding
/// The registry of widget-state (render-state) types kept in the UI cache. One
/// `Pool(T)` is generated per declaration. This is where the generic `ui` engine
/// meets the concrete state types — see `README.md` in this folder.
pub const UiState = struct {
    /// Pure text-state data — one slot per text widget, sourced and blit by the `text`
    /// feature (`features/text.zig`). The `State` types live *here*, not with their
    /// feature: the pool registry `UiState` is scanned by `Ctx` to generate pools, and a
    /// feature module already imports `ctx_binding` for `UiCtx`/`Node` — so declaring the
    /// state in the feature and referencing it back here would be an import cycle. The
    /// feature exposes it as `pub const State = cb.UiState.TextState` for the contract.
    pub const TextState = struct {
        /// Longest cached string, in bytes. Sized to comfortably hold real UI strings —
        /// labels, values, a full `max_query_bytes = 128` search query rendered as text,
        /// and the game's short log/status copy — with headroom. A source past this is
        /// **refused as a whole** (see `update`), never a silently cut prefix, so the
        /// renderer never draws half a string or a severed UTF-8 codepoint. TEXT-02
        /// wrapping/ellipsis is the mechanism for text that genuinely needs to be longer.
        pub const cap = 256;

        buf: [cap]u8,
        len: usize,
        /// The last `update` was refused because the source exceeded `cap` (or was not a
        /// codepoint-aligned prefix of a longer string — an impossible-to-render partial).
        /// The renderer treats a refused state as "no reliable text here" — it draws
        /// nothing rather than a cut string, matching the `semantics.OwnedText` policy and
        /// the editor's non-silent refusal. Cleared by the next accepted `update`.
        refused: bool,
        /// Point size to render this text at, in px. Set by the `text` feature's `attach`
        /// (default) and overridden by `style.apply` when a `font` fragment resolves — so
        /// the size travels from build to the feature's `draw`, which renders at it. The
        /// pool calls `init`, which seeds `px` at 0; `attach` (run every frame before `draw`)
        /// (re)sets this; a stray 0 would just clamp to the backend's 1px floor.
        px: f32,
        /// Maximum content width, in px, for constrained multiline text (TEXT-02). `0` (the
        /// default) is the **single-line fast path**: the node measures/draws one line
        /// exactly as before, so dense rows pay nothing for the wrap machinery. A positive
        /// value makes `attach`/`draw` run the pure `features/wrap.zig` routine — the same
        /// routine for both, so the measured box and the rendered lines always agree. Set by
        /// `El.with_wrap` (imperative placement, before style re-measures); `style.apply`
        /// reads it so a heading re-measures at the same constraint. POD: still no allocator,
        /// so the pool contract is unchanged (line spans are recomputed, never stored).
        wrap_width: f32 = 0,
        /// Single-line overflow discipline for a *cell* of an explicitly allocated width
        /// (TEXT-03). This is the vocabulary for a fixed-width slot — a stock token, a
        /// catalog name column, a status readout in a narrow tile — where the drawn glyphs
        /// must never redefine the box: the layout/hit geometry stays the allocated cell,
        /// only the *visible* glyphs are constrained. Explicit, never implicit:
        ///   - `.visible` (default) — the fast/wrapped path unchanged; no cell constraint,
        ///     the box is the measured glyph width (or wrapped width).
        ///   - `.clip` — draw the whole accepted string but scope the renderer's clip to
        ///     the content cell (and restore the prior clip after, including on error).
        ///   - `.ellipsis` — draw the longest codepoint-aligned prefix that fits
        ///     `overflow_width − ellipsis_width` plus a deterministic ellipsis token.
        /// Mutually exclusive with `wrap_width`: wrapping is multiline, overflow is
        /// single-line; if both are set the wrap path wins (a wrapped node is not a cell).
        overflow: Overflow = .visible,
        /// The allocated cell width, in px, for `overflow != .visible` (TEXT-03). A
        /// **required nonnegative** value the caller allocates (a column/token/tile width);
        /// `0` is a degenerate but legal zero-width cell (draws nothing, reserves nothing).
        /// When positive and not wrapping, `remeasure` writes `data_width = overflow_width`
        /// — the box and hit geometry are this cell, *never* the unbounded glyph width — so
        /// a widening label can never shove its neighbors. `data_height`/`baseline` still
        /// come from the font (a single line). POD like `wrap_width`; no allocator.
        overflow_width: f32 = 0,
        /// **Device-px letter-spacing** added between glyph clusters when rendering and
        /// measuring this text (TEXT-04). `0` (the default) is the **untracked fast path**:
        /// measure uses one `getStringSize` and draw uses one `renderTextSolid` span, exactly
        /// as before, so untracked text (and dense rows) pay nothing. A non-zero value (set by
        /// `style.apply` from a role's `tracking_em` resolved through the frame `scale` at
        /// `st.px`, via `type.deviceTracking`) makes both `remeasure` and `draw` run the *same*
        /// per-cluster advance routine — the measured width and the drawn glyph positions add
        /// the identical integer `dx` between the identical clusters, so box and render agree
        /// exactly for single-line, wrapped, clip, and ellipsis paths. Already an **integer**
        /// device px (rounded at resolve time) so it stays crisp (RENDER-06). POD like
        /// `wrap_width`/`overflow` in *shape*, but the state as a whole is **no longer POD**
        /// (see `tex`/`cache_key` below): TEXT-05 gave it an owned GPU texture and a `deinit`.
        /// This is the render-affecting attribute the TEXT-05 texture cache keys on.
        tracking: f32 = 0,
        /// Final text orientation (TEXT-06). `.horizontal` is every ordinary label.
        /// `.counter_clockwise_90` rotates the cached upright composite 90° counter-clockwise
        /// at blit time so the collapsed-rail label reads bottom-to-top. `text.remeasure`
        /// swaps the content-box axes for the same state, keeping layout, focus outline, and
        /// rectangular hit geometry synchronized with the rotated pixels. Orientation is a
        /// final-blit transform, not a composite-pixel input, so changing it reuses the
        /// TEXT-05 texture rather than re-rasterizing glyphs.
        orientation: Orientation = .horizontal,

        /// **TEXT-05 cached composite texture.** The uploaded, white-rasterized **composite**
        /// for whatever variant this node draws — single-line (tracked or not), wrapped,
        /// `.clip`, or `.ellipsis`, including the tracked combinations — tinted at blit via
        /// `setColorMod`/`setAlphaMod` (so color is not a cache dimension — a hover/focus
        /// recolor reuses this texture). One composite per `TextState`, generated atomically on
        /// a cache miss (`features/text.zig`'s `renderComposite`) and blitted on every hit, so
        /// no variant re-rasterizes per frame. `null` = nothing
        /// cached yet (or a refused/empty string, or a just-abandoned post-reset handle). This
        /// makes `TextState` a **resource-owning** state exactly like `SvgState`: the pool's
        /// eviction hook (`cache.zig`) calls `deinit` on prune (scrolled-away / filtered-out
        /// node) and once more at pool teardown, freeing the texture **exactly once** per live
        /// occupant. The handle is a thin `sdl.render.Texture` (a `*SDL_Texture`), so it is
        /// memcpy-safe and survives pool growth/relocation by value — the same relocation the
        /// handles-not-pointers `Pool` contract already proves for `SvgState`. Never hold this
        /// across a pool `acquire`; deref through the pool each frame.
        tex: ?sdl.render.Texture = null,
        /// The `text_cache.Key` (all render-affecting inputs) that produced `tex`, or `null`
        /// when nothing is cached. `draw` compares the wanted key to this: equal ⇒ reuse;
        /// differ ⇒ free-or-abandon `tex` and re-rasterize (see `text_cache.decide`). Stored
        /// alongside the texture exactly like `SvgState.src_key`, generalized to the full key.
        cache_key: ?@import("features/text_cache.zig").Key = null,

        /// TEXT-03 single-line overflow modes. `.visible` is today's behavior (no cell
        /// constraint); `.clip` and `.ellipsis` bound the drawn glyphs to `overflow_width`
        /// while the layout box stays that allocated cell. Declared here (not with the
        /// feature) for the same import-cycle reason as `TextState` itself.
        pub const Overflow = enum { visible, clip, ellipsis };

        /// The only axis-aligned text orientations the product uses (TEXT-06). A bounded enum
        /// keeps measurement exact (90° is a width/height swap) instead of exposing arbitrary
        /// angles whose non-axis-aligned hit bounds would require a broader geometry policy.
        pub const Orientation = enum { horizontal, counter_clockwise_90 };

        pub fn init() TextState {
            return .{ .buf = undefined, .len = 0, .refused = false, .px = 0, .wrap_width = 0 };
        }

        /// Release the cached GPU texture (TEXT-05) — the pool eviction hook. Called by
        /// `Pool.evict` on prune (node disappeared) and once more at pool teardown for a live
        /// slot; `initialValue` re-inits a reused hole so a freed slot never double-frees or
        /// inherits a stale handle. Frees **exactly once** per occupant (the proven pattern,
        /// tested for `SvgState` and, SDL-free, for the fake-backed slot in `text_cache.zig`).
        /// Convention (see `cache.zig`): teardown order frees the ui pools **before** the
        /// renderer (`main.zig`'s `App.deinit`), so this always runs while the renderer is
        /// still alive — a normal free, never a post-reset abandon.
        pub fn deinit(self: *TextState) void {
            if (self.tex) |t| t.deinit();
            self.tex = null;
            self.cache_key = null;
        }

        /// Drop the cached texture **without** freeing it (TEXT-05 renderer-reset path). Used
        /// only when a true render-device reset has already invalidated the underlying GPU
        /// texture: calling `deinit` on it would double-free an object SDL already destroyed,
        /// so the handle is **abandoned** instead. The ordinary content/px/tracking
        /// invalidation frees (renderer alive); any renderer-generation mismatch abandons,
        /// even when content or another key field changed during the reset frame — the
        /// decision lives in `text_cache.decide`, this is just the effect.
        pub fn abandonTexture(self: *TextState) void {
            self.tex = null;
            self.cache_key = null;
        }

        /// Copy `t` into the persistent buffer **in full**, or refuse it **as a whole** if
        /// it would not fit `cap`. Returns whether it was accepted. On refusal the buffer
        /// is cleared (`len = 0`) and `refused` is set, so a reader/renderer never observes
        /// a truncated or mid-codepoint prefix — the same non-silent contract as
        /// `semantics.OwnedText.set` and the editor's whole-edit refusal. An empty slice
        /// clears the field (accepted). The content buffer stays **inline/allocator-free**
        /// (owned by value, safe under pool relocation); TEXT-05's cached texture is the
        /// state's only heap/GPU resource and is released by `deinit`, so the pool contract
        /// (init on fresh/reused slots, eviction frees the texture exactly once) holds.
        pub fn update(self: *TextState, t: []const u8) bool {
            if (t.len > cap) {
                self.len = 0;
                self.refused = true;
                return false;
            }
            @memcpy(self.buf[0..t.len], t);
            self.len = t.len;
            self.refused = false;
            return true;
        }

        /// The current text, reconstructed from `buf` + `len` at the call site. Returns
        /// `null` (renders nothing) when empty **or when the last `update` was refused** —
        /// a refused string is never partially rendered. Never store the result across a
        /// pool `acquire` — the slot may move; call this again instead.
        pub fn text(self: *const TextState) ?[]const u8 {
            if (self.refused or self.len == 0) return null;
            return self.buf[0..self.len];
        }
    };
    /// A scroll container's persisted offset and active thumb-drag anchors, keyed by its
    /// own `node.key`. The offset survives frame-arena reset; drag ownership remains in
    /// generic `Ctx` capture and these fields only preserve host scroll math.
    pub const ScrollState = struct {
        offset: f32 = 0,
        dragging: bool = false,
        drag_origin_y: f32 = 0,
        drag_origin_offset: f32 = 0,
        drag_pointer_kind: @import("input.zig").PointerKind = .unknown,
        drag_pointer_id: ?u64 = null,
        drag_owner_key: ?u64 = null,

        pub fn clearDrag(self: *ScrollState) void {
            self.dragging = false;
            self.drag_origin_y = 0;
            self.drag_origin_offset = 0;
            self.drag_pointer_kind = .unknown;
            self.drag_pointer_id = null;
            self.drag_owner_key = null;
        }
    };
    /// A tab strip's persisted selection (an index into its labels), keyed by the strip's
    /// own `node.key` — the `ScrollState` pattern for content that switches. Tab 0 is the
    /// semantic and bitwise-zero default, so this state uses the zeroable fallback.
    pub const TabsState = struct { active: usize = 0 };
    /// A multi-step panel's position in its sequence, keyed by the panel's own
    /// `node.key` — the `TabsState` pattern for content that advances rather than
    /// switches: the caller reads `step`, builds that step, and bumps it on a click.
    /// Step 0 is the semantic and bitwise-zero default.
    pub const StepState = struct { step: usize = 0 };
    /// The BUILD list's sort and filter, keyed on a node that is built **every** frame —
    /// the tab strip's container, not the list itself, which only exists while its tab is
    /// active and would have its slot pruned on every visit to the other one.
    ///
    /// `init` returns the declared semantic defaults, so enum declaration order can
    /// change without silently changing what the player sees on a fresh run.
    pub const BuildViewState = struct {
        pub const Sort = enum { reach, materials, time };
        pub const Show = enum { in_reach, ready, all };
        pub const Tier = enum { any, crude, manufactured };
        sort: Sort = .reach,
        show: Show = .in_reach,
        tier: Tier = .any,
        built: bool = false,

        pub fn init() BuildViewState {
            return .{};
        }
    };
    /// A `text_input`'s persisted, authoritative editing model (INPUT-07). This is the
    /// full host editor — buffer plus caret/anchor selection, UTF-8 and single-line
    /// validation, an explicit `max_query_bytes`, and non-silent refusal — defined in
    /// `ui_client/editor.zig` so the generic engine stays unaware of editor semantics.
    /// The widget acquires it via `node.state(ctx, UiState.TextInputState)` each frame and
    /// reads caret/selection to render; `main.zig` routes SDL text/clipboard/command
    /// events into its methods against whichever stable key `UiCtx.focusedKey()` returns.
    /// See `text_input`.
    pub const TextInputState = editor.LineEditor;
    /// The `svg` feature's cached rasterization (see `ui_client/features/svg.zig`): the
    /// texture SDL_image produced for the current source+size, plus the `src_key` hash
    /// that produced it — so the feature's `attach` re-rasterizes only when the source
    /// or target size changes. Unlike the POD states above, this **owns a GPU resource**,
    /// so it declares `deinit`: the pool's eviction hook (`cache.zig`) frees the texture
    /// when the node disappears or the app tears down. Without it, the texture would leak
    /// every time a scrolled-away / closed SVG node's slot is pruned. `src_key == 0` means
    /// "nothing rasterized yet"; `SvgState` intentionally uses the zeroable fallback.
    /// A polyline's points, keyed by its own `node.key`. The first state that carries
    /// *variable-length* data rather than a handle or a scalar — which is why it exists
    /// at all: `RenderData` holds one payload per feature per node, and coordinates do
    /// not fit in a tint. Fixed capacity keeps it POD (no `deinit`, no allocator), and a
    /// caller with more points than this wants a second node rather than a bigger buffer.
    /// `LineState` intentionally uses the zeroable fallback, so an unset line has
    /// `len == 0` and draws nothing.
    pub const LineState = struct {
        pub const cap = 64;
        buf: [cap]Point = undefined,
        len: usize = 0,

        pub fn set(self: *LineState, pts: []const Point) void {
            const n = @min(pts.len, cap);
            @memcpy(self.buf[0..n], pts[0..n]);
            self.len = n;
        }

        /// The stored points. Never hold the slice across a pool `acquire` — the slot
        /// may move; call this again instead.
        pub fn points(self: *const LineState) []const Point {
            return self.buf[0..self.len];
        }
    };
    pub const SvgState = struct {
        src_key: u64 = 0,
        tex: ?sdl.render.Texture = null,
        pub fn deinit(self: *SvgState) void {
            if (self.tex) |t| t.deinit();
            self.tex = null;
        }
    };

    /// An indexed triangle **mesh** for the `geometry` feature (RENDER-03): the vertices and
    /// `u16` indices produced by `features/geometry_tess.zig` (a convex-polygon fan, a thick
    /// polyline with miter joins/caps). Like `LineState` this is the *variable-length* kind of
    /// state — a mesh has a variable vertex/index count that does not fit in a `RenderData`
    /// payload — and it follows the same POD, fixed-capacity contract: inline buffers owned by
    /// value, **no allocator and no `deinit`**, so the pool's init-on-fresh/reuse and
    /// eviction-reclaims-the-slot guarantees hold with nothing to free (the mesh is CPU-side
    /// vertex data uploaded per frame by `renderGeometry`, not a retained GPU texture). A mesh
    /// too large for the capacity is **refused as a whole** by the tessellator's `Mesh`
    /// builder (it latches overflow and emits no partial triangle), so an over-budget shape
    /// draws nothing rather than a torn mesh — the whole-refusal policy shared with
    /// `TextState`/`LineState`. Positions are node-local unit-square coords (see `Vert`); the
    /// feature maps them to device px at draw. Uses the zeroable fallback, so an unset mesh has
    /// `vlen == 0` and draws nothing.
    pub const GeometryState = struct {
        /// Vertex/index capacities. Sized for the shapes this draws — a hex body (6),
        /// its rails (a closed 6-edge polyline ≈ 24 verts), a distribution curve, a slider
        /// diamond — with headroom, while staying POD. A shape needing more wants its own node.
        pub const vcap = 256;
        pub const icap = 512;
        verts: [vcap]Vert = undefined,
        vlen: usize = 0,
        idx: [icap]u16 = undefined,
        ilen: usize = 0,

        /// Copy a tessellated mesh (from `geometry_tess.Mesh`) into this state. Positions and
        /// colors are stored as-is (unit-square local coords + per-vertex `Color`); on
        /// capacity overflow it stores nothing (`vlen = ilen = 0`) — whole-refusal, so `draw`
        /// paints nothing rather than a partial mesh.
        pub fn set(self: *GeometryState, vs: []const Vert, is: []const u16) void {
            if (vs.len > vcap or is.len > icap) {
                self.vlen = 0;
                self.ilen = 0;
                return;
            }
            @memcpy(self.verts[0..vs.len], vs);
            @memcpy(self.idx[0..is.len], is);
            self.vlen = vs.len;
            self.ilen = is.len;
        }

        /// The stored vertices. Never hold the slice across a pool `acquire` — the slot may
        /// move; call this again instead.
        pub fn vertices(self: *const GeometryState) []const Vert {
            return self.verts[0..self.vlen];
        }
        /// The stored indices (length is a multiple of 3).
        pub fn indices(self: *const GeometryState) []const u16 {
            return self.idx[0..self.ilen];
        }
    };
};

/// One mesh vertex for the `geometry` feature: a node-local unit-square position plus its
/// own `Color`. Per-vertex color is what lets one mesh carry a flat fill (all equal), a
/// gradient/mixed fill (unequal — the RENDER-04 seam), or a multi-hue rail. The device-px
/// mapping and the `Color`→SDL `FColor` conversion happen in `features/geometry.zig` at draw.
pub const Vert = struct { p: Point, color: Color };

/// A point in a node's own box, in the unit square: (0,0) is its top-left corner and
/// (1,1) its bottom-right. Relative rather than pixel so a polyline survives a resize
/// and a zoom without the caller recomputing it. See `features/line.zig`.
pub const Point = struct { x: f32, y: f32 };

/// A stroke: what a polyline is drawn *with*, as against where it goes (which is
/// variable-length, so it lives in `LineState`). Width is in px, unscaled.
pub const Stroke = struct { color: Color, width: f32 = 1 };

/// The `geometry` feature's payload (RENDER-03): the per-mesh draw parameters that are *not*
/// the variable-length vertices (those live in `GeometryState`, like a polyline's points live
/// in `LineState`). Today that is a single `opacity` multiplier applied to every vertex's
/// alpha at draw — a cheap mesh-wide fade that is the natural hook for per-node dimming
/// (RENDER-07) without recomputing each vertex color. Present ⟹ draw the node's pooled mesh.
pub const Geometry = struct { opacity: f32 = 1 };

/// Host-defined interaction vocabulary (policy — the engine stores it opaquely,
/// keyed by widget key). Pointer-derived fields are transient and republished from
/// input/capture every frame. Semantic fields persist through the event stage, but a
/// control must publish all of them from its authoritative widget/domain owner each
/// build with `publishControlState`; none is an unowned toggle.
pub const Interaction = packed struct {
    hovering: bool = false,
    pressed: bool = false,
    held: bool = false,
    released: bool = false,
    wheel: bool = false,
    clicked: bool = false,
    dragging: bool = false,
    captured: bool = false,
    dismissed: bool = false,

    disabled: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    selected: bool = false,
    checked: bool = false,

    pub const transient = [_][]const u8{
        "hovering",
        "pressed",
        "held",
        "released",
        "wheel",
        "clicked",
        "dragging",
        "captured",
        "dismissed",
    };
};

pub const ControlState = struct {
    disabled: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    selected: bool = false,
    checked: bool = false,
};

/// Publish every semantic visual state, including false, from the control's actual
/// owner. These values survive into the next event stage but never self-toggle/latch.
pub fn publishControlState(ctx: *UiCtx, key: u64, state: ControlState) void {
    ctx.setFlag(key, .disabled, state.disabled);
    ctx.setFlag(key, .focused, state.focused);
    ctx.setFlag(key, .focus_visible, state.focus_visible);
    ctx.setFlag(key, .selected, state.selected);
    ctx.setFlag(key, .checked, state.checked);
}

/// Concrete UI context type, bound here where `ui` and `res` meet.
pub const UiCtx = ui.Ctx(UiState, Interaction, Resources);

/// Node Binding
pub const icon_cell = 512.0;
pub const Sprite = struct {
    texture: sdl.render.Texture,
    src: ?sdl.rect.FRect = null,
};
/// A stroked border for the `outline` feature. `width` is the bar thickness in px (drawn
/// *inward*, so it never grows the node's box); `style` picks solid / dashed / dotted. The
/// whole feature payload, so a caller can vary thickness and pattern per node — see
/// `features/outline.zig` for how each `style` rasterizes. Defaults (`width = 1`, `.solid`)
/// reproduce the old 1px box border.
pub const LineStyle = enum { solid, dashed, dotted };
pub const Outline = struct {
    color: Color,
    width: f32 = 1,
    style: LineStyle = .solid,
};

/// Name one cell of the shared icon sheet by grid (col, row). The single place that
/// knows the sheet lives on `res.platform.icons` and how big a cell is — callers reference a
/// cell, not a texture+rect, so the spritesheet isn't threaded through every icon.
pub fn icon_sprite(res: *Resources, col: f32, row: f32) Sprite {
    return .{
        .texture = res.platform.icons,
        .src = .{ .x = col * icon_cell, .y = row * icon_cell, .w = icon_cell, .h = icon_cell },
    };
}

/// Host-defined render descriptor carried on every node (policy — core stores it
/// opaquely, never reads it). One field per **paint feature** (`ui_client/features/`):
/// each is an *optional payload* — present ⟹ draw that aspect, and the value is the
/// payload the feature's `draw` needs (a `Color` to paint in, a `Sprite` to blit).
/// Composable: a node can set several at once. Hand-written (not generated), but kept
/// honest by `features.assertFeature`, which fails to compile if a listed feature's
/// `name`/`Payload` doesn't match a field here. Field *order* is irrelevant — the draw
/// z-order is the feature `list`'s order, not this struct's. Add a feature: add its
/// module to `features/`, list it, and add the matching field here — no engine change.
///
/// Overflow/clip is **not** here — it moved to `Layout.overflow` (it's geometry read by
/// the render walk *and* hit-testing, not a paint aspect). See `src/ui/features/layout.zig`.
pub const RenderData = struct {
    text: ?Color = null, // cached glyphs (in node.state(TextState)), blit in this color
    fill: ?Color = null, // solid rect spanning the node's resolved box, in this color
    outline: ?Outline = null, // stroked border (color + width + solid/dashed/dotted), drawn inward
    img: ?Sprite = null, // textured draw (texture + optional sheet cell), blit over the node's box
    svg: ?Color = null, // cached SVG raster (in node.state(SvgState)), tinted this color
    line: ?Stroke = null, // polyline through node.state(LineState)'s points, in this stroke
    geometry: ?Geometry = null, // indexed triangle mesh in node.state(GeometryState), per-vertex color

    /// **Per-node visual opacity** (RENDER-07), 0..1, default fully opaque. *Not* a paint
    /// feature — it is a render-walk modulation: `draw_tree` multiplies a node's opacity into
    /// the opacity it inherits from ancestors and folds the product into every feature's paint
    /// alpha, so a whole subtree dims (a filtered board tile, a disabled control) without
    /// recomputing each child's color. Purely visual: hit-testing (`mark`/interaction) never
    /// reads it, so opacity never changes clickability — state logic decides that separately.
    opacity: f32 = 1,
};

/// Concrete node type for this host, bound to the host's `RenderData`. Persistent
/// per-node state (the glyph surface, an svg raster) lives in a `UiState` pool keyed by
/// `node.key`, reached lazily via `node.state(u, T)` — the node itself holds no handle.
pub const Node = ui.Node(RenderData);

test "pointer states reset while authoritative control states persist and republish false" {
    // res/arena are untouched by the interaction methods, so `undefined` is safe.
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const k = ui.key(0, "btn");
    u.setFlag(k, .hovering, true);
    u.setFlag(k, .pressed, true);
    u.setFlag(k, .held, true);
    u.setFlag(k, .released, true);
    u.setFlag(k, .wheel, true);
    u.setFlag(k, .clicked, true);
    u.setFlag(k, .dragging, true);
    u.setFlag(k, .captured, true);
    u.setFlag(k, .dismissed, true);
    publishControlState(&u, k, .{
        .disabled = true,
        .focused = true,
        .focus_visible = true,
        .selected = true,
        .checked = true,
    });

    const on = u.interactionOf(k);
    try std.testing.expect(on.hovering and on.pressed and on.held and on.released and on.wheel and on.clicked);
    try std.testing.expect(on.dragging and on.captured and on.dismissed);
    try std.testing.expect(on.disabled and on.focused and on.focus_visible and on.selected and on.checked);

    u.clearTransient();
    const after = u.interactionOf(k);
    try std.testing.expect(!after.hovering and !after.pressed and !after.held and !after.released and !after.wheel and !after.clicked);
    try std.testing.expect(!after.dragging and !after.captured and !after.dismissed);
    try std.testing.expect(after.disabled and after.focused and after.focus_visible and after.selected and after.checked);

    publishControlState(&u, k, .{});
    const cleared = u.interactionOf(k);
    try std.testing.expect(!cleared.disabled and !cleared.focused and !cleared.focus_visible and !cleared.selected and !cleared.checked);
}

test "control activation marks press immediately and click once on valid release" {
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const parent = ui.key(0, "activation-parent");
    const control = ui.key(parent, "activation-control");
    _ = u.interactionOf(parent);
    _ = u.stampRect(parent, .{ .x = 0, .y = 0, .w = 100, .h = 40 }, null, null);
    _ = u.interactionOf(control);
    _ = u.stampRect(control, .{ .x = 60, .y = 0, .w = 40, .h = 40 }, null, parent);

    var gesture: @import("activation.zig").PointerActivation = .{};
    const pressed_target = u.markTarget(.pressed, 80, 20);
    gesture.press(pressed_target, .mouse, 1, .{ .x = 80, .y = 20 });
    try std.testing.expect(u.interactionOf(control).pressed);
    try std.testing.expect(u.interactionOf(parent).pressed);
    try std.testing.expect(!u.interactionOf(control).clicked);

    try std.testing.expectEqual(@as(?u64, control), u.markTarget(.released, 80, 20));
    try std.testing.expect(u.interactionOf(control).released);
    try std.testing.expect(u.interactionOf(parent).released);
    try std.testing.expect(!u.interactionOf(control).clicked);
    if (gesture.release(u.targetAt(80, 20), .mouse, 1, .{ .x = 80, .y = 20 })) |key| {
        try std.testing.expect(u.markKey(key, .clicked));
    }
    try std.testing.expect(u.interactionOf(control).clicked);
    try std.testing.expect(u.interactionOf(parent).clicked);
    try std.testing.expectEqual(@as(?u64, null), gesture.release(u.targetAt(80, 20), .mouse, 1, .{ .x = 80, .y = 20 }));
}

test "held dragging and captured states follow pointer owners and reset" {
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const key = ui.key(0, "drag-owner");
    _ = u.interactionOf(key);
    _ = u.stampRect(key, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, null, null);

    var gesture: @import("activation.zig").PointerActivation = .{};
    gesture.press(key, .mouse, 1, .{ .x = 5, .y = 5 });
    try std.testing.expect(u.markKey(gesture.pressedKey().?, .held));
    gesture.motion(.mouse, 1, .{ .x = 10, .y = 5 });
    try std.testing.expect(u.markKey(gesture.draggingKey().?, .dragging));
    try std.testing.expect(u.capturePointer(key));
    u.setFlag(u.capturedPointerKey().?, .captured, true);

    const on = u.interactionOf(key);
    try std.testing.expect(on.held and on.dragging and on.captured);
    u.clearTransient();
    const cleared = u.interactionOf(key);
    try std.testing.expect(!cleared.held and !cleared.dragging and !cleared.captured);
}

// --- TextState (TEXT-01): non-silent, whole-string cached text -------------------------

const TextStateT = UiState.TextState;

test "TextState copies a fitting string in full and round-trips" {
    var st = TextStateT.init();
    try std.testing.expect(st.text() == null); // empty renders nothing
    try std.testing.expect(st.update("Forage the ridge"));
    try std.testing.expect(!st.refused);
    try std.testing.expectEqualStrings("Forage the ridge", st.text().?);
    // An empty slice clears the field and is accepted (not a refusal).
    try std.testing.expect(st.update(""));
    try std.testing.expect(!st.refused);
    try std.testing.expect(st.text() == null);
}

test "TextState accepts a string exactly at capacity" {
    var st = TextStateT.init();
    var at_cap: [TextStateT.cap]u8 = undefined;
    @memset(&at_cap, 'a');
    try std.testing.expect(st.update(&at_cap));
    try std.testing.expect(!st.refused);
    try std.testing.expectEqual(@as(usize, TextStateT.cap), st.text().?.len);
}

test "TextState refuses an over-capacity string as a whole, never a cut prefix" {
    var st = TextStateT.init();
    // Seed with accepted text first, to prove a refusal clears rather than keeps a prefix.
    try std.testing.expect(st.update("kept"));
    var over: [TextStateT.cap + 1]u8 = undefined;
    @memset(&over, 'x');
    try std.testing.expect(!st.update(&over));
    try std.testing.expect(st.refused);
    try std.testing.expectEqual(@as(usize, 0), st.len);
    try std.testing.expect(st.text() == null); // renders nothing, not a truncated prefix
    // A subsequent fitting update clears the refusal.
    try std.testing.expect(st.update("ok"));
    try std.testing.expect(!st.refused);
    try std.testing.expectEqualStrings("ok", st.text().?);
}

test "TextState refuses long multibyte UTF-8 whole, never cutting a codepoint" {
    var st = TextStateT.init();
    // Fill just past cap with 3-byte codepoints (U+2603 SNOWMAN = E2 98 83). A silent
    // @min-style truncation would have severed the final codepoint mid-sequence; the
    // whole-string refusal must instead keep nothing and flag it.
    const snowman = "\u{2603}";
    var buf: [TextStateT.cap + 3]u8 = undefined;
    var n: usize = 0;
    while (n + snowman.len <= buf.len) : (n += snowman.len) @memcpy(buf[n .. n + snowman.len], snowman);
    try std.testing.expect(n > TextStateT.cap); // genuinely over capacity
    try std.testing.expect(!st.update(buf[0..n]));
    try std.testing.expect(st.refused);
    try std.testing.expectEqual(@as(usize, 0), st.len);
    try std.testing.expect(st.text() == null);
    // A multibyte string that *fits* is stored intact, byte-for-byte.
    const short = snowman ** 4; // 12 bytes, well within cap
    try std.testing.expect(st.update(short));
    try std.testing.expect(std.unicode.utf8ValidateSlice(st.text().?));
    try std.testing.expectEqualStrings(short, st.text().?);
}

const Pool = ui.cache.Pool;

test "TextState pool: fresh + reused slots initialize clean via init contract" {
    const alloc = std.testing.allocator;
    var p: Pool(TextStateT) = .{};
    defer p.deinit(alloc);

    // Fresh slot starts empty/unrefused (the declared init defaults, not garbage).
    const a = try p.acquire(alloc, 111, 1);
    try std.testing.expect(p.get(a).text() == null);
    try std.testing.expect(!p.get(a).refused);

    // Dirty it (accepted text + then a refusal latch), prune, and prove the reused hole
    // is reinitialized to clean defaults rather than inheriting the previous occupant.
    try std.testing.expect(p.get(a).update("stale"));
    var over: [TextStateT.cap + 1]u8 = undefined;
    @memset(&over, 'z');
    try std.testing.expect(!p.get(a).update(&over));
    try std.testing.expect(p.get(a).refused);
    try p.prune(alloc, 2);

    const reused = try p.acquire(alloc, 222, 2);
    try std.testing.expectEqual(a, reused);
    try std.testing.expect(p.get(reused).text() == null);
    try std.testing.expect(!p.get(reused).refused);
    try std.testing.expectEqual(@as(usize, 0), p.get(reused).len);
}

test "TextState pool: values survive pool growth (handle, not pointer)" {
    const alloc = std.testing.allocator;
    var p: Pool(TextStateT) = .{};
    defer p.deinit(alloc);

    const h0 = try p.acquire(alloc, 1, 1);
    try std.testing.expect(p.get(h0).update("anchor"));

    // Force many appends so the backing array reallocates/moves.
    var n: u64 = 2;
    while (n < 300) : (n += 1) {
        const h = try p.acquire(alloc, n, 1);
        try std.testing.expect(p.get(h).update("filler"));
    }
    // Re-deref the original handle: its owned bytes are intact across the move.
    try std.testing.expectEqualStrings("anchor", p.get(h0).text().?);
}

test "TextState pool: deinit under a failing allocator does not leak (POD state)" {
    // TextState owns no heap (fixed inline buffer), so a mid-growth allocation failure
    // must leave the pool safely deinitializable with the testing allocator asserting no
    // leak. This guards the POD ownership claim behind the Option A design.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 8 });
    const alloc = failing.allocator();
    var p: Pool(TextStateT) = .{};
    defer p.deinit(alloc);

    var n: u64 = 0;
    while (n < 64) : (n += 1) {
        const h = p.acquire(alloc, n, 1) catch break; // stop at the injected failure
        try std.testing.expect(p.get(h).update("x"));
    }
    // Reaching here (and the deferred deinit) proves teardown is clean after a failure.
}

test "INPUT-07 regression: text input keeps its 128-byte whole-edit refusal" {
    // TEXT-01 migrates the *render-cache* TextState; the authoritative text-input editor
    // (INPUT-07) must be untouched — still the 128-byte LineEditor that refuses an
    // over-length edit as a whole rather than becoming unbounded or truncating.
    const LineEditor = editor.LineEditor;
    try std.testing.expectEqual(UiState.TextInputState, LineEditor);
    try std.testing.expectEqual(@as(usize, 128), LineEditor.max_query_bytes);

    var ed: LineEditor = .{};
    try std.testing.expect(!ed.refused);
    try std.testing.expectEqual(LineEditor.Result.accepted, ed.insert("iron ore"));
    try std.testing.expectEqualStrings("iron ore", ed.text());

    // An edit that would exceed max_query_bytes is refused whole, mutating nothing.
    var over: [LineEditor.max_query_bytes + 1]u8 = undefined;
    @memset(&over, 'a');
    try std.testing.expectEqual(LineEditor.Result.refused, ed.insert(&over));
    try std.testing.expect(ed.refused); // visible, non-silent refusal latch
    try std.testing.expectEqualStrings("iron ore", ed.text()); // unchanged, not truncated
}
