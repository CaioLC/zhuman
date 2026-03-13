const std = @import("std");
const ui = @import("root.zig");
const Node = ui.Node;
const position = @import("features/position.zig");
const clickable = @import("features/clickable.zig");

pub fn Runtime(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        root: ?*Node,
        ctx: ?*Ctx,
        clickables: std.ArrayList(*Node),

        pub fn init() Self {
            return .{
                .root = null,
                .ctx = null,
                .clickables = .empty,
            };
        }

        pub fn bind(self: *Self, ctx: *Ctx) void {
            self.ctx = ctx;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.clickables.clearAndFree(allocator);
            if (self.root) |root| {
                root.deinit(allocator);
                allocator.destroy(root);
                self.root = null;
            }
        }

        pub fn register(self: *Self, allocator: std.mem.Allocator, node: *Node) !void {
            std.debug.assert(node.on_click != null);
            try self.clickables.append(allocator, node);
        }

        pub fn unregister(self: *Self, node: *Node) void {
            for (self.clickables.items, 0..) |n, i| {
                if (n == node) {
                    _ = self.clickables.swapRemove(i);
                    return;
                }
            }
        }

        pub fn update(self: *Self) !void {
            if (self.root) |root| {
                const ctx: ?*anyopaque = if (self.ctx) |c| @ptrCast(c) else null;
                try position.set_global_pos(root, null, ctx);
            }
        }

        pub fn render(self: *Self) void {
            const root = self.root orelse return;
            const ctx: ?*anyopaque = if (self.ctx) |c| @ptrCast(c) else null;
            var buf: [@sizeOf(*Node) * 256]u8 = undefined;
            var bfa = std.heap.FixedBufferAllocator.init(&buf);
            const allocator = bfa.allocator();
            var node_stack: std.ArrayList(*Node) = .empty;
            defer node_stack.clearRetainingCapacity();
            root.collect(allocator, &node_stack) catch return;

            for (node_stack.items) |node| {
                if (node.on_render) |on_render| {
                    on_render.invoke(node, ctx);
                }
            }
        }

        pub fn dispatch_click(self: *Self, mx: f32, my: f32, button: clickable.MouseButton) void {
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
}

test "runtime dispatch click hits registered node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestCtx = struct {
        clicked: bool = false,

        fn on_click(self: *@This(), _: clickable.ClickEvent) void {
            self.clicked = true;
        }
    };

    var ctx = TestCtx{};

    var node = try allocator.create(Node);
    node.* = Node.init("test");
    _ = node.with_position(ui.Position.initStatic(.top_left, null, 100, 50, null));
    node.position.?._global_x = 10;
    node.position.?._global_y = 20;
    node.on_click = clickable.OnClick.typed(TestCtx, &TestCtx.on_click, &ctx);

    var rt = Runtime(TestCtx).init();
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

        fn on_click(self: *@This(), _: clickable.ClickEvent) void {
            self.clicked = true;
        }
    };

    var ctx = TestCtx{};

    var node = try allocator.create(Node);
    node.* = Node.init("test");
    _ = node.with_position(ui.Position.initStatic(.top_left, null, 100, 50, null));
    node.position.?._global_x = 10;
    node.position.?._global_y = 20;
    node.on_click = clickable.OnClick.typed(TestCtx, &TestCtx.on_click, &ctx);

    var rt = Runtime(TestCtx).init();
    defer rt.deinit(allocator);
    try rt.register(allocator, node);

    // Click outside node bounds
    rt.dispatch_click(500, 500, .left);
    try std.testing.expect(!ctx.clicked);
}
