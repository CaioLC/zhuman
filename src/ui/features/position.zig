const ui = @import("../root.zig");

pub const Padding = struct {
    up: f32,
    right: f32,
    down: f32,
    left: f32,

    pub fn init(p: f32) Padding {
        return .{ .up = p, .right = p, .down = p, .left = p };
    }

    pub fn initSymmetric(w: f32, h: f32) Padding {
        return .{ .up = h, .right = w, .down = h, .left = w };
    }

    pub fn initEach(u: f32, r: f32, d: f32, l: f32) Padding {
        return .{ .up = u, .right = r, .down = d, .left = l };
    }
};

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

pub const Position = struct {
    // a function that takes the owning node and ui context, returns data_width and data_height
    calc_pos: *const fn (*ui.Node, ?*anyopaque) struct { f32, f32 },
    // where to place, in relation to parent
    anchor: Anchor,
    // how to place children position nodes
    children_align: ChildrenAlign,
    // these are self explanatory
    padding: Padding,
    width: f32,
    height: f32,
    data_width: f32,
    data_height: f32,
    _global_x: ?f32,
    _global_y: ?f32,

    pub fn init(
        calc_pos: *const fn (*ui.Node, ?*anyopaque) struct { f32, f32 },
        anchor: Anchor,
        children_align: ?ChildrenAlign,
        padding: ?Padding,
    ) Position {
        const pad = padding orelse Padding.init(0);
        const ch = children_align orelse .horizontal;
        return .{
            .calc_pos = calc_pos,
            .anchor = anchor,
            .children_align = ch,
            .padding = pad,
            .data_width = 0,
            .data_height = 0,
            .width = pad.left + pad.right,
            .height = pad.up + pad.down,
            ._global_x = null,
            ._global_y = null,
        };
    }

    fn static_calc_pos(node: *ui.Node, _: ?*anyopaque) struct { f32, f32 } {
        const pos = node.position orelse return .{ 0, 0 };
        return .{ pos.data_width, pos.data_height };
    }

    pub fn initStatic(
        anchor: Anchor,
        children_align: ?ChildrenAlign,
        width: f32,
        height: f32,
        padding: ?Padding,
    ) Position {
        const pad = padding orelse Padding.init(0);
        const ch = children_align orelse .horizontal;
        return .{
            .calc_pos = &static_calc_pos,
            .anchor = anchor,
            .children_align = ch,
            .padding = pad,
            .data_width = width,
            .data_height = height,
            .width = width + pad.left + pad.right,
            .height = height + pad.up + pad.down,
            ._global_x = null,
            ._global_y = null,
        };
    }
};

// --- Layout functions (operate on Node, reading its Position feature) ---

pub fn recalculate_size(node: *ui.Node, ctx: ?*anyopaque) void {
    for (node.children.items) |c| recalculate_size(c, ctx);
    if (node.position) |*pos| {
        pos.data_width, pos.data_height = pos.calc_pos(node, ctx);
        pos.width = pos.data_width + pos.padding.left + pos.padding.right;
        pos.height = pos.data_height + pos.padding.up + pos.padding.down;
    }
}

pub fn set_global_pos(node: *ui.Node, children_info: ?ChildrenPosInfo, ctx: ?*anyopaque) !void {
    const pos: *Position = &(node.position orelse return);

    if (node.parent == null) recalculate_size(node, ctx);

    // Get parent position info
    var pw: f32 = 0.0;
    var ph: f32 = 0.0;
    var px: f32 = 0.0;
    var py: f32 = 0.0;
    if (node.parent) |p| {
        if (p.position) |pp| {
            pw = pp.width;
            ph = pp.height;
            px = pp._global_x orelse 0.0;
            py = pp._global_y orelse 0.0;
        }
    }

    var x: f32, var y: f32 = .{ undefined, undefined };
    if (pos.anchor != .relative) {
        x, y = set_indep_global_pos(pos.*, pw, ph);
    } else {
        const my_offsets = children_info orelse return error.NoInfoForChildren;
        x = my_offsets.x_offset;
        y = my_offsets.y_offset;
    }

    pos._global_x = px + x;
    pos._global_y = py + y;

    // Classify children into independent and dependent
    var indep_buf: [256]*ui.Node = undefined;
    var indep_count: usize = 0;
    var dep_buf: [256]*ui.Node = undefined;
    var dep_count: usize = 0;

    for (node.children.items) |c| {
        if (c.position) |cp| {
            if (cp.anchor == .relative) {
                dep_buf[dep_count] = c;
                dep_count += 1;
            } else {
                indep_buf[indep_count] = c;
                indep_count += 1;
            }
        }
    }

    const indep_children = indep_buf[0..indep_count];
    const dep_children = dep_buf[0..dep_count];

    // Independent children position themselves
    for (indep_children) |c| {
        try set_global_pos(c, null, ctx);
    }

    // Dependent children are positioned by parent's children_align
    if (dep_count > 0) {
        var x_offset: f32 = 0.0;
        var y_offset: f32 = 0.0;
        var row_max_height: f32 = 0.0;
        var col_max_width: f32 = 0.0;

        for (dep_children, 0..) |c, idx| {
            const cpos = c.position.?;
            switch (pos.children_align) {
                .horizontal => {
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    x_offset += cpos.width;
                },
                .horizontal_wrapped => {
                    if (x_offset + cpos.width > pos.width) {
                        x_offset = 0.0;
                        y_offset += row_max_height;
                        row_max_height = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    x_offset += cpos.width;
                    row_max_height = @max(row_max_height, cpos.height);
                },
                .horizontal_reverse => {
                    x_offset -= cpos.width;
                    try set_global_pos(c, .{ .x_offset = pos.width + x_offset, .y_offset = y_offset }, ctx);
                },
                .horizontal_reverse_wrapped => {
                    x_offset -= cpos.width;
                    if (-x_offset > pos.width) {
                        x_offset = 0 - cpos.width;
                        y_offset += row_max_height;
                        row_max_height = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = pos.width + x_offset, .y_offset = y_offset }, ctx);
                    row_max_height = @max(row_max_height, cpos.height);
                },
                .vertical => {
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    y_offset += cpos.height;
                },
                .vertical_wrapped => {
                    if (y_offset + cpos.height > pos.height) {
                        y_offset = 0.0;
                        x_offset += col_max_width;
                        col_max_width = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = y_offset }, ctx);
                    y_offset += cpos.height;
                    col_max_width = @max(col_max_width, cpos.width);
                },
                .vertical_reverse => {
                    y_offset -= cpos.height;
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = pos.height + y_offset }, ctx);
                },
                .vertical_reverse_wrapped => {
                    y_offset -= cpos.height;
                    if (-y_offset > pos.height) {
                        y_offset = 0 - cpos.height;
                        x_offset += col_max_width;
                        col_max_width = 0.0;
                    }
                    try set_global_pos(c, .{ .x_offset = x_offset, .y_offset = pos.height + y_offset }, ctx);
                    col_max_width = @max(col_max_width, cpos.width);
                },
                .centered => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = pos.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cpos.width / 2);
                    const start_y = (pos.height - cpos.height) / 2;
                    try set_global_pos(c, .{ .x_offset = start_x, .y_offset = start_y }, ctx);
                },
                .centered_top => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = pos.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cpos.width / 2);
                    try set_global_pos(c, .{ .x_offset = start_x, .y_offset = 0 }, ctx);
                },
                .centered_bottom => {
                    const f_idx: f32 = @floatFromInt(idx);
                    const n_elements: f32 = @floatFromInt(dep_count);
                    const w_central_point = pos.width / (1.0 + n_elements);
                    const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                    const start_x = element_central_point - (cpos.width / 2);
                    try set_global_pos(c, .{ .x_offset = start_x, .y_offset = pos.height - cpos.height }, ctx);
                },
                .centered_top_wrapped => {
                    if (idx != 0) continue;
                    try set_centered_wrapped_rows(dep_children, pos.width, 0.0, ctx);
                },
                .centered_bottom_wrapped => {
                    if (idx != 0) continue;
                    const total_h = compute_wrapped_height(dep_children, pos.width);
                    try set_centered_wrapped_rows(dep_children, pos.width, pos.height - total_h, ctx);
                },
                .centered_wrapped => {
                    if (idx != 0) continue;
                    const total_h = compute_wrapped_height(dep_children, pos.width);
                    try set_centered_wrapped_rows(dep_children, pos.width, (pos.height - total_h) / 2.0, ctx);
                },
            }
        }
    }
}

fn set_indep_global_pos(pos: Position, pw: f32, ph: f32) struct { f32, f32 } {
    var x: f32 = 0;
    var y: f32 = 0;

    switch (pos.anchor) {
        .top_left => {},
        .top_center => x = pw * 0.5 - pos.width * 0.5,
        .top_right => x = pw - pos.width,
        .center_left => y = ph * 0.5 - pos.height * 0.5,
        .center => {
            x = pw * 0.5 - pos.width * 0.5;
            y = ph * 0.5 - pos.height * 0.5;
        },
        .center_right => {
            x = pw - pos.width;
            y = ph * 0.5 - pos.height * 0.5;
        },
        .bottom_left => y = ph - pos.height,
        .bottom_center => {
            x = pw * 0.5 - pos.width * 0.5;
            y = ph - pos.height;
        },
        .bottom_right => {
            x = pw - pos.width;
            y = ph - pos.height;
        },
        .relative => unreachable,
    }
    return .{ x, y };
}

// --- Shared helpers for centered_*_wrapped layouts ---

fn compute_wrapped_height(dep_children: []*ui.Node, parent_width: f32) f32 {
    var total_h: f32 = 0.0;
    var scan_start: usize = 0;
    while (scan_start < dep_children.len) {
        var scan_end: usize = scan_start + 1;
        var scan_w: f32 = dep_children[scan_start].position.?.width;
        var scan_h: f32 = dep_children[scan_start].position.?.height;
        while (scan_end < dep_children.len) {
            const next_w = dep_children[scan_end].position.?.width;
            const next_h = dep_children[scan_end].position.?.height;
            if (scan_w + next_w > parent_width) break;
            scan_w += next_w;
            scan_h = @max(scan_h, next_h);
            scan_end += 1;
        }
        total_h += scan_h;
        scan_start = scan_end;
    }
    return total_h;
}

fn set_centered_wrapped_rows(dep_children: []*ui.Node, parent_width: f32, start_y: f32, ctx: ?*anyopaque) error{NoInfoForChildren}!void {
    var row_start: usize = 0;
    var current_y: f32 = start_y;
    while (row_start < dep_children.len) {
        var row_end: usize = row_start + 1;
        var row_w: f32 = dep_children[row_start].position.?.width;
        var row_h: f32 = dep_children[row_start].position.?.height;
        while (row_end < dep_children.len) {
            const next_w = dep_children[row_end].position.?.width;
            const next_h = dep_children[row_end].position.?.height;
            if (row_w + next_w > parent_width) break;
            row_w += next_w;
            row_h = @max(row_h, next_h);
            row_end += 1;
        }
        var x_row = (parent_width - row_w) / 2.0;
        for (dep_children[row_start..row_end]) |child| {
            try set_global_pos(child, .{ .x_offset = x_row, .y_offset = current_y }, ctx);
            x_row += child.position.?.width;
        }
        current_y += row_h;
        row_start = row_end;
    }
}
