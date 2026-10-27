const std = @import("std");

pub const Entity = u32;
pub const MAX_ENTITIES: u32 = 1024;

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

        pub fn get(self: *Self, e: Entity) ?*T {
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

pub const World = struct {
    next_id: Entity,
    components: Storages(@import("./components.zig")),
    tags: Storages(@import("./tags.zig")),

    pub fn init() World {
        var w: World = undefined;
        w.next_id = 0;
        inline for (@typeInfo(@TypeOf(w.components)).@"struct".field_names) |name| {
            @field(w.components, name) = .{};
        }
        inline for (@typeInfo(@TypeOf(w.tags)).@"struct".field_names) |name| {
            @field(w.tags, name) = .{};
        }
        return w;
    }

    pub fn deinit(_: *World) void {}

    /// Spawn an entity carrying a `bundle` of components/tags, returning its id.
    /// Each tuple element is either a **component instance** (`comp.Life{ … }`,
    /// added as-is) or a bare **tag type** (`tag.Player` — a zero-sized marker,
    /// added as a default `T{}`). An already-instanced tag (`tag.Player{}`) also
    /// works, falling through the value path. `spawn(.{})` spawns a bare entity.
    pub fn spawn(self: *World, bundle: anytype) Entity {
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

    pub fn storageOf(self: *World, comptime T: type) *SparseSet(T) {
        const comps = @typeInfo(@TypeOf(self.components)).@"struct";
        inline for (comps.field_names, comps.field_types) |name, FT| {
            if (FT == SparseSet(T)) return &@field(self.components, name);
        }
        const tags = @typeInfo(@TypeOf(self.tags)).@"struct";
        inline for (tags.field_names, tags.field_types) |name, FT| {
            if (FT == SparseSet(T)) return &@field(self.tags, name);
        }
        @compileError("no storage registered for " ++ @typeName(T));
    }

    pub fn add(self: *World, e: Entity, v: anytype) void {
        self.storageOf(@TypeOf(v)).add(e, v);
    }

    pub fn get(self: *World, e: Entity, comptime T: type) ?*T {
        return self.storageOf(T).get(e);
    }

    pub fn has(self: *World, e: Entity, comptime T: type) bool {
        return self.storageOf(T).has(e);
    }

    pub fn remove(self: *World, e: Entity, comptime T: type) void {
        self.storageOf(T).remove(e);
    }

    /// Remove `e` from every component and tag storage (each `remove` no-ops if `e`
    /// isn't in that storage). The entity id is not recycled — `next_id` only climbs.
    pub fn despawn(self: *World, e: Entity) void {
        inline for (@typeInfo(@TypeOf(self.components)).@"struct".field_names) |name| {
            @field(self.components, name).remove(e);
        }
        inline for (@typeInfo(@TypeOf(self.tags)).@"struct".field_names) |name| {
            @field(self.tags, name).remove(e);
        }
    }
};
