//! **Elements** — the *content* layer, plus the **`El` handle** that makes composition
//! fluent. A content element creates a node and sets *what* is in it (a string, a texture,
//! an svg). It returns an `El` (`{ ctx, node }`), a tiny host handle carrying `ctx` so
//! style + placement chain right onto it:
//!
//!   const header = try root.div("header");
//!   _ = header.with_layout(.top_left)                     // own anchor within the parent
//!             .with_flow(.{ .dir = .row, .cross = .center }) // arrange children
//!             .with_gap(6)
//!             .with_style(.{ h1, red });                  // style — declarative fragment fold
//!
//! Content leaves default their anchor to **`.relative`** (they are always children — roots
//! come from `el.root`, which stays `.top_left`), so flowed layout is the zero-config case.
//! **Placement is set straight onto the node** via `with_layout` (own anchor) / `with_flow`
//! (how children arrange — direction/wrap/reverse/main/cross) / `with_gap`/`with_size`/
//! `with_overflow` (no "Placement" partial folding over the engine's values); **style** is
//! the fragment fold (`with_style` → `style.apply`). The two stay cleanly separate.
//!
//! Why a handle and not `*Node` methods: applying a `font` re-measures the text (needs the
//! font backend on `ctx`), and the engine `Node` is deliberately ctx-agnostic. `El` is the
//! layer's lingua franca: parents are taken as `El` and the template shelf returns `El`
//! too, so a template's output feeds the next call's input with no unwrapping. Drop to the
//! raw node with `.get()` (for geometry reads, or handing roots to the render walk).

const std = @import("std");
const sdl = @import("sdl3");
const ui = @import("../ui/root.zig");
const cb = @import("./ctx_binding.zig");
const feat = @import("./features/root.zig");
const style = @import("./style.zig");
const view = @import("./view.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;

/// Re-exports so screens name the gradient vocabulary through `elements` (RENDER-04).
pub const GradientStop = feat.geometry.GradientStop;
pub const GradientDir = feat.geometry.Dir;

/// A fluent handle over a built node: the node plus the `ctx` needed to style it. Returned
/// by every element constructor. Placement methods write the engine `Layout`/`Size` fields
/// directly; `with_style` folds a style spec. `.get()` drops to the raw `*Node`.
pub const El = struct {
    ctx: *UiCtx,
    node: *Node,

    /// The raw node — for passing to a template, or reading geometry.
    pub fn get(self: El) *Node {
        return self.node;
    }

    /// Last stamped geometry (global rect + inherited clip) from a prior frame.
    pub fn prior_geometry(self: El) ?ui.Geometry {
        return self.node.priorGeometry(self.ctx);
    }

    /// This node's interaction this frame (buttons read `.clicked`). Uses the handle's ctx.
    pub fn query(self: El) UiCtx.Interaction {
        return self.node.query(self.ctx);
    }

    /// Observe and consume one host interaction flag on this node and its stamped
    /// ancestors. Descendants consume before ancestor action decisions; hover and
    /// unrelated flags remain available.
    pub fn consume(self: El, comptime flag: std.meta.FieldEnum(UiCtx.Interaction)) bool {
        return self.ctx.consumeFlag(self.node.key, flag);
    }

    /// Set this node's own anchor — how *it* sits within its parent. How this node arranges
    /// its own children is the separate concern `with_flow`.
    pub fn with_layout(self: El, anchor: ui.Anchor) El {
        self.node.layout.anchor = anchor;
        return self;
    }

    /// Set how this node arranges its in-flow children — direction, wrap, reverse, and the
    /// main/cross alignment. See `ui.Flow`; unset fields take their defaults, so
    /// `.{ .dir = .column }` is a plain top-to-bottom column and `.{ .dir = .row }` a
    /// baseline-aligned left-to-right row.
    pub fn with_flow(self: El, flow: ui.Flow) El {
        self.node.layout.flow = flow;
        return self;
    }

    /// Spacing between this node's in-flow children, in **logical** px (VIEW-02 scales it to
    /// device px by the frame scale). A `fit_children` parent grows to include the gaps.
    pub fn with_gap(self: El, g: f32) El {
        self.node.layout.gap = view.dp(g, self.ctx.res.view.scale);
        return self;
    }

    /// Per-axis size rule — `.fit_children`, `.grow`, `.{ .fixed = 240 }`,
    /// `.{ .pct_of_parent = 1 }`, …. A **fixed** extent is a *logical* px value scaled to
    /// device px by the frame scale (VIEW-02); `content`/`pct`/`grow`/`fit_children` are
    /// derived (content is the already-device-scaled measured box; the others are relative),
    /// so only `.fixed` scales. Extents computed from **stamped geometry** (already device px)
    /// use `with_size_px` to avoid double-scaling.
    pub fn with_size(self: El, w: ui.SizeRule, h: ui.SizeRule) El {
        self.node.size.w = scaleRule(w, self.ctx.res.view.scale);
        self.node.size.h = scaleRule(h, self.ctx.res.view.scale);
        return self;
    }

    /// Per-axis size rule from **device-px** values that must **not** be scaled again
    /// (VIEW-02): extents derived from stamped geometry (`.rect`/`.prior_geometry`) or a
    /// parent's resolved `size.*.fixed`, which are already device px. Authored logical
    /// literals use `with_size`.
    pub fn with_size_px(self: El, w: ui.SizeRule, h: ui.SizeRule) El {
        self.node.size.w = w;
        self.node.size.h = h;
        return self;
    }

    /// Displace this node in **logical** px (VIEW-02 scales to device px) from wherever its
    /// anchor or its parent's flow put it. `.center` plus a computed delta is polar placement
    /// — the way anything positioned by its own arithmetic (a radial board, a graph) reaches
    /// the screen.
    pub fn with_offset(self: El, dx: f32, dy: f32) El {
        const s = self.ctx.res.view.scale;
        self.node.layout.offset_x = view.dp(dx, s);
        self.node.layout.offset_y = view.dp(dy, s);
        return self;
    }

    /// Displace this node by a **device-px** offset that must not be scaled again (VIEW-02) —
    /// for offsets derived from stamped geometry or an already-device-px rect (the centered
    /// terminal box). Authored logical offsets use `with_offset`.
    pub fn with_offset_px(self: El, dx: f32, dy: f32) El {
        self.node.layout.offset_x = dx;
        self.node.layout.offset_y = dy;
        return self;
    }

    /// Overflow handling for this node's content (`.visible` / `.clip`).
    pub fn with_overflow(self: El, o: ui.features.Overflow) El {
        self.node.layout.overflow = o;
        return self;
    }

    /// Compose a style spec onto the node (see `style.apply`) — style only, no placement.
    pub fn with_style(self: El, spec: anytype) El {
        style.apply(self.ctx, self.node, spec);
        return self;
    }

    /// Set this node's **visual opacity** (0..1) — RENDER-07. The render walk multiplies it
    /// into the opacity inherited from ancestors and folds the product into every feature's
    /// paint alpha, so this node *and its whole subtree* dim together without recomputing any
    /// child's color (a filtered board tile, a disabled control). Purely visual: it never
    /// changes hit eligibility — state logic decides clickability separately.
    pub fn with_opacity(self: El, opacity: f32) El {
        self.node.render_data.opacity = opacity;
        return self;
    }

    /// Constrain this text node to `max_w` px and wrap it onto multiple lines (TEXT-02).
    /// Word-boundary greedy wrap with a deterministic UTF-8-safe hard-break for an
    /// over-long word; the reserved box grows to the wrapped `width`×`height` and the render
    /// draws exactly those lines. `max_w <= 0` restores the single-line fast path. This is
    /// *placement* (it sets a measurement constraint), so it is imperative like `with_size`,
    /// not a style fragment; apply it after the content leaf and before/independent of
    /// `with_style` — a later `with_style(.{ font })` re-measures at the same constraint.
    ///
    /// The explicit width is the seam `ViewMetrics` (VIEW-01) will later feed; today a
    /// template passes a column/dialog width it already knows.
    pub fn with_wrap(self: El, max_w: f32) El {
        const st = self.node.state(self.ctx, cb.UiState.TextState);
        // VIEW-02: the wrap width is authored in logical px but compared against device-px font
        // measurements, so scale it to device by the frame scale (the one `view.dp` seam).
        st.wrap_width = view.dp(max_w, self.ctx.res.view.scale);
        feat.text.remeasure(self.ctx, self.node);
        return self;
    }

    /// Constrain this text node to a single-line **cell** of `cell_w` px with an explicit
    /// overflow discipline (TEXT-03): `.clip` renders the whole string but scopes the
    /// renderer's clip to the cell, `.ellipsis` renders the longest codepoint-aligned prefix
    /// that fits `cell_w − ellipsis_width` plus a deterministic ellipsis token. `.visible`
    /// clears the constraint (back to the measured-glyph fast path).
    ///
    /// The point of a cell is geometry: the node's layout box and hit box become exactly
    /// `cell_w`, *never* the unbounded glyph width — so a widening label (a longer stock
    /// token, a long recipe name) can never shove its neighbors, and the cell reserves its
    /// full width for stable column alignment even when the text is shorter. Like `with_wrap`
    /// this is *placement* (a measurement constraint), so it is imperative, applied after the
    /// content leaf; a later `with_style(.{ font })` re-measures at the same cell.
    ///
    /// `cell_w` must be **nonnegative** (a required allocated width; `0` is a legal
    /// zero-width cell that draws nothing). Mutually exclusive with `with_wrap` — a cell is
    /// single-line — so this clears `wrap_width`; the explicit width is the seam
    /// `ViewMetrics` (VIEW-01) will feed, exactly like `with_wrap`'s width today.
    pub fn with_cell(self: El, mode: cb.UiState.TextState.Overflow, cell_w: f32) El {
        std.debug.assert(cell_w >= 0);
        const st = self.node.state(self.ctx, cb.UiState.TextState);
        st.wrap_width = 0; // single-line cell; wrapping and overflow are mutually exclusive
        st.overflow = mode;
        // VIEW-02: the cell width is authored logical but is the node's device-px layout box,
        // so scale it to device by the frame scale.
        st.overflow_width = view.dp(cell_w, self.ctx.res.view.scale);
        // A `.clip` cell also routes through the engine's generic `Layout.overflow=.clip` so
        // the node's *subtree* (any decoration children) is cropped to its box for free and
        // hit-testing already rejects outside the viewport; the leaf's own glyphs are cropped
        // renderer-scoped in `text.draw`. `.ellipsis`/`.visible` leave layout overflow alone.
        self.node.layout.overflow = if (mode == .clip) .clip else self.node.layout.overflow;
        feat.text.remeasure(self.ctx, self.node);
        return self;
    }

    /// Rotate a single-line text leaf 90° counter-clockwise so it reads bottom-to-top
    /// (TEXT-06), matching the collapsed Holdings restore label. The existing TEXT-05
    /// upright composite is rotated only at final blit; `remeasure` swaps width/height so
    /// the content box, focus outline, and rectangular hit target are the rotated footprint.
    ///
    /// This is a deliberately narrow axis-aligned placement primitive, not arbitrary visual
    /// rotation. The rail label is one line, so this clears multiline wrap and fixed-cell
    /// overflow constraints before remeasuring. A later font/tracking style still remeasures
    /// through the same orientation. Pass `.horizontal` to restore ordinary text.
    pub fn with_orientation(self: El, orientation: cb.UiState.TextState.Orientation) El {
        const st = self.node.state(self.ctx, cb.UiState.TextState);
        st.wrap_width = 0;
        st.overflow = .visible;
        st.overflow_width = 0;
        st.orientation = orientation;
        feat.text.remeasure(self.ctx, self.node);
        return self;
    }

    /// Collapsed-rail convenience spelling for the only transformed orientation in use.
    pub fn vertical(self: El) El {
        return self.with_orientation(.counter_clockwise_90);
    }

    /// Take this node out of hit-testing: it is neither flagged nor does it occlude
    /// what is drawn beneath it. For a node queried *only* to read its own geometry
    /// back — `scroll_view`'s content, which needs last frame's height for the scroll
    /// clamp — because `mark` stops at the topmost node it hits, and a bare geometry
    /// probe sitting over a button would otherwise swallow the click.
    pub fn pass_through(self: El) El {
        self.ctx.setPassThrough(self.node.key, true);
        return self;
    }

    /// Refine this node's rectangular hit box with a static host-supplied predicate.
    /// The engine still applies clipping, paint order, pass-through, and bubbling.
    /// The callback receives the stamped global rect and point, so it can derive local
    /// coordinates without storing a pointer into the per-frame arena.
    pub fn hit_test(self: El, predicate: ui.HitTestFn) El {
        self.ctx.setHitTest(self.node.key, predicate);
        return self;
    }

    // -- Content leaves: a child of this node, returned as its own handle. ----------------
    // The parent handle carries `ctx`, so a leaf names only its id and its content. Anything
    // that builds more than one node is a function taking a parent `El`, not a method.

    /// A box holding no content — a row/column container, or a bare hit box.
    pub fn div(self: El, id: []const u8) !El {
        return .{ .ctx = self.ctx, .node = try child(self, id) };
    }

    /// A content-sized text node holding `str` (measured at the default font; recolor/resize
    /// with `with_style`).
    pub fn text(self: El, id: []const u8, str: []const u8) !El {
        const node = try child(self, id);
        try feat.data_text(self.ctx, node, str);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A whole-texture image node, sized to the texture.
    pub fn image(self: El, id: []const u8, texture: sdl.render.Texture) !El {
        const node = try child(self, id);
        try feat.data_img(self.ctx, node, texture);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// One `src` cell of a sprite sheet, drawn at `px`×`px`.
    pub fn sprite(self: El, id: []const u8, spr: Sprite, px: f32) !El {
        const node = try child(self, id);
        try feat.data_sprite(self.ctx, node, spr, px);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A cached SVG raster from `path`, drawn at `px`×`px` (recolor the tint with `with_style`).
    pub fn svg(self: El, id: []const u8, path: [:0]const u8, px: f32) !El {
        const node = try child(self, id);
        try feat.data_svg(self.ctx, node, path, px);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A polyline through `pts` — node-local coordinates in the unit square, so (0,0) is this
    /// node's top-left and (1,1) its bottom-right. Unlike the other content leaves this one
    /// does **not** size itself: points are relative, so the caller gives the node a box
    /// (`with_size`) and the line stretches to fill it.
    pub fn line(self: El, id: []const u8, pts: []const cb.Point, stroke: cb.Stroke) !El {
        const node = try child(self, id);
        feat.data_line(self.ctx, node, pts, stroke);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A filled **convex polygon** through `pts` — node-local unit-square coordinates like
    /// `line`, stretching to whatever box the caller sizes the node to. Fan-triangulated and
    /// drawn by the `geometry` feature (RENDER-03). Flat `color`; `opacity` fades the whole
    /// mesh. Does not size the node.
    pub fn polygon(self: El, id: []const u8, pts: []const cb.Point, color: cb.Color, opacity: f32) !El {
        const node = try child(self, id);
        feat.data_polygon(self.ctx, node, pts, color, opacity);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A **thick polyline** through `pts` (node-local unit-square coords) at `half_width`
    /// (unit-square units, mapped to px at draw), with honest miter joins and `cap` ends;
    /// `closed` connects last→first for a rail loop. Drawn by the `geometry` feature. Does
    /// not size the node.
    pub fn polyline(self: El, id: []const u8, pts: []const cb.Point, half_width: f32, closed: bool, cap: feat.geometry.Cap, color: cb.Color, opacity: f32) !El {
        const node = try child(self, id);
        feat.data_polyline(self.ctx, node, pts, half_width, closed, cap, color, opacity);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A **linear gradient** fill (RENDER-04) along `dir` through ordered `stops` (positions
    /// 0..1 on the axis), drawn by the `geometry` feature via per-vertex colors. Two stops at
    /// the same position give a hard split; a `tint → transparent` pair gives a wash.
    /// `opacity` fades the whole mesh. Does not size the node.
    pub fn gradient(self: El, id: []const u8, dir: feat.geometry.Dir, stops: []const feat.geometry.GradientStop, opacity: f32) !El {
        const node = try child(self, id);
        feat.data_gradient(self.ctx, node, dir, stops, opacity);
        return .{ .ctx = self.ctx, .node = node };
    }
};

/// A fresh child node, anchored `.relative` — the default for content leaves.
fn child(parent: El, id: []const u8) !*Node {
    const node = try Node.pcreate(parent.ctx.arena, id, parent.node);
    node.layout.anchor = .relative; // children flow by default; override with `with_layout`
    return node;
}

/// Scale a `SizeRule`'s **fixed** extent from logical to device px (VIEW-02); leave
/// `content`/`grow`/`fit_children`/`pct_of_parent` untouched.
fn scaleRule(rule: ui.SizeRule, scale: f32) ui.SizeRule {
    return switch (rule) {
        .fixed => |px| .{ .fixed = view.dp(px, scale) },
        else => rule,
    };
}

// -- The root: the one constructor with no parent handle to hang off. ------------------

/// A fullscreen root sized to the live window — the anchor box a screen positions against.
/// A root has no parent and stays non-relative (`.top_left`). Children are `El` methods.
pub fn root(ctx: *UiCtx, id: []const u8) !El {
    const node = try Node.create(ctx.arena, id);
    // A root must place *itself*: `Node.init` defaults `.relative`, which errors the
    // placement pass on a parentless node (`NoInfoForChildren`) — the gameover screen
    // crashed the first time death ever fired, because unlike the play screen it never
    // overrode the anchor. Set here so the doc's promise ("stays non-relative") is true.
    node.layout.anchor = .top_left;
    // VIEW-02: the layout is solved in **device pixels** (the space the renderer draws and
    // that text boxes already live in via `type.toDevice`), so the root is the drawable pixel
    // size (`metrics.px_w/px_h` = logical × DPI). At DPI 1 this equals the window coordinate
    // size (today's behavior); at high-DPI it fills the whole drawable crisply.
    const m = ctx.res.view.metrics;
    node.size = ui.features.Size.initFixed(m.px_w, m.px_h);
    return .{ .ctx = ctx, .node = node };
}

test {
    std.testing.refAllDecls(@This());
}
