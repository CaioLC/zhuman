const std = @import("std");
const Allocator = std.mem.Allocator;

pub const features = @import("./features/root.zig");
pub const runtime = @import("runtime.zig");
pub const event = @import("event.zig");

// Re-export common types for convenience
// Features
pub const Anchor = features.Anchor;
pub const ChildrenAlign = features.ChildrenAlign;
pub const Padding = features.Padding;
pub const Position = features.Position;
pub const OnClick = features.OnClick;
pub const OnRender = features.OnRender;

// Events
pub const Event = event.Event;

pub const Node = struct {
    id: []const u8,
    runtime: ?*runtime.Runtime(),
    parent: ?*Node,
    children: std.ArrayList(*Node),
    data: ?*anyopaque,
    on_deinit: ?*const fn (Allocator, *anyopaque) void,

    // Features
    position: ?features.Position,
    on_click: ?features.OnClick,
    on_render: ?features.OnRender,

    pub fn init(id: []const u8) Node {
        return .{
            .id = id,
            .runtime = null,
            .parent = null,
            .children = .empty,
            .data = null,
            .on_deinit = null,
            .position = null,
            .on_click = null,
            .on_render = null,
        };
    }

    // --- Builder methods ---
    pub fn with_position(self: *Node, position: features.Position) *Node {
        self.position = position;
        return self;
    }

    pub fn with_onclick(self: *Node, on_click: features.OnClick) *Node {
        self.on_click = on_click;
        return self;
    }

    pub fn with_render(self: *Node, on_render: features.OnRender) *Node {
        self.on_render = on_render;
        return self;
    }

    pub fn with_data(self: *Node, data: *anyopaque, on_deinit: ?*const fn (Allocator, *anyopaque) void) *Node {
        self.data = data;
        self.on_deinit = on_deinit;
        return self;
    }

    // --- Tree operations ---

    pub fn add_child(self: *Node, allocator: Allocator, child: *Node) !void {
        child.parent = self;
        child.runtime = self.runtime;
        try self.children.append(allocator, child);
        self.runtime.?.register(allocator, child); // TODO: replace this with an Event based system.
    }

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.clearAndFree(allocator);
        if (self.on_deinit) |deinit_fn| {
            if (self.data) |data| {
                deinit_fn(allocator, data);
            }
        }
    }

    pub fn collect(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self.children.items) |child| {
            try child.collect(allocator, list);
        }
    }

    pub fn get_by_id(self: *Node, id: []const u8) ?*Node {
        if (std.mem.eql(u8, self.id, id)) {
            return self;
        }
        for (self.children.items) |child| {
            if (child.get_by_id(id)) |found| {
                return found;
            }
        }
        return null;
    }

    // --- Feature delegation ---

    pub fn set_global_pos(self: *Node, children_info: ?features.ChildrenPosInfo, ctx: ?*anyopaque) !void {
        try features.set_global_pos(self, children_info, ctx);
    }
};

test "node tree layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try allocator.create(Node);
    root.* = Node.init("root");
    _ = root.with_position(Position.initStatic(.top_left, null, 800, 600, null));
    root.position.?._global_x = 0;
    root.position.?._global_y = 0;

    const child = try allocator.create(Node);
    child.* = Node.init("chd1");
    _ = child.with_position(Position.initStatic(.center, null, 100, 50, null));
    try root.add_child(allocator, child);

    const child2 = try allocator.create(Node);
    child2.* = Node.init("chd2");
    _ = child2.with_position(Position.initStatic(.bottom_center, null, 100, 50, null));
    try root.add_child(allocator, child2);

    try root.set_global_pos(null, null);

    try std.testing.expect(child.position.?._global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child.position.?._global_y.? == 275.0); // (600/2 - 50/2)

    try std.testing.expect(child2.position.?._global_x.? == 350.0); // (800/2 - 100/2)
    try std.testing.expect(child2.position.?._global_y.? == 550.0); // (600 - 50)
}

test "collect returns each node exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try allocator.create(Node);
    root.* = Node.init("root");
    _ = root.with_position(Position.initStatic(.top_left, null, 800, 600, null));

    const indep = try allocator.create(Node);
    indep.* = Node.init("indp");
    _ = indep.with_position(Position.initStatic(.center, null, 100, 50, null));
    try root.add_child(allocator, indep);

    const dep = try allocator.create(Node);
    dep.* = Node.init("dep1");
    _ = dep.with_position(Position.initStatic(.relative, null, 100, 50, null));
    try root.add_child(allocator, dep);

    var list: std.ArrayList(*Node) = .empty;
    defer list.clearAndFree(allocator);
    try root.collect(allocator, &list);

    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqual(root, list.items[0]);
    try std.testing.expectEqual(indep, list.items[1]);
    try std.testing.expectEqual(dep, list.items[2]);
}
