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
const ui = @import("ui");
const cb = @import("./ctx_binding.zig");
const feat = @import("./features/root.zig");
const style = @import("./style.zig");
const view = @import("./view.zig");
const control_mod = @import("./control.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;

/// Re-exports so screens name the gradient vocabulary through `elements`.
pub const GradientStop = feat.geometry.GradientStop;
pub const GradientDir = feat.geometry.Dir;

/// A text leaf's measurement constraint, chosen when the leaf is created (`El.text_fit`) —
/// exactly one of the six, by construction. `.free` is what a plain `text` leaf gets.
pub const TextFit = union(enum) {
    /// The measured glyph box, single line.
    free,
    /// Constrained multiline: greedy word wrap at this many logical px, with a
    /// deterministic UTF-8-safe hard break for an over-long word; the box is the wrapped
    /// width × height and the render draws exactly the measured lines.
    wrap: f32,
    /// Constrained multiline at the width the **layout** gives the leaf: no width is authored.
    /// The leaf's width rule becomes `.pct_of_parent = 1.0` (its parent's content box); chain
    /// `with_size` after `text_fit` to pick another width rule (`.grow`, `.fixed`, …), and keep
    /// the height `.content`. The solve wraps the text at the resolved width and sizes the
    /// height from the wrapped lines, before any height is computed, so a parent, a `.grow`
    /// sibling or a stretched row all see the wrapped height.
    ///
    /// The width must resolve **definitely**: a `pct_of_parent`/`grow` under a
    /// `fit_children` parent falls back to the single-line width, so the text stays one line
    /// at that width. Give the parent chain a definite width (fixed, a percentage of a definite
    /// box, grow on a definite main axis, or a `.stretch` cross axis).
    fill,
    /// A single-line cell of an allocated logical width: the layout box and the hit
    /// box are exactly `width`, never the glyph width, so a widening label cannot shove its
    /// neighbours and a shorter one still reserves its column. `.clip` crops the glyphs to the
    /// cell; `.ellipsis` draws the longest codepoint-aligned prefix plus an ellipsis. `width`
    /// must be nonnegative; `0` is a legal zero-width cell that draws nothing.
    cell: Cell,
    /// A single-line `.cell` at the width the **layout** gives the leaf (CSS `text-overflow` on
    /// a `min-width: 0` box): no width is authored. The width rule becomes
    /// `.pct_of_parent = 1.0`; chain `with_size` after `text_fit` for another (`.grow` takes a
    /// row's remainder). The leaf reserves no width of its own (`data_width = 0`), so it never
    /// inflates a `fit_children` parent or pushes a sibling, and under an indefinite parent it
    /// collapses to 0 (draws nothing). The solve records the resolved width and the draw
    /// clips or elides at it; height and baseline stay the font's single line. `.clip` also
    /// sets `Layout.overflow = .clip`, as `.cell` does.
    cell_fill: CellMode,
    /// One line rotated 90° counter-clockwise, reading bottom-to-top (the collapsed
    /// rail label); the box is the swapped footprint. A bounded orientation, not an angle.
    vertical,

    pub const Cell = struct { mode: CellMode, width: f32 };
    pub const CellMode = enum { clip, ellipsis };
};

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

    /// The keep-alive read: query this node only so it owns an interaction slot and its rect
    /// is stamped — for a node whose flags nobody reads. A scroll view's content probe (read
    /// back next frame for the clamp), the modal scrim and box (a stamped root occludes the
    /// trees beneath it), the tooltip box. Says what `_ = x.query()` left implicit.
    pub fn track(self: El) El {
        _ = self.node.query(self.ctx);
        return self;
    }

    /// This node's pooled `T` slot — acquired on first use, kept while touched each frame,
    /// pruned when the node stops being built (see the engine README, "Where node state
    /// lives"). A template owns its logical state here unless the caller passes a pointer.
    pub fn state(self: El, comptime T: type) *T {
        return self.node.state(self.ctx, T);
    }

    /// Keep a hidden direct child's `T` slot alive this frame without building the child.
    /// Derives the child's structural key; returns false when no such slot exists. Call it
    /// every hidden frame from the always-built owner; pruning resumes when the owner stops.
    pub fn retain_child(self: El, child_id: []const u8, comptime T: type) bool {
        return self.node.retainChildState(self.ctx, child_id, T);
    }

    /// Observe and consume one host interaction flag on this node and its stamped
    /// ancestors. Descendants consume before ancestor action decisions; hover and
    /// unrelated flags remain available.
    pub fn consume(self: El, comptime flag: std.meta.FieldEnum(UiCtx.Interaction)) bool {
        return self.ctx.consumeFlag(self.node.key, flag);
    }

    /// Make this node a control: run the one host lifecycle (focus registration, activation,
    /// disabled consumption, focus acquisition, `ControlState` and semantic publication, the
    /// cursor) and return the published interaction. See `control.zig`. The caller keeps the
    /// enabled gate, the accessible name and role, and paints its chrome from the result.
    pub fn control(self: El, opts: control_mod.Options) UiCtx.Interaction {
        return control_mod.control(self.ctx, self.node, opts);
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

    /// Spacing between this node's in-flow children, in **logical** px (scaled to
    /// device px by the frame scale). A `fit_children` parent grows to include the gaps.
    pub fn with_gap(self: El, g: f32) El {
        self.node.layout.gap = view.dp(g, self.ctx.res.view.scale);
        return self;
    }

    /// Main-axis margins of this node in its parent's run (CSS `margin` along the parent's
    /// flow), in **logical** px scaled to device px by the frame scale: `before` is the
    /// space ahead of it (left in a row, top in a column), `after` the space behind it. They
    /// add to the parent's gap on that side, a `fit_children` parent includes them, and
    /// `grow`/`shrink` treat them as fixed space. The per-sibling spacing a uniform
    /// `with_gap` can't express (`.with_margin(0, 8)` under a heading). Ignored on an
    /// anchored node and on a track cell; there is no cross-axis margin (pad the parent).
    pub fn with_margin(self: El, before: f32, after: f32) El {
        const s = self.ctx.res.view.scale;
        self.node.layout.margin_before = view.dp(before, s);
        self.node.layout.margin_after = view.dp(after, s);
        return self;
    }

    /// Per-axis size rule — `.fit_children`, `.grow`, `.{ .fixed = 240 }`,
    /// `.{ .pct_of_parent = 1 }`, …. A **fixed** extent is a *logical* px value scaled to
    /// device px by the frame scale; `content`/`pct`/`grow`/`fit_children` are
    /// derived (content is the already-device-scaled measured box; the others are relative),
    /// so only `.fixed` scales. Extents computed from **stamped geometry** (already device px)
    /// use `with_size_px` to avoid double-scaling.
    pub fn with_size(self: El, w: ui.SizeRule, h: ui.SizeRule) El {
        self.node.size.w = scaleRule(w, self.ctx.res.view.scale);
        self.node.size.h = scaleRule(h, self.ctx.res.view.scale);
        return self;
    }

    /// Per-axis size rule from **device-px** values that must **not** be scaled again:
    /// extents derived from stamped geometry (`.rect`/`.prior_geometry`) or a
    /// parent's resolved `size.*.fixed`, which are already device px. Authored logical
    /// literals use `with_size`.
    pub fn with_size_px(self: El, w: ui.SizeRule, h: ui.SizeRule) El {
        self.node.size.w = w;
        self.node.size.h = h;
        return self;
    }

    /// Per-axis lower bound (CSS `min-width`/`min-height`) in **logical** px, scaled to device
    /// px by the frame scale; a null axis keeps its current bound. Pass `null, 38` to floor
    /// only the height. The bound applies to the **content box** whatever the rule, and padding
    /// is added after the clamp, so a padded node is `min + padding` tall at least: a CSS
    /// `box-sizing: border-box` min-height converts by subtracting the node's own padding. A
    /// border-box rule (`pct_of_parent`, `grow`) takes its padding out of its share first, so
    /// a min can push the box past that share. A min above the max wins (`Size.min_*`).
    pub fn with_min(self: El, w: ?f32, h: ?f32) El {
        const s = self.ctx.res.view.scale;
        if (w) |v| self.node.size.min_width = view.dp(v, s);
        if (h) |v| self.node.size.min_height = view.dp(v, s);
        return self;
    }

    /// Per-axis upper bound (CSS `max-width`/`max-height`) in **logical** px, scaled to device
    /// px by the frame scale; a null axis keeps its current bound (unbounded by default).
    /// Like `with_min` it bounds the **content box**: padding is added after the clamp, so a
    /// CSS border-box max converts by subtracting the node's own padding. A min above the max
    /// still wins.
    pub fn with_max(self: El, w: ?f32, h: ?f32) El {
        const s = self.ctx.res.view.scale;
        if (w) |v| self.node.size.max_width = view.dp(v, s);
        if (h) |v| self.node.size.max_height = view.dp(v, s);
        return self;
    }

    /// Per-axis px a `pct_of_parent` axis leaves out of its share (CSS `calc(p% − Npx)`), in
    /// **logical** px scaled to device px by the frame scale; a null axis keeps its current
    /// value (0 by default). `.with_size(.{ .pct_of_parent = 1.0 }, …).with_pct_less(8, null)`
    /// ends 8px short of the parent's content box; the node's own padding still comes out of
    /// what is left, and min/max still bound the content box. Other rules ignore it.
    pub fn with_pct_less(self: El, w: ?f32, h: ?f32) El {
        const s = self.ctx.res.view.scale;
        if (w) |v| self.node.size.pct_less_width = view.dp(v, s);
        if (h) |v| self.node.size.pct_less_height = view.dp(v, s);
        return self;
    }

    /// Growth weight for a `.grow` main axis (CSS `flex-grow`): growers split the parent's
    /// free space in proportion, so `with_grow(2)` takes twice a plain `.grow` sibling's
    /// share. `0` holds the node at its minimum. Unitless, so not scaled.
    pub fn with_grow(self: El, weight: f32) El {
        self.node.size.grow_weight = weight;
        return self;
    }

    /// Opt in to main-axis shrink (CSS `flex-shrink`; the default 0 never shrinks). When a
    /// definite, non-wrapping parent's run overflows, this node gives up overflow in
    /// proportion to `factor ×` its content extent, down to its main-axis minimum.
    /// Ignored on a `.grow` main axis. Unitless, so not scaled.
    pub fn with_shrink(self: El, factor: f32) El {
        self.node.size.shrink = factor;
        return self;
    }

    /// Declare a shared column-track set (from `tracks`) on this node, the common ancestor of
    /// every row that lays out by it: a table's head and its rows, at whatever depths. The
    /// node itself keeps its own flow. Every `in_tracks` row of `set` must be built under it.
    pub fn with_tracks(self: El, set: *ui.TrackSet) El {
        self.node.layout.track_owner = set;
        return self;
    }

    /// Lay this row's in-flow children out by `set`'s columns (CSS `grid-template-columns`
    /// repeated on each row): each child is a cell whose width and x come from the tracks,
    /// and whose descendants see that width as definite (`.fill` text, a `1.0` child). The
    /// row must be a non-wrapping, non-reversed `.dir = .row` flow under the set's
    /// `with_tracks` owner. A cell that doesn't fit on the current line (an `at_track` col
    /// behind the cursor, or a span past the last track) opens a new line, spaced by the set's
    /// row gap (`tracks_gaps`); `flow.cross` aligns the cells of each line and `with_gap` is
    /// not read (the set has its own gaps). Each row keeps its own key, control and role.
    pub fn in_tracks(self: El, set: *ui.TrackSet) El {
        self.node.layout.track_row = set;
        return self;
    }

    /// Place this cell of an `in_tracks` row explicitly: start at track `col` (null takes the
    /// next visible track) and cover `span` tracks plus the gaps between them. A plain cell
    /// needs no call. `at_track(0, all_tracks)` is CSS `grid-column: 1 / -1`: after any other
    /// cell it takes a line of its own, full width.
    pub fn at_track(self: El, col: ?u16, span: u16) El {
        self.node.layout.cell_col = col;
        self.node.layout.cell_span = span;
        return self;
    }

    /// A span that covers every track from its start (clamped to the set).
    pub const all_tracks: u16 = std.math.maxInt(u16);

    /// Displace this node in **logical** px (scales to device px) from wherever its
    /// anchor or its parent's flow put it. `.center` plus a computed delta is polar placement
    /// — the way anything positioned by its own arithmetic (a radial board, a graph) reaches
    /// the screen.
    pub fn with_offset(self: El, dx: f32, dy: f32) El {
        const s = self.ctx.res.view.scale;
        self.node.layout.offset_x = view.dp(dx, s);
        self.node.layout.offset_y = view.dp(dy, s);
        return self;
    }

    /// Displace this node by a **device-px** offset that must not be scaled again —
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

    /// Set this node's **visual opacity** (0..1). The render walk multiplies it
    /// into the opacity inherited from ancestors and folds the product into every feature's
    /// paint alpha, so this node *and its whole subtree* dim together without recomputing any
    /// child's color (a filtered board tile, a disabled control). Purely visual: it never
    /// changes hit eligibility — state logic decides clickability separately.
    pub fn with_opacity(self: El, opacity: f32) El {
        self.node.render_data.opacity = opacity;
        return self;
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

    /// The `i`-th repeated child under this node: a box keyed by `id` **and** the index through
    /// the engine's `key_i`, so a loop body never formats an id into the arena. Build the
    /// item's content into the returned box. When the item owns state or focus, pass a stable
    /// domain index (a recipe's catalog index), never a filtered or sorted position, so the
    /// item keeps its identity when the list reorders.
    pub fn item(self: El, id: []const u8, i: usize) !El {
        const node = try Node.pcreate_i(self.ctx.arena, id, i, self.node);
        node.layout.anchor = .relative;
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A fixed-size empty box that only takes up space (logical px). Non-interactive by
    /// construction: nothing queries it, so it owns no interaction slot and neither takes nor
    /// blocks a hit — no pass-through declaration needed.
    pub fn spacer(self: El, id: []const u8, w: f32, h: f32) !El {
        return (try self.div(id)).with_size(.{ .fixed = w }, .{ .fixed = h });
    }

    /// A content-sized text node holding `str` (measured at the default font; recolor/resize
    /// with `with_style`).
    pub fn text(self: El, id: []const u8, str: []const u8) !El {
        const node = try child(self, id);
        try feat.data_text(self.ctx, node, str);
        return .{ .ctx = self.ctx, .node = node };
    }

    /// A text leaf with a measurement constraint — see `TextFit`. The fit is *placement* (it
    /// sets the reserved box), so it is a creation parameter of the leaf rather than a style
    /// field; a later `with_style(.{ font })` re-measures at the same fit. Widths are logical
    /// px, scaled once here against the device-px font metrics. The rotated footprint,
    /// the cell box and the wrapped box are what the engine stamps, so layout, focus outline and
    /// hit target agree with the drawn glyphs by construction. `.fill` and `.cell_fill` also set
    /// the width rule and opt the node into the solve's measure — see `TextFit`.
    pub fn text_fit(self: El, id: []const u8, str: []const u8, fit: TextFit) !El {
        const leaf = try self.text(id, str);
        const st = leaf.node.state(self.ctx, cb.UiState.TextState);
        const scale = self.ctx.res.view.scale;
        switch (fit) {
            .free => st.fit = .free,
            .wrap => |max_w| st.fit = .{ .wrap = view.dp(max_w, scale) },
            .fill => {
                // Measured one line here (the width seed); the solve's measurer wraps it at
                // the resolved width and writes the height (`text.heightForWidth`).
                st.fit = .{ .fill = 0 };
                leaf.node.size.w = .{ .pct_of_parent = 1.0 };
                leaf.node.size.measure_h = true;
            },
            .cell => |c| {
                std.debug.assert(c.width >= 0);
                st.fit = .{ .cell = .{
                    .mode = switch (c.mode) {
                        .clip => .clip,
                        .ellipsis => .ellipsis,
                    },
                    .width = view.dp(c.width, scale),
                } };
                // A `.clip` cell also routes through the engine's `Layout.overflow = .clip`, so any
                // decoration subtree is cropped to the cell and hit-testing rejects outside it; the
                // leaf's own glyphs are cropped renderer-scoped in `text.draw`.
                if (c.mode == .clip) leaf.node.layout.overflow = .clip;
            },
            .cell_fill => |mode| {
                // No reserved width (`remeasure` writes `data_width = 0`); the solve's measurer
                // records the resolved width on the fit (`text.heightForWidth`) and returns
                // null, so the single-line height and baseline stand.
                st.fit = .{ .cell_fill = .{
                    .mode = switch (mode) {
                        .clip => .clip,
                        .ellipsis => .ellipsis,
                    },
                    .width = 0,
                } };
                leaf.node.size.w = .{ .pct_of_parent = 1.0 };
                leaf.node.size.measure_h = true;
                if (mode == .clip) leaf.node.layout.overflow = .clip;
            },
            .vertical => st.fit = .vertical,
        }
        feat.text.remeasure(self.ctx, leaf.node);
        return leaf;
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

    /// A filled **convex polygon** through `pts` — node-local unit-square coordinates,
    /// stretching to whatever box the caller sizes the node to. Fan-triangulated and
    /// drawn by the `geometry` feature. Flat `color`; `opacity` fades the whole
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

    /// A **linear gradient** fill along `dir` through ordered `stops` (positions
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

/// Scale a `SizeRule`'s **fixed** extent from logical to device px; leave
/// `content`/`grow`/`fit_children`/`pct_of_parent` untouched.
fn scaleRule(rule: ui.SizeRule, scale: f32) ui.SizeRule {
    return switch (rule) {
        .fixed => |px| .{ .fixed = view.dp(px, scale) },
        else => rule,
    };
}

/// A shared column-track set for `El.with_tracks`/`El.in_tracks`, allocated this frame in
/// `ctx.arena` with its solve scratch. `spec` is in **logical** px (a comptime literal is
/// fine; the set holds a scaled copy): `px`, `min`, `max` and `col_gap` scale to device px,
/// `fr` weights are unitless. One table, one call:
///
///   const set = try el.tracks(ctx, &.{ .{ .basis = .{ .fr = 1 } }, .{ .basis = .{ .px = 86 } } }, 10);
pub fn tracks(ctx: *UiCtx, spec: []const ui.Track, col_gap: f32) !*ui.TrackSet {
    return tracks_gaps(ctx, spec, col_gap, 0);
}

/// `tracks` with a `row_gap` (logical px, scaled like `col_gap`) between the implicit lines of
/// a participant whose cells don't fit on one line (CSS `gap: <row> <column>`).
pub fn tracks_gaps(ctx: *UiCtx, spec: []const ui.Track, col_gap: f32, row_gap: f32) !*ui.TrackSet {
    const s = ctx.res.view.scale;
    const a = ctx.arena;
    const scaled = try a.alloc(ui.Track, spec.len);
    for (spec, scaled) |t, *out| {
        out.* = t;
        out.min = view.dp(t.min, s);
        if (t.max) |m| out.max = view.dp(m, s);
        out.basis = switch (t.basis) {
            .px => |v| .{ .px = view.dp(v, s) },
            else => t.basis,
        };
    }
    const set = try a.create(ui.TrackSet);
    set.* = .{
        .tracks = scaled,
        .col_gap = view.dp(col_gap, s),
        .row_gap = view.dp(row_gap, s),
        .auto_max = try a.alloc(f32, spec.len),
        .widths = try a.alloc(f32, spec.len),
    };
    @memset(set.auto_max, 0);
    @memset(set.widths, 0);
    return set;
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
    // The layout is solved in **device pixels** (the space the renderer draws and
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
