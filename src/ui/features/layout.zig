const std = @import("std");
const Allocator = std.mem.Allocator;

const size_mod = @import("size.zig");
const Size = size_mod.Size;

pub const Anchor = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,
    relative,
};

// ============================ Flow ===========================================

/// The **flow** of a parent's in-flow (`.relative`) children: how they arrange. It's a
/// small struct of *orthogonal* axes rather than one flat enum, because arrangement is a
/// product of independent choices — direction × wrap × reverse × main-distribution ×
/// cross-alignment — and enumerating that product by hand is what makes a layout engine
/// sprawl. One flow algorithm (`place`) reads these five knobs; every combination composes.
///
/// Modeled on CSS flexbox (`flex-direction` / `flex-wrap` / `justify-content` /
/// `align-items`). Out-of-flow children (`anchor != .relative`) ignore all of this — they
/// place themselves by their own `Anchor`, like absolute positioning.
pub const Flow = struct {
    /// The **main axis** — the direction children flow along. `.row` ⇒ main = x (children
    /// left-to-right); `.column` ⇒ main = y (top-to-bottom). The **cross axis** is the other
    /// one. Everything below is expressed in main/cross terms and mapped to x/y by `dir`.
    dir: Direction = .row,
    /// Lay the children out in reverse order along the main axis. Composes with any `main`
    /// alignment (it just reverses the sequence before packing). Replaces the old
    /// `*_reverse` enum variants.
    reverse: bool = false,
    /// Wrap onto a new line when the running main-axis extent would exceed the box, instead
    /// of overflowing in one line. Lines stack along the cross axis (flush from the start;
    /// `align-content` — distributing the lines — is not modeled yet). Replaces `*_wrapped`.
    wrap: bool = false,
    /// **Main-axis distribution**: where the *whole run* of children sits within the box's
    /// main extent, and how leftover main-axis space is shared. This is about the group
    /// (flexbox `justify-content`). Defaults to `.start` (flush at the leading edge).
    main: MainAlign = .start,
    /// **Cross-axis alignment**: where *each child individually* sits within its line's
    /// cross extent (flexbox `align-items`). Defaults to `.baseline` — text-first: a row of
    /// mixed-size text shares a common writing line; a plain box (no baseline) falls back to
    /// the trailing edge, and on a `.column` (where baseline is meaningless) it falls back to
    /// the leading edge (`.start`).
    cross: CrossAlign = .baseline,
};

pub const Direction = enum { row, column };

/// Main-axis distribution — how the run of children is placed within the box's main extent,
/// and how any leftover main-axis space is shared. `gap` (see `Layout.gap`) still spaces
/// adjacent children for the packed modes (`start`/`center`/`end`); the `space_*` modes
/// derive their own spacing from the free space and ignore `gap`.
pub const MainAlign = enum {
    /// Pack at the leading edge (default). Slack, if any, sits after the last child.
    start,
    /// Pack as a block, centered — slack split evenly before and after the run.
    center,
    /// Pack at the trailing edge — slack sits before the first child.
    end,
    /// First child at the leading edge, last at the trailing edge, equal space *between*
    /// each adjacent pair (no space at the ends). One child ⇒ leading edge.
    space_between,
    /// Equal space *around* every child — the end spaces are half the between spaces.
    space_around,
    /// Equal space *everywhere*, including both ends — n children make n+1 equal gaps.
    space_evenly,
};

/// Cross-axis alignment — where each child sits within its line's cross extent. `start`/
/// `center`/`end` are relative to the line's cross band (top/center/bottom for a row;
/// left/center/right for a column). `baseline` (rows only) lines every child's text baseline
/// onto a shared line, so mixed-size text reads on one row; a box with no baseline aligns to
/// its trailing edge, and on a column `baseline` degrades to `start`.
pub const CrossAlign = enum { start, center, end, baseline };

pub const ChildrenPosInfo = struct {
    x_offset: f32,
    y_offset: f32,
};

/// The **overflow** axis: what happens to content that exceeds a node's box. Pure
/// geometry, read *after* the solve — it never changes any computed size. Distinct
/// from the *sizing* axis (`SizeRule`, where the box yields) and from *content-fill*
/// (tiling/stretching a payload to the box, which is host paint policy): overflow keeps
/// the box fixed and constrains the *content's* visible extent. Orthogonal to
/// `scroll_x/y` — scroll *translates* children, overflow *masks* the result; a scroll
/// viewport is the composition `.clip` + a `scroll_y` offset (see `scroll_view`).
pub const Overflow = enum {
    /// Content spilling past the box paints (and hit-tests) normally. The default —
    /// every ordinary node.
    visible,
    /// Crop this node's subtree to its own box. Read by the host render walk (SDL
    /// clip rect) and, in time, by hit-testing. Future crop variants: `scroll` (folds
    /// the `scroll_y` offset in), `ellipsis`.
    clip,
};

pub const Layout = struct {
    /// How *this* node sits within its parent: one of the 9 anchor presets (it places
    /// itself, out-of-flow), or `.relative` (the parent's `flow` places it).
    anchor: Anchor,
    /// How this node's `.relative` children arrange — see `Flow`. Defaults to a plain row.
    flow: Flow = .{},
    /// Space inserted *between* adjacent flowed (`relative`) children along the main axis
    /// (and between wrapped lines on the cross axis). Not before the first / after the last,
    /// and ignored by the `space_*` main distributions (they compute their own spacing).
    /// A `fit_children` parent grows to include the gaps. Defaults to 0 — set via `with_gap`.
    gap: f32,
    /// Screen origin for a *parentless* (root) node: where its top-left lands. Lets a
    /// second, independent tree — an overlay/tooltip layer — be placed anywhere on
    /// screen instead of stacking at (0,0). Ignored once a node has a parent (it's
    /// positioned relative to that parent). Defaults to (0,0), so the main root is
    /// unaffected. Set via `with_origin`.
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    /// Translates this node's *children* (not the node itself) by `-scroll_x`/`-scroll_y`
    /// — a positive value shifts flowed content up/left, as if scrolled down/right. This
    /// is how a scroll container (`widgets.scroll_view`) moves its overflowing `content`
    /// without a second layout pass: the container holds the offset, `place` folds it into
    /// the base position it hands each child. Defaults to 0 (no effect on ordinary nodes).
    /// Distinct from `origin`, which positions a *root* itself, not its children.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Overflow handling for this node's content — see `Overflow`. Defaults to
    /// `.visible` (no cropping), so ordinary nodes are unaffected. Set directly
    /// (`node.layout.overflow = .clip`) or via `with_overflow`.
    overflow: Overflow = .visible,
    _global_x: ?f32,
    _global_y: ?f32,

    pub fn init(anchor: Anchor, flow: ?Flow) Layout {
        return .{
            .anchor = anchor,
            .flow = flow orelse .{},
            .gap = 0,
            ._global_x = null,
            ._global_y = null,
        };
    }

    /// Copy with `gap` set — chains after `init` (`Layout.init(.., .{ .dir = .column }).with_gap(8)`).
    pub fn with_gap(self: Layout, g: f32) Layout {
        var l = self;
        l.gap = g;
        return l;
    }

    /// Copy with the root `origin` set — chains after `init`. Only meaningful on a root
    /// node (see `origin_x`/`origin_y`); use it to float an overlay tree at a point.
    pub fn with_origin(self: Layout, x: f32, y: f32) Layout {
        var l = self;
        l.origin_x = x;
        l.origin_y = y;
        return l;
    }

    /// Copy with `overflow` set — chains after `init`. `.clip` crops this node's
    /// subtree to its box in the render walk (see `Overflow`).
    pub fn with_overflow(self: Layout, o: Overflow) Layout {
        var l = self;
        l.overflow = o;
        return l;
    }
};

// ============================ Public entry ===================================

/// Solve the whole tree, then place it. Three passes:
///   1. `recalculate_size` — bottom-up: resolve `fixed`/`content`/`fit_children`.
///   2. `resolve_pct`       — top-down: finalize `pct_of_parent` vs. definite parents.
///   3. `place`             — top-down: assign every node its global position.
/// The sizing passes are pure (no host callback — `content` sizes read the host's
/// pre-measured `data_width`/`data_height`, set on the node at build). `place` takes a
/// scratch `Allocator` only to materialize each node's in-flow child list; it still never
/// consults the host. Call at the root.
pub fn set_global_pos(node: anytype, alloc: Allocator) anyerror!void {
    recalculate_size(node);
    resolve_pct(node, true, true, 0, 0);
    try place(node, alloc, null);
}

// ============================ Sizing (passes 1 & 2) ==========================

const Axis = enum { x, y };

/// The main (flow) axis of a parent's children: x for a row, y for a column. `fit_children`
/// sums child extents along this axis and maxes them across it.
fn main_axis(flow: Flow) Axis {
    return switch (flow.dir) {
        .row => .x,
        .column => .y,
    };
}

/// This box's extent along `axis`.
fn extent(node: anytype, axis: Axis) f32 {
    return if (axis == .x) node.size.width else node.size.height;
}

/// `fit_children` on one axis. On the **main** axis: sum of child extents plus one `gap`
/// per adjacent in-flow pair — a `fit` parent wraps its spaced children exactly. On the
/// **cross** axis: `fit_cross` (a max, or a baseline-aware ascent+descent for a baseline
/// row). Reads children's already-resolved (pass-1) sizes.
///
/// Note: this sizes for a *single line*; a `fit_children` parent that also `wrap`s is not
/// modeled (the same limitation as before the flow rewrite — wrap is used with fixed/pct
/// containers). Anchored (out-of-flow) children still count toward the main-axis sum, as
/// they did previously.
fn fit_axis(node: anytype, axis: Axis, main: Axis) f32 {
    const flow = node.layout.flow;
    if (axis != main) return fit_cross(node, axis, flow);

    var acc: f32 = 0;
    var flow_count: usize = 0;
    for (node.children.items) |c| {
        acc += extent(c, axis);
        if (c.layout.anchor == .relative) flow_count += 1;
    }
    if (flow_count > 1) acc += node.layout.gap * @as(f32, @floatFromInt(flow_count - 1));
    return acc;
}

/// Cross-axis `fit`. For a baseline row the run's extent is the deepest above-baseline
/// (ascent) plus the deepest below-baseline (descent), so mixed-size text still fits — an
/// out-of-flow child just contributes its own extent. Every other case is a plain max of
/// child cross-extents (which is what `start`/`center`/`end` need). Reduces to
/// `max(child cross-extent)` when no baseline row widens it.
fn fit_cross(node: anytype, cross_axis: Axis, flow: Flow) f32 {
    if (flow.dir == .row and flow.cross == .baseline) {
        var max_ascent: f32 = 0; // deepest above the baseline (height − baseline)
        var max_descent: f32 = 0; // deepest below it (the stored baseline offset)
        var max_anchored: f32 = 0;
        for (node.children.items) |c| {
            const h = c.size.height;
            if (c.layout.anchor == .relative) {
                max_ascent = @max(max_ascent, h - c.size.baseline_off());
                max_descent = @max(max_descent, c.size.baseline_off());
            } else {
                max_anchored = @max(max_anchored, h);
            }
        }
        return @max(max_ascent + max_descent, max_anchored);
    }
    var acc: f32 = 0;
    for (node.children.items) |c| acc = @max(acc, extent(c, cross_axis));
    return acc;
}

/// Pass 1 — bottom-up sizing. Resolves `fixed`, `content`, and `fit_children`
/// (from already-resolved children); `pct_of_parent` takes a provisional = its
/// content size (the fallback value), finalized top-down in `resolve_pct`.
fn recalculate_size(node: anytype) void {
    for (node.children.items) |c| recalculate_size(c);
    const s = &node.size;
    const main = main_axis(node.layout.flow);
    s.width = bottom_up_axis(s.w, s.data_width, node, .x, main) + s.padding.left + s.padding.right;
    s.height = bottom_up_axis(s.h, s.data_height, node, .y, main) + s.padding.up + s.padding.down;
}

fn bottom_up_axis(rule: size_mod.SizeRule, content: f32, node: anytype, axis: Axis, main: Axis) f32 {
    return switch (rule) {
        .fixed => |n| n,
        .content => content,
        .pct_of_parent => content, // provisional; resolve_pct finalizes vs. parent
        .fit_children => fit_axis(node, axis, main),
    };
}

/// Pass 2 — top-down `pct_of_parent` finalize. An axis is *definite* (a usable
/// base for a child's %) when it's known without consulting that child: `fixed`,
/// `content`, or a `pct` once resolved. `fit_children` is indefinite, so a `pct`
/// child of it has no definite base and falls back to `content` (→ the node's
/// measured `data_*`, or 0). `p_inner_*` is the parent's content-box per axis.
fn resolve_pct(node: anytype, p_def_w: bool, p_def_h: bool, p_inner_w: f32, p_inner_h: f32) void {
    const s = &node.size;
    const pad_w = s.padding.left + s.padding.right;
    const pad_h = s.padding.up + s.padding.down;
    const def_w, const inner_w = finalize_axis(s.w, s.data_width, s.width - pad_w, p_def_w, p_inner_w);
    const def_h, const inner_h = finalize_axis(s.h, s.data_height, s.height - pad_h, p_def_h, p_inner_h);
    s.width = inner_w + pad_w;
    s.height = inner_h + pad_h;
    for (node.children.items) |c| resolve_pct(c, def_w, def_h, inner_w, inner_h);
}

/// `(definite, inner_size)` for one axis. `pass1_inner` is the bottom-up
/// content-box already computed (kept as-is for non-`pct` rules and as the `fit`
/// value). A `pct` resolves to `parent_inner * f` when the parent axis is
/// definite, else falls back to `content_seed` (null-safe 0).
fn finalize_axis(rule: size_mod.SizeRule, content_seed: f32, pass1_inner: f32, p_def: bool, p_inner: f32) struct { bool, f32 } {
    return switch (rule) {
        .fixed => |n| .{ true, n },
        .content => .{ true, content_seed },
        .fit_children => .{ false, pass1_inner },
        .pct_of_parent => |f| if (p_def) .{ true, p_inner * f } else .{ true, content_seed },
    };
}

// ============================ Placement (pass 3) =============================

/// Assign global positions top-down. Sizes are already resolved, so this is pure geometry;
/// the `Allocator` is scratch space to materialize each node's in-flow child list (so the
/// flow algorithm reads as one clean loop, and there are no fixed-size stack buffers).
///
/// Each node: resolve its own global position, place its out-of-flow (anchored) children
/// (each self-anchors), then run `flow_place` over its in-flow (`.relative`) children.
fn place(node: anytype, alloc: Allocator, info: ?ChildrenPosInfo) anyerror!void {
    const s: *Size = &node.size;
    const l: *Layout = &node.layout;

    // --- this node's own global position -------------------------------------------------
    var pw: f32 = 0.0;
    var ph: f32 = 0.0;
    var px: f32 = 0.0;
    var py: f32 = 0.0;
    if (node.parent) |p| {
        // Base against the parent's *content box*, not its full box: shrink the extent by
        // the parent's padding and shift the origin in by its leading padding. This is the
        // one spot that makes padding inset children — both the flowed run below (whose
        // offsets add onto px/py) and the anchored path (which anchors within pw/ph at
        // px/py) inherit the inset for free, so `flow_place`/`set_indep_global_pos` can work
        // in pure content-box coordinates (origin 0).
        const pp = p.size.padding;
        pw = p.size.width - pp.left - pp.right;
        ph = p.size.height - pp.up - pp.down;
        px = (p.layout._global_x orelse 0.0) - p.layout.scroll_x + pp.left;
        py = (p.layout._global_y orelse 0.0) - p.layout.scroll_y + pp.up;
    } else {
        // Root: seed from its `origin` (0,0 for the main tree; the cursor/icon point for a
        // floating overlay). Anchor math runs against a zero-size parent, so a `.top_left`
        // overlay lands exactly on its origin.
        px = l.origin_x;
        py = l.origin_y;
    }

    var x: f32, var y: f32 = .{ undefined, undefined };
    if (l.anchor != .relative) {
        x, y = set_indep_global_pos(s.*, l.anchor, pw, ph);
    } else {
        const my_offsets = info orelse return error.NoInfoForChildren;
        x = my_offsets.x_offset;
        y = my_offsets.y_offset;
    }
    l._global_x = px + x;
    l._global_y = py + y;

    // --- children: place anchored (out-of-flow) inline, collect the in-flow run ----------
    var n_flow: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor == .relative) {
            n_flow += 1;
        } else {
            try place(c, alloc, null); // out-of-flow: places itself by its own anchor
        }
    }
    if (n_flow == 0) return;

    const flow_kids = try alloc.alloc(@TypeOf(node), n_flow);
    var w: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor == .relative) {
            flow_kids[w] = c;
            w += 1;
        }
    }
    if (l.flow.reverse) std.mem.reverse(@TypeOf(node), flow_kids);

    try flow_place(node, alloc, flow_kids);
}

/// The one flow algorithm: arrange `kids` (already ordered, reverse applied) inside `node`'s
/// box per its `Flow`. Breaks them into lines (one line unless `wrap`), distributes each line
/// along the main axis (`flow.main`), aligns each child across it (`flow.cross`), and stacks
/// the lines along the cross axis. Axis-generic: it works in (main, cross) and maps to (x, y)
/// via `dir`, so a row and a column share every line of code.
fn flow_place(node: anytype, alloc: Allocator, kids: []@TypeOf(node)) anyerror!void {
    const flow = node.layout.flow;
    const m = main_axis(flow); // .x for a row, .y for a column
    const pad = node.size.padding;
    // Flow within the *content* box, not the full box. `place` already shifted this node's
    // children's origin in by the leading padding (via px/py), so here we only shrink the
    // main extent by the padding on the main axis — every offset below is content-relative
    // (origin 0). The cross axis needs nothing: no distribution reads the box's cross extent,
    // and `line_start` starting at 0 plus the px/py inset already places the first line
    // against the leading cross padding.
    const main_size = extent(node, m) - (if (m == .x) pad.left + pad.right else pad.up + pad.down);
    const gap = node.layout.gap;

    var line_start: f32 = 0; // cross-axis cursor: where the current line begins
    var i: usize = 0;
    while (i < kids.len) {
        // -- gather this line [i, j): pack children until the box is full (when wrapping) --
        var j = i;
        var run: f32 = 0; // main extent incl. gaps so far — the wrap test
        var main_sum: f32 = 0; // sum of child main extents (no gaps)
        var cross_max: f32 = 0;
        var max_ascent: f32 = 0;
        var max_descent: f32 = 0;
        while (j < kids.len) {
            const c = kids[j];
            const cm = extent(c, m);
            const step = if (j == i) cm else gap + cm; // no leading gap on the first child
            if (flow.wrap and j > i and run + step > main_size) break;
            run += step;
            main_sum += cm;
            cross_max = @max(cross_max, extent(c, cross(m)));
            if (m == .x) { // baseline only means something for a row
                max_ascent = @max(max_ascent, c.size.height - c.size.baseline_off());
                max_descent = @max(max_descent, c.size.baseline_off());
            }
            j += 1;
        }
        const count = j - i;
        const fcount: f32 = @floatFromInt(count);
        const line_cross = if (flow.dir == .row and flow.cross == .baseline)
            @max(max_ascent + max_descent, cross_max) // a baseline row can be deeper than any child
        else
            cross_max;

        // -- main-axis distribution: leading offset + spacing between children --
        var lead: f32 = 0;
        var between: f32 = gap;
        switch (flow.main) {
            .start => {},
            .center => lead = (main_size - (main_sum + gap * (fcount - 1))) / 2,
            .end => lead = main_size - (main_sum + gap * (fcount - 1)),
            .space_between => between = if (count > 1) (main_size - main_sum) / (fcount - 1) else 0,
            .space_around => {
                const u = (main_size - main_sum) / fcount;
                lead = u / 2;
                between = u;
            },
            .space_evenly => {
                const u = (main_size - main_sum) / (fcount + 1);
                lead = u;
                between = u;
            },
        }

        // -- place each child of the line --
        var cursor = lead;
        for (kids[i..j]) |c| {
            const cm = extent(c, m);
            const co = line_start + cross_within(flow, m, line_cross, c, max_ascent);
            const xo = if (m == .x) cursor else co;
            const yo = if (m == .x) co else cursor;
            try place(c, alloc, .{ .x_offset = xo, .y_offset = yo });
            cursor += cm + between;
        }

        line_start += line_cross + gap; // wrapped lines are gap-separated on the cross axis
        i = j;
    }
}

/// The axis perpendicular to `m`.
fn cross(m: Axis) Axis {
    return if (m == .x) .y else .x;
}

/// A child's offset within its line's cross band (measured from the line's cross start).
/// `start`/`center`/`end` position the box; `baseline` (rows only) drops the child so its
/// baseline lands on the line's shared baseline (at `max_ascent` from the line top), and on
/// a column falls back to `start`.
fn cross_within(flow: Flow, m: Axis, line_cross: f32, c: anytype, max_ascent: f32) f32 {
    const cc = extent(c, cross(m));
    return switch (flow.cross) {
        .start => 0,
        .center => (line_cross - cc) / 2,
        .end => line_cross - cc,
        .baseline => if (flow.dir == .row) max_ascent - (c.size.height - c.size.baseline_off()) else 0,
    };
}

/// Position for a node that anchors *itself* within its parent (an out-of-flow child, or a
/// root against a zero-size parent). Pure function of the box size, the anchor, and the
/// parent extent.
fn set_indep_global_pos(s: Size, anchor: Anchor, pw: f32, ph: f32) struct { f32, f32 } {
    var x: f32 = 0;
    var y: f32 = 0;
    switch (anchor) {
        .top_left => {},
        .top_center => x = pw * 0.5 - s.width * 0.5,
        .top_right => x = pw - s.width,
        .center_left => y = ph * 0.5 - s.height * 0.5,
        .center => {
            x = pw * 0.5 - s.width * 0.5;
            y = ph * 0.5 - s.height * 0.5;
        },
        .center_right => {
            x = pw - s.width;
            y = ph * 0.5 - s.height * 0.5;
        },
        .bottom_left => y = ph - s.height,
        .bottom_center => {
            x = pw * 0.5 - s.width * 0.5;
            y = ph - s.height;
        },
        .bottom_right => {
            x = pw - s.width;
            y = ph - s.height;
        },
        .relative => unreachable,
    }
    return .{ x, y };
}
