const std = @import("std");
const Allocator = std.mem.Allocator;

pub const features = @import("./features/root.zig");
pub const cache = @import("./cache.zig");

pub const Ui = @import("./ui.zig").Ui;
pub const key = cache.key;
pub const key_i = cache.key_i;
pub const Pool = cache.Pool;
pub const Pools = cache.Pools;

pub const Anchor = features.Anchor;
pub const ChildrenAlign = features.ChildrenAlign;
pub const Padding = features.Padding;
pub const Size = features.Size;
pub const Layout = features.Layout;
pub const OnClick = features.OnClick;
pub const OnRender = features.OnRender;

pub const Node = struct {
    id: []const u8,
    parent: ?*Node,
    children: std.ArrayList(*Node),
    /// Type-erased handle (pool index) into the UI cache. The render/size
    /// callbacks supply the concrete state type when resolving it. `null` for
    /// pure layout containers. See docs/ui-building-language-plan.md.
    state: ?u32,

    size: ?features.Size,
    layout: ?features.Layout,
    on_click: ?features.OnClick,
    on_render: ?features.OnRender,

    pub fn init(id: []const u8) Node {
        return .{
            .id = id,
            .parent = null,
            .children = .empty,
            .state = null,
            .size = null,
            .layout = null,
            .on_click = null,
            .on_render = null,
        };
    }

    pub fn create(allocator: Allocator, id: []const u8) !*Node {
        const node = try allocator.create(Node);
        node.* = Node.init(id);
        return node;
    }

    pub fn with_size(self: *Node, size: features.Size) *Node {
        self.size = size;
        return self;
    }

    pub fn with_layout(self: *Node, layout: features.Layout) *Node {
        self.layout = layout;
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

    pub fn add_child(self: *Node, allocator: Allocator, child: *Node) !void {
        child.parent = self;
        try self.children.append(allocator, child);
    }

    pub fn collect(self: *Node, allocator: Allocator, list: *std.ArrayList(*Node)) !void {
        try list.append(allocator, self);
        for (self.children.items) |child| {
            try child.collect(allocator, list);
        }
    }

    pub fn get_by_id(self: *Node, id: []const u8) ?*Node {
        if (std.mem.eql(u8, self.id, id)) return self;
        for (self.children.items) |child| {
            if (child.get_by_id(id)) |found| return found;
        }
        return null;
    }

    pub fn set_global_pos(self: *Node, children_info: ?features.ChildrenPosInfo, ctx: ?*anyopaque) !void {
        try features.set_global_pos(self, children_info, ctx);
    }
};

pub fn dispatch_click(node: *Node, mx: f32, my: f32, button: features.MouseButton) void {
    if (node.on_click) |oc| {
        if (node.size) |s| {
            if (node.layout) |l| {
                const gx = l._global_x orelse 0;
                const gy = l._global_y orelse 0;
                if (mx >= gx and mx <= gx + s.width and my >= gy and my <= gy + s.height) {
                    oc.invoke(.{ .x = mx, .y = my, .button = button });
                }
            }
        }
    }
    for (node.children.items) |child| {
        dispatch_click(child, mx, my, button);
    }
}

pub fn render(node: *Node, ctx: *anyopaque) void {
    if (node.on_render) |or_| or_.invoke(ctx, node);
    for (node.children.items) |child| {
        render(child, ctx);
    }
}

test {
    _ = cache;
    _ = @import("./ui.zig");
}

test "node tree layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try Node.create(allocator, "root");
    _ = root.with_size(Size.initFixed(800, 600, null));
    _ = root.with_layout(Layout.init(.top_left, null));
    root.layout.?._global_x = 0;
    root.layout.?._global_y = 0;

    const child = try Node.create(allocator, "chd1");
    _ = child.with_size(Size.initFixed(100, 50, null));
    _ = child.with_layout(Layout.init(.center, null));
    try root.add_child(allocator, child);

    const child2 = try Node.create(allocator, "chd2");
    _ = child2.with_size(Size.initFixed(100, 50, null));
    _ = child2.with_layout(Layout.init(.bottom_center, null));
    try root.add_child(allocator, child2);

    try root.set_global_pos(null, null);

    try std.testing.expect(child.layout.?._global_x.? == 350.0);
    try std.testing.expect(child.layout.?._global_y.? == 275.0);

    try std.testing.expect(child2.layout.?._global_x.? == 350.0);
    try std.testing.expect(child2.layout.?._global_y.? == 550.0);
}

test "collect returns each node exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try Node.create(allocator, "root");
    _ = root.with_size(Size.initFixed(800, 600, null));
    _ = root.with_layout(Layout.init(.top_left, null));

    const indep = try Node.create(allocator, "indp");
    _ = indep.with_size(Size.initFixed(100, 50, null));
    _ = indep.with_layout(Layout.init(.center, null));
    try root.add_child(allocator, indep);

    const dep = try Node.create(allocator, "dep1");
    _ = dep.with_size(Size.initFixed(100, 50, null));
    _ = dep.with_layout(Layout.init(.relative, null));
    try root.add_child(allocator, dep);

    var list: std.ArrayList(*Node) = .empty;
    defer list.clearAndFree(allocator);
    try root.collect(allocator, &list);

    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqual(root, list.items[0]);
    try std.testing.expectEqual(indep, list.items[1]);
    try std.testing.expectEqual(dep, list.items[2]);
}
