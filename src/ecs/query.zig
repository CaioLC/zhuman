//! Queries: `Query`, `Single`, `MaybeSingle` and `getMany`, with the filters `With`,
//! `Without` and `Maybe`. Each takes the world pointer type first; through `*World` an entry
//! holds `*T`, through `*const World` it holds `*const T`.

const std = @import("std");
const world_mod = @import("./world.zig");
const Entity = world_mod.Entity;
const Ref = world_mod.Ref;

/// The system params `run` builds beyond the world and the resource groups; a type carrying
/// `_system_param_kind` is one. The queries are built from the world, the event params
/// (`events.zig`) from the resource group that is their store.
pub const ParamKind = enum { query, single, maybe_single, event_writer, event_reader };
const FilterKind = enum { with, without, maybe };

/// Must have `T`; fetches nothing.
pub fn With(comptime T: type) type {
    return struct {
        pub const _filter_kind: FilterKind = .with;
        pub const _filter_inner: type = T;
    };
}

/// Must not have `T`.
pub fn Without(comptime T: type) type {
    return struct {
        pub const _filter_kind: FilterKind = .without;
        pub const _filter_inner: type = T;
    };
}

/// Fetches `T` when present (`?*T`); does not filter or drive iteration.
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

    inline for (@typeInfo(@TypeOf(params)).@"struct".field_names) |name| {
        const T = @field(params, name);
        if (T == Entity) {
            // The `Entity` item yields the id, not a component pointer, and does not drive
            // iteration (it is not a storage). Checked before @hasDecl, which is a compile
            // error on a non-container type like u32.
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

fn entryFieldType(comptime WorldPtr: type, comptime it: EntryItem) type {
    return switch (it.kind) {
        .fetch => Ref(WorldPtr, it.T),
        .maybe => ?Ref(WorldPtr, it.T),
        .entity => Entity,
    };
}

fn EntryType(comptime WorldPtr: type, comptime spec: ParamSpec) type {
    const items = spec.entry_order;
    if (items.len == 1) {
        return entryFieldType(WorldPtr, items[0]);
    }
    var types: [items.len]type = undefined;
    for (items, 0..) |it, i| types[i] = entryFieldType(WorldPtr, it);
    return @Tuple(&types);
}

/// What `Query(WorldPtr, params)` yields per entity, `Single` returns, and `getMany` returns.
pub fn Entry(comptime WorldPtr: type, comptime params: anytype) type {
    return EntryType(WorldPtr, parseParams(params));
}

fn buildEntry(
    comptime spec: ParamSpec,
    comptime E: type,
    w: anytype,
    e: Entity,
    driver_idx: u32,
) E {
    if (spec.entry_order.len == 1) {
        const it = spec.entry_order[0];
        return switch (it.kind) {
            .entity => e,
            .maybe => w.storageOf(it.T).get(e),
            // A single fetch is the driver: use the index directly.
            .fetch => &w.storageOf(it.T).dense_values[driver_idx],
        };
    }
    var entry: E = undefined;
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

fn checkWorldPtr(comptime WorldPtr: type) void {
    const info = @typeInfo(WorldPtr);
    if (info != .pointer or info.pointer.size != .one or !@hasDecl(info.pointer.child, "storageOf")) {
        @compileError("a query's first parameter is the world pointer type (*World or *const World); got " ++ @typeName(WorldPtr));
    }
}

/// Iterate every entity matching `params`. `next()` yields a tuple of `*T` in declaration
/// order (plus `Entity`, and `?*T` for `Maybe`), built at comptime by `EntryType`; through
/// `*const World` the pointers are `*const T`.
///
/// A note for editors: that tuple is `@Tuple`-constructed, which no language server
/// evaluates, so a destructure of it resolves to nothing. Annotating the bindings
/// (`const a: *A, const b: *B = entry;`) restores completion and costs only the line.
/// This is a tooling limit, not a design one: declaring `params` as a concrete
/// `[]const type` instead of `anytype` was measured and changes nothing.
pub fn Query(comptime WorldPtr: type, comptime params: anytype) type {
    comptime checkWorldPtr(WorldPtr);
    const spec = comptime parseParams(params);
    if (spec.fetches.len == 0) {
        @compileError("Query needs at least one non-Maybe fetch to drive iteration");
    }
    const E = EntryType(WorldPtr, spec);
    const driver_T = spec.fetches[0];

    return struct {
        world: WorldPtr,

        pub const _system_param_kind: ParamKind = .query;
        pub const Item = E;

        pub fn iter(self: @This()) Iter {
            return .{ .world = self.world, .driver_idx = 0 };
        }

        pub const Iter = struct {
            world: WorldPtr,
            driver_idx: u32,

            pub fn next(it: *@This()) ?E {
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

                    return buildEntry(spec, E, it.world, e, i);
                }
                return null;
            }
        };
    };
}

/// Exactly one match: `get` panics on none or several.
pub fn Single(comptime WorldPtr: type, comptime params: anytype) type {
    return struct {
        world: WorldPtr,

        pub const _system_param_kind: ParamKind = .single;

        pub fn get(self: @This()) Entry(WorldPtr, params) {
            var q: Query(WorldPtr, params) = .{ .world = self.world };
            var it = q.iter();
            const first = it.next() orelse @panic("Single: no match");
            if (it.next() != null) @panic("Single: multiple matches");
            return first;
        }
    };
}

/// At most one match: `get` returns null on none and panics on several.
pub fn MaybeSingle(comptime WorldPtr: type, comptime params: anytype) type {
    return struct {
        world: WorldPtr,

        pub const _system_param_kind: ParamKind = .maybe_single;

        pub fn get(self: @This()) ?Entry(WorldPtr, params) {
            var q: Query(WorldPtr, params) = .{ .world = self.world };
            var it = q.iter();
            const first = it.next() orelse return null;
            if (it.next() != null) @panic("MaybeSingle: multiple matches");
            return first;
        }
    };
}

/// Fetch several components off one *known* entity: `Query`'s non-iterating sibling.
/// There is no driver storage to walk (the entity is already known), so every fetch is a
/// direct sparse-set lookup; a required (non-`Maybe`) component missing from `e` is a
/// caller bug (`e` was expected to already qualify) and panics rather than degrading to an
/// optional. `With`/`Without` do not apply here (there is no set of entities to filter),
/// so passing them is a compile error rather than a silent no-op.
pub fn getMany(world: anytype, e: Entity, comptime params: anytype) Entry(@TypeOf(world), params) {
    const WorldPtr = @TypeOf(world);
    comptime checkWorldPtr(WorldPtr);
    const spec = comptime parseParams(params);
    if (spec.withs.len != 0 or spec.withouts.len != 0) {
        @compileError("getMany: With/Without filters aren't meaningful for a known-entity fetch");
    }
    const E = EntryType(WorldPtr, spec);
    if (spec.entry_order.len == 1) {
        const it = spec.entry_order[0];
        return switch (it.kind) {
            .entity => e,
            .maybe => world.storageOf(it.T).get(e),
            .fetch => world.storageOf(it.T).get(e) orelse @panic("getMany: entity missing required component"),
        };
    }
    var entry: E = undefined;
    inline for (spec.entry_order, 0..) |it, i| {
        switch (it.kind) {
            .entity => entry[i] = e,
            .maybe => entry[i] = world.storageOf(it.T).get(e),
            .fetch => entry[i] = world.storageOf(it.T).get(e) orelse @panic("getMany: entity missing required component"),
        }
    }
    return entry;
}

const test_comps = struct {
    pub const Pos = struct { x: f32 = 0 };
    pub const Hp = struct { v: u32 = 10 };
    pub const Name = struct { s: []const u8 = "" };
};
const test_tags = struct {
    pub const Hero = struct {};
    pub const Dead = struct {};
};
const TestWorld = world_mod.World(test_comps, test_tags);

fn sampleWorld() !TestWorld {
    var w = try TestWorld.init(std.testing.allocator);
    errdefer w.deinit();
    _ = w.spawn(.{ test_comps.Pos{ .x = 1 }, test_comps.Hp{ .v = 5 }, test_tags.Hero });
    _ = w.spawn(.{ test_comps.Pos{ .x = 2 }, test_comps.Name{ .s = "b" } });
    _ = w.spawn(.{ test_comps.Pos{ .x = 3 }, test_comps.Hp{ .v = 7 }, test_tags.Dead });
    return w;
}

test "Query: fetches, With, Without, Maybe and Entity in declaration order" {
    var w = try sampleWorld();
    defer w.deinit();
    var sum: f32 = 0;
    var q: Query(*TestWorld, .{ test_comps.Pos, test_comps.Hp }) = .{ .world = &w };
    var it = q.iter();
    while (it.next()) |entry| {
        const pos: *test_comps.Pos, const hp: *test_comps.Hp = entry;
        sum += pos.x;
        hp.v += 1;
    }
    try std.testing.expectEqual(@as(f32, 4), sum);
    try std.testing.expectEqual(@as(u32, 6), w.get(0, test_comps.Hp).?.v);

    var alive: Query(*TestWorld, .{ Entity, test_comps.Pos, Without(test_tags.Dead), Maybe(test_comps.Name) }) = .{ .world = &w };
    var ai = alive.iter();
    var n: u32 = 0;
    while (ai.next()) |entry| {
        const e, _, const name = entry;
        try std.testing.expect(e != 2);
        if (e == 1) try std.testing.expectEqualStrings("b", name.?.s) else try std.testing.expect(name == null);
        n += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), n);

    const hero = Single(*TestWorld, .{ Entity, test_comps.Pos, With(test_tags.Hero) }){ .world = &w };
    try std.testing.expectEqual(@as(Entity, 0), hero.get()[0]);
    const none = MaybeSingle(*TestWorld, .{ test_comps.Name, With(test_tags.Hero) }){ .world = &w };
    try std.testing.expect(none.get() == null);
}

test "a *const World query yields *const T" {
    var w = try sampleWorld();
    defer w.deinit();
    const cw: *const TestWorld = &w;
    var q: Query(*const TestWorld, .{ test_comps.Pos, Maybe(test_comps.Name) }) = .{ .world = cw };
    var it = q.iter();
    const first = it.next().?;
    try std.testing.expect(@TypeOf(first[0]) == *const test_comps.Pos);
    try std.testing.expect(@TypeOf(first[1]) == ?*const test_comps.Name);
    try std.testing.expect(Query(*TestWorld, .{test_comps.Pos}).Item == *test_comps.Pos);
    try std.testing.expect(Query(*const TestWorld, .{test_comps.Pos}).Item == *const test_comps.Pos);

    const one = Single(*const TestWorld, .{ test_comps.Hp, With(test_tags.Hero) }){ .world = cw };
    try std.testing.expect(@TypeOf(one.get()) == *const test_comps.Hp);
    const maybe = MaybeSingle(*const TestWorld, .{ test_comps.Hp, With(test_tags.Hero) }){ .world = cw };
    try std.testing.expect(@TypeOf(maybe.get()) == ?*const test_comps.Hp);
}

test "getMany fetches off a known entity; const through *const World" {
    var w = try sampleWorld();
    defer w.deinit();
    const pos, const name = getMany(&w, 1, .{ test_comps.Pos, Maybe(test_comps.Hp) });
    try std.testing.expectEqual(@as(f32, 2), pos.x);
    try std.testing.expect(name == null);
    pos.x = 9;

    const cw: *const TestWorld = &w;
    const cpos = getMany(cw, 1, .{test_comps.Pos});
    try std.testing.expect(@TypeOf(cpos) == *const test_comps.Pos);
    try std.testing.expectEqual(@as(f32, 9), cpos.x);
}
