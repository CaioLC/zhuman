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

pub const ChildrenPosInfo = struct {
    x_offset: f32,
    y_offset: f32,
};

pub const Layout = struct {
    anchor: Anchor,
    children_align: ChildrenAlign,
    /// Space inserted *between* adjacent flowed (`relative`) children, along the
    /// flow axis (and between rows/columns of the `_wrapped` variants). Does not
    /// apply to the proportional `centered*` aligns (they already distribute space)
    /// nor before the first / after the last child. `fit_children` parents grow to
    /// include the gaps. Defaults to 0 — set via `with_gap`.
    gap: f32,
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
        px = p.layout._global_x orelse 0.0;
        py = p.layout._global_y orelse 0.0;
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
        const gap = l.gap; // inserted between flowed children (and wrapped rows/cols)

        for (dep_buf[0..dep_count], 0..) |c, idx| {
            const cs = c.size;
            switch (l.children_align) {
                .horizontal => {
                    try place(c, .{ .x_offset = x_offset, .y_offset = y_offset });
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
                    try place(c, .{ .x_offset = x_offset, .y_offset = y_offset });
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
