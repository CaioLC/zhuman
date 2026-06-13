//! Bevy-style ECS system parameters and dispatcher.
//!
//! Heavily inspired by [Bevy](https://bevyengine.org)'s ECS ergonomics — system
//! params, `Query`/`With`/`Without`/`Maybe` filters, `Single`, and bundle spawning
//! (`world.spawn(.{ Counter{…}, Player })`) — adapted to a comptime-Zig sparse-set
//! world rather than Rust archetypes. Not a port; just the shape of the API.
//!
//! Systems declare their needs as parameter types:
//!     fn update_counter(res: *Resources, q: Query(.{Counter, With(tag.Player)})) void
//!
//! `run(world, res, system_fn)` introspects the function at comptime and
//! builds each parameter from the world / resources before invoking it.

const std = @import("std");
const world_mod = @import("./world.zig");
const World = world_mod.World;
const Entity = world_mod.Entity;
const Resources = @import("./res.zig").Resources;

const ParamKind = enum { query, single, maybe_single };
const FilterKind = enum { with, without, maybe };

pub fn With(comptime T: type) type {
    return struct {
        pub const _filter_kind: FilterKind = .with;
        pub const _filter_inner: type = T;
    };
}

pub fn Without(comptime T: type) type {
    return struct {
        pub const _filter_kind: FilterKind = .without;
        pub const _filter_inner: type = T;
    };
}

pub fn Maybe(comptime T: type) type {
    return struct {
        pub const _filter_kind: FilterKind = .maybe;
        pub const _filter_inner: type = T;
    };
}

const EntryKind = enum { fetch, maybe, entity };
const EntryItem = struct {
    kind: EntryKind,
    T: type, // unused for .entity
};

const ParamSpec = struct {
    fetches: []const type,         // required components contributing *T to the entry
    withs: []const type,           // must-have filters
    withouts: []const type,        // must-not-have filters
    entry_order: []const EntryItem, // declaration order of fetches + Maybes
};

fn parseParams(comptime params: anytype) ParamSpec {
    var fetches: []const type = &.{};
    var withs: []const type = &.{};
    var withouts: []const type = &.{};
    var entry_order: []const EntryItem = &.{};

    const fields = @typeInfo(@TypeOf(params)).@"struct".fields;
    inline for (fields) |f| {
        const T = @field(params, f.name);
        if (T == Entity) {
            // Bevy-style `Entity` query item — yields the id, not a component ptr, and
            // doesn't drive iteration (it's not a storage). Checked before @hasDecl,
            // which is a compile error on a non-container type like u32.
            entry_order = entry_order ++ &[_]EntryItem{.{ .kind = .entity, .T = Entity }};
        } else if (@hasDecl(T, "_filter_kind")) {
            const fk: FilterKind = T._filter_kind;
            const inner: type = T._filter_inner;
            switch (fk) {
                .with => withs = withs ++ &[_]type{inner},
                .without => withouts = withouts ++ &[_]type{inner},
                .maybe => entry_order = entry_order ++ &[_]EntryItem{.{ .kind = .maybe, .T = inner }},
            }
        } else {
            fetches = fetches ++ &[_]type{T};
            entry_order = entry_order ++ &[_]EntryItem{.{ .kind = .fetch, .T = T }};
        }
    }
    return .{
        .fetches = fetches,
        .withs = withs,
        .withouts = withouts,
        .entry_order = entry_order,
    };
}

fn entryFieldType(comptime it: EntryItem) type {
    return switch (it.kind) {
        .fetch => *it.T,
        .maybe => ?*it.T,
        .entity => Entity,
    };
}

fn EntryType(comptime spec: ParamSpec) type {
    const items = spec.entry_order;
    if (items.len == 1) {
        return entryFieldType(items[0]);
    }
    var fields: [items.len]std.builtin.Type.StructField = undefined;
    for (items, 0..) |it, i| {
        const FT = entryFieldType(it);
        fields[i] = .{
            .name = std.fmt.comptimePrint("{}", .{i}),
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
        .is_tuple = true,
    } });
}

fn buildEntry(
    comptime spec: ParamSpec,
    comptime Entry: type,
    w: *World,
    e: Entity,
    driver_idx: u32,
) Entry {
    if (spec.entry_order.len == 1) {
        const it = spec.entry_order[0];
        return switch (it.kind) {
            .entity => e,
            .maybe => w.storageOf(it.T).get(e),
            // Single fetch IS the driver, use the index directly.
            .fetch => &w.storageOf(it.T).dense_values[driver_idx],
        };
    }
    var entry: Entry = undefined;
    const driver_T = spec.fetches[0];
    inline for (spec.entry_order, 0..) |it, i| {
        switch (it.kind) {
            .entity => entry[i] = e,
            .maybe => entry[i] = w.storageOf(it.T).get(e),
            .fetch => entry[i] = if (it.T == driver_T)
                &w.storageOf(it.T).dense_values[driver_idx]
            else
                w.storageOf(it.T).get(e).?,
        }
    }
    return entry;
}

pub fn Query(comptime params: anytype) type {
    const spec = comptime parseParams(params);
    if (spec.fetches.len == 0) {
        @compileError("Query needs at least one non-Maybe fetch to drive iteration");
    }
    const Entry = EntryType(spec);
    const driver_T = spec.fetches[0];

    return struct {
        world: *World,

        pub const _system_param_kind: ParamKind = .query;

        pub fn iter(self: @This()) Iter {
            return .{ .world = self.world, .driver_idx = 0 };
        }

        pub const Iter = struct {
            world: *World,
            driver_idx: u32,

            pub fn next(it: *@This()) ?Entry {
                const drv = it.world.storageOf(driver_T);
                outer: while (it.driver_idx < drv.len) {
                    const i = it.driver_idx;
                    it.driver_idx += 1;
                    const e = drv.dense_ids[i];

                    inline for (spec.fetches[1..]) |T| {
                        if (!it.world.storageOf(T).has(e)) continue :outer;
                    }
                    inline for (spec.withs) |T| {
                        if (!it.world.storageOf(T).has(e)) continue :outer;
                    }
                    inline for (spec.withouts) |T| {
                        if (it.world.storageOf(T).has(e)) continue :outer;
                    }

                    return buildEntry(spec, Entry, it.world, e, i);
                }
                return null;
            }
        };
    };
}

pub fn Single(comptime params: anytype) type {
    return struct {
        world: *World,

        pub const _system_param_kind: ParamKind = .single;

        pub fn get(self: @This()) EntryType(parseParams(params)) {
            var q: Query(params) = .{ .world = self.world };
            var it = q.iter();
            const first = it.next() orelse @panic("Single: no match");
            if (it.next() != null) @panic("Single: multiple matches");
            return first;
        }
    };
}

pub fn MaybeSingle(comptime params: anytype) type {
    return struct {
        world: *World,

        pub const _system_param_kind: ParamKind = .maybe_single;

        pub fn get(self: @This()) ?EntryType(parseParams(params)) {
            var q: Query(params) = .{ .world = self.world };
            var it = q.iter();
            const first = it.next() orelse return null;
            if (it.next() != null) @panic("MaybeSingle: multiple matches");
            return first;
        }
    };
}

pub fn run(world: *World, res: *Resources, comptime sys: anytype) void {
    const Fn = @TypeOf(sys);
    const fn_info = @typeInfo(Fn).@"fn";
    var args: std.meta.ArgsTuple(Fn) = undefined;
    inline for (fn_info.params, 0..) |p, i| {
        args[i] = extract(p.type.?, world, res);
    }
    @call(.auto, sys, args);
}

fn extract(comptime PT: type, world: *World, res: *Resources) PT {
    if (PT == *World) return world; // direct world access for structural changes (add/remove/despawn)
    if (PT == *Resources) return res;
    if (PT == *const Resources) return res;
    if (!@hasDecl(PT, "_system_param_kind")) {
        @compileError("system param must be *World / *Resources / Query / Single / MaybeSingle, got " ++ @typeName(PT));
    }
    return .{ .world = world };
}
