const std = @import("std");
const Node = @import("root.zig").Node;
const clickable = @import("clickable.zig");

pub const Runtime = struct {
    clickables: std.ArrayList(*Node),

    pub fn init() Runtime {
        return .{
            .clickables = .empty,
        };
    }

    pub fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        self.clickables.clearAndFree(allocator);
    }

    pub fn register(self: *Runtime, allocator: std.mem.Allocator, node: *Node) !void {
        std.debug.assert(node.clickable != null);
        try self.clickables.append(allocator, node);
    }

    pub fn unregister(self: *Runtime, node: *Node) void {
        for (self.clickables.items, 0..) |n, i| {
            if (n == node) {
                _ = self.clickables.swapRemove(i);
                return;
            }
        }
    }

    pub fn dispatch_click(self: *Runtime, mx: f32, my: f32, button: clickable.MouseButton) void {
        const event = clickable.ClickEvent{
            .x = mx,
            .y = my,
            .button = button,
        };

        for (self.clickables.items) |node| {
            const gx = node._global_x orelse continue;
            const gy = node._global_y orelse continue;

            if (mx >= gx and mx <= gx + node.width and
                my >= gy and my <= gy + node.height)
            {
                node.clickable.?.on_click(event);
            }
        }
    }
};

test "runtime dispatch click hits registered node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestHandler = struct {
        clicked: bool = false,

        pub fn on_click(self: *@This(), _: clickable.ClickEvent) void {
            self.clicked = true;
        }
    };

    var handler = TestHandler{};

    var node = try allocator.create(Node);
    node.* = try Node.init(allocator, "test", .top_left, null, 100, 50, null, null);
    node._global_x = 10;
    node._global_y = 20;
    node.clickable = clickable.Clickable.init(&handler);

    var rt = Runtime.init();
    defer rt.deinit(allocator);
    try rt.register(allocator, node);

    // Click inside node bounds
    rt.dispatch_click(50, 40, .left);
    try std.testing.expect(handler.clicked);
}

test "runtime dispatch click misses outside node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestHandler = struct {
        clicked: bool = false,

        pub fn on_click(self: *@This(), _: clickable.ClickEvent) void {
            self.clicked = true;
        }
    };

    var handler = TestHandler{};

    var node = try allocator.create(Node);
    node.* = try Node.init(allocator, "test", .top_left, null, 100, 50, null, null);
    node._global_x = 10;
    node._global_y = 20;
    node.clickable = clickable.Clickable.init(&handler);

    var rt = Runtime.init();
    defer rt.deinit(allocator);
    try rt.register(allocator, node);

    // Click outside node bounds
    rt.dispatch_click(500, 500, .left);
    try std.testing.expect(!handler.clicked);
}
