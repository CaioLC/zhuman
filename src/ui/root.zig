const std = @import("std");
const Allocator = std.mem.Allocator;

pub const features = @import("./features/root.zig");
pub const cache = @import("./cache.zig");
pub const geometry = @import("./geometry.zig");

pub const Ctx = @import("./ctx.zig").Ctx;
pub const Rect = geometry.Rect;
pub const key = cache.key;
pub const key_i = cache.key_i;
// Note: no `Color` here — RGBA is host policy (the engine carries `RenderData`
// opaquely and never reads a color). The host aliases its own (see `src/theme.zig`).
pub const Pool = cache.Pool;
pub const Pools = cache.Pools;

pub const Anchor = features.Anchor;
pub const ChildrenAlign = features.ChildrenAlign;
pub const Padding = features.Padding;
pub const Size = features.Size;
pub const SizeRule = features.SizeRule;
pub const Layout = features.Layout;

/// The tree atom. Stores a host render descriptor opaquely.
///
/// One host-policy type param, carried but never interpreted by core:
/// - `RenderData` — the host's render descriptor: which aspects to draw this frame
///   and the inline payload each carries (e.g. `text`/`fill`/`outline`, each an
///   optional `Color`). The render walk switches on it; the engine never reads it.
///   New host visuals (opacity, a sprite color…) go here, so the engine never
///   recompiles to gain one. Must be default-constructible (`.{}`) — seeded at `init`.
///
/// Frame-local vs persistent: `render_data` is rebuilt every frame (like the node).
/// Anything that must outlive the frame lives in a `key`-addressed pool, reached via
/// `node.state(u, T)` — the node holds no handle, only its `key`, which re-derives the
/// slot every frame. So a node can carry several cached states (text *and* an svg
/// raster) with no per-node bookkeeping.
pub fn Node(comptime RenderData: type) type {
    return struct {
        const Self = @This();

        id: []const u8,
        parent: ?*Self,
        children: std.ArrayList(*Self),
        /// Stable identity for this node — the hash of its parent seed + local id, and the
        /// key into every persistent cache pool it uses (render state, interaction store).
        /// It bridges the frame boundary: the tree is rebuilt each frame, but the key
        /// re-derives identically and re-finds the node's slots.
        key: u64,
        /// Host-defined render descriptor (policy). Core only carries it; the host's
        /// render walk reads it to decide what/how to draw — which aspects, in which
        /// color. Frame-local (rebuilt each frame). Defaults to all-clear (`.{}`).
        render_data: RenderData,

        /// Every node is a box: both default at `create` (size hugs its children,
        /// layout anchors top-left flowing horizontally) and are overridden via
        /// `with_size`/`with_layout` or a feature mixin. Never null — the layout
        /// passes assume a box, so there are no "transparent" nodes.
        size: features.Size,
        layout: features.Layout,

        /// Zero-allocation pre-order tree cursor. See `iterate` fn.
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
                .key = key(0, id),
                .render_data = .{},
                .size = features.Size.init(.fit_children, .fit_children),
                .layout = features.Layout.init(.relative, .horizontal),
            };
        }

        pub fn create(allocator: Allocator, id: []const u8) !*Self {
            const node = try allocator.create(Self);
            node.* = Self.init(id);
            return node;
        }

        /// create and bind to a parent
        pub fn pcreate(allocator: Allocator, id: []const u8, parent: *Self) !*Self {
            const node = try allocator.create(Self);
            node.* = Self.init(id);
            try parent.add_child(allocator, node);
            return node;
        }

        pub fn with_size(self: *Self, size: features.Size) *Self {
            self.size = size;
            return self;
        }

        pub fn with_layout(self: *Self, anchor: Anchor, children_align: ?ChildrenAlign) *Self {
            const l = features.Layout.init(anchor, children_align);
            self.layout = l;
            return self;
        }

        pub fn with_render_data(self: *Self, rd: RenderData) *Self {
            self.render_data = rd;
            return self;
        }

        pub fn add_child(self: *Self, allocator: Allocator, child: *Self) !void {
            child.parent = self;
            child.rekey(self.key); // re-derive child + its whole subtree off our key
            try self.children.append(allocator, child);
        }

        pub fn add_children(self: *Self, allocator: Allocator, children: []const *Self) !void {
            for (children) |child| try self.add_child(allocator, child);
        }

        /// Re-derive this node's key from `seed` and recurse into the subtree, so
        /// identity is independent of wiring order — attaching an already-assembled
        /// subtree re-keys all of it, not just the top node. Trees are small and
        /// rebuilt per frame, so the walk is free.
        fn rekey(self: *Self, seed: u64) void {
            self.key = key(seed, self.id);
            for (self.children.items) |child| child.rekey(self.key);
        }

        /// Flatten a builder's return value into the frame's render `list`: a single
        /// `*Self`, an `?*Self` (skipped when null), or a tuple mixing them (a screen plus
        /// its optional overlay). Each leaf is an **independent root tree** whose position
        /// in `list` is its draw order — distinct from `iterate`, which walks one tree's
        /// own subtree. Pure structure over `*Self`, so it's engine mechanism, not host
        /// policy (the host only decides what shapes its builders return).
        pub fn collect(list: *std.ArrayList(*Self), allocator: Allocator, item: anytype) !void {
            switch (@typeInfo(@TypeOf(item))) {
                .optional => if (item) |v| try collect(list, allocator, v),
                .pointer => try list.append(allocator, item), // a single `*Self` root
                .@"struct" => |s| inline for (s.fields) |f| try collect(list, allocator, @field(item, f.name)),
                else => @compileError("collect: unsupported UI tree shape " ++ @typeName(@TypeOf(item))),
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
        /// its store slot). **Panics** if the node has no `key`. `u` is duck-typed
        /// (the concrete `Ctx`); the return type is the host's interaction-flag
        /// struct (`Ctx.Interaction`).
        pub fn query(self: *Self, u: anytype) @TypeOf(u.*).Interaction {
            return u.interactionOf(self.key);
        }

        /// This node's rect from a *prior* frame's layout (read off its interaction
        /// slot), or null if it has no live slot yet. Use to place something relative
        /// to where this node was last drawn — the current frame's rect isn't resolved
        /// until layout runs after build. `u` is the duck-typed concrete `Ctx`.
        pub fn rect(self: *Self, u: anytype) ?Rect {
            return u.rectOf(self.key);
        }

        /// This node's cached render-state of type `T`: acquire-or-create the slot for
        /// `node.key` in `T`'s pool and return a pointer to it. This is how a feature
        /// reaches persistent state — the engine owns the caching (keying, lifecycle,
        /// eviction); the caller just asks for its state and reads/writes it. The slot
        /// survives the frame-arena reset (the node doesn't); acquiring keeps it alive
        /// this frame. `T` must be registered in the host's `StateNs`. **Don't stash the
        /// pointer across another `acquire` on `T`'s pool** — the pool may grow; call
        /// again. `u` is the duck-typed concrete `Ctx`.
        pub fn state(self: *Self, u: anytype, comptime T: type) *T {
            return u.pool(T).get(u.cache(self.key, T));
        }
    };
}

/// A node's resolved screen rect from its layout + size, or null if it hasn't
/// been laid out yet. Pure geometry read straight off the node. `node` is
/// `anytype` (a `*Node(RenderData)`); only render-agnostic fields are touched.
fn node_rect(node: anytype) ?geometry.Rect {
    return .{
        .x = node.layout._global_x orelse return null,
        .y = node.layout._global_y orelse return null,
        .w = node.size.width,
        .h = node.size.height,
    };
}

/// Capture each interactive node's resolved rect into its interaction slot, so next
/// frame's event stage can hit-test from the slot pool alone (`Ctx.mark`) with no
/// tree walk. Only stamps nodes that already have a live slot — i.e. were `query`'d
/// this frame; `stampRect` no-ops otherwise. Call once after `set_global_pos`, before
/// the arena (and this tree) is reset. `u`/`node` are duck-typed (the concrete `Ctx`
/// / `*Node(RenderData)`) to keep this module free of the binding.
pub fn stamp_rects(u: anytype, node: anytype) void {
    if (node_rect(node)) |r| u.stampRect(node.key, r);
    for (node.children.items) |child| stamp_rects(u, child);
}

test {
    _ = cache;
    _ = @import("./ctx.zig");
}

/// A concrete `Node` for tests — the render descriptor is irrelevant to
/// layout/traversal, so an empty struct suffices.
const TestNode = Node(struct {});

test "node tree layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try TestNode.create(allocator, "root");
    _ = root.with_size(Size.initFixed(800, 600));
    _ = root.with_layout(.top_left, null);
    root.layout._global_x = 0;
    root.layout._global_y = 0;

    const child = try TestNode.create(allocator, "chd1");
    _ = child.with_size(Size.initFixed(100, 50));
    _ = child.with_layout(.center, null);
    try root.add_child(allocator, child);

    const child2 = try TestNode.create(allocator, "chd2");
    _ = child2.with_size(Size.initFixed(100, 50));
    _ = child2.with_layout(.bottom_center, null);
    try root.add_child(allocator, child2);

    try root.set_global_pos();

    try std.testing.expect(child.layout._global_x.? == 350.0);
    try std.testing.expect(child.layout._global_y.? == 275.0);

    try std.testing.expect(child2.layout._global_x.? == 350.0);
    try std.testing.expect(child2.layout._global_y.? == 550.0);
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

test "node carries host render data opaquely: default-clear, settable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Aspects are optional payloads (a color), not bare bits — present ⟹ draw it.
    // The payload type is host policy; a trivial local stand-in exercises the point.
    const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };
    const RenderData = struct { text: ?Rgba = null, border: ?Rgba = null };
    const N = Node(RenderData);

    const n = try N.create(a, "n");
    try std.testing.expect(n.render_data.text == null and n.render_data.border == null); // init = all-clear
    n.render_data.text = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    try std.testing.expect(n.render_data.text != null and n.render_data.border == null); // independent aspects
}

test "pct_of_parent resolves against a definite (fixed) parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(800, 600));
    _ = root.with_layout(.top_left, .vertical);

    const child = try TestNode.create(a, "child");
    _ = child.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .{ .fixed = 100 }));
    _ = child.with_layout(.top_left, null);
    try root.add_child(a, child);

    try root.set_global_pos();
    try std.testing.expectEqual(@as(f32, 400), child.size.width); // 0.5 * 800
    try std.testing.expectEqual(@as(f32, 100), child.size.height);
}

test "fit_children sums on the main axis, maxes on the cross" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Vertical parent → main axis = y: height = 50 + 30 = 80, width = max(100, 200) = 200.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .vertical);

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(100, 50));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);

    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(200, 30));
    _ = k2.with_layout(.relative, null);
    try root.add_child(a, k2);

    try root.set_global_pos();
    try std.testing.expectEqual(@as(f32, 200), root.size.width);
    try std.testing.expectEqual(@as(f32, 80), root.size.height);
}

test "layout gap: fit parent reserves it, children flow spaced by it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Vertical parent, gap 10 between its two children (50 + 30 tall):
    // height = 50 + 10 + 30 = 90; width = max(100, 200) = 200 (no cross-axis gap).
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .vertical);
    root.layout.gap = 10;
    root.layout._global_x = 0;
    root.layout._global_y = 0;

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(100, 50));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);

    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(200, 30));
    _ = k2.with_layout(.relative, null);
    try root.add_child(a, k2);

    try root.set_global_pos();
    try std.testing.expectEqual(@as(f32, 200), root.size.width);
    try std.testing.expectEqual(@as(f32, 90), root.size.height); // 50 + gap + 30
    try std.testing.expectEqual(@as(f32, 0), k1.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 60), k2.layout._global_y.?); // 50 + gap
}

test "pct_of_parent under an indefinite (fit) parent falls back to content (0, no deref)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Parent width is fit_children (indefinite). The child wants 50% of it but has
    // no measured content (data_width = 0) — the fallback must resolve to 0, safely.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .{ .fixed = 100 }));
    _ = root.with_layout(.top_left, .vertical);

    const child = try TestNode.create(a, "child");
    _ = child.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .{ .fixed = 50 }));
    _ = child.with_layout(.relative, null);
    try root.add_child(a, child);

    try root.set_global_pos();
    try std.testing.expectEqual(@as(f32, 0), child.size.width); // no definite base ⇒ content ⇒ 0
    try std.testing.expectEqual(@as(f32, 0), root.size.width); // fit cross-axis = max(0) = 0
}
