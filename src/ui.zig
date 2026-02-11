const std = @import("std");
const Allocator = std.mem.Allocator;
const sdl3 = @import("sdl3");

pub const ChildrenPosInfo = struct {
    x_offset: f32,
    y_offset: f32,
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
    centered_expand,
    centered_expand_wrapped,
};

pub const Node = struct {
    id: []const u8,
    parent: ?*Node,
    anchor: Anchor,
    children_align: ChildrenAlign,
    width: f32,
    height: f32,
    _global_x: ?f32,
    _global_y: ?f32,
    _children_indep: std.ArrayList(*Node),
    _children_dep: std.ArrayList(*Node),

    // Attributes
    surface: ?sdl3.surface.Surface,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        anchor: Anchor,
        children_align: ?ChildrenAlign,
        width: f32,
        height: f32,
        surface: ?sdl3.surface.Surface,
    ) !Node {
        const ch_align = children_align orelse ChildrenAlign.horizontal;
        return .{
            .id = id,
            .parent = null,
            .anchor = anchor,
            .children_align = ch_align,
            .width = width,
            .height = height,
            .surface = surface,
            ._global_x = null,
            ._global_y = null,
            ._children_indep = try .initCapacity(allocator, 1),
            ._children_dep = try .initCapacity(allocator, 1),
        };
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
            for (self._children_dep.items) |c| {
                switch (self.children_align) {
                    .horizontal => {
                        try c.set_global_pos(.{ .x_offset = x_offset, .y_offset = y_offset });
                        y_offset = 0.0;
                        x_offset += c.width;
                    },
                    .horizontal_wrapped => {},
                    .horizontal_reverse => {},
                    .horizontal_reverse_wrapped => {},
                    .vertical => {},
                    .vertical_wrapped => {},
                    .vertical_reverse => {},
                    .vertical_reverse_wrapped => {},
                    .centered => {},
                    .centered_wrapped => {},
                    .centered_expand => {},
                    .centered_expand_wrapped => {},
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
        try self.collect_independent(allocator, list);
        try self.collect_dependent(allocator, list);
    }

    pub fn collect_dependent(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self._children_dep.items) |child| {
            try child.collect_dependent(allocator, list);
        }
    }

    pub fn collect_independent(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self._children_indep.items) |child| {
            try child.collect_independent(allocator, list);
        }
    }

    pub fn get_id(self: *Node, id: *const [4:0]u8) ?*Node {
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
    root.* = try Node.init(allocator, "root", 800, 600, .top_left);
    root._global_x = 0;
    root._global_y = 0;

    const child = try allocator.create(Node);
    child.* = try Node.init(allocator, "chd1", 100, 50, .center);
    try root.add_child(allocator, child);

    const child2 = try allocator.create(Node);
    child2.* = try Node.init(allocator, "chd2", 100, 50, .bottom_center);
    try root.add_child(allocator, child2);

    root.set_global_pos();

    try std.testing.expect(child._global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child._global_y.? == 275.0); // (600/2 - 50/2)

    try std.testing.expect(child2._global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child2._global_y.? == 550.0); // (600/2 - 50/2)
}
