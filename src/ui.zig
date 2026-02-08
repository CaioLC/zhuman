const std = @import("std");
const Allocator = std.mem.Allocator;

const sdl3 = @import("sdl3");

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

pub const Node = struct {
    parent: ?*Node,
    children: std.ArrayList(*Node),
    width: f32,
    height: f32,
    anchor: Anchor,
    global_x: ?f32,
    global_y: ?f32,
    id: *const[4:0]u8,

    // Attributes
    surface: ?sdl3.surface.Surface,

    pub fn init(
        allocator: Allocator,
        id: *const[4:0]u8,
        width: f32,
        height: f32,
        anchor: Anchor,
    ) !Node {
        return .{
            .id = id,
            .parent = null,
            .children = try .initCapacity(allocator, 0),
            .width = width,
            .height = height,
            .anchor = anchor,
            .global_x = null,
            .global_y = null,
            .surface = null,
        };
    }

    pub fn add_child(self: *Node, allocator: std.mem.Allocator, child: *Node) !void {
        child.parent = self;
        try self.children.append(allocator, child);
    }

    /// NOTE: doing this recursively gives a segmentation fault.
    /// should be fixed if we have nested nodes
    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |child| {
            std.log.debug("child free", .{});
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.clearAndFree(allocator);
    }

    pub fn set_global_pos(self: *Node) void {
        var pw: f32 = 0.0;
        var ph: f32 = 0.0;
        var px: f32 = 0.0;
        var py: f32 = 0.0;
        if (self.parent) |p| {
            pw = p.width;
            ph = p.height;
            px = p.global_x orelse 0.0;
            py = p.global_y orelse 0.0;
        }

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
        }

        self.global_x = px + x;
        self.global_y = py + y;

        for (self.children.items) |c| {
            c.set_global_pos();
        }
    }

    pub fn collect(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self.children.items) |child| {
            try child.collect(allocator, list);
        }
    }

    pub fn get_id(self: *Node, id: *const [4:0]u8) ?*Node {
        if (std.mem.eql(u8, self.id, id)) {
            return self;
        }
        for (self.children.items) |child| {
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
    root.* = Node.init(800, 600, .top_left);
    root.global_x = 0;
    root.global_y = 0;

    const child = try allocator.create(Node);
    child.* = Node.init(100, 50, .center);
    try root.add_child(allocator, child);

    const child2 = try allocator.create(Node);
    child2.* = Node.init(100, 50, .bottom_center);
    try root.add_child(allocator, child2);

    root.set_global_pos();

    try std.testing.expect(child.global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child.global_y.? == 275.0); // (600/2 - 50/2)

    try std.testing.expect(child2.global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child2.global_y.? == 550.0); // (600/2 - 50/2)
}
