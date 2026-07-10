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

pub const ChildrenAlign = enum {
    horizontal,
    horizontal_wrapped,
    horizontal_reverse,
    horizontal_reverse_wrapped,
    vertical,
    vertical_right,
    vertical_wrapped,
    vertical_reverse,
    vertical_reverse_wrapped,
    centered,
    centered_wrapped,
    centered_top,
    centered_bottom,
    centered_top_wrapped,
    centered_bottom_wrapped,
};

/// Cross-axis alignment for a `.horizontal` flow — how a mixed-height row lines its
/// children up **vertically**. All four are one operation: give each child a *reference
/// line* (an offset from its top), then place every child so its reference lands on the
/// row's deepest reference (see `cross_ref` + `place`). `top`/`center`/`bottom` reference
/// the box edge/middle; `baseline` references the text baseline (`Size.baseline`), so
/// mixed-size text shares a common line. A box with no baseline (`baseline == 0`) falls
/// back to its bottom edge, so `.baseline` degrades to `.bottom` for plain boxes.
/// **Horizontal-flow only** — a vertical flow's cross axis is X, where "baseline" has no
/// meaning, so it keeps aligning left/center/right via `child_anchor` (see `place`).
pub const CrossAlign = enum { top, center, bottom, baseline };

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
    anchor: Anchor,
    children_align: ChildrenAlign,
    /// Where this node's flowed children settle within its **leftover space**, for the
    /// simple `.horizontal`/`.vertical` flows only. The anchor's *cross-axis* part aligns
    /// each child individually (a short child in a tall row → top/center/bottom); its
    /// *main-axis* part justifies the whole packed run within any main-axis slack
    /// (left/center/right). A no-op when the parent exactly fits its children on that axis
    /// (e.g. `fit_children`) and for the wrapped/reverse/`centered` flows. Defaults to
    /// `.top_left` — children flush to the start of both axes, i.e. the historical behavior.
    /// Set via `El.with_align_children`; the engine's `Node.with_layout` leaves it at default.
    child_anchor: Anchor = .top_left,
    /// Cross-axis alignment of a `.horizontal` flow's children — see `CrossAlign`. Defaults
    /// to `.baseline` (text-first: mixed-size text shares a line, plain boxes bottom-align).
    /// Supersedes `child_anchor`'s cross (vertical) component for horizontal flows; ignored
    /// by vertical flows (which cross-align via `child_anchor`) and by wrapped/reverse flows.
    /// Set via `El.with_cross_align`.
    cross_align: CrossAlign = .baseline,
    /// Space inserted *between* adjacent flowed (`relative`) children, along the
    /// flow axis (and between rows/columns of the `_wrapped` variants). Does not
    /// apply to the proportional `centered*` aligns (they already distribute space)
    /// nor before the first / after the last child. `fit_children` parents grow to
    /// include the gaps. Defaults to 0 — set via `with_gap`.
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

    pub fn init(anchor: Anchor, children_align: ?ChildrenAlign) Layout {
        return .{
            .anchor = anchor,
            .children_align = children_align orelse .horizontal,
            .gap = 0,
            ._global_x = null,
            ._global_y = null,
        };
    }

    /// Copy with `gap` set — chains after `init` (`Layout.init(.., .vertical).with_gap(8)`).
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

/// Solve the whole tree, then place it. Three passes, all pure (no host callback):
///   1. `recalculate_size` — bottom-up: resolve `fixed`/`content`/`fit_children`.
///   2. `resolve_pct`       — top-down: finalize `pct_of_parent` vs. definite parents.
///   3. `place`             — top-down: assign every node its global position.
/// `content` sizes read the host's pre-measured `data_width`/`data_height` (set on
/// the node at build), so the engine never measures anything itself. Call at root.
pub fn set_global_pos(node: anytype) anyerror!void {
    recalculate_size(node);
    resolve_pct(node, true, true, 0, 0);
    try place(node, null);
}

// ============================ Sizing (passes 1 & 2) ==========================

const Axis = enum { x, y };

/// The main (flow) axis of a parent's children, from its `children_align`:
/// vertical* flows on y, horizontal* and centered* on x. `fit_children` sums
/// child extents along this axis and maxes them across it.
fn main_axis(layout: Layout) Axis {
    return switch (layout.children_align) {
        .vertical, .vertical_right, .vertical_wrapped, .vertical_reverse, .vertical_reverse_wrapped => .y,
        else => .x,
    };
}

/// `fit_children` on one axis: sum of child box extents if that axis is the flow
/// (main) axis, else the max. Reads children's already-resolved (pass-1) sizes. On
/// the main axis it also reserves the inter-child `gap` (one per flowed pair), so a
/// `fit` parent wraps its spaced children exactly.
fn fit_axis(node: anytype, axis: Axis, main: Axis) f32 {
    // Cross axis (height) of a simple horizontal flow: the box must wrap the *reference-
    // aligned* run, so its height is the deepest reference plus the deepest below-reference
    // (`fit_cross`), not a plain child-height max. It reduces to `max(child height)` for
    // top/center/bottom and only grows past it when a baseline row's tallest ascent and
    // deepest descent come from different children.
    if (axis == .y and main == .x and node.layout.children_align == .horizontal)
        return fit_cross(node);

    var acc: f32 = 0;
    var flow_count: usize = 0;
    for (node.children.items) |c| {
        const cs = c.size;
        const v = if (axis == .x) cs.width else cs.height;
        if (axis == main) {
            acc += v;
            if (c.layout.anchor == .relative) flow_count += 1;
        } else {
            acc = @max(acc, v);
        }
    }
    if (axis == main and flow_count > 1) acc += node.layout.gap * @as(f32, @floatFromInt(flow_count - 1));
    return acc;
}

/// Cross-axis (height) fit for a `.horizontal` flow, reference-aware. Flowed children
/// contribute `maxAscent + maxDescent` — their reference lines share one row line, so the
/// run's extent is the deepest above-reference plus the deepest below-reference. An
/// independently-anchored child (placed by its own anchor, not in the flow) just
/// contributes its own height. Both fold into one max.
fn fit_cross(node: anytype) f32 {
    var max_ascent: f32 = 0; // deepest reference-from-top (what `cross_ref` returns)
    var max_descent: f32 = 0; // deepest below the reference line (h − ref)
    var max_anchored: f32 = 0;
    for (node.children.items) |c| {
        const h = c.size.height;
        if (c.layout.anchor == .relative) {
            const ref = cross_ref(node.layout.cross_align, h, c.size.baseline);
            max_ascent = @max(max_ascent, ref);
            max_descent = @max(max_descent, h - ref);
        } else {
            max_anchored = @max(max_anchored, h);
        }
    }
    return @max(max_ascent + max_descent, max_anchored);
}

/// Pass 1 — bottom-up sizing. Resolves `fixed`, `content`, and `fit_children`
/// (from already-resolved children); `pct_of_parent` takes a provisional = its
/// content size (the fallback value), finalized top-down in `resolve_pct`. `node`
/// is `anytype` (a `*Node(RenderData)`). `data_width`/`data_height` are the host's
/// pre-measured content dims (set at build); read for `content`, never overwritten.
fn recalculate_size(node: anytype) void {
    for (node.children.items) |c| recalculate_size(c);
    const s = &node.size;
    const main = main_axis(node.layout);
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

/// Fraction of a box anchor's leftover space that sits *before* the child on the X axis
/// (left→0, center→0.5, right→1). `.relative` is invalid as a `child_anchor` → treated as 0.
fn anchor_fx(a: Anchor) f32 {
    return switch (a) {
        .top_center, .center, .bottom_center => 0.5,
        .top_right, .center_right, .bottom_right => 1.0,
        else => 0.0,
    };
}

/// Same, for the Y axis (top→0, center→0.5, bottom→1).
fn anchor_fy(a: Anchor) f32 {
    return switch (a) {
        .center_left, .center, .center_right => 0.5,
        .bottom_left, .bottom_center, .bottom_right => 1.0,
        else => 0.0,
    };
}

/// A child's cross-axis **reference line**, as a px offset from its **top** edge, for a
/// `.horizontal` flow's `cross_align`. The row lines every child's reference onto the
/// deepest one (`place`), and the row's `fit` height is `max(ref) + max(h − ref)`
/// (`fit_cross`). `top`/`center`/`bottom` reference the box; `baseline` references the
/// text baseline — `Size.baseline` is stored from the bottom, so the top offset is
/// `h − baseline` (= the font ascent), and `baseline == 0` makes it the bottom edge.
fn cross_ref(mode: CrossAlign, h: f32, baseline: f32) f32 {
    return switch (mode) {
        .top => 0,
        .center => h / 2,
        .bottom => h,
        .baseline => h - baseline,
    };
}

/// Assign global positions top-down. Pure geometry — sizes are already resolved,
/// so this never consults the host (`ctx`). `node` is `anytype` (a `*Node(RenderData)`);
/// only render-agnostic fields are touched, so the walk monomorphizes per node type.
fn place(node: anytype, children_info: ?ChildrenPosInfo) anyerror!void {
    const s: *Size = &node.size;
    const l: *Layout = &node.layout;

    var pw: f32 = 0.0;
    var ph: f32 = 0.0;
    var px: f32 = 0.0;
    var py: f32 = 0.0;
    if (node.parent) |p| {
        pw = p.size.width;
        ph = p.size.height;
        px = (p.layout._global_x orelse 0.0) - p.layout.scroll_x;
        py = (p.layout._global_y orelse 0.0) - p.layout.scroll_y;
    } else {
        // Root: seed from its `origin` (0,0 for the main tree; the cursor/icon point
        // for a floating overlay). Anchor math below runs against a zero-size parent,
        // so a `.top_left` overlay lands exactly on its origin.
        px = node.layout.origin_x;
        py = node.layout.origin_y;
    }

    var x: f32, var y: f32 = .{ undefined, undefined };
    if (l.anchor != .relative) {
        x, y = set_indep_global_pos(s.*, l.anchor, pw, ph);
    } else {
        const my_offsets = children_info orelse return error.NoInfoForChildren;
        x = my_offsets.x_offset;
        y = my_offsets.y_offset;
    }

    l._global_x = px + x;
    l._global_y = py + y;

    var indep_buf: [256]@TypeOf(node) = undefined;
    var indep_count: usize = 0;
    var dep_buf: [256]@TypeOf(node) = undefined;
    var dep_count: usize = 0;

    for (node.children.items) |c| {
        if (c.layout.anchor == .relative) {
            dep_buf[dep_count] = c;
            dep_count += 1;
        } else {
            indep_buf[indep_count] = c;
            indep_count += 1;
        }
    }

    for (indep_buf[0..indep_count]) |c| try place(c, null);

    if (dep_count > 0) {
        var x_offset: f32 = 0.0;
        var y_offset: f32 = 0.0;
        var row_max_height: f32 = 0.0;
        var col_max_width: f32 = 0.0;
        var max_ref: f32 = 0.0; // `.horizontal` cross-align: the shared reference line (deepest ref-from-top)
        const gap = l.gap; // inserted between flowed children (and wrapped rows/cols)

        // Block justification (simple flows only): shift the whole flowed run within the
        // parent's leftover *main-axis* space, per `child_anchor`'s main-axis component.
        // `.top_left` (the default) leaves the run flush at the start — historical behavior.
        switch (l.children_align) {
            .horizontal => {
                var block: f32 = 0;
                for (dep_buf[0..dep_count]) |c| block += c.size.width;
                if (dep_count > 1) block += gap * @as(f32, @floatFromInt(dep_count - 1));
                x_offset = anchor_fx(l.child_anchor) * (s.width - block);
                // Cross-align: the shared line every child's reference gets pulled onto.
                for (dep_buf[0..dep_count]) |c|
                    max_ref = @max(max_ref, cross_ref(l.cross_align, c.size.height, c.size.baseline));
            },
            .vertical => {
                var block: f32 = 0;
                for (dep_buf[0..dep_count]) |c| block += c.size.height;
                if (dep_count > 1) block += gap * @as(f32, @floatFromInt(dep_count - 1));
                y_offset = anchor_fy(l.child_anchor) * (s.height - block);
            },
            else => {},
        }

        for (dep_buf[0..dep_count], 0..) |c, idx| {
            const cs = c.size;
            switch (l.children_align) {
                .horizontal => {
                    // Cross-align: pull this child's reference onto the row's shared line.
                    // Reduces to bottom-align for plain boxes (baseline 0), and to
                    // top/center/bottom per `cross_align`; baselines coincide for text.
                    const cy = max_ref - cross_ref(l.cross_align, cs.height, cs.baseline);
                    try place(c, .{ .x_offset = x_offset, .y_offset = cy });
                    x_offset += cs.width + gap;
                },
                .horizontal_wrapped => {
                    if (x_offset + cs.width > s.width) {
                        x_offset = 0.0;
                        y_offset += row_max_height + gap;
                        row_max_height = 0.0;
                    }
                    try place(c, .{ .x_offset = x_offset, .y_offset = y_offset });
                    x_offset += cs.width + gap;
                    row_max_height = @max(row_max_height, cs.height);
                },
                .horizontal_reverse => {
                    x_offset -= cs.width;
                    try place(c, .{ .x_offset = s.width + x_offset, .y_offset = y_offset });
                    x_offset -= gap;
                },
                .horizontal_reverse_wrapped => {
                    x_offset -= cs.width;
                    if (-x_offset > s.width) {
                        x_offset = 0 - cs.width;
                        y_offset += row_max_height + gap;
                        row_max_height = 0.0;
                    }
                    try place(c, .{ .x_offset = s.width + x_offset, .y_offset = y_offset });
                    x_offset -= gap;
                    row_max_height = @max(row_max_height, cs.height);
                },
                .vertical => {
                    const cx = anchor_fx(l.child_anchor) * (s.width - cs.width); // cross-align
                    try place(c, .{ .x_offset = cx, .y_offset = y_offset });
                    y_offset += cs.height + gap;
                },
                .vertical_right => {
                    try place(c, .{ .x_offset = s.width - cs.width, .y_offset = y_offset });
                    y_offset += cs.height + gap;
                },
                .vertical_wrapped => {
                    if (y_offset + cs.height > s.height) {
                        y_offset = 0.0;
                        x_offset += col_max_width + gap;
                        col_max_width = 0.0;
                    }
                    try place(c, .{ .x_offset = x_offset, .y_offset = y_offset });
                    y_offset += cs.height + gap;
                    col_max_width = @max(col_max_width, cs.width);
                },
                .vertical_reverse => {
                    y_offset -= cs.height;
                    try place(c, .{ .x_offset = x_offset, .y_offset = s.height + y_offset });
                    y_offset -= gap;
                },
                .vertical_reverse_wrapped => {
                    y_offset -= cs.height;
                    if (-y_offset > s.height) {
                        y_offset = 0 - cs.height;
                        x_offset += col_max_width + gap;
                        col_max_width = 0.0;
                    }
                    try place(c, .{ .x_offset = x_offset, .y_offset = s.height + y_offset });
                    y_offset -= gap;
                    col_max_width = @max(col_max_width, cs.width);
                },
                .centered => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = s.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cs.width / 2);
                    const start_y = (s.height - cs.height) / 2;
                    try place(c, .{ .x_offset = start_x, .y_offset = start_y });
                },
                .centered_top => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = s.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cs.width / 2);
                    try place(c, .{ .x_offset = start_x, .y_offset = 0 });
                },
                .centered_bottom => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = s.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cs.width / 2);
                    try place(c, .{ .x_offset = start_x, .y_offset = s.height - cs.height });
                },
                .centered_top_wrapped => {
                    if (idx != 0) continue;
                    try set_centered_wrapped_rows(dep_buf[0..dep_count], s.width, 0.0);
                },
                .centered_bottom_wrapped => {
                    if (idx != 0) continue;
                    const total_h = compute_wrapped_height(dep_buf[0..dep_count], s.width);
                    try set_centered_wrapped_rows(dep_buf[0..dep_count], s.width, s.height - total_h);
                },
                .centered_wrapped => {
                    if (idx != 0) continue;
                    const total_h = compute_wrapped_height(dep_buf[0..dep_count], s.width);
                    try set_centered_wrapped_rows(dep_buf[0..dep_count], s.width, (s.height - total_h) / 2.0);
                },
            }
        }
    }
}

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

fn compute_wrapped_height(dep_children: anytype, parent_width: f32) f32 {
    var total_h: f32 = 0.0;
    var scan_start: usize = 0;
    while (scan_start < dep_children.len) {
        const first = dep_children[scan_start].size;
        var scan_end: usize = scan_start + 1;
        var scan_w: f32 = first.width;
        var scan_h: f32 = first.height;
        while (scan_end < dep_children.len) {
            const next = dep_children[scan_end].size;
            if (scan_w + next.width > parent_width) break;
            scan_w += next.width;
            scan_h = @max(scan_h, next.height);
            scan_end += 1;
        }
        total_h += scan_h;
        scan_start = scan_end;
    }
    return total_h;
}

fn set_centered_wrapped_rows(dep_children: anytype, parent_width: f32, start_y: f32) !void {
    var row_start: usize = 0;
    var current_y: f32 = start_y;
    while (row_start < dep_children.len) {
        const first = dep_children[row_start].size;
        var row_end: usize = row_start + 1;
        var row_w: f32 = first.width;
        var row_h: f32 = first.height;
        while (row_end < dep_children.len) {
            const next = dep_children[row_end].size;
            if (row_w + next.width > parent_width) break;
            row_w += next.width;
            row_h = @max(row_h, next.height);
            row_end += 1;
        }
        var x_row = (parent_width - row_w) / 2.0;
        for (dep_children[row_start..row_end]) |child| {
            const cs = child.size;
            try place(child, .{ .x_offset = x_row, .y_offset = current_y });
            x_row += cs.width;
        }
        current_y += row_h;
        row_start = row_end;
    }
}
