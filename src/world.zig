const std = @import("std");

pub const Entity = u32;
pub const MAX_ENTITIES: u32 = 1024;

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        dense_ids: [MAX_ENTITIES]Entity = undefined,
        dense_values: [MAX_ENTITIES]T = undefined,
        sparse: [MAX_ENTITIES]?u32 = [_]?u32{null} ** MAX_ENTITIES,
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
    const decls = @typeInfo(ns).@"struct".decls;
    var fields: [decls.len]std.builtin.Type.StructField = undefined;
    for (decls, 0..) |d, i| {
        const v = @field(ns, d.name);
        if (@TypeOf(v) != type) {
            @compileError("only type declarations allowed in " ++ @typeName(ns) ++ " (offending decl: " ++ d.name ++ ")");
        }
        const T: type = v;
        const FT = SparseSet(T);
        fields[i] = .{
            .name = d.name,
            .type = FT,
            .default_value_ptr = null,
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

pub const World = struct {
    next_id: Entity,
    components: Storages(@import("./components.zig")),
    tags: Storages(@import("./tags.zig")),

    pub fn init() World {
        var w: World = undefined;
        w.next_id = 0;
        inline for (@typeInfo(@TypeOf(w.components)).@"struct".fields) |f| {
            @field(w.components, f.name) = .{};
        }
        inline for (@typeInfo(@TypeOf(w.tags)).@"struct".fields) |f| {
            @field(w.tags, f.name) = .{};
        }
        return w;
    }

    pub fn deinit(_: *World) void {}

    pub fn spawn(self: *World) Entity {
        const e = self.next_id;
        self.next_id += 1;
        return e;
    }

    pub fn storageOf(self: *World, comptime T: type) *SparseSet(T) {
        inline for (@typeInfo(@TypeOf(self.components)).@"struct".fields) |f| {
            if (f.type == SparseSet(T)) return &@field(self.components, f.name);
        }
        inline for (@typeInfo(@TypeOf(self.tags)).@"struct".fields) |f| {
            if (f.type == SparseSet(T)) return &@field(self.tags, f.name);
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
};
