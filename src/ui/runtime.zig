const std = @import("std");
const ui = @import("root.zig");
const Node = ui.Node;
const clickable = @import("features/clickable.zig");

pub const Runtime = struct {
    root: ?*Node,
    clickables: std.ArrayList(*Node),

    pub fn init() Runtime {
        return .{
            .root = null,
            .clickables = .empty,
        };
    }

    pub fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        self.clickables.clearAndFree(allocator);
        if (self.root) |root| {
            root.deinit(allocator);
            allocator.destroy(root);
            self.root = null;
        }
    }

    pub fn register(self: *Runtime, allocator: std.mem.Allocator, node: *Node) !void {
        std.debug.assert(node.on_click != null);
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
            const pos = node.position orelse continue;
            const gx = pos._global_x orelse continue;
            const gy = pos._global_y orelse continue;

            if (mx >= gx and mx <= gx + pos.width and
                my >= gy and my <= gy + pos.height)
            {
                if (node.on_click) |oc| {
                    oc.invoke(event);
                }
            }
        }
    }
};

test "runtime dispatch click hits registered node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestCtx = struct {
        clicked: bool = false,

        fn on_click(data: ?*anyopaque, _: clickable.ClickEvent) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.clicked = true;
        }
    };

    var ctx = TestCtx{};

    var node = try allocator.create(Node);
    node.* = Node.init("test");
    _ = node.with_position(ui.Position.init(.top_left, null, 100, 50, null));
    node.position.?._global_x = 10;
    node.position.?._global_y = 20;
    node.on_click = clickable.OnClick.init(TestCtx.on_click, @ptrCast(&ctx));

    var rt = Runtime.init();
    defer rt.deinit(allocator);
    try rt.register(allocator, node);

    // Click inside node bounds
    rt.dispatch_click(50, 40, .left);
    try std.testing.expect(ctx.clicked);
}

test "runtime dispatch click misses outside node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestCtx = struct {
        clicked: bool = false,

        fn on_click(data: ?*anyopaque, _: clickable.ClickEvent) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.clicked = true;
        }
    };

    var ctx = TestCtx{};

    var node = try allocator.create(Node);
    node.* = Node.init("test");
    _ = node.with_position(ui.Position.init(.top_left, null, 100, 50, null));
    node.position.?._global_x = 10;
    node.position.?._global_y = 20;
    node.on_click = clickable.OnClick.init(TestCtx.on_click, @ptrCast(&ctx));

    var rt = Runtime.init();
    defer rt.deinit(allocator);
    try rt.register(allocator, node);

    // Click outside node bounds
    rt.dispatch_click(500, 500, .left);
    try std.testing.expect(!ctx.clicked);
}
