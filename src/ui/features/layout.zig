const ui = @import("../root.zig");
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
    _global_x: ?f32,
    _global_y: ?f32,

    pub fn init(anchor: Anchor, children_align: ?ChildrenAlign) Layout {
        return .{
            .anchor = anchor,
            .children_align = children_align orelse .horizontal,
            ._global_x = null,
            ._global_y = null,
        };
    }
};

pub fn set_global_pos(node: *ui.Node, children_info: ?ChildrenPosInfo, ctx: ?*anyopaque) anyerror!void {
    const s: *Size = &(node.size orelse return);
    const l: *Layout = &(node.layout orelse return);

    if (node.parent == null) {
        if (ctx) |c| try size_mod.recalculate_size(node, c);
    }

    var pw: f32 = 0.0;
    var ph: f32 = 0.0;
    var px: f32 = 0.0;
    var py: f32 = 0.0;
    if (node.parent) |p| {
        if (p.size) |ps| { pw = ps.width; ph = ps.height; }
        if (p.layout) |pl| { px = pl._global_x orelse 0.0; py = pl._global_y orelse 0.0; }
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

    var indep_buf: [256]*ui.Node = undefined;
    var indep_count: usize = 0;
    var dep_buf: [256]*ui.Node = undefined;
    var dep_count: usize = 0;

    for (node.children.items) |c| {
        if (c.layout) |cl| {
            if (cl.anchor == .relative) {
                dep_buf[dep_count] = c;
                dep_count += 1;
            } else {
                indep_buf[indep_count] = c;
                indep_count += 1;
            }
        }
    }

    for (indep_buf[0..indep_count]) |c| try set_global_pos(c, null, ctx);

    if (dep_count > 0) {
        var x_offset: f32 = 0.0;
        var y_offset: f32 = 0.0;
        var row_max_height: f32 = 0.0;
        var col_max_width: f32 = 0.0;

        for (dep_buf[0..dep_count], 0..) |c, idx| {
            const cs = c.size orelse continue;
            switch (l.children_align) {
                .horizontal => {
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    x_offset += cs.width;
                },
                .horizontal_wrapped => {
                    if (x_offset + cs.width > s.width) {
                        x_offset = 0.0;
                        y_offset += row_max_height;
                        row_max_height = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    x_offset += cs.width;
                    row_max_height = @max(row_max_height, cs.height);
                },
                .horizontal_reverse => {
                    x_offset -= cs.width;
                    try set_global_pos(c, .{ .x_offset = s.width + x_offset, .y_offset = y_offset }, ctx);
                },
                .horizontal_reverse_wrapped => {
                    x_offset -= cs.width;
                    if (-x_offset > s.width) {
                        x_offset = 0 - cs.width;
                        y_offset += row_max_height;
                        row_max_height = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = s.width + x_offset, .y_offset = y_offset }, ctx);
                    row_max_height = @max(row_max_height, cs.height);
                },
                .vertical => {
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    y_offset += cs.height;
                },
                .vertical_right => {
                    try set_global_pos(c, .{ .x_offset = s.width - cs.width, .y_offset = y_offset }, ctx);
                    y_offset += cs.height;
                },
                .vertical_wrapped => {
                    if (y_offset + cs.height > s.height) {
                        y_offset = 0.0;
                        x_offset += col_max_width;
                        col_max_width = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    y_offset += cs.height;
                    col_max_width = @max(col_max_width, cs.width);
                },
                .vertical_reverse => {
                    y_offset -= cs.height;
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = s.height + y_offset }, ctx);
                },
                .vertical_reverse_wrapped => {
                    y_offset -= cs.height;
                    if (-y_offset > s.height) {
                        y_offset = 0 - cs.height;
                        x_offset += col_max_width;
                        col_max_width = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = s.height + y_offset }, ctx);
                    col_max_width = @max(col_max_width, cs.width);
                },
                .centered => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = s.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cs.width / 2);
                    const start_y = (s.height - cs.height) / 2;
                    try set_global_pos(c, .{ .x_offset = start_x, .y_offset = start_y }, ctx);
                },
                .centered_top => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = s.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cs.width / 2);
                    try set_global_pos(c, .{ .x_offset = start_x, .y_offset = 0 }, ctx);
                },
                .centered_bottom => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = s.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cs.width / 2);
                    try set_global_pos(c, .{ .x_offset = start_x, .y_offset = s.height - cs.height }, ctx);
                },
                .centered_top_wrapped => {
                    if (idx != 0) continue;
                    try set_centered_wrapped_rows(dep_buf[0..dep_count], s.width, 0.0, ctx);
                },
                .centered_bottom_wrapped => {
                    if (idx != 0) continue;
                    const total_h = compute_wrapped_height(dep_buf[0..dep_count], s.width);
                    try set_centered_wrapped_rows(dep_buf[0..dep_count], s.width, s.height - total_h, ctx);
                },
                .centered_wrapped => {
                    if (idx != 0) continue;
                    const total_h = compute_wrapped_height(dep_buf[0..dep_count], s.width);
                    try set_centered_wrapped_rows(dep_buf[0..dep_count], s.width, (s.height - total_h) / 2.0, ctx);
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
        .center => { x = pw * 0.5 - s.width * 0.5; y = ph * 0.5 - s.height * 0.5; },
        .center_right => { x = pw - s.width; y = ph * 0.5 - s.height * 0.5; },
        .bottom_left => y = ph - s.height,
        .bottom_center => { x = pw * 0.5 - s.width * 0.5; y = ph - s.height; },
        .bottom_right => { x = pw - s.width; y = ph - s.height; },
        .relative => unreachable,
    }
    return .{ x, y };
}

fn compute_wrapped_height(dep_children: []*ui.Node, parent_width: f32) f32 {
    var total_h: f32 = 0.0;
    var scan_start: usize = 0;
    while (scan_start < dep_children.len) {
        const first = dep_children[scan_start].size orelse { scan_start += 1; continue; };
        var scan_end: usize = scan_start + 1;
        var scan_w: f32 = first.width;
        var scan_h: f32 = first.height;
        while (scan_end < dep_children.len) {
            const next = dep_children[scan_end].size orelse break;
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

fn set_centered_wrapped_rows(dep_children: []*ui.Node, parent_width: f32, start_y: f32, ctx: ?*anyopaque) !void {
    var row_start: usize = 0;
    var current_y: f32 = start_y;
    while (row_start < dep_children.len) {
        const first = dep_children[row_start].size orelse { row_start += 1; continue; };
        var row_end: usize = row_start + 1;
        var row_w: f32 = first.width;
        var row_h: f32 = first.height;
        while (row_end < dep_children.len) {
            const next = dep_children[row_end].size orelse break;
            if (row_w + next.width > parent_width) break;
            row_w += next.width;
            row_h = @max(row_h, next.height);
            row_end += 1;
        }
        var x_row = (parent_width - row_w) / 2.0;
        for (dep_children[row_start..row_end]) |child| {
            const cs = child.size orelse continue;
            try set_global_pos(child, .{ .x_offset = x_row, .y_offset = current_y }, ctx);
            x_row += cs.width;
        }
        current_y += row_h;
        row_start = row_end;
    }
}
