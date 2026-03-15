const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("root.zig");
const Node = ui.Node;
const position = @import("features/position.zig");
const clickable = @import("features/clickable.zig");

pub fn Runtime(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        root: *Node,
        allocator: Allocator,
        ctx: *Ctx,
        clickables: std.ArrayList(*Node),

        pub fn init(allocator: Allocator, ctx: *Ctx, pos: ui.Position) !Self {
            const root = try allocator.create(Node);
            root.* = Node.init("root");
            _ = root.with_position(pos);
            return .{
                .root = root,
                .allocator = allocator,
                .ctx = ctx,
                .clickables = .empty,
            };
        }

        pub fn setEventListener(self: *Self) void {
            self.root.event_listener = .{
                .ctx = @ptrCast(self),
                .handler = &handleEvent,
            };
        }

        fn handleEvent(raw_self: *anyopaque, ev: ui.Event) void {
            const self: *Self = @ptrCast(@alignCast(raw_self));
            switch (ev) {
                .node_added => |node| {
                    if (node.on_click != null) {
                        self.clickables.append(self.allocator, node) catch return;
                    }
                },
            }
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.clickables.clearAndFree(allocator);
            self.root.deinit(allocator);
            allocator.destroy(self.root);
        }

        pub fn register(self: *Self, allocator: Allocator, node: *Node) !void {
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
            const ctx: *anyopaque = @ptrCast(self.ctx);
            try position.set_global_pos(self.root, null, ctx);
        }

        pub fn render(self: *Self) void {
            const ctx: *anyopaque = @ptrCast(self.ctx);
            var buf: [@sizeOf(*Node) * 256]u8 = undefined;
            var bfa = std.heap.FixedBufferAllocator.init(&buf);
            const allocator = bfa.allocator();
            var node_stack: std.ArrayList(*Node) = .empty;
            defer node_stack.clearRetainingCapacity();
            self.root.collect(allocator, &node_stack) catch return;

            for (node_stack.items) |node| {
                if (node.on_render) |on_render| {
                    on_render.invoke(node, ctx);
                }
            }
        }

        pub fn dispatch_click(self: *Self, mx: f32, my: f32, button: clickable.MouseButton) void {
            const ev = clickable.ClickEvent{
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
                        oc.invoke(ev);
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

    var rt = try Runtime(TestCtx).init(allocator, &ctx, ui.Position.initStatic(.top_left, null, 800, 600, null));
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

    var rt = try Runtime(TestCtx).init(allocator, &ctx, ui.Position.initStatic(.top_left, null, 800, 600, null));
    defer rt.deinit(allocator);
    try rt.register(allocator, node);

    // Click outside node bounds
    rt.dispatch_click(500, 500, .left);
    try std.testing.expect(!ctx.clicked);
}
