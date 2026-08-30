//! Bevy-style ECS system parameters and dispatcher.
//!
//! Heavily inspired by [Bevy](https://bevyengine.org)'s ECS ergonomics — system
//! params, `Query`/`With`/`Without`/`Maybe` filters, `Single`, and bundle spawning
//! (`world.spawn(.{ Energy{…}, Player })`) — adapted to a comptime-Zig sparse-set
//! world rather than Rust archetypes. Not a port; just the shape of the API.
//!
//! Systems declare their needs as parameter types:
//!     fn metabolize(time: *const Time, cfg: *const Config, sim: *Sim,
//!                   q: Query(.{Vigor, InventoryFood, Metabolism})) void
//!
//! `run(world, res, system_fn)` introspects the function at comptime and
//! builds each parameter from the world / resources before invoking it.
//!
//! A parameter may be `*World`, the whole `*Resources`, a `Query`/`Single`/
//! `MaybeSingle`, or **one resource group** — any struct-typed field of
//! `Resources` (see `groups`). Naming groups is preferred: the signature then
//! states the system's reach and the compiler enforces it, and `*const` vs `*`
//! says whether it reads or writes. A system with no `*Platform` param cannot
//! touch the renderer.

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
    fetches: []const type, // required components contributing *T to the entry
    withs: []const type, // must-have filters
    withouts: []const type, // must-not-have filters
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

/// Iterate every entity matching `params`. `next()` yields a tuple of `*T` in declaration
/// order (plus `Entity` and `?*T` for `Maybe`), built at comptime by `EntryType`.
///
/// A note for editors: that tuple is `@Type`-constructed, which no language server
/// evaluates, so a destructure of it resolves to nothing. Annotating the bindings
/// (`const vigor: *comp.Vigor, … = entry;`) restores completion and costs only the line.
/// This is a tooling limit, not a design one — declaring `params` as a concrete
/// `[]const type` instead of `anytype` was measured and changes nothing.
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

/// Fetch several components off one *known* entity — `Query`'s non-iterating sibling.
/// There's no driver storage to walk (the entity is already known), so every fetch is a
/// direct sparse-set lookup; a required (non-`Maybe`) component missing from `e` is a
/// caller bug (`e` was expected to already qualify — e.g. matched by a `Query` upstream,
/// or it's the entity a decider was handed) and panics rather than degrading to an
/// optional. `With`/`Without` don't apply here (there's no set of entities to filter),
/// so passing them is a compile error rather than a silent no-op.
pub fn getMany(world: *World, e: Entity, comptime params: anytype) EntryType(parseParams(params)) {
    const spec = comptime parseParams(params);
    if (spec.withs.len != 0 or spec.withouts.len != 0) {
        @compileError("getMany: With/Without filters aren't meaningful for a known-entity fetch");
    }
    const Entry = EntryType(spec);
    if (spec.entry_order.len == 1) {
        const it = spec.entry_order[0];
        return switch (it.kind) {
            .entity => e,
            .maybe => world.storageOf(it.T).get(e),
            .fetch => world.storageOf(it.T).get(e) orelse @panic("getMany: entity missing required component"),
        };
    }
    var entry: Entry = undefined;
    inline for (spec.entry_order, 0..) |it, i| {
        switch (it.kind) {
            .entity => entry[i] = e,
            .maybe => entry[i] = world.storageOf(it.T).get(e),
            .fetch => entry[i] = world.storageOf(it.T).get(e) orelse @panic("getMany: entity missing required component"),
        }
    }
    return entry;
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

/// The injectable **resource groups**: every struct-typed field of `Resources`. A system
/// names the group it touches (`*Sim`, `*const Config`) instead of taking the whole bundle,
/// so its signature states its reach and the compiler holds it to that — a system with no
/// `*Platform` param cannot reach the renderer.
///
/// Derived from the fields rather than listed, so a new group is injectable with no edit
/// here. Two guards keep the type-directed binding honest:
///
///  - **struct-typed fields only.** A bare primitive on `Resources` (a top-level `f32`)
///    would make `*f32` injectable, and every system taking an `*f32` would silently bind
///    to it. A scalar belongs inside a group anyway, so excluding it costs nothing.
///  - **distinct types.** Two fields of the same type make `*T` ambiguous; the `comptime`
///    block below turns that into a build error instead of a silent bind to whichever
///    field comes first.
const groups = blk: {
    var out: []const std.builtin.Type.StructField = &.{};
    for (std.meta.fields(Resources)) |f| {
        if (@typeInfo(f.type) == .@"struct") out = out ++ [_]std.builtin.Type.StructField{f};
    }
    break :blk out;
};

comptime {
    for (groups, 0..) |a, i| for (groups[i + 1 ..]) |b| {
        if (a.type == b.type) @compileError(
            "Resources." ++ a.name ++ " and Resources." ++ b.name ++ " share the type " ++
                @typeName(a.type) ++ ", so a `*" ++ @typeName(a.type) ++
                "` system param would be ambiguous. Give one of them its own type.",
        );
    };
}

/// The group names, for the "valid system param" error message. Comptime-built from
/// `groups`, so it can never fall out of step with what is actually injectable.
const group_list = blk: {
    var out: []const u8 = "";
    for (groups, 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ "*" ++ @typeName(f.type);
    break :blk out;
};

fn extract(comptime PT: type, world: *World, res: *Resources) PT {
    if (PT == *World) return world; // direct world access for structural changes (add/remove/despawn)
    if (PT == *Resources) return res;
    if (PT == *const Resources) return res;
    // One resource group. `*const` is the read-only form and is worth reaching for: it puts
    // "reads tuning" vs "writes the run" in the signature, checked by the compiler.
    inline for (groups) |f| {
        if (PT == *f.type or PT == *const f.type) return &@field(res, f.name);
    }
    // `@hasDecl` demands a container, and the likeliest wrong guess is a pointer (`*Log`,
    // `*f32`), so check the shape first — otherwise a bad param dies on a builtin error
    // and never reaches the message that lists what is actually valid.
    const is_container = switch (@typeInfo(PT)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
    if (!is_container or !@hasDecl(PT, "_system_param_kind")) {
        @compileError("system param must be *World, *Resources, a Query/Single/MaybeSingle, " ++
            "or a resource group (" ++ group_list ++ ", each also valid as *const); got " ++ @typeName(PT));
    }
    return .{ .world = world };
}
