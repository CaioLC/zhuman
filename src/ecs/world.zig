//! The sparse-set world: one `SparseSet` per component or tag type, generated at comptime from
//! the public declarations of two namespaces the host supplies.

const std = @import("std");

pub const Entity = u32;

/// The lifetime-spawn cap. Ids are never recycled (`next_id` only climbs), so this bounds every
/// entity a world ever spawns, not the live count.
pub const MAX_ENTITIES: u32 = 1024;

/// The pointer to `T` reached through a pointer of type `P`: `*const T` when `P` points to
/// const, `*T` otherwise. Every accessor that takes its owner as `anytype` returns through
/// this, so a read through `*const World` cannot yield a writable component.
pub fn Ref(comptime P: type, comptime T: type) type {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("expected a single-item pointer, got " ++ @typeName(P));
    }
    return if (info.pointer.attrs.@"const") *const T else *T;
}

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        dense_ids: [MAX_ENTITIES]Entity = undefined,
        dense_values: [MAX_ENTITIES]T = undefined,
        sparse: [MAX_ENTITIES]?u32 = @splat(null),
        len: u32 = 0,

        pub fn add(self: *Self, e: Entity, v: T) void {
            self.dense_ids[self.len] = e;
            self.dense_values[self.len] = v;
            self.sparse[e] = self.len;
            self.len += 1;
        }

        pub fn has(self: *const Self, e: Entity) bool {
            return self.sparse[e] != null;
        }

        /// `?*T` through `*Self`, `?*const T` through `*const Self`.
        pub fn get(self: anytype, e: Entity) ?Ref(@TypeOf(self), T) {
            comptime checkSelf(Self, @TypeOf(self));
            const idx = self.sparse[e] orelse return null;
            return &self.dense_values[idx];
        }

        pub fn remove(self: *Self, e: Entity) void {
            const idx = self.sparse[e] orelse return;
            const last = self.len - 1;
            if (idx != last) {
                const moved_e = self.dense_ids[last];
                self.dense_ids[idx] = moved_e;
                self.dense_values[idx] = self.dense_values[last];
                self.sparse[moved_e] = idx;
            }
            self.sparse[e] = null;
            self.len = last;
        }
    };
}

/// An accessor taking its owner as `anytype` accepts exactly `*Self` and `*const Self`.
fn checkSelf(comptime Self: type, comptime P: type) void {
    if (P != *Self and P != *const Self) {
        @compileError("expected *" ++ @typeName(Self) ++ " or *const " ++ @typeName(Self) ++ ", got " ++ @typeName(P));
    }
}

fn Storages(comptime ns: type) type {
    const names = @typeInfo(ns).@"struct".decl_names;
    var types: [names.len]type = undefined;
    for (names, 0..) |name, i| {
        const v = @field(ns, name);
        if (@TypeOf(v) != type) {
            @compileError("only type declarations allowed in " ++ @typeName(ns) ++ " (offending decl: " ++ name ++ ")");
        }
        const T: type = v;
        types[i] = SparseSet(T);
    }
    const attrs: [names.len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.auto, null, names, &types, &attrs);
}

/// A world over the component namespace `comps` and the tag namespace `tags`. Each public
/// declaration of either must be a type, and each gets one storage. The two namespaces differ
/// only in intent (a tag is a zero-sized marker); the world treats them alike.
pub fn World(comptime comps: type, comptime tags: type) type {
    return struct {
        const Self = @This();

        next_id: Entity,
        components: Storages(comps),
        tags: Storages(tags),

        pub fn init() Self {
            var w: Self = undefined;
            w.next_id = 0;
            inline for (@typeInfo(@TypeOf(w.components)).@"struct".field_names) |name| {
                @field(w.components, name) = .{};
            }
            inline for (@typeInfo(@TypeOf(w.tags)).@"struct".field_names) |name| {
                @field(w.tags, name) = .{};
            }
            return w;
        }

        pub fn deinit(_: *Self) void {}

        /// Spawn an entity carrying a `bundle` of components/tags, returning its id.
        /// Each tuple element is either a **component instance** (added as-is) or a bare
        /// **tag type** (a zero-sized marker, added as a default `T{}`). An already-instanced
        /// tag also works, falling through the value path. `spawn(.{})` spawns a bare entity.
        pub fn spawn(self: *Self, bundle: anytype) Entity {
            const e = self.next_id;
            self.next_id += 1;
            inline for (@typeInfo(@TypeOf(bundle)).@"struct".field_names) |name| {
                const item = @field(bundle, name);
                if (@TypeOf(item) == type) {
                    self.add(e, item{}); // bare tag type → its zero-sized instance
                } else {
                    self.add(e, item); // component (or already-instanced tag)
                }
            }
            return e;
        }

        /// The storage of `T`: `*SparseSet(T)` through `*Self`, `*const SparseSet(T)` through
        /// `*const Self`. A type in neither namespace is a compile error.
        pub fn storageOf(self: anytype, comptime T: type) Ref(@TypeOf(self), SparseSet(T)) {
            comptime checkSelf(Self, @TypeOf(self));
            const cs = @typeInfo(@TypeOf(self.components)).@"struct";
            inline for (cs.field_names, cs.field_types) |name, FT| {
                if (FT == SparseSet(T)) return &@field(self.components, name);
            }
            const ts = @typeInfo(@TypeOf(self.tags)).@"struct";
            inline for (ts.field_names, ts.field_types) |name, FT| {
                if (FT == SparseSet(T)) return &@field(self.tags, name);
            }
            @compileError("no storage registered for " ++ @typeName(T));
        }

        pub fn add(self: *Self, e: Entity, v: anytype) void {
            self.storageOf(@TypeOf(v)).add(e, v);
        }

        /// `?*T` through `*Self`, `?*const T` through `*const Self`.
        pub fn get(self: anytype, e: Entity, comptime T: type) ?Ref(@TypeOf(self), T) {
            return self.storageOf(T).get(e);
        }

        pub fn has(self: anytype, e: Entity, comptime T: type) bool {
            return self.storageOf(T).has(e);
        }

        pub fn remove(self: *Self, e: Entity, comptime T: type) void {
            self.storageOf(T).remove(e);
        }

        /// Remove `e` from every component and tag storage (each `remove` no-ops if `e`
        /// is not in that storage). The entity id is not recycled: `next_id` only climbs.
        pub fn despawn(self: *Self, e: Entity) void {
            inline for (@typeInfo(@TypeOf(self.components)).@"struct".field_names) |name| {
                @field(self.components, name).remove(e);
            }
            inline for (@typeInfo(@TypeOf(self.tags)).@"struct".field_names) |name| {
                @field(self.tags, name).remove(e);
            }
        }
    };
}

// A sample namespace pair: the engine has no components of its own.
const test_comps = struct {
    pub const Pos = struct { x: f32 = 0 };
    pub const Hp = struct { v: u32 = 10 };
};
const test_tags = struct {
    pub const Marked = struct {};
};
const TestWorld = World(test_comps, test_tags);

test "spawn takes component instances and bare tag types" {
    var w = TestWorld.init();
    defer w.deinit();
    const a = w.spawn(.{ test_comps.Pos{ .x = 2 }, test_tags.Marked });
    const b = w.spawn(.{});
    try std.testing.expectEqual(@as(Entity, 0), a);
    try std.testing.expectEqual(@as(Entity, 1), b);
    try std.testing.expectEqual(@as(f32, 2), w.get(a, test_comps.Pos).?.x);
    try std.testing.expect(w.has(a, test_tags.Marked));
    try std.testing.expect(!w.has(b, test_comps.Pos));
    try std.testing.expect(w.get(b, test_comps.Hp) == null);
}

test "remove and despawn; ids are not recycled" {
    var w = TestWorld.init();
    const a = w.spawn(.{ test_comps.Pos{}, test_comps.Hp{} });
    const b = w.spawn(.{test_comps.Pos{ .x = 7 }});
    w.remove(a, test_comps.Hp);
    try std.testing.expect(!w.has(a, test_comps.Hp));
    w.despawn(a);
    try std.testing.expect(!w.has(a, test_comps.Pos));
    // The swap-remove moved `b` into `a`'s dense slot; its sparse index follows.
    try std.testing.expectEqual(@as(f32, 7), w.get(b, test_comps.Pos).?.x);
    try std.testing.expectEqual(@as(Entity, 2), w.spawn(.{}));
}

test "get through *const World yields ?*const T, through *World ?*T" {
    var w = TestWorld.init();
    const e = w.spawn(.{test_comps.Hp{ .v = 3 }});
    const cw: *const TestWorld = &w;
    try std.testing.expect(@TypeOf(cw.get(e, test_comps.Hp)) == ?*const test_comps.Hp);
    try std.testing.expect(@TypeOf(w.get(e, test_comps.Hp)) == ?*test_comps.Hp);
    try std.testing.expect(@TypeOf(cw.storageOf(test_comps.Hp)) == *const SparseSet(test_comps.Hp));
    try std.testing.expectEqual(@as(u32, 3), cw.get(e, test_comps.Hp).?.v);
    try std.testing.expect(cw.has(e, test_comps.Hp));
    w.get(e, test_comps.Hp).?.v = 4;
    try std.testing.expectEqual(@as(u32, 4), cw.get(e, test_comps.Hp).?.v);
}
