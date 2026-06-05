const std = @import("std");
const Allocator = std.mem.Allocator;

pub const features = @import("./features/root.zig");
pub const cache = @import("./cache.zig");
pub const geometry = @import("./geometry.zig");
pub const interaction = @import("./interaction.zig");

pub const Ui = @import("./ui.zig").Ui;
pub const Rect = geometry.Rect;
pub const Interaction = interaction.Interaction;
pub const InteractionFlag = interaction.Flag;
pub const key = cache.key;
pub const key_i = cache.key_i;
pub const Pool = cache.Pool;
pub const Pools = cache.Pools;

pub const Anchor = features.Anchor;
pub const ChildrenAlign = features.ChildrenAlign;
pub const Padding = features.Padding;
pub const Size = features.Size;
pub const SizeRule = features.SizeRule;
pub const Layout = features.Layout;

/// The tree atom, generic over the host's `Tags` type — a packed-struct flag set
/// describing what each node *is* for rendering (e.g. `.text`, `.border`,
/// `.inactive`). Core stores `Tags` opaquely and never reads it; the host's render
/// walk switches on it. `Tags` must be default-constructible (`.{}`) — give every
/// field a default. Every other field is tag-agnostic.
pub fn Node(comptime Tags: type) type {
    return struct {
        const Self = @This();

        id: []const u8,
        parent: ?*Self,
        children: std.ArrayList(*Self),
        /// Type-erased handle (pool index) into the UI cache for this node's render
        /// state. The host's render walk supplies the concrete state type when
        /// resolving it. `null` for pure layout containers.
        state: ?u32,
        /// Interaction key (opt-in). Non-null only for interactive widgets; `null`
        /// for labels and containers. Carrying it is what makes a node markable and
        /// queryable — its interaction state lives in `Ui`'s keyed store, not here.
        interaction_key: ?u64,
        /// Host-defined render flags (policy). Core only carries them; the host's
        /// render walk reads them to decide what/how to draw. Defaults to all-clear.
        tags: Tags,

        size: ?features.Size,
        layout: ?features.Layout,

        /// Zero-allocation pre-order tree cursor (see `iterate`). Carries only the
        /// subtree root and a cursor: advancement rides the `parent` pointers every
        /// node already holds, so there's no traversal stack and nothing to free.
        /// Rendering is host policy — the host walks this and draws each node by its
        /// `tags`/`state`; the engine never touches pixels.
        pub const Iterator = struct {
            root: *Self,
            current: ?*Self,

            pub fn next(self: *Iterator) ?*Self {
                const node = self.current orelse return null;
                self.current = advance(self.root, node);
                return node;
            }

            /// The next node in pre-order after `node`: its first child, else the
            /// next sibling of the nearest ancestor that has one, else null at root.
            fn advance(root: *Self, node: *Self) ?*Self {
                if (node.children.items.len > 0) return node.children.items[0];
                var n = node;
                while (n != root) {
                    const parent = n.parent.?;
                    if (next_sibling(parent, n)) |sib| return sib;
                    n = parent;
                }
                return null;
            }

            fn next_sibling(parent: *Self, child: *Self) ?*Self {
                const kids = parent.children.items;
                for (kids, 0..) |k, i| {
                    if (k == child) return if (i + 1 < kids.len) kids[i + 1] else null;
                }
                return null;
            }
        };

        pub fn init(id: []const u8) Self {
            return .{
                .id = id,
                .parent = null,
                .children = .empty,
                .state = null,
                .interaction_key = null,
                .tags = .{},
                .size = null,
                .layout = null,
            };
        }

        pub fn create(allocator: Allocator, id: []const u8) !*Self {
            const node = try allocator.create(Self);
            node.* = Self.init(id);
            return node;
        }

        pub fn with_size(self: *Self, size: features.Size) *Self {
            self.size = size;
            return self;
        }

        pub fn with_layout(self: *Self, layout: features.Layout) *Self {
            self.layout = layout;
            return self;
        }

        pub fn add_child(self: *Self, allocator: Allocator, child: *Self) !void {
            child.parent = self;
            try self.children.append(allocator, child);
        }

        pub fn collect(self: *Self, allocator: Allocator, list: *std.ArrayList(*Self)) !void {
            try list.append(allocator, self);
            for (self.children.items) |child| {
                try child.collect(allocator, list);
            }
        }

        /// A zero-allocation pre-order walk of this subtree (self first, then each
        /// child's subtree). Pre-order is painter's order: a parent is yielded
        /// before its children, i.e. drawn *under* them. Don't mutate mid-walk.
        pub fn iterate(self: *Self) Iterator {
            return .{ .root = self, .current = self };
        }

        pub fn get_by_id(self: *Self, id: []const u8) ?*Self {
            if (std.mem.eql(u8, self.id, id)) return self;
            for (self.children.items) |child| {
                if (child.get_by_id(id)) |found| return found;
            }
            return null;
        }

        /// Solve and place the whole subtree (size passes + placement). Pure — sizes
        /// read each node's host-measured `data_*` (set at build); no host callback.
        /// Call at the root.
        pub fn set_global_pos(self: *Self) !void {
            try features.set_global_pos(self);
        }

        /// This node's interaction state this frame (read-through: allocates/keeps
        /// its store slot). **Panics** if the node is non-interactive (no
        /// `interaction_key`): `query` asserts the node opted into interaction, so
        /// querying a label/container is a precondition violation, not a silent
        /// no-op. `u` is duck-typed (the concrete `Ui`).
        pub fn query(self: *Self, u: anytype) Interaction {
            const k = self.interaction_key orelse
                std.debug.panic("query() on non-interactive node '{s}' (no interaction_key)", .{self.id});
            return u.interactionOf(k);
        }
    };
}

/// A node's resolved screen rect from its layout + size, or null if it hasn't
/// been laid out yet. Pure geometry read straight off the node. `node` is
/// `anytype` (a `*Node(Tags)`); only tag-agnostic fields are touched.
fn node_rect(node: anytype) ?geometry.Rect {
    const s = node.size orelse return null;
    const l = node.layout orelse return null;
    return .{
        .x = l._global_x orelse return null,
        .y = l._global_y orelse return null,
        .w = s.width,
        .h = s.height,
    };
}

/// Walk the tree and set `flag` on every keyed node whose rect contains (x, y).
/// Called at the event stage against the *previous* frame's (already laid-out)
/// tree; writes the flag into the keyed interaction store so this frame's build
/// can read it back. `u` and `node` are duck-typed (the concrete `Ui` /
/// `*Node(Tags)`) to keep this module free of the binding. Mechanism only:
/// userland supplies the point — mouse, touch, gamepad cursor — and decides what
/// the flag means.
pub fn mark_at(u: anytype, node: anytype, comptime flag: InteractionFlag, x: f32, y: f32) void {
    if (node.interaction_key) |k| {
        if (node_rect(node)) |r| {
            if (r.contains(x, y)) u.setFlag(k, flag, true);
        }
    }
    for (node.children.items) |child| mark_at(u, child, flag, x, y);
}

test {
    _ = cache;
    _ = @import("./ui.zig");
}

/// A concrete `Node` for tests — flags are irrelevant to layout/traversal, so an
/// empty tag set suffices.
const TestNode = Node(packed struct {});

test "node tree layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try TestNode.create(allocator, "root");
    _ = root.with_size(Size.initFixed(800, 600, null));
    _ = root.with_layout(Layout.init(.top_left, null));
    root.layout.?._global_x = 0;
    root.layout.?._global_y = 0;

    const child = try TestNode.create(allocator, "chd1");
    _ = child.with_size(Size.initFixed(100, 50, null));
    _ = child.with_layout(Layout.init(.center, null));
    try root.add_child(allocator, child);

    const child2 = try TestNode.create(allocator, "chd2");
    _ = child2.with_size(Size.initFixed(100, 50, null));
    _ = child2.with_layout(Layout.init(.bottom_center, null));
    try root.add_child(allocator, child2);

    // Sizing happens in the solve pass — pure, no host bundle. These are all
    // `fixed`, so no measured `data_*` is needed.
    try root.set_global_pos();

    try std.testing.expect(child.layout.?._global_x.? == 350.0);
    try std.testing.expect(child.layout.?._global_y.? == 275.0);

    try std.testing.expect(child2.layout.?._global_x.? == 350.0);
    try std.testing.expect(child2.layout.?._global_y.? == 550.0);
}

test "collect returns each node exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try TestNode.create(allocator, "root");
    _ = root.with_size(Size.initFixed(800, 600, null));
    _ = root.with_layout(Layout.init(.top_left, null));

    const indep = try TestNode.create(allocator, "indp");
    _ = indep.with_size(Size.initFixed(100, 50, null));
    _ = indep.with_layout(Layout.init(.center, null));
    try root.add_child(allocator, indep);

    const dep = try TestNode.create(allocator, "dep1");
    _ = dep.with_size(Size.initFixed(100, 50, null));
    _ = dep.with_layout(Layout.init(.relative, null));
    try root.add_child(allocator, dep);

    var list: std.ArrayList(*TestNode) = .empty;
    defer list.clearAndFree(allocator);
    try root.collect(allocator, &list);

    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqual(root, list.items[0]);
    try std.testing.expectEqual(indep, list.items[1]);
    try std.testing.expectEqual(dep, list.items[2]);
}

test "iterate walks the subtree in pre-order, climbing across levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // root ─┬─ a ─┬─ a1
    //       │     └─ a2
    //       └─ b
    // pre-order: root, a, a1, a2, b — exercises descend, next-sibling, and the
    // climb from a2 (a leaf, last child) back up to root's next child b.
    const root = try TestNode.create(allocator, "root");
    const a = try TestNode.create(allocator, "a");
    const a1 = try TestNode.create(allocator, "a1");
    const a2 = try TestNode.create(allocator, "a2");
    const b = try TestNode.create(allocator, "b");
    try root.add_child(allocator, a);
    try a.add_child(allocator, a1);
    try a.add_child(allocator, a2);
    try root.add_child(allocator, b);

    const expected = [_]*TestNode{ root, a, a1, a2, b };
    var i: usize = 0;
    var it = root.iterate();
    while (it.next()) |node| : (i += 1) {
        try std.testing.expect(i < expected.len);
        try std.testing.expectEqual(expected[i], node);
    }
    try std.testing.expectEqual(expected.len, i); // and no extras

    // A leaf subtree yields exactly itself.
    var leaf_it = a1.iterate();
    try std.testing.expectEqual(a1, leaf_it.next().?);
    try std.testing.expectEqual(@as(?*TestNode, null), leaf_it.next());
}

test "node carries host tags opaquely: default-clear, settable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tags = packed struct { text: bool = false, border: bool = false };
    const N = Node(Tags);

    const n = try N.create(a, "n");
    try std.testing.expect(!n.tags.text and !n.tags.border); // init = all-clear
    n.tags = .{ .text = true };
    try std.testing.expect(n.tags.text and !n.tags.border); // composable, independent
}

test "pct_of_parent resolves against a definite (fixed) parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(800, 600, null));
    _ = root.with_layout(Layout.init(.top_left, .vertical));

    const child = try TestNode.create(a, "child");
    _ = child.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .{ .fixed = 100 }, null));
    _ = child.with_layout(Layout.init(.top_left, null));
    try root.add_child(a, child);

    try root.set_global_pos();
    try std.testing.expectEqual(@as(f32, 400), child.size.?.width); // 0.5 * 800
    try std.testing.expectEqual(@as(f32, 100), child.size.?.height);
}

test "fit_children sums on the main axis, maxes on the cross" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Vertical parent → main axis = y: height = 50 + 30 = 80, width = max(100, 200) = 200.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children, null));
    _ = root.with_layout(Layout.init(.top_left, .vertical));

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(100, 50, null));
    _ = k1.with_layout(Layout.init(.relative, null));
    try root.add_child(a, k1);

    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(200, 30, null));
    _ = k2.with_layout(Layout.init(.relative, null));
    try root.add_child(a, k2);

    try root.set_global_pos();
    try std.testing.expectEqual(@as(f32, 200), root.size.?.width);
    try std.testing.expectEqual(@as(f32, 80), root.size.?.height);
}

test "pct_of_parent under an indefinite (fit) parent falls back to content (0, no deref)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Parent width is fit_children (indefinite). The child wants 50% of it but has
    // no measured content (data_width = 0) — the fallback must resolve to 0, safely.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .{ .fixed = 100 }, null));
    _ = root.with_layout(Layout.init(.top_left, .vertical));

    const child = try TestNode.create(a, "child");
    _ = child.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .{ .fixed = 50 }, null));
    _ = child.with_layout(Layout.init(.relative, null));
    try root.add_child(a, child);

    try root.set_global_pos();
    try std.testing.expectEqual(@as(f32, 0), child.size.?.width); // no definite base ⇒ content ⇒ 0
    try std.testing.expectEqual(@as(f32, 0), root.size.?.width); // fit cross-axis = max(0) = 0
}
