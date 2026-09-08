//! UI widget-state key-cache: pools + handles.
//!
//! Persistence substrate for the immediate-mode building language. Each cached
//! state type `T` gets its own `Pool(T)` — a slot map keyed by a `u64` widget
//! key. Widgets store the returned `u32` index (a handle), never a raw pointer,
//! so a pool growing/reallocating never dangles anyone: dereference through the
//! live pool at point of use. Removed slots become holes in a free-list (we
//! never compact), so live indices are stable for the lifetime of a slot.
//!
//! See `../ui/README.md` — "The key-cache: pools + handles".

const std = @import("std");

/// Deterministic, frame-stable key from a parent seed + a local id string.
pub fn key(seed: u64, id: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, id);
}

/// Key for a loop instance: folds an index into the local id.
pub fn key_i(seed: u64, id: []const u8, i: usize) u64 {
    return std.hash.Wyhash.hash(key(seed, id), std.mem.asBytes(&i));
}

/// A slot map of `T`, keyed by `u64`. Hands out `u32` indices (handles).
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Slot = struct {
            value: T,
            key: u64,
            touched: u64,
            live: bool,
        };

        /// Construct a fresh slot value. A pooled container type may declare
        /// `pub fn init() T` to establish semantic defaults; otherwise the type opts
        /// into the zeroable fallback. Initialization runs for both appended slots and
        /// reused holes, after the previous occupant has been evicted.
        ///
        /// The `@typeInfo` guard keeps `@hasDecl` legal for scalar `T` (for example the
        /// `Pool(u32)` used in tests). A declared `init` is part of the pool contract:
        /// it must take no arguments and return `T` directly.
        fn initialValue() T {
            return switch (@typeInfo(T)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "init")) T.init() else std.mem.zeroes(T),
                else => std.mem.zeroes(T),
            };
        }

        /// Release a slot's resources before its storage is dropped. If `T` declares
        /// `pub fn deinit(self: *T) void`, call it; otherwise a no-op. This is the
        /// eviction hook: a POD state (`TextState`, `ScrollState`) needs nothing, but a
        /// state that *owns* a resource — an SVG feature caching a rasterized
        /// `sdl.Texture` — would otherwise leak it when its node disappears.
        /// The `@typeInfo` guard keeps `@hasDecl` legal for non-container `T` (e.g. the
        /// `Pool(u32)` in tests). Convention: `deinit` takes no allocator — a cached
        /// GPU/handle resource frees itself; anything needing the gpa isn't pool-cached.
        fn evict(value: *T) void {
            switch (@typeInfo(T)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "deinit")) value.deinit(),
                else => {},
            }
        }

        slots: std.ArrayList(Slot) = .empty,
        free: std.ArrayList(u32) = .empty,
        index: std.AutoHashMapUnmanaged(u64, u32) = .{},

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            // Evict live slots (dead ones were already evicted at prune). Only these
            // can still own a resource at teardown — e.g. an on-screen SVG's texture.
            for (self.slots.items) |*slot| if (slot.live) evict(&slot.value);
            self.slots.deinit(alloc);
            self.free.deinit(alloc);
            self.index.deinit(alloc);
        }

        /// Find-or-create the slot for `k`, mark it touched this frame, return its index.
        pub fn acquire(self: *Self, alloc: std.mem.Allocator, k: u64, frame: u64) std.mem.Allocator.Error!u32 {
            if (self.index.get(k)) |idx| {
                self.slots.items[idx].touched = frame;
                return idx;
            }
            // Reuse a hole if one exists, else append a fresh slot. Both paths apply
            // the same initialization contract so a reused handle cannot inherit the
            // previous key's state.
            if (self.free.items.len != 0) {
                const idx = self.free.items[self.free.items.len - 1];
                self.free.items.len -= 1;
                self.slots.items[idx] = .{ .value = initialValue(), .key = k, .touched = frame, .live = true };
                try self.index.put(alloc, k, idx);
                return idx;
            }
            const idx: u32 = @intCast(self.slots.items.len);
            try self.slots.append(alloc, .{ .value = initialValue(), .key = k, .touched = frame, .live = true });
            try self.index.put(alloc, k, idx);
            return idx;
        }

        /// Dereference a handle. Never hold the result across another `acquire`
        /// on this pool — the backing array may grow. Store the index instead.
        pub fn get(self: *Self, idx: u32) *T {
            return &self.slots.items[idx].value;
        }

        /// Free every live slot not touched this frame (into the free-list). A pruned
        /// slot's value is `evict`ed here (releasing any resource it owns) before it
        /// becomes a hole — so by the time `acquire` reuses that hole, it's already clean.
        pub fn prune(self: *Self, alloc: std.mem.Allocator, frame: u64) std.mem.Allocator.Error!void {
            for (self.slots.items, 0..) |*slot, i| {
                if (slot.live and slot.touched != frame) {
                    evict(&slot.value);
                    slot.live = false;
                    _ = self.index.remove(slot.key);
                    try self.free.append(alloc, @intCast(i));
                }
            }
        }
    };
}

/// Comptime-generate a struct holding one `Pool(T)` per type declared in `ns`.
/// Mirrors `world.Storages`. The owning `Ctx` looks pools up by element type.
pub fn Pools(comptime ns: type) type {
    const decls = @typeInfo(ns).@"struct".decls;
    var fields: [decls.len]std.builtin.Type.StructField = undefined;
    for (decls, 0..) |d, i| {
        const v = @field(ns, d.name);
        if (@TypeOf(v) != type) {
            @compileError("only type declarations allowed in UI state ns (offending decl: " ++ d.name ++ ")");
        }
        const T: type = v;
        const FT = Pool(T);
        const default_val: FT = .{};
        fields[i] = .{
            .name = d.name,
            .type = FT,
            .default_value_ptr = &default_val,
            .is_comptime = false,
            .alignment = @alignOf(FT),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

test "acquire is stable per key and preserves written values" {
    const alloc = std.testing.allocator;
    var p: Pool(u32) = .{};
    defer p.deinit(alloc);

    const a = try p.acquire(alloc, 111, 1);
    p.get(a).* = 42;
    const b = try p.acquire(alloc, 111, 1);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 42), p.get(b).*);

    const c = try p.acquire(alloc, 222, 1);
    try std.testing.expect(a != c);
}

test "prune frees untouched slots and frees are reused" {
    const alloc = std.testing.allocator;
    var p: Pool(u32) = .{};
    defer p.deinit(alloc);

    _ = try p.acquire(alloc, 111, 1);
    const x = try p.acquire(alloc, 222, 1);

    // Frame 2: only re-touch 111.
    _ = try p.acquire(alloc, 111, 2);
    try p.prune(alloc, 2);

    // 222 was untouched → its slot is now a hole; re-acquiring reuses index x.
    const y = try p.acquire(alloc, 222, 2);
    try std.testing.expectEqual(x, y);
}

test "acquire honors init defaults for fresh and reused slots" {
    const alloc = std.testing.allocator;
    const State = struct {
        const Mode = enum { zero, expected };

        mode: Mode = .expected,
        count: u8 = 7,

        pub fn init() @This() {
            return .{};
        }
    };

    var p: Pool(State) = .{};
    defer p.deinit(alloc);

    const first = try p.acquire(alloc, 111, 1);
    try std.testing.expectEqual(State.Mode.expected, p.get(first).mode);
    try std.testing.expectEqual(@as(u8, 7), p.get(first).count);

    // Dirty the value, prune it, then prove the same physical hole is initialized
    // from semantic defaults rather than retaining the previous key's state.
    p.get(first).* = .{ .mode = .zero, .count = 0 };
    try p.prune(alloc, 2);

    const reused = try p.acquire(alloc, 222, 2);
    try std.testing.expectEqual(first, reused);
    try std.testing.expectEqual(State.Mode.expected, p.get(reused).mode);
    try std.testing.expectEqual(@as(u8, 7), p.get(reused).count);
}

test "values survive pool growth (handles, not pointers)" {
    const alloc = std.testing.allocator;
    var p: Pool(u32) = .{};
    defer p.deinit(alloc);

    const h0 = try p.acquire(alloc, 1, 1);
    p.get(h0).* = 7;

    var n: u64 = 2;
    while (n < 200) : (n += 1) _ = try p.acquire(alloc, n, 1);

    // Re-derefing the handle reads the (moved) slot — value intact.
    try std.testing.expectEqual(@as(u32, 7), p.get(h0).*);
}

test "keys are deterministic and seed-sensitive" {
    try std.testing.expectEqual(key(0, "volume"), key(0, "volume"));
    try std.testing.expect(key(0, "volume") != key(1, "volume"));
    try std.testing.expect(key(0, "a") != key(0, "b"));
    try std.testing.expect(key_i(0, "item", 1) != key_i(0, "item", 2));
}

test "resource states initialize on reuse and deinitialize exactly once per occupant" {
    const alloc = std.testing.allocator;

    var freed: usize = 0;
    const Res = struct {
        tally: ?*usize = null,
        marker: u8 = 9,

        pub fn init() @This() {
            return .{};
        }

        pub fn deinit(self: *@This()) void {
            if (self.tally) |t| t.* += 1;
            self.tally = null;
        }
    };

    var p: Pool(Res) = .{};

    const first = try p.acquire(alloc, 1, 1);
    try std.testing.expectEqual(@as(u8, 9), p.get(first).marker);
    p.get(first).tally = &freed;

    // Pruning evicts the first occupant exactly once.
    try p.prune(alloc, 2);
    try std.testing.expectEqual(@as(usize, 1), freed);

    // Reuse initializes the hole, clearing the old resource pointer and restoring
    // semantic defaults without evicting the already-dead occupant a second time.
    const reused = try p.acquire(alloc, 2, 2);
    try std.testing.expectEqual(first, reused);
    try std.testing.expectEqual(@as(?*usize, null), p.get(reused).tally);
    try std.testing.expectEqual(@as(u8, 9), p.get(reused).marker);
    try std.testing.expectEqual(@as(usize, 1), freed);
    p.get(reused).tally = &freed;

    // Teardown evicts the second occupant once; each occupant was finalized once.
    p.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), freed);
}

test "Pools generates a pool per declared type" {
    const Ns = struct {
        pub const A = u32;
        pub const B = u64;
    };
    const PS = Pools(Ns);
    var ps: PS = .{};
    defer ps.A.deinit(std.testing.allocator);
    defer ps.B.deinit(std.testing.allocator);

    const ia = try ps.A.acquire(std.testing.allocator, 10, 1);
    ps.A.get(ia).* = 5;
    try std.testing.expectEqual(@as(u32, 5), ps.A.get(ia).*);
}
