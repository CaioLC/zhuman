//! `Node` — the engine's tree atom, generic over the host's `RenderData`, plus the
//! `stamp_rects` post-layout walk that captures each queried node's rect into its
//! interaction slot. Split out of `root.zig`, which re-exports both (`ui.Node`,
//! `ui.stamp_rects`). Imports only leaf engine modules — no host binding.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const features = @import("./features/root.zig");
const geometry = @import("./geometry.zig");
const key = @import("./cache.zig").key;
const key_i = @import("./cache.zig").key_i;

const Rect = geometry.Rect;
const Anchor = features.Anchor;
const Flow = features.Flow;
const Size = features.Size;

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
        /// A repeated child's loop index, folded into `key` through `key_i` so identity never
        /// depends on an id formatted per iteration; it survives `rekey`. Null for a named child.
        index: ?usize = null,
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
                .layout = features.Layout.init(.relative, null),
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

        /// `pcreate` for the `i`-th repeated child: the index folds into the key (`key_i`), so a
        /// loop needs no per-iteration id string and the node keeps its index through `rekey`.
        pub fn pcreate_i(allocator: Allocator, id: []const u8, i: usize, parent: *Self) !*Self {
            const node = try allocator.create(Self);
            node.* = Self.init(id);
            node.index = i;
            try parent.add_child(allocator, node);
            return node;
        }

        pub fn with_size(self: *Self, size: features.Size) *Self {
            self.size = size;
            return self;
        }

        pub fn with_layout(self: *Self, anchor: Anchor, flow: ?Flow) *Self {
            const l = features.Layout.init(anchor, flow);
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
            // Two siblings with one key would share every pooled slot (text, interaction,
            // state) and silently alias. In safe modes that is a visible failure with the path.
            if (builtin.mode == .debug or builtin.mode == .safe) {
                if (self.duplicateSibling(child)) |twin| {
                    var buf: [512]u8 = undefined;
                    std.debug.panic(
                        "ui: duplicate child id \"{s}\" under {s}: an earlier sibling \"{s}\" has the same key, so pooled state would alias",
                        .{ child.id, self.pathInto(&buf), twin.id },
                    );
                }
            }
            try self.children.append(allocator, child);
        }

        /// The earlier sibling whose key `child` would duplicate, or null. Keys are structural
        /// — the parent's key folded with the id, and the index for an indexed child — so a
        /// match is the same path, and the same pooled slots.
        pub fn duplicateSibling(self: *const Self, child: *const Self) ?*Self {
            for (self.children.items) |sib| if (sib.key == child.key) return sib;
            return null;
        }

        /// This node's structural path for diagnostics, `root/panel/row[3]`, written into
        /// `buf` (cut short when it does not fit; the ancestry walk stops at 64 levels).
        pub fn pathInto(self: *const Self, buf: []u8) []const u8 {
            var chain: [64]*const Self = undefined;
            var depth: usize = 0;
            var cursor: ?*const Self = self;
            while (cursor) |c| : (cursor = c.parent) {
                if (depth == chain.len) break;
                chain[depth] = c;
                depth += 1;
            }
            var written: usize = 0;
            var i = depth;
            while (i > 0) {
                i -= 1;
                const c = chain[i];
                const sep: []const u8 = if (written > 0) "/" else "";
                const seg = if (c.index) |idx|
                    std.mem.print(buf[written..], "{s}{s}[{d}]", .{ sep, c.id, idx }) catch break
                else
                    std.mem.print(buf[written..], "{s}{s}", .{ sep, c.id }) catch break;
                written += seg.len;
            }
            return buf[0..written];
        }

        pub fn add_children(self: *Self, allocator: Allocator, children: []const *Self) !void {
            for (children) |child| try self.add_child(allocator, child);
        }

        /// Re-derive this node's key from `seed` and recurse into the subtree, so
        /// identity is independent of wiring order — attaching an already-assembled
        /// subtree re-keys all of it, not just the top node. Trees are small and
        /// rebuilt per frame, so the walk is free.
        fn rekey(self: *Self, seed: u64) void {
            self.key = if (self.index) |i| key_i(seed, self.id, i) else key(seed, self.id);
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
                .@"struct" => |s| inline for (s.field_names) |name| try collect(list, allocator, @field(item, name)),
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

        /// Solve and place the whole subtree (size passes + placement). Sizing reads each
        /// node's host-measured `data_*` (set at build) — no host callback; `alloc` is
        /// scratch space the placement pass uses to materialize in-flow child lists. Call
        /// at the root.
        pub fn set_global_pos(self: *Self, alloc: Allocator) !void {
            try features.set_global_pos(self, alloc);
        }

        /// Diagnostic solve returning exact timings for the layout passes (bottom-up,
        /// top-down, placement), read from the host's monotonic `clock`.
        pub fn set_global_pos_profiled(self: *Self, alloc: Allocator, clock: @import("profile.zig").Clock) !@import("profile.zig").Sample {
            return features.set_global_pos_profiled(self, alloc, clock);
        }

        /// `set_global_pos` with a host measurer: each `Size.measure_h` node's height and
        /// baseline are re-measured at its resolved width, between the width and height
        /// passes. `measurer` is a struct value with
        /// `fn height_for_width(self, node: *Self, width: f32) ?features.Measured`.
        pub fn set_global_pos_measured(self: *Self, alloc: Allocator, measurer: anytype) !void {
            try features.set_global_pos_measured(self, alloc, measurer);
        }

        /// The profiled `set_global_pos_measured`; the measure walk reports as `Sample.measure`.
        pub fn set_global_pos_measured_profiled(self: *Self, alloc: Allocator, clock: @import("profile.zig").Clock, measurer: anytype) !@import("profile.zig").Sample {
            return features.set_global_pos_measured_profiled(self, alloc, clock, measurer);
        }

        /// This node's interaction state this frame (read-through: allocates/keeps
        /// its store slot). **Panics** if the node has no `key`. `u` is duck-typed
        /// (the concrete `Ctx`); the return type is the host's interaction-flag
        /// struct (`Ctx.Interaction`).
        pub fn query(self: *Self, u: anytype) @TypeOf(u.*).Interaction {
            return u.interactionOf(self.key);
        }

        /// This node's full geometry from a prior frame's layout/stamp, including the
        /// inherited global clip, or null before it has a stamped interaction slot.
        pub fn priorGeometry(self: *Self, u: anytype) ?geometry.Geometry {
            return u.priorGeometryOf(self.key);
        }

        /// Compatibility rect projection; use `priorGeometry` for conversions/clips.
        pub fn rect(self: *Self, u: anytype) ?Rect {
            return (self.priorGeometry(u) orelse return null).rect;
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

        /// Keep an existing `T` state slot for a conditionally hidden direct child alive
        /// this frame. Derives the same structural key that `add_child` would assign,
        /// but creates neither the child nor a state slot. Returning false means that
        /// child has never acquired this state (or was already pruned). The caller must
        /// be built and call this every hidden frame; when it disappears or stops, normal
        /// pruning resumes.
        pub fn retainChildState(self: *Self, u: anytype, child_id: []const u8, comptime T: type) bool {
            return u.retainState(key(self.key, child_id), T);
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

/// Capture each interactive node's geometry into its interaction slot, so next frame's
/// event stage can hit-test from the slot pool alone (`Ctx.mark`) with no tree walk.
/// Only stamps nodes that already have a live slot — i.e. were `query`'d this frame;
/// `stampRect` no-ops otherwise. Call once after `set_global_pos`, before the arena
/// (and this tree) is reset. `u`/`node` are duck-typed (the concrete `Ctx` /
/// `*Node(RenderData)`) to keep this module free of the binding.
///
/// The walk is pre-order, and the host calls it over the roots in list order — which
/// is exactly the order the render walk paints. So the sequence of stamps *is* back-to
/// front z-order, and `Ctx` records it as one: this pass is where the paint-order list
/// comes from. Two things ride down the recursion to make that list usable:
///
///   - the **clip** region, folded the same way the render walk folds it (a `.clip`
///     node crops its subtree to its own box; `.visible` passes the inherited one
///     through). Stamped beside the full rect, never *into* it — cropping the stored
///     rect would tell a scroll container its content fits inside the viewport.
///   - the nearest **stamped ancestor's key**, so a hit can bubble up the containment
///     chain past nodes that were never queried.
pub fn stamp_rects(u: anytype, node: anytype) void {
    stamp_walk(u, node, null, null);
}

fn stamp_walk(u: anytype, node: anytype, clip: ?geometry.Rect, parent_key: ?u64) void {
    const box = node_rect(node);
    var next_parent = parent_key;
    if (box) |r| {
        if (u.stampRect(node.key, r, clip, parent_key)) next_parent = node.key;
    }
    const child_clip: ?geometry.Rect = if (node.layout.overflow == .clip) blk: {
        const b = box orelse break :blk clip;
        break :blk if (clip) |c| c.intersect(b) else b;
    } else clip;
    for (node.children.items) |child| stamp_walk(u, child, child_clip, next_parent);
}

/// A concrete `Node` for tests — the render descriptor is irrelevant to
/// layout/traversal, so an empty struct suffices.
const TestNode = Node(struct {});

test "profiled solve times each pass from the host clock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try TestNode.create(allocator, "root");
    _ = root.with_size(Size.initFixed(800, 600));
    _ = root.with_layout(.top_left, null);
    const kid = try TestNode.pcreate(allocator, "kid", root);
    _ = kid.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .fit_children)).with_layout(.relative, null);

    // Each reading advances 10ns, so every pass measures exactly one tick. The solve has five
    // passes: both bottom-up passes are `intrinsic`, both top-down passes `relative`.
    const Ticker = struct {
        var t: u64 = 0;
        fn now(_: *const anyopaque) u64 {
            t += 10;
            return t;
        }
    };
    const clock: @import("profile.zig").Clock = .{ .ctx = &Ticker.t, .nowFn = Ticker.now };
    const s = try root.set_global_pos_profiled(allocator, clock);
    try std.testing.expectEqual(@as(u64, 20), s.intrinsic);
    try std.testing.expectEqual(@as(u64, 20), s.relative);
    try std.testing.expectEqual(@as(u64, 10), s.placement);
    try std.testing.expectEqual(@as(u64, 0), s.stamping); // the host's, never the engine's
    try std.testing.expectEqual(@as(u64, 0), s.drawing);
    // The profiled solve is the same solve.
    try std.testing.expectEqual(@as(f32, 400), kid.size.width);
    try std.testing.expectEqual(@as(f32, 0), kid.layout._global_y.?);
}

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

    try root.set_global_pos(allocator);

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
    _ = root.with_layout(.top_left, .{ .dir = .column });

    const child = try TestNode.create(a, "child");
    _ = child.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .{ .fixed = 100 }));
    _ = child.with_layout(.top_left, null);
    try root.add_child(a, child);

    try root.set_global_pos(a);
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
    _ = root.with_layout(.top_left, .{ .dir = .column });

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(100, 50));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);

    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(200, 30));
    _ = k2.with_layout(.relative, null);
    try root.add_child(a, k2);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 200), root.size.width);
    try std.testing.expectEqual(@as(f32, 80), root.size.height);
}

test "horizontal cross-align: baseline lines up references; fit = maxAscent + maxDescent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Horizontal parent (cross axis = y), default cross = .baseline. Two children of
    // different height + baseline: k1 100×50 baseline 10 (ascent 40), k2 80×30 baseline 6
    // (ascent 24). Shared line = max ascent = 40 → cy1 = 0, cy2 = 16 (both baselines at y=40).
    // fit height = maxAscent(40) + maxDescent(10) = 50; width = 100 + 80 = 180.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row });

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(100, 50));
    _ = k1.with_layout(.relative, null);
    k1.size.baseline = 10;
    try root.add_child(a, k1);

    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(80, 30));
    _ = k2.with_layout(.relative, null);
    k2.size.baseline = 6;
    try root.add_child(a, k2);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 180), root.size.width);
    try std.testing.expectEqual(@as(f32, 50), root.size.height);
    try std.testing.expectEqual(@as(f32, 0), k1.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 16), k2.layout._global_y.?);
}

test "horizontal cross-align: baseline folds a padded child's bottom padding in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same shape as above, but k2 is padded (a text chip/badge): content 80×30 baseline 6,
    // padding up 2 / down 4 → box 80×36, reference = 6 + 4 = 10 up from the box bottom
    // (ascent 26). Shared line = max ascent = 40 → k2's box top at 40 − 26 = 14, so its
    // *content* baseline lands on the line: 14 + 36 − 4 − 6 = 40, same as k1's (50 − 10).
    // fit height = maxAscent(40) + maxDescent(10) = 50.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row });

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(100, 50));
    _ = k1.with_layout(.relative, null);
    k1.size.baseline = 10;
    try root.add_child(a, k1);

    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(80, 30));
    _ = k2.with_layout(.relative, null);
    k2.size.baseline = 6;
    k2.size.padding = features.Padding.initEach(2, 0, 4, 0);
    try root.add_child(a, k2);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 50), root.size.height);
    try std.testing.expectEqual(@as(f32, 0), k1.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 14), k2.layout._global_y.?);
}

test "horizontal cross-align: center is derived from the same reduction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same shape, cross = .center: k2 (shorter) centers in the row's max height (50).
    // cy2 = (50 − 30)/2 = 10; height stays max child height = 50.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .center });

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(100, 50));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);

    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(80, 30));
    _ = k2.with_layout(.relative, null);
    try root.add_child(a, k2);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 50), root.size.height);
    try std.testing.expectEqual(@as(f32, 0), k1.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 10), k2.layout._global_y.?);
}

/// A child whose cross extent is decided by `content`: a fixed main extent and a measured
/// cross extent of `cross_px`, set the way the host's text measure sets `data_*`.
fn stretch_kid(a: std.mem.Allocator, id: []const u8, parent: *TestNode, main_px: f32, cross_px: f32) !*TestNode {
    const k = try TestNode.pcreate(a, id, parent);
    _ = k.with_size(Size.init(.{ .fixed = main_px }, .content)).with_layout(.relative, null);
    k.size.data_height = cross_px;
    return k;
}

test "cross stretch: a definite row fills auto children to its content height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Row 200x60 (content box), padding-top 5. `fit` holds a 30x20 grandchild, so pass 1
    // makes it 20 tall; stretch raises it to 60. The fixed 40x30 child keeps 30. Both sit at
    // the line start, the parent's content top (y = 5).
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 60));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .stretch });
    root.size.padding = features.Padding.initEach(5, 0, 0, 0);
    const fit = try TestNode.pcreate(a, "fit", root);
    _ = fit.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, null);
    const gc = try TestNode.pcreate(a, "gc", fit);
    _ = gc.with_size(Size.initFixed(30, 20)).with_layout(.relative, null);
    const fixed = try TestNode.pcreate(a, "fixed", root);
    _ = fixed.with_size(Size.initFixed(40, 30)).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 60), fit.size.height);
    try std.testing.expectEqual(@as(f32, 30), fit.size.width);
    try std.testing.expectEqual(@as(f32, 20), gc.size.height);
    try std.testing.expectEqual(@as(f32, 30), fixed.size.height);
    try std.testing.expectEqual(@as(f32, 5), fit.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 5), fixed.layout._global_y.?);
}

test "cross stretch: a fit row stretches to its tallest child and stays that size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Auto children 20/50/35 tall plus a fixed 25: the fit height is the plain max (50), the
    // auto children all become 50, the fixed one stays 25, and nothing feeds back.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .stretch });
    const k20 = try stretch_kid(a, "k20", root, 10, 20);
    const k50 = try stretch_kid(a, "k50", root, 10, 50);
    const k35 = try stretch_kid(a, "k35", root, 10, 35);
    const fixed = try TestNode.pcreate(a, "fixed", root);
    _ = fixed.with_size(Size.initFixed(10, 25)).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 50), root.size.height);
    try std.testing.expectEqual(@as(f32, 50), k20.size.height);
    try std.testing.expectEqual(@as(f32, 50), k50.size.height);
    try std.testing.expectEqual(@as(f32, 50), k35.size.height);
    try std.testing.expectEqual(@as(f32, 25), fixed.size.height);
    for ([_]*TestNode{ k20, k50, k35, fixed }) |k| try std.testing.expectEqual(@as(f32, 0), k.layout._global_y.?);
}

test "cross stretch: a column fills a content-width child's border box, padding included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Column with a 300-wide content box (padding 10 left/right on top). The child measures
    // 40 wide with 6px side padding (box 52); stretched, its border box is the parent's
    // content width, 300, so its content is 288. It starts at the content left (x = 10).
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(300, 100));
    _ = root.with_layout(.top_left, .{ .dir = .column, .cross = .stretch });
    root.size.padding = features.Padding.initEach(0, 10, 0, 10);
    const k = try TestNode.pcreate(a, "k", root);
    _ = k.with_size(Size.init(.content, .{ .fixed = 20 })).with_layout(.relative, null);
    k.size.data_width = 40;
    k.size.padding = features.Padding.initEach(0, 6, 0, 6);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 300), k.size.width);
    try std.testing.expectEqual(@as(f32, 10), k.layout._global_x.?);
}

test "cross stretch: the stretched axis is definite for the child's descendants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Row 80 tall. `cell` is a fit row (padding 4 top/bottom) holding a `pct 1.0`-tall
    // grandchild: unstretched it would be indefinite and fall back to 0; stretched to 80 its
    // content box is 72, which the grandchild fills. `col` is a fit column with a 20 header
    // and a `grow` body: the body takes the stretched remainder, 80 − 20 = 60.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 80));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .stretch });
    const cell = try TestNode.pcreate(a, "cell", root);
    _ = cell.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, null);
    cell.size.padding = features.Padding.initEach(4, 0, 4, 0);
    const fill = try TestNode.pcreate(a, "fill", cell);
    _ = fill.with_size(Size.init(.{ .fixed = 10 }, .{ .pct_of_parent = 1.0 })).with_layout(.relative, null);
    const col = try TestNode.pcreate(a, "col", root);
    _ = col.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, .{ .dir = .column });
    const head = try TestNode.pcreate(a, "head", col);
    _ = head.with_size(Size.initFixed(10, 20)).with_layout(.relative, null);
    const body = try TestNode.pcreate(a, "body", col);
    _ = body.with_size(Size.init(.{ .fixed = 10 }, .grow)).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 80), cell.size.height);
    try std.testing.expectEqual(@as(f32, 72), fill.size.height);
    try std.testing.expectEqual(@as(f32, 80), col.size.height);
    try std.testing.expectEqual(@as(f32, 60), body.size.height);
    try std.testing.expectEqual(@as(f32, 20), body.layout._global_y.?);
}

test "cross stretch: max caps the stretch, min is respected, nothing shrinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Row 100 tall. `capped`: max content 40 → 40. `capped_pad`: max 40 plus 5+5 padding →
    // box 50. `floored`: min 10 → stretched to 100. `tall`: min 120 already exceeds the line,
    // and a stretch never shrinks, so it stays 120.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 100));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .stretch });
    const capped = try stretch_kid(a, "capped", root, 10, 15);
    capped.size.max_height = 40;
    const capped_pad = try stretch_kid(a, "capped_pad", root, 10, 15);
    capped_pad.size.max_height = 40;
    capped_pad.size.padding = features.Padding.initEach(5, 0, 5, 0);
    const floored = try stretch_kid(a, "floored", root, 10, 5);
    floored.size.min_height = 10;
    const tall = try stretch_kid(a, "tall", root, 10, 5);
    tall.size.min_height = 120;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 40), capped.size.height);
    try std.testing.expectEqual(@as(f32, 50), capped_pad.size.height);
    try std.testing.expectEqual(@as(f32, 100), floored.size.height);
    try std.testing.expectEqual(@as(f32, 120), tall.size.height);
}

test "cross stretch: a wrapping row stretches each child to its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Width 100, gap 4, three 40-wide children: k0 (auto 10), k1 (fixed 30), k2 (auto 5).
    // Forward: line 1 = k0,k1 (40+4+40 ≤ 100) max 30; line 2 = k2 alone, 5. So k0 → 30 and
    // k2 stays 5, at y = 30 + 4. Fit height = 30 + 4 + 5.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.{ .fixed = 100 }, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row, .wrap = true, .cross = .stretch });
    root.layout.gap = 4;
    const k0 = try stretch_kid(a, "k0", root, 40, 10);
    const k1 = try TestNode.pcreate(a, "k1", root);
    _ = k1.with_size(Size.initFixed(40, 30)).with_layout(.relative, null);
    const k2 = try stretch_kid(a, "k2", root, 40, 5);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 39), root.size.height);
    try std.testing.expectEqual(@as(f32, 30), k0.size.height);
    try std.testing.expectEqual(@as(f32, 30), k1.size.height);
    try std.testing.expectEqual(@as(f32, 5), k2.size.height);
    try std.testing.expectEqual(@as(f32, 0), k0.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 34), k2.layout._global_y.?);

    // Reversed, the packing order is k2,k1 | k0, so k2 now shares k1's line (→ 30) and k0
    // is alone on line 2 (stays 10). The pass-2 packing mirrors `flow_place`'s reverse.
    root.layout.flow.reverse = true;
    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 30), k2.size.height);
    try std.testing.expectEqual(@as(f32, 10), k0.size.height);
    try std.testing.expectEqual(@as(f32, 34), k0.layout._global_y.?);
}

test "cross stretch: a stretch row's line is the plain max, not the baseline extent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Under `.baseline` this pair would fit to max ascent + max descent: k1 (50 tall,
    // baseline 10) has ascent 40, k2 (30 tall, baseline 25) has descent 25, so 65. Stretch
    // ignores baselines: the line is max(50, 30) = 50 and k2 (auto) stretches to it.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .stretch });
    const k1 = try TestNode.pcreate(a, "k1", root);
    _ = k1.with_size(Size.initFixed(100, 50)).with_layout(.relative, null);
    k1.size.baseline = 10;
    const k2 = try stretch_kid(a, "k2", root, 80, 30);
    k2.size.baseline = 25;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 50), root.size.height);
    try std.testing.expectEqual(@as(f32, 50), k2.size.height);
    try std.testing.expectEqual(@as(f32, 0), k2.layout._global_y.?);
}

test "layout gap: fit parent reserves it, children flow spaced by it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Vertical parent, gap 10 between its two children (50 + 30 tall):
    // height = 50 + 10 + 30 = 90; width = max(100, 200) = 200 (no cross-axis gap).
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .column });
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

    try root.set_global_pos(a);
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
    _ = root.with_layout(.top_left, .{ .dir = .column });

    const child = try TestNode.create(a, "child");
    _ = child.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .{ .fixed = 50 }));
    _ = child.with_layout(.relative, null);
    try root.add_child(a, child);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 0), child.size.width); // no definite base ⇒ content ⇒ 0
    try std.testing.expectEqual(@as(f32, 0), root.size.width); // fit cross-axis = max(0) = 0
}

test "an out-of-flow pct child resolves against its fit parent's final size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A fit column holding 100x20 and 60x30 is 100x50; padding 4 all round makes it 108x58.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .column });
    root.size.padding = .{ .up = 4, .right = 4, .down = 4, .left = 4 };
    const k1 = try TestNode.pcreate(a, "k1", root);
    _ = k1.with_size(Size.initFixed(100, 20)).with_layout(.relative, null);
    const k2 = try TestNode.pcreate(a, "k2", root);
    _ = k2.with_size(Size.initFixed(60, 30)).with_layout(.relative, null);
    // An underbar: half the content box wide, 3 high, on the bottom edge.
    const bar = try TestNode.pcreate(a, "bar", root);
    _ = bar.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .{ .fixed = 3 })).with_layout(.bottom_left, null);
    // A wash covering the whole content box.
    const wash = try TestNode.pcreate(a, "wash", root);
    _ = wash.with_size(Size.init(.{ .pct_of_parent = 1 }, .{ .pct_of_parent = 1 })).with_layout(.top_left, null);
    // An in-flow pct child of the same parent keeps the indefinite fallback.
    const flow = try TestNode.pcreate(a, "flow", root);
    _ = flow.with_size(Size.init(.{ .pct_of_parent = 1 }, .{ .fixed = 0 })).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 108), root.size.width); // the overlays never fed the fit
    try std.testing.expectEqual(@as(f32, 58), root.size.height);
    try std.testing.expectEqual(@as(f32, 50), bar.size.width);
    try std.testing.expectEqual(@as(f32, 51), bar.layout._global_y.?); // 4 + 50 - 3
    try std.testing.expectEqual(@as(f32, 100), wash.size.width);
    try std.testing.expectEqual(@as(f32, 50), wash.size.height);
    try std.testing.expectEqual(@as(f32, 0), flow.size.width);
}

/// A fixed 200×40 row holding one `pct_of_parent = frac` child padded `pad_x` left and
/// right; returns the child so a test can read its box and content widths.
fn padded_pct_child(a: std.mem.Allocator, frac: f32, pad_x: f32) !*TestNode {
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 40)).with_layout(.top_left, .{ .dir = .row });
    const child = try TestNode.pcreate(a, "child", root);
    _ = child.with_size(Size.init(.{ .pct_of_parent = frac }, .{ .fixed = 10 })).with_layout(.relative, null);
    child.size.padding = features.Padding.initSymmetric(pad_x, 0);
    try root.set_global_pos(a);
    return child;
}

test "pct_of_parent sizes the border box: 1.0 plus padding fills the parent exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const child = try padded_pct_child(arena.allocator(), 1.0, 10);
    try std.testing.expectEqual(@as(f32, 200), child.size.width); // not 220
    try std.testing.expectEqual(@as(f32, 180), child.size.width - child.size.padding.left - child.size.padding.right); // content
    try std.testing.expectEqual(@as(f32, 10), child.size.height); // fixed axis untouched
}

test "pct_of_parent border box: a fraction's padding comes out of its share" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const child = try padded_pct_child(arena.allocator(), 0.5, 10);
    try std.testing.expectEqual(@as(f32, 100), child.size.width); // 0.5 × 200, content 80
}

test "pct_of_parent border box: padding wider than the share clamps content to 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 0.1 × 200 = 20 of share against 60 of padding: content 0, box = the padding.
    const child = try padded_pct_child(arena.allocator(), 0.1, 30);
    try std.testing.expectEqual(@as(f32, 60), child.size.width);
}

test "pct_of_parent border box: min still bounds the content left after padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 40)).with_layout(.top_left, .{ .dir = .row });
    const child = try TestNode.pcreate(a, "child", root);
    _ = child.with_size(Size.init(.{ .pct_of_parent = 0.25 }, .{ .fixed = 10 })).with_layout(.relative, null);
    child.size.padding = features.Padding.initSymmetric(10, 0);
    child.size.min_width = 60; // share 50 − padding 20 = 30 content, raised to 60
    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 80), child.size.width);
}

test "an out-of-flow padded pct child under a fit parent is border-box too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A fit column around one 100×20 child; an anchored 1.0 × 1.0 wash padded 6 all round
    // covers the parent's content box exactly (100×20), its content inset to 88×8.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .column });
    const k = try TestNode.pcreate(a, "k", root);
    _ = k.with_size(Size.initFixed(100, 20)).with_layout(.relative, null);
    const wash = try TestNode.pcreate(a, "wash", root);
    _ = wash.with_size(Size.init(.{ .pct_of_parent = 1 }, .{ .pct_of_parent = 1 })).with_layout(.top_left, null);
    wash.size.padding = features.Padding.init(6);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 100), root.size.width); // the overlay never fed the fit
    try std.testing.expectEqual(@as(f32, 20), root.size.height);
    try std.testing.expectEqual(@as(f32, 100), wash.size.width);
    try std.testing.expectEqual(@as(f32, 20), wash.size.height);
}

/// Build a fixed 200×100 row with two fixed 40-wide children, under `main` distribution,
/// and return their resolved main-axis (x) positions. The parent is definite, so the
/// distribution has 200 − 80 = 120 of free main space to share.
fn two_child_row_x(a: std.mem.Allocator, main: features.MainAlign) !struct { f32, f32 } {
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 100));
    _ = root.with_layout(.top_left, .{ .dir = .row, .main = main });
    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(40, 10));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);
    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(40, 10));
    _ = k2.with_layout(.relative, null);
    try root.add_child(a, k2);
    try root.set_global_pos(a);
    return .{ k1.layout._global_x.?, k2.layout._global_x.? };
}

test "main-axis distribution shares free space per `main`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // start: flush left. center: run (80) centered → lead 60. end: flush right → lead 120.
    try std.testing.expectEqual(.{ 0, 40 }, try two_child_row_x(a, .start));
    try std.testing.expectEqual(.{ 60, 100 }, try two_child_row_x(a, .center));
    try std.testing.expectEqual(.{ 120, 160 }, try two_child_row_x(a, .end));
    // space_between: ends pinned, 120 between. space_evenly: three 40-gaps (lead 40, between 40).
    try std.testing.expectEqual(.{ 0, 160 }, try two_child_row_x(a, .space_between));
    try std.testing.expectEqual(.{ 40, 120 }, try two_child_row_x(a, .space_evenly));
    // space_around: half-gap ends → unit 60, lead 30, k2 at 30+40+60 = 130.
    try std.testing.expectEqual(.{ 30, 130 }, try two_child_row_x(a, .space_around));
}

test "reverse lays the run out back-to-front along the main axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Row, reverse: the sequence flips before start-packing, so k2 lands at the leading edge
    // and k1 after it. (k1 first in source order, but drawn second.)
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 100));
    _ = root.with_layout(.top_left, .{ .dir = .row, .reverse = true });
    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(40, 10));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);
    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(40, 10));
    _ = k2.with_layout(.relative, null);
    try root.add_child(a, k2);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 40), k1.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 0), k2.layout._global_x.?);
}

test "wrap breaks the run into cross-stacked lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Fixed 100-wide row, wrap on, three 40-wide/10-tall children: k1+k2 fill the first line
    // (80 ≤ 100), k3 (would be 120) wraps to a second line one row-height (10) down.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(100, 100));
    _ = root.with_layout(.top_left, .{ .dir = .row, .wrap = true });
    const kids = [_]*TestNode{ undefined, undefined, undefined };
    var buf = kids;
    for (&buf, 0..) |*slot, i| {
        const kid = try a.print("k{d}", .{i});
        const k = try TestNode.create(a, kid);
        _ = k.with_size(Size.initFixed(40, 10));
        _ = k.with_layout(.relative, null);
        try root.add_child(a, k);
        slot.* = k;
    }

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 0), buf[0].layout._global_y.?); // line 1
    try std.testing.expectEqual(@as(f32, 0), buf[1].layout._global_y.?); // line 1
    try std.testing.expectEqual(@as(f32, 10), buf[2].layout._global_y.?); // wrapped to line 2
    try std.testing.expectEqual(@as(f32, 0), buf[2].layout._global_x.?); // new line starts at the left
}

test "a fit_children height counts every wrapped line, not just the first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Fixed 100-wide, fit-height wrapping row with gap 4; three 40×10 children. k0+k1 fill
    // line 1 (40+4+40 = 84 ≤ 100), k2 wraps. The height must be both lines plus the
    // inter-line gap (10 + 4 + 10), not one line — otherwise whatever follows this row in a
    // column draws on top of its second line.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.{ .fixed = 100 }, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row, .wrap = true });
    root.layout.gap = 4;
    for (0..3) |i| {
        const kid = try a.print("k{d}", .{i});
        const k = try TestNode.create(a, kid);
        _ = k.with_size(Size.initFixed(40, 10));
        _ = k.with_layout(.relative, null);
        try root.add_child(a, k);
    }

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 24), root.size.height);
}

test "a wrapping fit falls back to one line when the main extent is indefinite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Main axis is itself fit_children — there's no limit to pack against (asking would be
    // circular), so the row measures as the single line it will actually be placed as.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row, .wrap = true });
    for (0..3) |i| {
        const kid = try a.print("k{d}", .{i});
        const k = try TestNode.create(a, kid);
        _ = k.with_size(Size.initFixed(40, 10));
        _ = k.with_layout(.relative, null);
        try root.add_child(a, k);
    }

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 10), root.size.height);
    try std.testing.expectEqual(@as(f32, 120), root.size.width);
}

/// `n` in-flow `w`×`h` fixed boxes under `parent`, for the wrap tests below.
fn test_boxes(a: Allocator, parent: *TestNode, n: usize, w: f32, h: f32) ![]*TestNode {
    const kids = try a.alloc(*TestNode, n);
    for (kids, 0..) |*slot, i| {
        const k = try TestNode.pcreate(a, try a.print("k{d}", .{i}), parent);
        _ = k.with_size(Size.initFixed(w, h)).with_layout(.relative, null);
        slot.* = k;
    }
    return kids;
}

test "width before height: a grown wrapping row counts every line it breaks into" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A 300-wide row: fixed 100 and 60 siblings leave the grower 140. Its three 60×10 kids
    // with gap 4 pack 60+4+60 = 124 on line 1; the third wraps. Height 10 + 4 + 10 = 24,
    // where pass 1 alone (no fixed width to pack against) would report one line.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(300, 100)).with_layout(.top_left, .{ .dir = .row, .cross = .start });
    const left = try TestNode.pcreate(a, "left", root);
    _ = left.with_size(Size.initFixed(100, 20)).with_layout(.relative, null);
    const wrap = try TestNode.pcreate(a, "wrap", root);
    _ = wrap.with_size(Size.init(.grow, .fit_children)).with_layout(.relative, .{ .dir = .row, .wrap = true, .cross = .start });
    wrap.layout.gap = 4;
    const kids = try test_boxes(a, wrap, 3, 60, 10);
    const right = try TestNode.pcreate(a, "right", root);
    _ = right.with_size(Size.initFixed(60, 20)).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 140), wrap.size.width);
    try std.testing.expectEqual(@as(f32, 24), wrap.size.height);
    try std.testing.expectEqual(@as(f32, 14), kids[2].layout._global_y.?); // line 2, placed where measured
    try std.testing.expectEqual(@as(f32, 100), kids[2].layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 240), right.layout._global_x.?);
}

test "width before height: a pct-width wrapping row counts every line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Half of 200 is the border box; 5px side padding leaves 90 of content. Four 30×10 kids
    // pack three to a line (90 ≤ 90), so the row is two lines tall.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 200)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const wrap = try TestNode.pcreate(a, "wrap", root);
    _ = wrap.with_size(Size.init(.{ .pct_of_parent = 0.5 }, .fit_children)).with_layout(.relative, .{ .dir = .row, .wrap = true, .cross = .start });
    wrap.size.padding = .initEach(0, 5, 0, 5);
    const kids = try test_boxes(a, wrap, 4, 30, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 100), wrap.size.width);
    try std.testing.expectEqual(@as(f32, 20), wrap.size.height);
    try std.testing.expectEqual(@as(f32, 10), kids[3].layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 5), kids[3].layout._global_x.?);
}

test "width before height: line packing reads the children's final pct widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A fixed 100-wide wrapping row of three 0.4 children. Bottom-up they are provisionally
    // 0 wide (no content) and would all share one line; final they are 40 each, so the
    // third wraps (40+40+40 > 100) and the height is two lines.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.{ .fixed = 100 }, .fit_children)).with_layout(.top_left, .{ .dir = .row, .wrap = true, .cross = .start });
    const kids = try test_boxes(a, root, 3, 0, 10);
    for (kids) |k| k.size.w = .{ .pct_of_parent = 0.4 };

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 40), kids[0].size.width);
    try std.testing.expectEqual(@as(f32, 20), root.size.height);
    try std.testing.expectEqual(@as(f32, 10), kids[2].layout._global_y.?);
}

test "width before height: a shrunk wrapping row is measured at its shrunk width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A 200-wide row holds a fixed 150 wrapping row (shrink 1) and a fixed 100 sibling: the
    // 50 overflow comes out of the wrapping row, leaving 100. Its three 40×10 kids fit one
    // line at 150 but two at 100, and its height follows the shrunk width.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 100)).with_layout(.top_left, .{ .dir = .row, .cross = .start });
    const wrap = try TestNode.pcreate(a, "wrap", root);
    _ = wrap.with_size(Size.init(.{ .fixed = 150 }, .fit_children)).with_layout(.relative, .{ .dir = .row, .wrap = true, .cross = .start });
    wrap.size.shrink = 1;
    const kids = try test_boxes(a, wrap, 3, 40, 10);
    const sib = try TestNode.pcreate(a, "sib", root);
    _ = sib.with_size(Size.initFixed(100, 10)).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 100), wrap.size.width);
    try std.testing.expectEqual(@as(f32, 20), wrap.size.height);
    try std.testing.expectEqual(@as(f32, 10), kids[2].layout._global_y.?);
}

test "width before height: a stretched content-width wrapping row is measured at the stretch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `.stretch` column raises its 50-wide content child to 200. At 200 its five 60×10
    // kids pack three to a line, so two lines; at its 50px content width each would take a
    // line of its own, and bottom-up there is no width to pack against at all.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 200)).with_layout(.top_left, .{ .dir = .column, .cross = .stretch });
    const wrap = try TestNode.pcreate(a, "wrap", root);
    _ = wrap.with_size(Size.init(.content, .fit_children)).with_layout(.relative, .{ .dir = .row, .wrap = true, .cross = .start });
    wrap.size.data_width = 50;
    const kids = try test_boxes(a, wrap, 5, 60, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 200), wrap.size.width);
    try std.testing.expectEqual(@as(f32, 20), wrap.size.height);
    try std.testing.expectEqual(@as(f32, 10), kids[3].layout._global_y.?);
}

test "width before height: column grow, row stretch and baseline read the re-solved height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each tree holds a wrapping row that is 20 tall (two 10px lines) only once its width is
    // known: four 100×10 kids in 300 (three to a line), or in a 250 grower (two to a line).
    {
        // A 100-tall column: the `.grow` sibling under the wrapping row takes the other 80.
        const root = try TestNode.create(a, "col");
        _ = root.with_size(Size.initFixed(300, 100)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
        const wrap = try TestNode.pcreate(a, "wrap", root);
        _ = wrap.with_size(Size.init(.{ .pct_of_parent = 1.0 }, .fit_children)).with_layout(.relative, .{ .dir = .row, .wrap = true, .cross = .start });
        _ = try test_boxes(a, wrap, 4, 100, 10);
        const rest = try TestNode.pcreate(a, "rest", root);
        _ = rest.with_size(Size.init(.{ .fixed = 10 }, .grow)).with_layout(.relative, null);

        try root.set_global_pos(a);
        try std.testing.expectEqual(@as(f32, 20), wrap.size.height);
        try std.testing.expectEqual(@as(f32, 80), rest.size.height);
        try std.testing.expectEqual(@as(f32, 20), rest.layout._global_y.?);
    }
    {
        // A fit-height `.stretch` row: its line is the wrapping row's 20, and the 5px content
        // sibling stretches to it.
        const root = try TestNode.create(a, "stretch");
        _ = root.with_size(Size.init(.{ .fixed = 300 }, .fit_children)).with_layout(.top_left, .{ .dir = .row, .cross = .stretch });
        const wrap = try TestNode.pcreate(a, "wrap", root);
        _ = wrap.with_size(Size.init(.grow, .fit_children)).with_layout(.relative, .{ .dir = .row, .wrap = true, .cross = .start });
        _ = try test_boxes(a, wrap, 4, 100, 10);
        const side = try TestNode.pcreate(a, "side", root);
        _ = side.with_size(Size.initContent(50, 5)).with_layout(.relative, null);

        try root.set_global_pos(a);
        try std.testing.expectEqual(@as(f32, 250), wrap.size.width);
        try std.testing.expectEqual(@as(f32, 20), root.size.height);
        try std.testing.expectEqual(@as(f32, 20), side.size.height);
    }
    {
        // A baseline row: no baselines set, so both align by their bottoms, and the 8px
        // sibling drops to the wrapping row's second line (20 − 8).
        const root = try TestNode.create(a, "baseline");
        _ = root.with_size(Size.init(.{ .fixed = 300 }, .fit_children)).with_layout(.top_left, .{ .dir = .row, .cross = .baseline });
        const wrap = try TestNode.pcreate(a, "wrap", root);
        _ = wrap.with_size(Size.init(.grow, .fit_children)).with_layout(.relative, .{ .dir = .row, .wrap = true, .cross = .start });
        _ = try test_boxes(a, wrap, 4, 100, 10);
        const side = try TestNode.pcreate(a, "side", root);
        _ = side.with_size(Size.initContent(50, 8)).with_layout(.relative, null);

        try root.set_global_pos(a);
        try std.testing.expectEqual(@as(f32, 20), root.size.height);
        try std.testing.expectEqual(@as(f32, 12), side.layout._global_y.?);
    }
}

test "width before height: a column-wrap's x pass still packs against bottom-up heights" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Pins the one y-to-x coupling left. A 200×100 wrapping `.stretch` column: k0 is 0.5 of
    // the height (50 final, 0 bottom-up), k1 a 10-wide content box 30 tall, k2 80 wide and
    // 30 tall. Widths are solved first, so the stretch packs the bottom-up heights 0+30+30
    // into one line, whose widest member is k2: k1 stretches to 80. (Against the final
    // heights, 50+30 would fill line 1 and k1 would stretch only to k0's 50.) Placement
    // then packs the final heights, puts k2 on a second line, and starts it past k1's 80.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 100)).with_layout(.top_left, .{ .dir = .column, .wrap = true, .cross = .stretch });
    const k0 = try TestNode.pcreate(a, "k0", root);
    _ = k0.with_size(Size.init(.{ .fixed = 50 }, .{ .pct_of_parent = 0.5 })).with_layout(.relative, null);
    const k1 = try TestNode.pcreate(a, "k1", root);
    _ = k1.with_size(Size.init(.content, .{ .fixed = 30 })).with_layout(.relative, null);
    k1.size.data_width = 10;
    const k2 = try TestNode.pcreate(a, "k2", root);
    _ = k2.with_size(Size.initFixed(80, 30)).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 50), k0.size.height);
    try std.testing.expectEqual(@as(f32, 80), k1.size.width);
    try std.testing.expectEqual(@as(f32, 50), k1.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 80), k2.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 0), k2.layout._global_y.?);

    // A fit-width column-wrap has the same limit: its width is measured in pass 1, where k0
    // is 0 tall, so it counts one column (80) though placement makes two.
    root.size.w = .fit_children;
    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 80), root.size.width);
}

test "padding grows a fit parent AND insets its flowed children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fit_children column, 10px padding all round, two fixed 40×30 children.
    // Box = content + padding: width = 40 + 20 = 60; height = 30 + 30 + 20 = 80.
    // Children flow within the *content* box, so they start at the leading padding (10,10),
    // not the box corner (0,0) — k2 stacks one child-height below with no gap.
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .column });
    root.size.padding = features.Padding.init(10);

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(40, 30));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);
    const k2 = try TestNode.create(a, "k2");
    _ = k2.with_size(Size.initFixed(40, 30));
    _ = k2.with_layout(.relative, null);
    try root.add_child(a, k2);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 60), root.size.width); // content 40 + padding 20
    try std.testing.expectEqual(@as(f32, 80), root.size.height); // content 60 + padding 20
    try std.testing.expectEqual(.{ 10, 10 }, .{ k1.layout._global_x.?, k1.layout._global_y.? });
    try std.testing.expectEqual(.{ 10, 40 }, .{ k2.layout._global_x.?, k2.layout._global_y.? });
}

test "padding: `.end` distribution packs against the trailing padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `fixed` axis is a *content-box*: padding grows the box on top of it, so a "fixed 200"
    // row with l10/r30 padding resolves to a 240-wide box over a 200-wide content extent.
    // `.end` packs the lone 40-wide child against the content trailing edge:
    // global_x = leftpad(10) + (200 − 40) = 170, so its right edge (210) sits exactly the
    // right padding (30) in from the box's right edge (240).
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 100));
    _ = root.with_layout(.top_left, .{ .dir = .row, .main = .end });
    root.size.padding = features.Padding.initEach(0, 30, 0, 10);

    const k1 = try TestNode.create(a, "k1");
    _ = k1.with_size(Size.initFixed(40, 10));
    _ = k1.with_layout(.relative, null);
    try root.add_child(a, k1);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 240), root.size.width); // content 200 + padding 40
    try std.testing.expectEqual(@as(f32, 170), k1.layout._global_x.?); // right edge 210 = 240 − 30
}

test "padding: an anchored child centres within the content box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Fixed 200×200 content-box, asymmetric padding (u10 r20 d30 l40) ⇒ a 260×240 box over a
    // 200×200 content extent. An out-of-flow `.center` child anchors within the *content* box,
    // not the full box: content spans global x[40,240] y[10,210], so a 40×40 child centres at
    // (140−20, 110−20) = (120, 90).
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 200));
    _ = root.with_layout(.top_left, .{ .dir = .column });
    root.size.padding = features.Padding.initEach(10, 20, 30, 40);

    const child = try TestNode.create(a, "child");
    _ = child.with_size(Size.initFixed(40, 40));
    _ = child.with_layout(.center, null);
    try root.add_child(a, child);

    try root.set_global_pos(a);
    try std.testing.expectEqual(.{ 120, 90 }, .{ child.layout._global_x.?, child.layout._global_y.? });
}

test "grow fills row remainder after fixed sibling gap and parent padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(500, 100));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .start });
    root.size.padding = features.Padding.init(10);
    root.layout.gap = 12;

    const rail = try TestNode.pcreate(a, "rail", root);
    _ = rail.with_size(Size.initFixed(252, 20)).with_layout(.relative, null);
    const surface = try TestNode.pcreate(a, "surface", root);
    _ = surface.with_size(Size.init(.grow, .{ .fixed = 20 })).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 236), surface.size.width); // 500 - 252 - 12
    try std.testing.expectEqual(@as(f32, 10), rail.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 274), surface.layout._global_x.?);
}

test "nested column grow resolves descendants against its final size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(300, 400));
    _ = root.with_layout(.top_left, .{ .dir = .column, .cross = .start });
    root.layout.gap = 10;

    const header = try TestNode.pcreate(a, "header", root);
    _ = header.with_size(Size.init(.{ .fixed = 300 }, .{ .fixed = 50 })).with_layout(.relative, null);
    const body = try TestNode.pcreate(a, "body", root);
    _ = body.with_size(Size.init(.{ .pct_of_parent = 1 }, .grow)).with_layout(.relative, .{ .dir = .column });
    const half = try TestNode.pcreate(a, "half", body);
    _ = half.with_size(Size.init(.{ .pct_of_parent = 1 }, .{ .pct_of_parent = 0.5 })).with_layout(.relative, null);
    const footer = try TestNode.pcreate(a, "footer", root);
    _ = footer.with_size(Size.init(.{ .fixed = 300 }, .{ .fixed = 30 })).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 300), body.size.height); // 400 - 50 - 30 - 2*10
    try std.testing.expectEqual(@as(f32, 150), half.size.height);
    try std.testing.expectEqual(@as(f32, 370), footer.layout._global_y.?);
}

test "multiple growers redistribute a max-capped share" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(300, 50));
    _ = root.with_layout(.top_left, .{ .dir = .row });
    const fixed = try TestNode.pcreate(a, "fixed", root);
    _ = fixed.with_size(Size.initFixed(50, 10)).with_layout(.relative, null);
    const capped = try TestNode.pcreate(a, "capped", root);
    _ = capped.with_size(Size.init(.grow, .{ .fixed = 10 })).with_layout(.relative, null);
    capped.size.max_width = 80;
    const rest = try TestNode.pcreate(a, "rest", root);
    _ = rest.with_size(Size.init(.grow, .{ .fixed = 10 })).with_layout(.relative, null);
    rest.size.min_width = 20;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 80), capped.size.width);
    try std.testing.expectEqual(@as(f32, 170), rest.size.width);
}

test "zero remaining space preserves grow minimum and deterministic overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(100, 30));
    _ = root.with_layout(.top_left, .{ .dir = .row });
    const fixed = try TestNode.pcreate(a, "fixed", root);
    _ = fixed.with_size(Size.initFixed(120, 10)).with_layout(.relative, null);
    const grow = try TestNode.pcreate(a, "grow", root);
    _ = grow.with_size(Size.init(.grow, .{ .fixed = 10 })).with_layout(.relative, null);
    grow.size.min_width = 15;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 15), grow.size.width);
    try std.testing.expectEqual(@as(f32, 120), grow.layout._global_x.?);
}

test "min and max constrain fixed content percent and conflicting bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(200, 100));
    _ = root.with_layout(.top_left, .{ .dir = .column });

    const fixed = try TestNode.pcreate(a, "fixed", root);
    _ = fixed.with_size(Size.initFixed(20, 5)).with_layout(.relative, null);
    fixed.size.min_width = 40;
    const content = try TestNode.pcreate(a, "content", root);
    content.size = Size.initContent(100, 5);
    _ = content.with_layout(.relative, null);
    content.size.max_width = 60;
    const pct = try TestNode.pcreate(a, "pct", root);
    _ = pct.with_size(Size.init(.{ .pct_of_parent = 0.8 }, .{ .fixed = 5 })).with_layout(.relative, null);
    pct.size.max_width = 90;
    const conflict = try TestNode.pcreate(a, "conflict", root);
    _ = conflict.with_size(Size.initFixed(50, 5)).with_layout(.relative, null);
    conflict.size.min_width = 70;
    conflict.size.max_width = 30;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 40), fixed.size.width);
    try std.testing.expectEqual(@as(f32, 60), content.size.width);
    try std.testing.expectEqual(@as(f32, 90), pct.size.width);
    try std.testing.expectEqual(@as(f32, 70), conflict.size.width);
}

test "wrap respects grow minimums and fit height counts overflow lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.{ .fixed = 100 }, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row, .wrap = true, .cross = .start });
    root.layout.gap = 5;
    const fixed = try TestNode.pcreate(a, "fixed", root);
    _ = fixed.with_size(Size.initFixed(60, 10)).with_layout(.relative, null);
    const grow = try TestNode.pcreate(a, "grow", root);
    _ = grow.with_size(Size.init(.grow, .{ .fixed = 20 })).with_layout(.relative, null);
    grow.size.min_width = 50;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 35), root.size.height); // 10 + line gap 5 + 20
    try std.testing.expectEqual(@as(f32, 15), grow.layout._global_y.?);
}

test "grow falls back to measured content without a definite main-axis parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.fit_children, .fit_children));
    _ = root.with_layout(.top_left, .{ .dir = .row });
    const child = try TestNode.pcreate(a, "child", root);
    child.size = Size.init(.grow, .grow);
    child.size.data_width = 30;
    child.size.data_height = 12;
    _ = child.with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 30), child.size.width);
    try std.testing.expectEqual(@as(f32, 12), child.size.height);
    try std.testing.expectEqual(@as(f32, 30), root.size.width);
}

/// An in-flow child of `parent` with rule `main_rule` on a row's main axis and a fixed
/// height of 10, for the weighted-grow and shrink tests.
fn flex_kid(a: std.mem.Allocator, id: []const u8, parent: *TestNode, main_rule: features.SizeRule) !*TestNode {
    const k = try TestNode.pcreate(a, id, parent);
    _ = k.with_size(Size.init(main_rule, .{ .fixed = 10 })).with_layout(.relative, null);
    return k;
}

/// A `fixed_w × 50` row root, flowing left to right.
fn flex_row(a: std.mem.Allocator, fixed_w: f32) !*TestNode {
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(fixed_w, 50));
    _ = root.with_layout(.top_left, .{ .dir = .row, .cross = .start });
    return root;
}

test "weighted grow: weights 1:2 split 300 of free space 100:200" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try flex_row(a, 300);
    const one = try flex_kid(a, "one", root, .grow);
    const two = try flex_kid(a, "two", root, .grow);
    two.size.grow_weight = 2;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 100), one.size.width);
    try std.testing.expectEqual(@as(f32, 200), two.size.width);
    try std.testing.expectEqual(@as(f32, 100), two.layout._global_x.?);
}

test "weighted grow: a max-capped heavy grower's excess redistributes by weight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Weights 1:1:2 over 400: the first round offers 100/100/200, the weight-2 child is
    // capped at 100, and its unused 100 goes 1:1 to the other two.
    const root = try flex_row(a, 400);
    const left = try flex_kid(a, "left", root, .grow);
    const mid = try flex_kid(a, "mid", root, .grow);
    const heavy = try flex_kid(a, "heavy", root, .grow);
    heavy.size.grow_weight = 2;
    heavy.size.max_width = 100;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 150), left.size.width);
    try std.testing.expectEqual(@as(f32, 150), mid.size.width);
    try std.testing.expectEqual(@as(f32, 100), heavy.size.width);
}

test "weighted grow: weight 0 stays at its minimum, and an all-zero sum grows nobody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try flex_row(a, 300);
    const still = try flex_kid(a, "still", root, .grow);
    still.size.grow_weight = 0;
    still.size.min_width = 30;
    const rest = try flex_kid(a, "rest", root, .grow);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 30), still.size.width);
    try std.testing.expectEqual(@as(f32, 270), rest.size.width);

    const root2 = try flex_row(a, 300);
    const z1 = try flex_kid(a, "z1", root2, .grow);
    z1.size.grow_weight = 0;
    const z2 = try flex_kid(a, "z2", root2, .grow);
    z2.size.grow_weight = -1;
    z2.size.min_width = 5;

    try root2.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 0), z1.size.width);
    try std.testing.expectEqual(@as(f32, 5), z2.size.width);
}

test "weighted grow: padding comes out of the border box before the weighted split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 300 − 30 of padding leaves 270 to split 1:2, so content 90:180 and border 120:180.
    const root = try flex_row(a, 300);
    const padded = try flex_kid(a, "padded", root, .grow);
    padded.size.padding = features.Padding.initEach(0, 15, 0, 15);
    const heavy = try flex_kid(a, "heavy", root, .grow);
    heavy.size.grow_weight = 2;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 120), padded.size.width);
    try std.testing.expectEqual(@as(f32, 180), heavy.size.width);
    try std.testing.expectEqual(@as(f32, 120), heavy.layout._global_x.?);
}

test "shrink: equal bases split the overflow by factor, and descendants follow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try flex_row(a, 300);
    const left = try flex_kid(a, "left", root, .{ .fixed = 200 });
    left.size.shrink = 1;
    const right = try flex_kid(a, "right", root, .{ .fixed = 200 });
    right.size.shrink = 1;
    // A full-width grandchild resolves against the shrunk box, not the fixed 200.
    const fill = try TestNode.pcreate(a, "fill", left);
    _ = fill.with_size(Size.init(.{ .pct_of_parent = 1 }, .{ .fixed = 5 })).with_layout(.relative, null);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 150), left.size.width);
    try std.testing.expectEqual(@as(f32, 150), right.size.width);
    try std.testing.expectEqual(@as(f32, 150), right.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 150), fill.size.width);

    // Factors 1:3 over equal 200 bases: the overflow of 100 splits 25:75.
    const root2 = try flex_row(a, 300);
    const light = try flex_kid(a, "light", root2, .{ .fixed = 200 });
    light.size.shrink = 1;
    const heavy = try flex_kid(a, "heavy", root2, .{ .fixed = 200 });
    heavy.size.shrink = 3;

    try root2.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 175), light.size.width);
    try std.testing.expectEqual(@as(f32, 125), heavy.size.width);
}

test "shrink: the overflow is weighted by each child's base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Bases 100 and 300, both factor 1, in 300: the overflow of 100 goes 25:75.
    const root = try flex_row(a, 300);
    const narrow = try flex_kid(a, "narrow", root, .{ .fixed = 100 });
    narrow.size.shrink = 1;
    const wide = try flex_kid(a, "wide", root, .{ .fixed = 300 });
    wide.size.shrink = 1;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 75), narrow.size.width);
    try std.testing.expectEqual(@as(f32, 225), wide.size.width);
}

test "shrink: a child stops at its min and the rest moves to its sibling; padding stays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An equal split would take 50 from each; `floored` can only give 20, so `free` gives 80.
    const root = try flex_row(a, 300);
    const floored = try flex_kid(a, "floored", root, .{ .fixed = 200 });
    floored.size.shrink = 1;
    floored.size.min_width = 180;
    const free = try flex_kid(a, "free", root, .{ .fixed = 200 });
    free.size.shrink = 1;

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 180), floored.size.width);
    try std.testing.expectApproxEqAbs(@as(f32, 120), free.size.width, 0.001);

    // Padding never shrinks: 220 + 200 overflows by 120, taken 60:60 from the 200 contents.
    const root2 = try flex_row(a, 300);
    const padded = try flex_kid(a, "padded", root2, .{ .fixed = 200 });
    padded.size.shrink = 1;
    padded.size.padding = features.Padding.initEach(0, 10, 0, 10);
    const plain = try flex_kid(a, "plain", root2, .{ .fixed = 200 });
    plain.size.shrink = 1;

    try root2.set_global_pos(a);
    try std.testing.expectApproxEqAbs(@as(f32, 160), padded.size.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 140), plain.size.width, 0.001);

    // Every shrinker at its floor: the run still overflows, deterministically.
    const root3 = try flex_row(a, 300);
    const stiff1 = try flex_kid(a, "stiff1", root3, .{ .fixed = 200 });
    stiff1.size.shrink = 1;
    stiff1.size.min_width = 190;
    const stiff2 = try flex_kid(a, "stiff2", root3, .{ .fixed = 200 });
    stiff2.size.shrink = 1;
    stiff2.size.min_width = 190;

    try root3.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 190), stiff1.size.width);
    try std.testing.expectEqual(@as(f32, 190), stiff2.size.width);
}

test "shrink: the default 0 overflows as before, and gap counts only for packed modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try flex_row(a, 300);
    root.layout.gap = 10;
    const left = try flex_kid(a, "left", root, .{ .fixed = 200 });
    const right = try flex_kid(a, "right", root, .{ .fixed = 200 });

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 200), left.size.width);
    try std.testing.expectEqual(@as(f32, 200), right.size.width);
    try std.testing.expectEqual(@as(f32, 210), right.layout._global_x.?);

    // Opted in under `.start`, the gap is part of the overflow: 410 − 300 = 110, 55 each.
    left.size.shrink = 1;
    right.size.shrink = 1;
    try root.set_global_pos(a);
    try std.testing.expectApproxEqAbs(@as(f32, 145), left.size.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 145), right.size.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 155), right.layout._global_x.?, 0.001);

    // `space_between` ignores `gap`, so only 100 overflows.
    root.layout.flow.main = .space_between;
    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 150), left.size.width);
    try std.testing.expectEqual(@as(f32, 150), right.size.width);

    // A grower's `shrink` is ignored: it sits at its minimum and the fixed sibling shrinks.
    const root2 = try flex_row(a, 300);
    const grower = try flex_kid(a, "grower", root2, .grow);
    grower.size.shrink = 1;
    grower.size.min_width = 40;
    const wide = try flex_kid(a, "wide", root2, .{ .fixed = 400 });
    wide.size.shrink = 1;

    try root2.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 40), grower.size.width);
    try std.testing.expectApproxEqAbs(@as(f32, 260), wide.size.width, 0.001);
}

test "shrink: a fit_children parent and a wrapping parent never shrink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fit = try TestNode.create(a, "fit");
    _ = fit.with_size(Size.init(.fit_children, .{ .fixed = 50 }));
    _ = fit.with_layout(.top_left, .{ .dir = .row, .cross = .start });
    fit.size.max_width = 300; // even capped short of its children, a fit axis stays indefinite
    const f1 = try flex_kid(a, "f1", fit, .{ .fixed = 200 });
    f1.size.shrink = 1;
    const f2 = try flex_kid(a, "f2", fit, .{ .fixed = 200 });
    f2.size.shrink = 1;

    try fit.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 300), fit.size.width);
    try std.testing.expectEqual(@as(f32, 200), f1.size.width);
    try std.testing.expectEqual(@as(f32, 200), f2.size.width);

    const wrap = try TestNode.create(a, "wrap");
    _ = wrap.with_size(Size.initFixed(300, 50));
    _ = wrap.with_layout(.top_left, .{ .dir = .row, .wrap = true, .cross = .start });
    const w1 = try flex_kid(a, "w1", wrap, .{ .fixed = 200 });
    w1.size.shrink = 1;
    const w2 = try flex_kid(a, "w2", wrap, .{ .fixed = 200 });
    w2.size.shrink = 1;

    try wrap.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 200), w1.size.width);
    try std.testing.expectEqual(@as(f32, 200), w2.size.width);
    try std.testing.expectEqual(@as(f32, 0), w2.layout._global_x.?); // broke onto line 2
    try std.testing.expectEqual(@as(f32, 10), w2.layout._global_y.?);
}

test "weighted grow and shrink work on a column's main axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try TestNode.create(a, "col");
    _ = col.with_size(Size.initFixed(50, 300));
    _ = col.with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const top = try TestNode.pcreate(a, "top", col);
    _ = top.with_size(Size.init(.{ .fixed = 10 }, .{ .fixed = 200 })).with_layout(.relative, null);
    top.size.shrink = 1;
    const bottom = try TestNode.pcreate(a, "bottom", col);
    _ = bottom.with_size(Size.init(.{ .fixed = 10 }, .{ .fixed = 200 })).with_layout(.relative, null);
    bottom.size.shrink = 1;

    try col.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 150), top.size.height);
    try std.testing.expectEqual(@as(f32, 150), bottom.size.height);
    try std.testing.expectEqual(@as(f32, 150), bottom.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 10), top.size.width); // the cross axis is untouched

    const col2 = try TestNode.create(a, "col2");
    _ = col2.with_size(Size.initFixed(50, 300));
    _ = col2.with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const g1 = try TestNode.pcreate(a, "g1", col2);
    _ = g1.with_size(Size.init(.{ .fixed = 10 }, .grow)).with_layout(.relative, null);
    const g2 = try TestNode.pcreate(a, "g2", col2);
    _ = g2.with_size(Size.init(.{ .fixed = 10 }, .grow)).with_layout(.relative, null);
    g2.size.grow_weight = 2;

    try col2.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 100), g1.size.height);
    try std.testing.expectEqual(@as(f32, 200), g2.size.height);
}

/// Records what `stamp_walk` handed it, standing in for a `Ctx` — the walk takes its
/// sink as `anytype`, so its ordering and clip logic test without a context, a pool or
/// a window. `slots` names the keys that have an interaction slot; every other key is
/// a node that was never queried, which `stampRect` skips.
const StampLog = struct {
    const Entry = struct { key: u64, clip: ?geometry.Rect, parent: ?u64 };
    entries: std.ArrayList(Entry) = .empty,
    alloc: Allocator,
    slots: []const u64,

    fn stampRect(self: *StampLog, k: u64, r: geometry.Rect, clip: ?geometry.Rect, parent: ?u64) bool {
        _ = r;
        for (self.slots) |s| {
            if (s != k) continue;
            self.entries.append(self.alloc, .{ .key = k, .clip = clip, .parent = parent }) catch unreachable;
            return true;
        }
        return false;
    }
    fn deinit(self: *StampLog) void {
        self.entries.deinit(self.alloc);
    }
    fn indexOf(self: *StampLog, k: u64) ?usize {
        for (self.entries.items, 0..) |e, i| if (e.key == k) return i;
        return null;
    }
};

test "stamp order is paint order: a parent lands before its children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try TestNode.create(alloc, "root");
    _ = root.with_size(Size.initFixed(200, 200));
    _ = root.with_layout(.top_left, null);
    root.layout._global_x = 0;
    root.layout._global_y = 0;

    const outer = try TestNode.pcreate(alloc, "outer", root);
    _ = outer.with_size(Size.initFixed(100, 100));
    const inner = try TestNode.pcreate(alloc, "inner", outer);
    _ = inner.with_size(Size.initFixed(50, 50));
    try root.set_global_pos(alloc);

    var log = StampLog{ .alloc = std.testing.allocator, .slots = &.{ outer.key, inner.key } };
    defer log.deinit();
    stamp_rects(&log, root);

    // The child is stamped after its parent, so walking the list backwards reaches the
    // child first — which is what makes "topmost wins" agree with what the eye sees.
    try std.testing.expectEqual(@as(usize, 2), log.entries.items.len);
    try std.testing.expect(log.indexOf(outer.key).? < log.indexOf(inner.key).?);
}

test "stamp_walk hands down the nearest queried ancestor, skipping unqueried ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try TestNode.create(alloc, "root");
    _ = root.with_size(Size.initFixed(200, 200));
    _ = root.with_layout(.top_left, null);
    root.layout._global_x = 0;
    root.layout._global_y = 0;

    const row = try TestNode.pcreate(alloc, "row", root); // queried
    const wrapper = try TestNode.pcreate(alloc, "wrap", row); // plain layout div, never queried
    const btn = try TestNode.pcreate(alloc, "btn", wrapper); // queried
    _ = row.with_size(Size.initFixed(100, 40));
    _ = wrapper.with_size(Size.initFixed(60, 40));
    _ = btn.with_size(Size.initFixed(20, 20));
    try root.set_global_pos(alloc);

    var log = StampLog{ .alloc = std.testing.allocator, .slots = &.{ row.key, btn.key } };
    defer log.deinit();
    stamp_rects(&log, root);

    // The bubble chain has to skip the wrapper — it has no slot to carry the flag.
    const b = log.entries.items[log.indexOf(btn.key).?];
    try std.testing.expectEqual(row.key, b.parent.?);
    const r = log.entries.items[log.indexOf(row.key).?];
    try std.testing.expect(r.parent == null);
}

test "a .clip node crops its subtree's hit region but not its siblings'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try TestNode.create(alloc, "root");
    _ = root.with_size(Size.initFixed(400, 400));
    _ = root.with_layout(.top_left, .{ .dir = .column });
    root.layout._global_x = 0;
    root.layout._global_y = 0;

    const viewport = try TestNode.pcreate(alloc, "viewport", root);
    _ = viewport.with_size(Size.initFixed(100, 100));
    viewport.layout.overflow = .clip;
    const content = try TestNode.pcreate(alloc, "content", viewport);
    _ = content.with_size(Size.initFixed(100, 300)); // taller than the viewport

    const outside = try TestNode.pcreate(alloc, "outside", root); // sibling, uncropped
    _ = outside.with_size(Size.initFixed(100, 40));
    try root.set_global_pos(alloc);

    var log = StampLog{ .alloc = std.testing.allocator, .slots = &.{ content.key, outside.key } };
    defer log.deinit();
    stamp_rects(&log, root);

    const c = log.entries.items[log.indexOf(content.key).?];
    try std.testing.expectEqual(@as(f32, 100), c.clip.?.h); // cropped to the viewport
    const o = log.entries.items[log.indexOf(outside.key).?];
    try std.testing.expect(o.clip == null); // nothing crops a sibling of the viewport
}

test "offset displaces a placement without replacing it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try TestNode.create(alloc, "root");
    _ = root.with_size(Size.initFixed(200, 200));
    _ = root.with_layout(.top_left, null);
    root.layout._global_x = 0;
    root.layout._global_y = 0;

    // Anchored: centred, then pushed out along a radius the caller computed itself.
    const tile = try TestNode.pcreate(alloc, "tile", root);
    _ = tile.with_size(Size.initFixed(40, 40));
    _ = tile.with_layout(.center, null);
    tile.layout = tile.layout.with_offset(63, -36);

    // Flowed: still in the run, just nudged.
    const flowed = try TestNode.pcreate(alloc, "flowed", root);
    _ = flowed.with_size(Size.initFixed(10, 10));
    flowed.layout.offset_y = 5;

    try root.set_global_pos(alloc);

    // centre of 200 minus half of 40 = 80, plus the offset
    try std.testing.expectEqual(@as(f32, 80 + 63), tile.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 80 - 36), tile.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 5), flowed.layout._global_y.?);
}

test "an indexed child keeps its key across sibling order and re-keying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    const seven = try TestNode.pcreate_i(a, "row", 7, root);
    const two = try TestNode.pcreate_i(a, "row", 2, root);
    try std.testing.expect(seven.key != two.key);

    // The key comes from (id, index), never from the position among siblings: the same
    // index under an identically keyed parent, created first instead of second, matches.
    const again = try TestNode.create(a, "root");
    const two_first = try TestNode.pcreate_i(a, "row", 2, again);
    try std.testing.expectEqual(two.key, two_first.key);

    // Re-keying on attach folds the index again, so an assembled subtree keeps its identity.
    const holder = try TestNode.create(a, "holder");
    const item = try TestNode.create(a, "row");
    item.index = 5;
    try holder.add_child(a, item);
    try std.testing.expectEqual(key_i(holder.key, "row", 5), item.key);
    try std.testing.expectEqual(@as(?*TestNode, null), holder.duplicateSibling(seven));
}

test "a duplicate sibling key is detected and the structural path names it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try TestNode.create(a, "root");
    const panel = try TestNode.pcreate(a, "panel", root);
    const first = try TestNode.pcreate(a, "label", panel);
    const row = try TestNode.pcreate_i(a, "row", 3, panel);

    // A second "label" under the same parent keys identically; the detector finds the first.
    const twin = try TestNode.create(a, "label");
    twin.rekey(panel.key);
    try std.testing.expectEqual(@as(?*TestNode, first), panel.duplicateSibling(twin));
    // A different id, or the same id under another parent, is no duplicate.
    const other = try TestNode.create(a, "other");
    other.rekey(panel.key);
    try std.testing.expectEqual(@as(?*TestNode, null), panel.duplicateSibling(other));
    try std.testing.expectEqual(@as(?*TestNode, null), root.duplicateSibling(twin));

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("root/panel", panel.pathInto(&buf));
    try std.testing.expectEqualStrings("root/panel/row[3]", row.pathInto(&buf));
    // A buffer too small for the path yields the longest prefix of whole segments.
    var tiny: [6]u8 = undefined;
    try std.testing.expectEqualStrings("root", row.pathInto(&tiny));
}

// ---- ENGINE-05: height measured at the resolved width -----------------------------------

/// A fake wrapped-text measurer: the text is `data_width` px long on one line, so at width
/// `w` it breaks into `ceil(data_width / w)` lines of 10 px, with a baseline of 3. Records
/// the widths it was called with; `refuse` makes it return null (keep `data_height`).
const FakeMeasure = struct {
    log: ?*Log = null,
    refuse: bool = false,

    const Log = struct { calls: usize = 0, last_w: f32 = -1 };

    pub fn height_for_width(self: FakeMeasure, node: *TestNode, w: f32) ?features.Measured {
        if (self.log) |l| {
            l.calls += 1;
            l.last_w = w;
        }
        if (self.refuse) return null;
        const lines = @max(1, @ceil(node.size.data_width / w));
        return .{ .height = lines * 10, .baseline = 3 };
    }
};

/// A `measure_h` text-like leaf under `parent`: width rule `w`, height `.content`, a
/// single-line seed of `seed_w` × 7 with baseline 1 (so a re-measure is visible).
fn measured_leaf(a: std.mem.Allocator, id: []const u8, parent: *TestNode, w: features.SizeRule, seed_w: f32) !*TestNode {
    const k = try TestNode.pcreate(a, id, parent);
    _ = k.with_size(Size.init(w, .content)).with_layout(.relative, null);
    k.size.data_width = seed_w;
    k.size.data_height = 7;
    k.size.baseline = 1;
    k.size.measure_h = true;
    return k;
}

test "measure_h: a full-width leaf in a column is measured at the column width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(100, 200)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const leaf = try measured_leaf(a, "leaf", root, .{ .pct_of_parent = 1.0 }, 250);
    const after = try TestNode.pcreate(a, "after", root);
    _ = after.with_size(Size.initFixed(10, 10)).with_layout(.relative, null);

    var log: FakeMeasure.Log = .{};
    try root.set_global_pos_measured(a, FakeMeasure{ .log = &log });
    try std.testing.expectEqual(@as(usize, 1), log.calls);
    try std.testing.expectEqual(@as(f32, 100), log.last_w);
    try std.testing.expectEqual(@as(f32, 100), leaf.size.width);
    try std.testing.expectEqual(@as(f32, 30), leaf.size.height); // ceil(250/100) = 3 lines
    try std.testing.expectEqual(@as(f32, 3), leaf.size.baseline);
    try std.testing.expectEqual(@as(f32, 250), leaf.size.data_width); // the seed is untouched
    try std.testing.expectEqual(@as(f32, 30), after.layout._global_y.?);
}

test "measure_h: a shrunk leaf is measured at its shrunk width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 150 + 50 in a 100 row: the leaf (the only shrinker) gives up the 100 overflow.
    const root = try flex_row(a, 100);
    const leaf = try measured_leaf(a, "leaf", root, .content, 150);
    leaf.size.shrink = 1;
    _ = try flex_kid(a, "rigid", root, .{ .fixed = 50 });

    var log: FakeMeasure.Log = .{};
    try root.set_global_pos_measured(a, FakeMeasure{ .log = &log });
    try std.testing.expectEqual(@as(f32, 50), leaf.size.width);
    try std.testing.expectEqual(@as(f32, 50), log.last_w);
    try std.testing.expectEqual(@as(f32, 30), leaf.size.height); // ceil(150/50)
}

test "measure_h: a leaf widened by column stretch is measured at the stretched width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(120, 200)).with_layout(.top_left, .{ .dir = .column, .cross = .stretch });
    const leaf = try measured_leaf(a, "leaf", root, .content, 60);

    var log: FakeMeasure.Log = .{};
    try root.set_global_pos_measured(a, FakeMeasure{ .log = &log });
    try std.testing.expectEqual(@as(f32, 120), leaf.size.width);
    try std.testing.expectEqual(@as(f32, 120), log.last_w);
    try std.testing.expectEqual(@as(f32, 10), leaf.size.height); // one line, not the 7 seed
}

test "measure_h: a column grow sibling takes the remainder after the measured height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(100, 100)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const leaf = try measured_leaf(a, "leaf", root, .{ .pct_of_parent = 1.0 }, 250);
    const rest = try TestNode.pcreate(a, "rest", root);
    _ = rest.with_size(Size.init(.{ .fixed = 10 }, .grow)).with_layout(.relative, null);

    try root.set_global_pos_measured(a, FakeMeasure{});
    try std.testing.expectEqual(@as(f32, 30), leaf.size.height);
    try std.testing.expectEqual(@as(f32, 70), rest.size.height);
    try std.testing.expectEqual(@as(f32, 30), rest.layout._global_y.?);
}

test "measure_h: a row stretch sibling is raised to the measured height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.{ .fixed = 100 }, .fit_children)).with_layout(.top_left, .{ .dir = .row, .cross = .stretch });
    const leaf = try measured_leaf(a, "leaf", root, .{ .pct_of_parent = 0.5 }, 120);
    const side = try TestNode.pcreate(a, "side", root);
    _ = side.with_size(Size.init(.{ .fixed = 50 }, .fit_children)).with_layout(.relative, null);

    try root.set_global_pos_measured(a, FakeMeasure{});
    try std.testing.expectEqual(@as(f32, 30), leaf.size.height); // ceil(120/50)
    try std.testing.expectEqual(@as(f32, 30), root.size.height);
    try std.testing.expectEqual(@as(f32, 30), side.size.height);
}

test "measure_h: a baseline row aligns on the measured baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.init(.{ .fixed = 200 }, .fit_children)).with_layout(.top_left, .{ .dir = .row, .cross = .baseline });
    const leaf = try measured_leaf(a, "leaf", root, .{ .pct_of_parent = 0.5 }, 250);
    const chip = try TestNode.pcreate(a, "chip", root);
    _ = chip.with_size(Size.initFixed(50, 20)).with_layout(.relative, null);

    try root.set_global_pos_measured(a, FakeMeasure{});
    // Leaf: 3 lines = 30 tall, baseline 3 → ascent 27. Chip: ascent 20, descent 0.
    try std.testing.expectEqual(@as(f32, 30), leaf.size.height);
    try std.testing.expectEqual(@as(f32, 3), leaf.size.baseline);
    try std.testing.expectEqual(@as(f32, 30), root.size.height); // 27 + 3
    try std.testing.expectEqual(@as(f32, 0), leaf.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 7), chip.layout._global_y.?); // 27 − 20
}

test "measure_h: under a fit_children parent the width falls back to the seed, the height follows the measurer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(300, 300)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const mid = try TestNode.pcreate(a, "mid", root);
    _ = mid.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, .{ .dir = .column, .cross = .start });
    const leaf = try measured_leaf(a, "leaf", mid, .{ .pct_of_parent = 1.0 }, 80);

    var log: FakeMeasure.Log = .{};
    try root.set_global_pos_measured(a, FakeMeasure{ .log = &log });
    try std.testing.expectEqual(@as(f32, 80), leaf.size.width); // indefinite: the seed
    try std.testing.expectEqual(@as(f32, 80), log.last_w);
    try std.testing.expectEqual(@as(f32, 10), leaf.size.height); // one line, from the measurer
    try std.testing.expectEqual(@as(f32, 80), mid.size.width);
    try std.testing.expectEqual(@as(f32, 10), mid.size.height);
}

// ---- ENGINE-06a: a zero-seed measure_h cell takes what layout gives it -------------------

test "measure_h: a zero-width seed under a fit_children parent contributes no width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(300, 100)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const mid = try TestNode.pcreate(a, "mid", root);
    _ = mid.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, .{ .dir = .row, .cross = .start });
    const label = try TestNode.pcreate(a, "label", mid);
    _ = label.with_size(Size.initFixed(40, 10)).with_layout(.relative, null);
    const cell = try measured_leaf(a, "cell", mid, .{ .pct_of_parent = 1.0 }, 0);

    var log: FakeMeasure.Log = .{};
    try root.set_global_pos_measured(a, FakeMeasure{ .log = &log, .refuse = true });
    try std.testing.expectEqual(@as(f32, 40), mid.size.width); // the cell adds nothing
    try std.testing.expectEqual(@as(f32, 0), cell.size.width);
    try std.testing.expectEqual(@as(f32, 0), log.last_w); // the measurer sees the 0
    try std.testing.expectEqual(@as(f32, 7), cell.size.height); // null keeps the seed height
}

test "measure_h: a zero-seed grow cell takes the row remainder after a gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The research title row: [title: grow row, gap 12 | heading 97, cell grow] [tools 327].
    const bar = try TestNode.create(a, "bar");
    _ = bar.with_size(Size.init(.{ .fixed = 816 }, .fit_children)).with_layout(.top_left, .{ .dir = .row, .main = .space_between, .cross = .center });
    const title = try TestNode.pcreate(a, "title", bar);
    _ = title.with_size(Size.init(.grow, .fit_children)).with_layout(.relative, .{ .dir = .row, .cross = .baseline });
    title.layout.gap = 12;
    const heading = try TestNode.pcreate(a, "heading", title);
    _ = heading.with_size(Size.initFixed(97, 28)).with_layout(.relative, null);
    const cell = try measured_leaf(a, "cell", title, .grow, 0);
    const tools = try TestNode.pcreate(a, "tools", bar);
    _ = tools.with_size(Size.initFixed(327, 24)).with_layout(.relative, null);

    var log: FakeMeasure.Log = .{};
    try bar.set_global_pos_measured(a, FakeMeasure{ .log = &log, .refuse = true });
    try std.testing.expectEqual(@as(f32, 489), title.size.width); // 816 − 327
    try std.testing.expectEqual(@as(f32, 380), cell.size.width); // 489 − 97 − 12
    try std.testing.expectEqual(@as(f32, 380), log.last_w);
    try std.testing.expectEqual(@as(f32, 109), cell.layout._global_x.?); // 97 + 12
    try std.testing.expectEqual(@as(f32, 489), tools.layout._global_x.?);
}

test "measure_h: the plain solve keeps the build-time data_height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(100, 200)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const leaf = try measured_leaf(a, "leaf", root, .{ .pct_of_parent = 1.0 }, 250);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 7), leaf.size.height);
    try std.testing.expectEqual(@as(f32, 1), leaf.size.baseline);
}

test "measure_h: a null measure keeps data_height, and nodes without measure_h are never asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(100, 200)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const leaf = try measured_leaf(a, "leaf", root, .{ .pct_of_parent = 1.0 }, 250);
    const plain = try measured_leaf(a, "plain", root, .{ .pct_of_parent = 1.0 }, 250);
    plain.size.measure_h = false;

    var log: FakeMeasure.Log = .{};
    try root.set_global_pos_measured(a, FakeMeasure{ .log = &log, .refuse = true });
    try std.testing.expectEqual(@as(usize, 1), log.calls); // only the opted-in leaf
    try std.testing.expectEqual(@as(f32, 7), leaf.size.height);
    try std.testing.expectEqual(@as(f32, 1), leaf.size.baseline);
    try std.testing.expectEqual(@as(f32, 7), plain.size.height);
}

test "measure_h: the profiled measured solve reports the measure walk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try TestNode.create(a, "root");
    _ = root.with_size(Size.initFixed(100, 200)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    const leaf = try measured_leaf(a, "leaf", root, .{ .pct_of_parent = 1.0 }, 250);

    const Ticker = struct {
        var t: u64 = 0;
        fn now(_: *const anyopaque) u64 {
            t += 10;
            return t;
        }
    };
    const clock: @import("profile.zig").Clock = .{ .ctx = &Ticker.t, .nowFn = Ticker.now };
    const s = try root.set_global_pos_measured_profiled(a, clock, FakeMeasure{});
    try std.testing.expectEqual(@as(u64, 10), s.measure);
    try std.testing.expectEqual(@as(u64, 20), s.intrinsic);
    try std.testing.expectEqual(@as(u64, 20), s.relative);
    try std.testing.expectEqual(@as(u64, 10), s.placement);
    try std.testing.expectEqual(@as(u64, 60), s.total());
    try std.testing.expectEqual(@as(f32, 30), leaf.size.height);

    // The plain profiled solve has no measure walk at all.
    const p = try root.set_global_pos_profiled(a, clock);
    try std.testing.expectEqual(@as(u64, 0), p.measure);
    try std.testing.expectEqual(@as(u64, 50), p.total());
}

// ---- ENGINE-06b: shared grid tracks ------------------------------------------------------

const Track = features.Track;
const TrackSet = features.TrackSet;

/// A `TrackSet` over `spec` with arena scratch (left undefined: the owner resets it).
fn track_set(a: std.mem.Allocator, spec: []const Track, gap: f32) !*TrackSet {
    const set = try a.create(TrackSet);
    set.* = .{
        .tracks = spec,
        .col_gap = gap,
        .auto_max = try a.alloc(f32, spec.len),
        .widths = try a.alloc(f32, spec.len),
    };
    return set;
}

/// A column root `w` × 400 owning `set`.
fn track_owner(a: std.mem.Allocator, w: f32, set: *TrackSet) !*TestNode {
    const root = try TestNode.create(a, "owner");
    _ = root.with_size(Size.initFixed(w, 400)).with_layout(.top_left, .{ .dir = .column, .cross = .start });
    root.layout.track_owner = set;
    return root;
}

/// A participant row under `parent`, width rule `w`, top-aligned cells.
fn track_row(a: std.mem.Allocator, id: []const u8, parent: *TestNode, set: *TrackSet, w: features.SizeRule) !*TestNode {
    const r = try TestNode.pcreate(a, id, parent);
    _ = r.with_size(Size.init(w, .fit_children)).with_layout(.relative, .{ .dir = .row, .cross = .start });
    r.layout.track_row = set;
    return r;
}

/// A content-sized cell `w` × `h` (its width is the track's once solved).
fn track_cell(a: std.mem.Allocator, id: []const u8, row: *TestNode, w: f32, h: f32) !*TestNode {
    const c = try TestNode.pcreate(a, id, row);
    _ = c.with_size(Size.initContent(w, h)).with_layout(.relative, null);
    return c;
}

const stall_spec = [_]Track{
    .{ .basis = .{ .fr = 1 } }, // minmax(0, 1fr)
    .{ .basis = .{ .px = 86 } },
    .{ .basis = .{ .px = 86 } },
    .{ .basis = .{ .px = 143 } },
};

test "tracks: minmax(0,1fr) 86 86 143 fill a padded 600 row, cells at their tracks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try track_set(a, &stall_spec, 10);
    const root = try track_owner(a, 600, set);
    const row = try track_row(a, "row", root, set, .{ .pct_of_parent = 1.0 });
    row.size.padding = features.Padding.initEach(0, 20, 0, 20);
    row.layout.flow.cross = .center;
    const item = try track_cell(a, "item", row, 400, 10); // wider than its track: no effect
    item.size.padding = features.Padding.initEach(0, 4, 0, 4);
    const fill = try TestNode.pcreate(a, "fill", item);
    _ = fill.with_size(Size.init(.{ .pct_of_parent = 1.0 }, .{ .fixed = 10 })).with_layout(.relative, null);
    const qty = try track_cell(a, "qty", row, 20, 30);
    const price = try track_cell(a, "price", row, 20, 10);
    const who = try track_cell(a, "who", row, 20, 10);

    try root.set_global_pos(a);
    // 560 inner − 315 − 3 × 10 = 215 for the fr track; the widths fill the inner exactly.
    try std.testing.expectEqualSlices(f32, &.{ 215, 86, 86, 143 }, set.widths);
    try std.testing.expectEqual(@as(f32, 215), item.size.width); // border box, padding inside
    try std.testing.expectEqual(@as(f32, 207), fill.size.width);
    try std.testing.expectEqual(@as(f32, 24), fill.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 20), item.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 245), qty.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 341), price.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 437), who.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 580), who.layout._global_x.? + who.size.width);
    // Cross alignment is the row's: centered in the 30 line.
    try std.testing.expectEqual(@as(f32, 30), row.size.height);
    try std.testing.expectEqual(@as(f32, 10), item.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 0), qty.layout._global_y.?);
}

test "tracks: auto is the widest cell over every participant, at any depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .auto }, .{ .basis = .{ .fr = 1 } } };
    const set = try track_set(a, &spec, 0);
    const root = try track_owner(a, 600, set);
    // The head right under the owner; the rows in scroll → content → wrap, fitted.
    const head = try track_row(a, "head", root, set, .{ .pct_of_parent = 1.0 });
    const h0 = try track_cell(a, "h0", head, 40, 10);
    _ = try track_cell(a, "h1", head, 5, 10);
    const scroll = try TestNode.pcreate(a, "scroll", root);
    _ = scroll.with_size(Size.initFixed(600, 100)).with_layout(.relative, .{ .dir = .column, .cross = .start });
    const content = try TestNode.pcreate(a, "content", scroll);
    _ = content.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, .{ .dir = .column, .cross = .start });
    const wrap = try TestNode.pcreate(a, "wrap", content);
    _ = wrap.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, .{ .dir = .column, .cross = .start });
    const r1 = try track_row(a, "r1", wrap, set, .fit_children);
    const c1 = try track_cell(a, "c1", r1, 55, 10);
    _ = try track_cell(a, "c1b", r1, 5, 10);
    const r2 = try track_row(a, "r2", wrap, set, .fit_children);
    const c2 = try track_cell(a, "c2", r2, 70, 10); // the widest, measured last
    const c2b = try track_cell(a, "c2b", r2, 5, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 70), set.auto_max[0]);
    try std.testing.expectEqual(@as(f32, 70), h0.size.width);
    try std.testing.expectEqual(@as(f32, 70), c1.size.width);
    try std.testing.expectEqual(@as(f32, 70), c2.size.width);
    // A fitted row is Σ base: 70 + the fr min 0, so the fr cell gets nothing. r1 was measured
    // before r2 reported 70, and the owner's redo brings it (and its fitted ancestors) up.
    try std.testing.expectEqual(@as(f32, 70), r1.size.width);
    try std.testing.expectEqual(@as(f32, 70), wrap.size.width);
    try std.testing.expectEqual(@as(f32, 70), content.size.width);
    try std.testing.expectEqual(@as(f32, 0), c2b.size.width);
    try std.testing.expectEqual(@as(f32, 70), c2b.layout._global_x.?);
    // The head is 600 wide, so its fr cell takes the rest.
    try std.testing.expectEqual(@as(f32, 530), head.children.items[1].size.width);
}

test "tracks: auto ignores a spanning cell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .auto }, .{ .basis = .auto } };
    const set = try track_set(a, &spec, 4);
    const root = try track_owner(a, 600, set);
    const r1 = try track_row(a, "r1", root, set, .{ .pct_of_parent = 1.0 });
    const wide = try track_cell(a, "wide", r1, 300, 10);
    wide.layout.cell_span = 2;
    const r2 = try track_row(a, "r2", root, set, .{ .pct_of_parent = 1.0 });
    _ = try track_cell(a, "a", r2, 30, 10);
    const b = try track_cell(a, "b", r2, 40, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqualSlices(f32, &.{ 30, 40 }, set.widths); // no fr: slack at the end
    try std.testing.expectEqual(@as(f32, 74), wide.size.width); // 30 + 4 + 40
    try std.testing.expectEqual(@as(f32, 34), b.layout._global_x.?);
}

test "tracks: fr weights split 1:2, and a capped fr releases its excess to the others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const weighted = [_]Track{ .{ .basis = .{ .fr = 1 } }, .{ .basis = .{ .fr = 2 } } };
    const set = try track_set(a, &weighted, 0);
    const root = try track_owner(a, 300, set);
    const row = try track_row(a, "row", root, set, .{ .pct_of_parent = 1.0 });
    _ = try track_cell(a, "a", row, 0, 10);
    _ = try track_cell(a, "b", row, 0, 10);
    try root.set_global_pos(a);
    try std.testing.expectEqualSlices(f32, &.{ 100, 200 }, set.widths);

    // 1 : 2 (max 100) : 1 in 400. Round one offers 100 / 200 / 100; the middle keeps 100
    // and the other 100 goes to the outer two, 50 each.
    const capped = [_]Track{ .{ .basis = .{ .fr = 1 } }, .{ .basis = .{ .fr = 2 }, .max = 100 }, .{ .basis = .{ .fr = 1 } } };
    set.* = (try track_set(a, &capped, 0)).*;
    root.size.w = .{ .fixed = 400 };
    _ = try track_cell(a, "c", row, 0, 10);
    try root.set_global_pos(a);
    try std.testing.expectEqualSlices(f32, &.{ 150, 100, 150 }, set.widths);
}

test "tracks: shrink_order gives way by order, each to its floor, and the residue overflows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{
        .{ .basis = .{ .px = 100 }, .min = 40, .shrink_order = 0 },
        .{ .basis = .{ .px = 100 }, .min = 50, .shrink_order = 1 },
        .{ .basis = .{ .px = 100 }, .min = 80, .shrink_order = 2 },
        .{ .basis = .{ .px = 50 } }, // never shrinks
    };
    const set = try track_set(a, &spec, 0);
    set.solve(300); // 50 over: order 0 alone
    try std.testing.expectEqualSlices(f32, &.{ 50, 100, 100, 50 }, set.widths);
    set.solve(230); // 120 over: order 0 to 40 (60), order 1 to 50 (50), order 2 gives 10
    try std.testing.expectEqualSlices(f32, &.{ 40, 50, 90, 50 }, set.widths);
    set.solve(100); // 250 over: every floor (140), the other 110 overflows
    try std.testing.expectEqualSlices(f32, &.{ 40, 50, 80, 50 }, set.widths);

    // One order shares in proportion to (base − min): 100 and 50 over floors 0 give 20 and 10.
    const shared = [_]Track{
        .{ .basis = .{ .px = 100 }, .shrink_order = 0 },
        .{ .basis = .{ .px = 50 }, .shrink_order = 0 },
    };
    const s2 = try track_set(a, &shared, 0);
    s2.solve(120);
    try std.testing.expectEqualSlices(f32, &.{ 80, 40 }, s2.widths);
}

/// `capital_row.fitted`'s arithmetic, restated for the golden test: the excess over the
/// surface comes out of WHAT CHANGES (if shown), then the recipe, then the cost, each to its
/// floor. Lanes in `capital_row.columns` order: recipe, cost, time, effect, state, corner.
fn fitted_ref(lanes: [6]f32, shown: [6]bool, surface: f32) [6]f32 {
    const row_gap: f32 = 8;
    const row_pad_x: f32 = 6;
    const scroll_gutter: f32 = 8;
    var width: f32 = 0;
    var n: f32 = 0;
    for (lanes, shown) |w, s| if (s) {
        width += w;
        n += 1;
    };
    const table = width + (n - 1) * row_gap + row_pad_x * 2;
    var out = lanes;
    var excess = table + scroll_gutter - surface;
    if (excess <= 0) return out;
    if (shown[3]) {
        const take = @min(excess, @max(0, out[3] - 70));
        out[3] -= take;
        excess -= take;
    }
    const from_recipe = @min(excess, @max(0, out[0] - 88));
    out[0] -= from_recipe;
    excess -= from_recipe;
    out[1] -= @min(excess, @max(0, out[1] - 56));
    return out;
}

test "tracks: priority shrink reproduces capital_row.fitted for Act I" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Act I (`capital_row.Widths{}`): effect is 178 less the 8px scroll gutter.
    const lanes = [6]f32{ 118, 74, 42, 170, 76, 54 };
    const variants = [_][6]bool{
        .{ true, true, true, true, true, true },
        .{ true, true, true, false, true, true }, // WHAT CHANGES dropped (w440)
        .{ true, true, false, false, true, true }, // and TIME (w560)
    };
    for (variants) |shown| {
        const spec = [_]Track{
            .{ .basis = .{ .px = lanes[0] }, .min = 88, .shrink_order = 1, .hidden = !shown[0] },
            .{ .basis = .{ .px = lanes[1] }, .min = 56, .shrink_order = 2, .hidden = !shown[1] },
            .{ .basis = .{ .px = lanes[2] }, .hidden = !shown[2] },
            .{ .basis = .{ .px = lanes[3] }, .min = 70, .shrink_order = 0, .hidden = !shown[3] },
            .{ .basis = .{ .px = lanes[4] }, .hidden = !shown[4] },
            .{ .basis = .{ .px = lanes[5] }, .hidden = !shown[5] },
        };
        const set = try track_set(a, &spec, 8);
        var surface: f32 = 300;
        while (surface <= 640) : (surface += 7) {
            // The row is the surface less the scroll gutter, its content box less 2 × 6 padding.
            set.solve(surface - 8 - 12);
            const want = fitted_ref(lanes, shown, surface);
            for (0..6) |t| {
                const expect: f32 = if (shown[t]) want[t] else 0;
                try std.testing.expectEqual(expect, set.widths[t]);
            }
        }
    }
    // Spot values, all lanes shown: 520 takes 74 from WHAT CHANGES; 470 floors it and takes
    // 24 from the recipe; 400 floors all three and 46 overflows.
    const all = [_]Track{
        .{ .basis = .{ .px = 118 }, .min = 88, .shrink_order = 1 },
        .{ .basis = .{ .px = 74 }, .min = 56, .shrink_order = 2 },
        .{ .basis = .{ .px = 42 } },
        .{ .basis = .{ .px = 170 }, .min = 70, .shrink_order = 0 },
        .{ .basis = .{ .px = 76 } },
        .{ .basis = .{ .px = 54 } },
    };
    const set = try track_set(a, &all, 8);
    set.solve(500);
    try std.testing.expectEqualSlices(f32, &.{ 118, 74, 42, 96, 76, 54 }, set.widths);
    set.solve(450);
    try std.testing.expectEqualSlices(f32, &.{ 94, 74, 42, 70, 76, 54 }, set.widths);
    set.solve(380);
    try std.testing.expectEqualSlices(f32, &.{ 88, 56, 42, 70, 76, 54 }, set.widths);
}

test "tracks: a hidden track is 0 wide, drops one gap, and implicit placement skips it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .{ .px = 50 } }, .{ .basis = .{ .px = 60 }, .hidden = true }, .{ .basis = .{ .px = 70 } } };
    const set = try track_set(a, &spec, 10);
    const root = try track_owner(a, 600, set);
    const row = try track_row(a, "row", root, set, .fit_children);
    const c0 = try track_cell(a, "a", row, 1, 10);
    const c1 = try track_cell(a, "b", row, 1, 10);
    const r2 = try track_row(a, "r2", root, set, .fit_children);
    const all = try track_cell(a, "all", r2, 1, 10);
    all.layout.cell_span = 3;

    try root.set_global_pos(a);
    try std.testing.expectEqualSlices(f32, &.{ 50, 0, 70 }, set.widths);
    try std.testing.expectEqual(@as(f32, 130), row.size.width); // 50 + 10 + 70
    try std.testing.expectEqual(@as(f32, 50), c0.size.width);
    try std.testing.expectEqual(@as(f32, 60), c1.layout._global_x.?); // track 2, after one gap
    try std.testing.expectEqual(@as(f32, 70), c1.size.width);
    try std.testing.expectEqual(@as(f32, 130), all.size.width); // the hidden track adds no gap
}

test "tracks: an explicit cell_col leaves a hole, and span 2 is w0 + gap + w1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .{ .px = 50 } }, .{ .basis = .{ .px = 60 } }, .{ .basis = .{ .px = 70 } } };
    const set = try track_set(a, &spec, 10);
    const root = try track_owner(a, 600, set);
    const r1 = try track_row(a, "r1", root, set, .{ .pct_of_parent = 1.0 });
    const first = try track_cell(a, "first", r1, 1, 10);
    const last = try track_cell(a, "last", r1, 1, 10);
    last.layout.cell_col = 2;
    const r2 = try track_row(a, "r2", root, set, .{ .pct_of_parent = 1.0 });
    const pair = try track_cell(a, "pair", r2, 1, 10);
    pair.layout.cell_span = 2;
    const after = try track_cell(a, "after", r2, 1, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 0), first.layout._global_x.?);
    try std.testing.expectEqual(@as(f32, 130), last.layout._global_x.?); // 50 + 10 + 60 + 10
    try std.testing.expectEqual(@as(f32, 70), last.size.width);
    try std.testing.expectEqual(@as(f32, 120), pair.size.width); // 50 + 10 + 60
    try std.testing.expectEqual(@as(f32, 130), after.layout._global_x.?);
}

test "tracks: a measure_h leaf in a cell is measured at the track width, and a 1.0 grandchild fills it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .{ .fr = 1 } }, .{ .basis = .{ .px = 100 } } };
    const set = try track_set(a, &spec, 0);
    const root = try track_owner(a, 300, set);
    const row = try track_row(a, "row", root, set, .{ .pct_of_parent = 1.0 });
    // A fit_children cell: without the track it would be indefinite for its children.
    const cell = try TestNode.pcreate(a, "cell", row);
    _ = cell.with_size(Size.init(.fit_children, .fit_children)).with_layout(.relative, .{ .dir = .column, .cross = .start });
    const leaf = try measured_leaf(a, "leaf", cell, .{ .pct_of_parent = 1.0 }, 450);
    const bar = try TestNode.pcreate(a, "bar", cell);
    _ = bar.with_size(Size.init(.{ .pct_of_parent = 1.0 }, .{ .fixed = 2 })).with_layout(.relative, null);
    _ = try track_cell(a, "side", row, 10, 10);

    var log: FakeMeasure.Log = .{};
    try root.set_global_pos_measured(a, FakeMeasure{ .log = &log });
    try std.testing.expectEqual(@as(f32, 200), cell.size.width);
    try std.testing.expectEqual(@as(f32, 200), log.last_w);
    try std.testing.expectEqual(@as(f32, 30), leaf.size.height); // ceil(450 / 200) lines
    try std.testing.expectEqual(@as(f32, 200), bar.size.width);
    try std.testing.expectEqual(@as(f32, 32), row.size.height);
}

test "tracks: a fit_children participant is its tracks' base plus gaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .{ .px = 50 } }, .{ .basis = .auto }, .{ .basis = .{ .fr = 1 }, .min = 20 } };
    const set = try track_set(a, &spec, 5);
    const root = try track_owner(a, 600, set);
    const row = try track_row(a, "row", root, set, .fit_children);
    _ = try track_cell(a, "a", row, 999, 10);
    _ = try track_cell(a, "b", row, 33, 10);
    const c = try track_cell(a, "c", row, 999, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 113), row.size.width); // 50 + 33 + 20 + 2 × 5
    try std.testing.expectEqual(@as(f32, 20), c.size.width); // no free space: the fr min
    try std.testing.expectEqual(@as(f32, 93), c.layout._global_x.?);
}

test "tracks: an anchored child of a participant is not a cell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .{ .px = 50 } }, .{ .basis = .{ .px = 60 } } };
    const set = try track_set(a, &spec, 0);
    const root = try track_owner(a, 600, set);
    const row = try track_row(a, "row", root, set, .{ .fixed = 200 });
    _ = try track_cell(a, "a", row, 1, 10);
    const badge = try TestNode.pcreate(a, "badge", row);
    _ = badge.with_size(Size.initFixed(12, 8)).with_layout(.top_right, null);
    const b = try track_cell(a, "b", row, 1, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 50), b.layout._global_x.?); // track 1, the badge skipped
    try std.testing.expectEqual(@as(f32, 12), badge.size.width);
    try std.testing.expectEqual(@as(f32, 188), badge.layout._global_x.?); // its own anchor
}

test "tracks: scroll_y on an ancestor shifts participants and their cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try track_set(a, &stall_spec, 10);
    const root = try track_owner(a, 600, set);
    root.layout.scroll_y = 15;
    const r1 = try track_row(a, "r1", root, set, .{ .pct_of_parent = 1.0 });
    const c1 = try track_cell(a, "c1", r1, 1, 10);
    const r2 = try track_row(a, "r2", root, set, .{ .pct_of_parent = 1.0 });
    _ = try track_cell(a, "c2", r2, 1, 10);
    const who = try track_cell(a, "who", r2, 1, 10);

    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, -15), r1.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, -15), c1.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, -5), r2.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, -5), who.layout._global_y.?);
    try std.testing.expectEqual(@as(f32, 265), who.layout._global_x.?); // 255 + 10
}

test "tracks: a re-solve resets the set, so it repeats exactly and follows changed cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]Track{ .{ .basis = .auto }, .{ .basis = .{ .fr = 1 } }, .{ .basis = .{ .px = 40 } } };
    const set = try track_set(a, &spec, 6);
    const root = try track_owner(a, 400, set);
    const r1 = try track_row(a, "r1", root, set, .{ .pct_of_parent = 1.0 });
    const wide = try track_cell(a, "wide", r1, 90, 10);
    const f1 = try track_cell(a, "f1", r1, 1, 10);
    const r2 = try track_row(a, "r2", root, set, .fit_children);
    _ = try track_cell(a, "n2", r2, 30, 10);
    const tail = try track_cell(a, "f2", r2, 1, 10);
    _ = try track_cell(a, "p2", r2, 1, 10);

    try root.set_global_pos(a);
    const first = [_]f32{ set.widths[0], set.widths[1], set.widths[2], r2.size.width, tail.layout._global_x.? };
    try root.set_global_pos(a);
    const again = [_]f32{ set.widths[0], set.widths[1], set.widths[2], r2.size.width, tail.layout._global_x.? };
    try std.testing.expectEqualSlices(f32, &first, &again);
    try std.testing.expectEqual(@as(f32, 258), f1.size.width); // 400 − 90 − 40 − 2 × 6
    try std.testing.expectEqual(@as(f32, 142), r2.size.width); // fitted: the fr track gets 0
    try std.testing.expectEqual(@as(f32, 96), tail.layout._global_x.?);

    // The widest cell narrows: without the owner's reset the old 90 would stay the max.
    wide.size.data_width = 20;
    try root.set_global_pos(a);
    try std.testing.expectEqual(@as(f32, 30), set.auto_max[0]);
    try std.testing.expectEqual(@as(f32, 82), r2.size.width); // 30 + 0 + 40 + 2 × 6
}
