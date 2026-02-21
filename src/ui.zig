const std = @import("std");
const Allocator = std.mem.Allocator;
const sdl3 = @import("sdl3");

pub const ChildrenPosInfo = struct {
    x_offset: f32,
    y_offset: f32,
};

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
};

pub const Node = struct {
    id: []const u8,
    parent: ?*Node,
    anchor: Anchor,
    children_align: ChildrenAlign,
    width: f32,
    height: f32,
    inner_width: f32,
    inner_height: f32,
    _global_x: ?f32,
    _global_y: ?f32,
    _children_indep: std.ArrayList(*Node),
    _children_dep: std.ArrayList(*Node),

    // Attributes
    surface: ?sdl3.surface.Surface,
    padding: Padding,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        anchor: Anchor,
        children_align: ?ChildrenAlign,
        inner_width: f32,
        inner_height: f32,
        surface: ?sdl3.surface.Surface,
        padding: ?Padding,
    ) !Node {
        const ch_align = children_align orelse ChildrenAlign.horizontal;
        const pad = padding orelse Padding.init(0);
        return .{
            .id = id,
            .parent = null,
            .anchor = anchor,
            .children_align = ch_align,
            .inner_width = inner_width,
            .inner_height = inner_height,
            .width = inner_width + pad.left + pad.right,
            .height = inner_height + pad.up + pad.down,
            .surface = surface,
            .padding = pad,
            ._global_x = null,
            ._global_y = null,
            ._children_indep = try .initCapacity(allocator, 1),
            ._children_dep = try .initCapacity(allocator, 1),
        };
    }

    fn recalculate_size(self: *Node) void {
        for (self._children_indep.items) |c| c.recalculate_size();
        for (self._children_dep.items) |c| c.recalculate_size();
        self.width = self.inner_width + self.padding.left + self.padding.right;
        self.height = self.inner_height + self.padding.up + self.padding.down;
    }

    pub fn add_child(self: *Node, allocator: std.mem.Allocator, child: *Node) !void {
        child.parent = self;
        if (child.anchor == .relative) {
            try self._children_dep.append(allocator, child);
        } else {
            try self._children_indep.append(allocator, child);
        }
    }

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self._children_indep.items) |child| {
            std.log.debug("child free", .{});
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self._children_indep.clearAndFree(allocator);
        for (self._children_dep.items) |child| {
            std.log.debug("child free", .{});
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self._children_dep.clearAndFree(allocator);
    }

    pub fn set_global_pos(self: *Node, children_info: ?ChildrenPosInfo) !void {
        if (self.parent == null) self.recalculate_size();
        // set position for self
        var pw: f32 = 0.0;
        var ph: f32 = 0.0;
        var px: f32 = 0.0;
        var py: f32 = 0.0;
        if (self.parent) |p| {
            pw = p.width;
            ph = p.height;
            px = p._global_x orelse 0.0;
            py = p._global_y orelse 0.0;
        }

        var x: f32, var y: f32 = .{ undefined, undefined };
        if (self.anchor != .relative) {
            x, y = self.set_indep_global_pos(pw, ph);
        } else {
            const my_offsets = children_info orelse return error.NoInfoForChildren;
            x = my_offsets.x_offset;
            y = my_offsets.y_offset;
        }

        self._global_x = px + x;
        self._global_y = py + y;

        // set position for children
        // independent children is simple
        for (self._children_indep.items) |c| {
            try c.set_global_pos(null);
        }

        // dependent children have position defined at parent level and just accept it
        if (self._children_dep.items.len > 0) {
            var x_offset: f32 = 0.0;
            var y_offset: f32 = 0.0;
            var row_max_height: f32 = 0.0;
            var col_max_width: f32 = 0.0;

            for (self._children_dep.items, 0..) |c, idx| {
                switch (self.children_align) {
                    .horizontal => {
                        try c.set_global_pos(.{ .x_offset = x_offset, .y_offset = y_offset });
                        x_offset += c.width;
                    },
                    .horizontal_wrapped => {
                        if (x_offset + c.width > self.width) {
                            x_offset = 0.0;
                            y_offset += row_max_height;
                            row_max_height = 0.0;
                        }
                        try c.set_global_pos(.{ .x_offset = x_offset, .y_offset = y_offset });
                        x_offset += c.width;
                        row_max_height = @max(row_max_height, c.height);
                    },
                    .horizontal_reverse => {
                        x_offset -= c.width;
                        try c.set_global_pos(.{ .x_offset = self.width + x_offset, .y_offset = y_offset });
                    },
                    .horizontal_reverse_wrapped => {
                        x_offset -= c.width;
                        if (-x_offset > self.width) {
                            x_offset = 0 - c.width;
                            y_offset += row_max_height;
                            row_max_height = 0.0;
                        }
                        try c.set_global_pos(.{ .x_offset = self.width + x_offset, .y_offset = y_offset });
                        row_max_height = @max(row_max_height, c.height);
                    },
                    .vertical => {
                        try c.set_global_pos(.{ .x_offset = x_offset, .y_offset = y_offset });
                        y_offset += c.height;
                    },
                    .vertical_wrapped => {
                        if (y_offset + c.height > self.height) {
                            y_offset = 0.0;
                            x_offset += col_max_width;
                            col_max_width = 0.0;
                        }
                        try c.set_global_pos(.{ .x_offset = x_offset, .y_offset = y_offset });
                        y_offset += c.height;
                        col_max_width = @max(col_max_width, c.width);
                    },
                    .vertical_reverse => {
                        y_offset -= c.height;
                        try c.set_global_pos(.{ .x_offset = x_offset, .y_offset = self.height + y_offset });
                    },
                    .vertical_reverse_wrapped => {
                        y_offset -= c.height;
                        if (-y_offset > self.height) {
                            y_offset = 0 - c.height;
                            x_offset += col_max_width;
                            col_max_width = 0.0;
                        }
                        try c.set_global_pos(.{ .x_offset = x_offset, .y_offset = self.height + y_offset });
                        col_max_width = @max(col_max_width, c.width);
                    },
                    .centered => {
                        const f_idx: f32 = @floatFromInt(idx);
                        const n_elements: f32 = @floatFromInt(self._children_dep.items.len);
                        const w_central_point = self.width / (1.0 + n_elements);
                        const element_central_point: f32 = w_central_point * (f_idx + 1.0);
                        const start_x = element_central_point - (c.width / 2);
                        const start_y = (self.height - c.height) / 2;
                        try c.set_global_pos(.{ .x_offset = start_x, .y_offset = start_y });
                    },
                    .centered_wrapped => {
                        // All children are handled on idx == 0; later iterations are skipped.
                        if (idx != 0) continue;
                        // Pre-pass: compute total content height for vertical centering.
                        var total_h: f32 = 0.0;
                        var scan_start: usize = 0;
                        while (scan_start < self._children_dep.items.len) {
                            var scan_end: usize = scan_start + 1;
                            var scan_w: f32 = self._children_dep.items[scan_start].width;
                            var scan_h: f32 = self._children_dep.items[scan_start].height;
                            while (scan_end < self._children_dep.items.len) {
                                const next = self._children_dep.items[scan_end];
                                if (scan_w + next.width > self.width) break;
                                scan_w += next.width;
                                scan_h = @max(scan_h, next.height);
                                scan_end += 1;
                            }
                            total_h += scan_h;
                            scan_start = scan_end;
                        }
                        // Placement pass: center each row horizontally, block vertically.
                        var row_start: usize = 0;
                        var current_y: f32 = (self.height - total_h) / 2.0;
                        while (row_start < self._children_dep.items.len) {
                            var row_end: usize = row_start + 1;
                            var row_w: f32 = self._children_dep.items[row_start].width;
                            var row_h: f32 = self._children_dep.items[row_start].height;
                            while (row_end < self._children_dep.items.len) {
                                const next = self._children_dep.items[row_end];
                                if (row_w + next.width > self.width) break;
                                row_w += next.width;
                                row_h = @max(row_h, next.height);
                                row_end += 1;
                            }
                            var x_row = (self.width - row_w) / 2.0;
                            for (self._children_dep.items[row_start..row_end]) |child| {
                                try child.set_global_pos(.{ .x_offset = x_row, .y_offset = current_y });
                                x_row += child.width;
                            }
                            current_y += row_h;
                            row_start = row_end;
                        }
                    },
                }
            }
        }
    }

    fn set_indep_global_pos(self: Node, pw: f32, ph: f32) struct { f32, f32 } {
        var x: f32 = 0;
        var y: f32 = 0;

        switch (self.anchor) {
            .top_left => {},
            .top_center => x = pw * 0.5 - self.width * 0.5,
            .top_right => x = pw - self.width,
            .center_left => y = ph * 0.5 - self.height * 0.5,
            .center => {
                x = pw * 0.5 - self.width * 0.5;
                y = ph * 0.5 - self.height * 0.5;
            },
            .center_right => {
                x = pw - self.width;
                y = ph * 0.5 - self.height * 0.5;
            },
            .bottom_left => y = ph - self.height,
            .bottom_center => {
                x = pw * 0.5 - self.width * 0.5;
                y = ph - self.height;
            },
            .bottom_right => {
                x = pw - self.width;
                y = ph - self.height;
            },
            .relative => unreachable,
        }
        return .{ x, y };
    }

    // fn set_dep_nodes_global_pos(self: Node, pw: *f32, ph: *f32, x: *f32, y: *f32) void {}
    pub fn collect(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self._children_indep.items) |child| {
            try child.collect(allocator, list);
        }
        for (self._children_dep.items) |child| {
            try child.collect(allocator, list);
        }
    }

    pub fn collect_independent(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self._children_indep.items) |child| {
            try child.collect_independent(allocator, list);
        }
    }

    pub fn collect_dependent(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self._children_dep.items) |child| {
            try child.collect_dependent(allocator, list);
        }
    }

    pub fn get_id(self: *Node, id: []const u8) ?*Node {
        if (std.mem.eql(u8, self.id, id)) {
            return self;
        }
        for (self._children_indep.items) |child| {
            if (child.get_id(id)) |found| {
                return found;
            }
        }
        for (self._children_dep.items) |child| {
            if (child.get_id(id)) |found| {
                return found;
            }
        }
        return null;
    }
};

test "node tree layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try allocator.create(Node);
    root.* = try Node.init(allocator, "root", .top_left, null, 800, 600, null, null);
    root._global_x = 0;
    root._global_y = 0;

    const child = try allocator.create(Node);
    child.* = try Node.init(allocator, "chd1", .center, null, 100, 50, null, null);
    try root.add_child(allocator, child);

    const child2 = try allocator.create(Node);
    child2.* = try Node.init(allocator, "chd2", .bottom_center, null, 100, 50, null, null);
    try root.add_child(allocator, child2);

    try root.set_global_pos(null);

    try std.testing.expect(child._global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child._global_y.? == 275.0); // (600/2 - 50/2)

    try std.testing.expect(child2._global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child2._global_y.? == 550.0); // (600 - 50)
}

test "collect returns each node exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try allocator.create(Node);
    root.* = try Node.init(allocator, "root", .top_left, null, 800, 600, null, null);

    const indep = try allocator.create(Node);
    indep.* = try Node.init(allocator, "indp", .center, null, 100, 50, null, null);
    try root.add_child(allocator, indep);

    const dep = try allocator.create(Node);
    dep.* = try Node.init(allocator, "dep1", .relative, null, 100, 50, null, null);
    try root.add_child(allocator, dep);

    var list: std.ArrayList(*Node) = .empty;
    defer list.clearAndFree(allocator);
    try root.collect(allocator, &list);

    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqual(root, list.items[0]);
    try std.testing.expectEqual(indep, list.items[1]);
    try std.testing.expectEqual(dep, list.items[2]);
}

test "collect_independent returns only independent subtree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try allocator.create(Node);
    root.* = try Node.init(allocator, "root", .top_left, null, 800, 600, null, null);

    const child_indep = try allocator.create(Node);
    child_indep.* = try Node.init(allocator, "indp", .center, null, 100, 50, null, null);
    try root.add_child(allocator, child_indep);

    const grandchild_indep = try allocator.create(Node);
    grandchild_indep.* = try Node.init(allocator, "grnd", .top_right, null, 50, 25, null, null);
    try child_indep.add_child(allocator, grandchild_indep);

    const child_dep = try allocator.create(Node);
    child_dep.* = try Node.init(allocator, "dep1", .relative, null, 100, 50, null, null);
    try root.add_child(allocator, child_dep);

    var list: std.ArrayList(*Node) = .empty;
    defer list.clearAndFree(allocator);
    try root.collect_independent(allocator, &list);

    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqual(root, list.items[0]);
    try std.testing.expectEqual(child_indep, list.items[1]);
    try std.testing.expectEqual(grandchild_indep, list.items[2]);
}

test "collect_dependent returns only dependent subtree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try allocator.create(Node);
    root.* = try Node.init(allocator, "root", .top_left, null, 800, 600, null, null);

    const child_indep = try allocator.create(Node);
    child_indep.* = try Node.init(allocator, "indp", .center, null, 100, 50, null, null);
    try root.add_child(allocator, child_indep);

    const child_dep = try allocator.create(Node);
    child_dep.* = try Node.init(allocator, "dep1", .relative, null, 100, 50, null, null);
    try root.add_child(allocator, child_dep);

    const grandchild_dep = try allocator.create(Node);
    grandchild_dep.* = try Node.init(allocator, "dep2", .relative, null, 50, 25, null, null);
    try child_dep.add_child(allocator, grandchild_dep);

    var list: std.ArrayList(*Node) = .empty;
    defer list.clearAndFree(allocator);
    try root.collect_dependent(allocator, &list);

    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqual(root, list.items[0]);
    try std.testing.expectEqual(child_dep, list.items[1]);
    try std.testing.expectEqual(grandchild_dep, list.items[2]);
}
