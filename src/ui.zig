const std = @import("std");
const Allocator = std.mem.Allocator;

const sdl3 = @import("sdl3");

pub const Placement = struct {
    anchor: Anchor,
    alignment: Alignment,
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
};

pub const Alignment = enum {
    self,
    parent,
};

pub const Node = struct {
    id: []const u8,
    parent: ?*Node,
    placement: Placement,
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
        placement: Placement,
        width: f32,
        height: f32,
        surface: ?sdl3.surface.Surface,
    ) !Node {
        return .{
            .id = id,
            .parent = null,
            .placement = placement,
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
        switch (child.placement.alignment) {
            .self => try self._children_indep.append(allocator, child),
            .parent => try self._children_dep.append(allocator, child),
        }
    }

    /// NOTE: doing this recursively gives a segmentation fault.
    /// should be fixed if we have nested nodes
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

    pub fn set_global_pos(self: *Node) void {
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

        var x: f32 = 0;
        var y: f32 = 0;

        switch (self.placement.anchor) {
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
        }

        self._global_x = px + x;
        self._global_y = py + y;

        for (self._children_indep.items) |c| {
            c.set_global_pos();
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
