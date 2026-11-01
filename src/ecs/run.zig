//! `run`: build a system's arguments from its parameter types, then call it.
//!
//! A system declares its needs as parameter types:
//!     fn step(time: *const Time, state: *State, q: Query(*World, .{ Pos, Vel })) void
//!
//! `run(world, res, step)` introspects the function at comptime and builds each parameter from
//! the world or the resources struct `res` points at. A parameter may be:
//!
//!  - the world pointer `run` was given (or its `*const` form), for structural changes;
//!  - the whole resources pointer, `*R` or `*const R`;
//!  - one **resource group**: any struct-typed field of `R`, as `*T` or `*const T`;
//!  - a `Query`, `Single` or `MaybeSingle`, built over the world;
//!  - an event `Writer(T)` or `Reader(T, id)` (`events.zig`), built over the one group of `R`
//!    whose type is that param's event store.
//!
//! Naming groups is preferred to taking the whole resources struct: the signature then states
//! the system's reach and the compiler holds it to that, and `*const` against `*` says whether
//! it reads or writes.

const std = @import("std");
const query = @import("./query.zig");

pub fn run(world: anytype, res: anytype, comptime sys: anytype) void {
    const Fn = @TypeOf(sys);
    const fn_info = @typeInfo(Fn).@"fn";
    var args: std.meta.ArgsTuple(Fn) = undefined;
    inline for (fn_info.param_types, 0..) |PT, i| {
        args[i] = extract(PT.?, world, res);
    }
    @call(.auto, sys, args);
}

/// The injectable groups of a resources struct `R`: every struct-typed field. Derived from the
/// fields rather than listed, so a new group is injectable with no edit here. Two guards keep
/// the type-directed binding honest:
///
///  - **struct-typed fields only.** A bare primitive on `R` (a top-level `f32`) would make
///    `*f32` injectable, and every system taking an `*f32` would silently bind to it. A scalar
///    belongs inside a group anyway, so excluding it costs nothing.
///  - **distinct types.** Two fields of the same type make `*T` ambiguous; that is a build
///    error instead of a silent bind to whichever field comes first.
const Group = struct { name: [:0]const u8, type: type };

fn groupsOf(comptime R: type) []const Group {
    comptime {
        const info = @typeInfo(R).@"struct";
        var out: []const Group = &.{};
        for (info.field_names, info.field_types) |name, T| {
            if (@typeInfo(T) == .@"struct") out = out ++ [_]Group{.{ .name = name, .type = T }};
        }
        for (out, 0..) |a, i| for (out[i + 1 ..]) |b| {
            if (a.type == b.type) @compileError(
                @typeName(R) ++ "." ++ a.name ++ " and " ++ @typeName(R) ++ "." ++ b.name ++
                    " share the type " ++ @typeName(a.type) ++ ", so a `*" ++ @typeName(a.type) ++
                    "` system param would be ambiguous. Give one of them its own type.",
            );
        };
        return out;
    }
}

/// The group names, for the "valid system param" error message; built from `groupsOf`, so it
/// cannot fall out of step with what is injectable.
fn groupList(comptime R: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (groupsOf(R), 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ "*" ++ @typeName(f.type);
        return out;
    }
}

fn Pointee(comptime P: type, comptime what: []const u8) type {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one or @typeInfo(info.pointer.child) != .@"struct") {
        @compileError("run: " ++ what ++ " must be a single-item pointer to a struct; got " ++ @typeName(P));
    }
    return info.pointer.child;
}

fn extract(comptime PT: type, world: anytype, res: anytype) PT {
    const W = Pointee(@TypeOf(world), "the world");
    const R = Pointee(@TypeOf(res), "the resources");
    if (PT == @TypeOf(world) or PT == *const W) return world;
    if (PT == *R or PT == *const R) return res;
    inline for (comptime groupsOf(R)) |f| {
        if (PT == *f.type or PT == *const f.type) return &@field(res, f.name);
    }
    // `@hasDecl` demands a container, and the likeliest wrong guess is a pointer (`*f32`), so
    // check the shape first; otherwise a bad param dies on a builtin error and never reaches
    // the message that lists what is valid.
    const is_container = switch (@typeInfo(PT)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
    if (!is_container or !@hasDecl(PT, "_system_param_kind")) {
        @compileError("system param must be " ++ @typeName(@TypeOf(world)) ++ ", *" ++ @typeName(R) ++
            ", a Query/Single/MaybeSingle, an event Writer/Reader over a store in " ++ @typeName(R) ++
            ", or a resource group (" ++ groupList(R) ++ ", each also valid as *const); got " ++ @typeName(PT));
    }
    switch (PT._system_param_kind) {
        .query, .single, .maybe_single => return .{ .world = world },
        .event_writer, .event_reader => {
            const name = comptime storeField(R, PT.Store) orelse @compileError(@typeName(PT) ++
                " needs the event store " ++ @typeName(PT.Store) ++ ", and " ++ @typeName(R) ++
                " has no field of that type");
            return PT.init(&@field(res, name));
        },
    }
}

/// The field of `R` holding the event store `Store`, or null when `R` has none. Event params
/// bind through this; a resources struct without the store cannot run a system that reads or
/// writes events.
fn storeField(comptime R: type, comptime Store: type) ?[:0]const u8 {
    for (groupsOf(R)) |f| if (f.type == Store) return f.name;
    return null;
}

const test_comps = struct {
    pub const Pos = struct { x: f32 = 0 };
    pub const Vel = struct { dx: f32 = 0 };
};
const test_tags = struct {};
const TestWorld = @import("./world.zig").World(test_comps, test_tags);

const Clock = struct { dt: f32 = 0 };
const Tally = struct { steps: u32 = 0 };
const TestRes = struct {
    clock: Clock = .{},
    tally: Tally = .{},
    scale: f32 = 2, // a scalar: not a group
};

fn move(clock: *const Clock, tally: *Tally, q: query.Query(*TestWorld, .{ test_comps.Pos, test_comps.Vel })) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const pos: *test_comps.Pos, const vel: *test_comps.Vel = entry;
        pos.x += vel.dx * clock.dt;
    }
    tally.steps += 1;
}

fn spawnOne(w: *TestWorld, res: *const TestRes) void {
    _ = w.spawn(.{ test_comps.Pos{ .x = res.scale }, test_comps.Vel{ .dx = 1 } });
}

fn peek(w: *const TestWorld, q: query.Query(*const TestWorld, .{test_comps.Pos}), tally: *Tally) void {
    var it = q.iter();
    while (it.next()) |pos| tally.steps += @intFromFloat(pos.x);
    _ = w;
}

test "run binds the world, the resources, groups and queries from an arbitrary resources struct" {
    var w = TestWorld.init();
    var res: TestRes = .{ .clock = .{ .dt = 0.5 } };
    run(&w, &res, spawnOne);
    run(&w, &res, move);
    try std.testing.expectEqual(@as(f32, 2.5), w.get(0, test_comps.Pos).?.x);
    try std.testing.expectEqual(@as(u32, 1), res.tally.steps);
    run(&w, &res, peek);
    try std.testing.expectEqual(@as(u32, 3), res.tally.steps);
}

const test_events = struct {
    pub const Rang = struct { n: u32 };
};
const TestEvents = @import("./events.zig").Events(test_events, enum { tally });
const EventRes = struct {
    tally: Tally = .{},
    events: TestEvents = .{},
};

fn ring(w: TestEvents.Writer(test_events.Rang)) void {
    _ = w.push(.{ .n = 3 });
}

fn hear(tally: *Tally, r: TestEvents.Reader(test_events.Rang, .tally)) void {
    while (r.next()) |ev| tally.steps += ev.n;
}

test "run binds an event writer and reader from the store in the resources struct" {
    var w = TestWorld.init();
    var res: EventRes = .{};
    res.events.update();
    run(&w, &res, ring);
    run(&w, &res, ring);
    run(&w, &res, hear);
    try std.testing.expectEqual(@as(u32, 6), res.tally.steps);
    run(&w, &res, hear); // the scheduled cursor saw both already
    try std.testing.expectEqual(@as(u32, 6), res.tally.steps);
}

test "a resources struct with no event store binds no event param" {
    // `run` turns a null here into a compile error naming the missing store; a negative compile
    // test is not possible, so the decision is tested where it is made.
    try std.testing.expect(comptime storeField(TestRes, TestEvents) == null);
    try std.testing.expectEqualStrings("events", comptime storeField(EventRes, TestEvents).?);
}
