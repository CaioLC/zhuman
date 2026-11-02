//! `States` and `Schedule`: the run's state machine and the ordered systems each state runs.
//!
//! `States(S)` is plain data, `{ current, next }`, so it sits as a field of any resources struct
//! and a system takes it as a resource group (`*States(S)`) to request a transition with `set`.
//! `Schedule(S, sets)` is the table of systems, declared once: per state, up to four ordered sets
//! (`on_enter`, `handle`, `update`, `on_exit`), each a tuple of system functions run through
//! `run`. Systems differ in signature, so a set is a tuple, not a slice.
//!
//! **The tick.** `tick` first applies a pending transition: the leaving state's `on_exit` set,
//! then the entering state's `on_enter` set, once each. A request for the state already current
//! is a restart and runs both the same way. Then the current state's `handle` set runs, and its
//! `update` set when the caller says time has passed. A transition requested during a tick is
//! applied at the top of the next one, so every system of a tick sees one state.

const std = @import("std");
const run = @import("./run.zig").run;

/// A run's state over the enum `S`: the state the schedule is in and the transition requested
/// for the next tick. `current` defaults to `S`'s first tag.
pub fn States(comptime S: type) type {
    const info = switch (@typeInfo(S)) {
        .@"enum" => |e| e,
        else => @compileError("States: the state type must be an enum; got " ++ @typeName(S)),
    };
    if (info.field_names.len == 0) @compileError("States: " ++ @typeName(S) ++ " has no states");

    return struct {
        const Self = @This();

        /// The state enum.
        pub const State = S;

        /// The state the schedule is in.
        current: S = @field(S, info.field_names[0]),
        /// The transition requested for the next tick, if any.
        next: ?S = null,

        /// Whether the schedule is in `s`.
        pub fn in(self: *const Self, s: S) bool {
            return self.current == s;
        }

        /// Request a transition to `s`, applied at the top of the next tick. A later request in
        /// the same tick replaces an earlier one; a request for the current state is a restart.
        pub fn set(self: *Self, s: S) void {
            self.next = s;
        }
    };
}

/// The four sets a state may declare, in the order a tick can reach them.
pub const SetKind = enum { on_enter, handle, update, on_exit };

/// The ordered systems per state of `S`. `table` is a struct literal with one field per state
/// that runs anything, each a struct literal of sets named by `SetKind`, each a tuple of system
/// functions. A state the table does not name has empty sets; a field that is not a state, a set
/// with another name, or a set that is not a tuple of functions is a compile error.
pub fn Schedule(comptime S: type, comptime table: anytype) type {
    comptime validate(S, table);

    return struct {
        /// The state enum.
        pub const State = S;
        /// The table as declared, for a test that reads the sets.
        pub const sets = table;

        /// The type of the set `kind` of state `s`: its tuple, or the empty tuple's.
        pub fn SetOf(comptime s: S, comptime kind: SetKind) type {
            if (!@hasField(@TypeOf(table), @tagName(s))) return @TypeOf(.{});
            const entry = @field(table, @tagName(s));
            if (!@hasField(@TypeOf(entry), @tagName(kind))) return @TypeOf(.{});
            return @TypeOf(@field(entry, @tagName(kind)));
        }

        /// The set `kind` of state `s`, in declared order; empty when the table does not name
        /// it. Comptime: a set holds functions.
        pub fn setOf(comptime s: S, comptime kind: SetKind) SetOf(s, kind) {
            if (!@hasField(@TypeOf(table), @tagName(s))) return .{};
            const entry = @field(table, @tagName(s));
            if (!@hasField(@TypeOf(entry), @tagName(kind))) return .{};
            return @field(entry, @tagName(kind));
        }

        /// One tick: apply the pending transition (`on_exit` of the current state, then
        /// `on_enter` of the next, the request cleared before either runs), then run the current
        /// state's `handle` set and, if `run_update`, its `update` set. `world` and `res` are
        /// what `run` binds each system's params from.
        pub fn tick(world: anytype, res: anytype, states: *States(S), run_update: bool) void {
            if (states.next) |next| {
                states.next = null;
                switch (states.current) {
                    inline else => |cur| runSet(world, res, cur, .on_exit),
                }
                states.current = next;
                switch (next) {
                    inline else => |entering| runSet(world, res, entering, .on_enter),
                }
            }
            switch (states.current) {
                inline else => |cur| {
                    runSet(world, res, cur, .handle);
                    if (run_update) runSet(world, res, cur, .update);
                },
            }
        }

        /// The position of `sys` in the set `kind` of state `s`, or null when it is not there.
        pub fn indexOf(comptime s: S, comptime kind: SetKind, comptime sys: anytype) ?usize {
            comptime {
                for (setOf(s, kind), 0..) |member, i| if (sameSystem(member, sys)) return i;
                return null;
            }
        }

        fn runSet(world: anytype, res: anytype, comptime s: S, comptime kind: SetKind) void {
            inline for (comptime setOf(s, kind)) |sys| run(world, res, sys);
        }
    };
}

/// Whether `a` and `b` are the same system function.
pub fn sameSystem(comptime a: anytype, comptime b: anytype) bool {
    if (@TypeOf(a) != @TypeOf(b)) return false;
    const P = *const @TypeOf(a);
    return @as(P, a) == @as(P, b);
}

/// Refuse at comptime a table field that is not a state of `S`, a set that is not a `SetKind`,
/// and a set that is not a tuple of functions.
fn validate(comptime S: type, comptime table: anytype) void {
    const where = "Schedule(" ++ @typeName(S) ++ ")";
    const states = switch (@typeInfo(@TypeOf(table))) {
        .@"struct" => |s| s,
        else => @compileError(where ++ ": the table must be a struct literal with one field per state"),
    };
    for (states.field_names) |name| {
        if (!@hasField(S, name)) @compileError(where ++ ": `." ++ name ++ "` is not a state of " ++ @typeName(S));
        const entry = @field(table, name);
        const kinds = switch (@typeInfo(@TypeOf(entry))) {
            .@"struct" => |s| s,
            else => @compileError(where ++ ": `." ++ name ++ "` must be a struct literal of sets"),
        };
        for (kinds.field_names) |kind| {
            if (!@hasField(SetKind, kind)) @compileError(where ++ ": `." ++ name ++ "." ++ kind ++
                "` is not a set; a state declares on_enter, handle, update and on_exit");
            const set = @field(entry, kind);
            const systems = switch (@typeInfo(@TypeOf(set))) {
                .@"struct" => |s| s,
                else => @compileError(where ++ ": `." ++ name ++ "." ++ kind ++ "` must be a tuple of systems"),
            };
            if (!systems.is_tuple and systems.field_names.len > 0)
                @compileError(where ++ ": `." ++ name ++ "." ++ kind ++ "` must be a tuple of systems, not a struct");
            for (systems.field_names) |i| {
                if (@typeInfo(@TypeOf(@field(set, i))) != .@"fn")
                    @compileError(where ++ ": `." ++ name ++ "." ++ kind ++ "` holds something that is not a function");
            }
        }
    }
}

// ============================ Tests ==========================================

const testing = std.testing;

const test_comps = struct {
    pub const Pos = struct { x: f32 = 0 };
};
const test_tags = struct {};
const TestWorld = @import("./world.zig").World(test_comps, test_tags);

const Phase = enum { idle, play, over };

/// What ran, one letter per system, in order.
const Trace = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    fn put(self: *Trace, c: u8) void {
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn take(self: *Trace) []const u8 {
        const out = self.buf[0..self.len];
        self.len = 0;
        return out;
    }
};

/// A transition a handler requests on its next run.
const Go = struct { to: ?Phase = null };

const TestRes = struct {
    trace: Trace = .{},
    go: Go = .{},
    states: States(Phase) = .{},
};

fn request(go: *Go, states: *States(Phase)) void {
    if (go.to) |p| states.set(p);
    go.to = null;
}

fn handleIdle(trace: *Trace, go: *Go, states: *States(Phase)) void {
    trace.put('i');
    request(go, states);
}

fn handlePlay(trace: *Trace, go: *Go, states: *States(Phase)) void {
    trace.put('h');
    request(go, states);
}

fn updateOne(trace: *Trace) void {
    trace.put('u');
}

fn updateTwo(trace: *Trace, w: *TestWorld) void {
    _ = w;
    trace.put('v');
}

fn enterPlay(trace: *Trace) void {
    trace.put('E');
}

fn exitPlay(trace: *Trace) void {
    trace.put('X');
}

const TestSchedule = Schedule(Phase, .{
    .idle = .{ .handle = .{handleIdle} },
    .play = .{
        .on_enter = .{enterPlay},
        .handle = .{handlePlay},
        .update = .{ updateOne, updateTwo },
        .on_exit = .{exitPlay},
    },
});

fn tickOnce(w: *TestWorld, res: *TestRes, run_update: bool) []const u8 {
    TestSchedule.tick(w, res, &res.states, run_update);
    return res.trace.take();
}

test "States begins on the first tag with nothing pending; set requests, in reads" {
    var s: States(Phase) = .{};
    try testing.expect(s.in(.idle));
    try testing.expectEqual(@as(?Phase, null), s.next);
    s.set(.over);
    try testing.expect(s.in(.idle));
    try testing.expectEqual(@as(?Phase, .over), s.next);
}

test "a transition is applied at the top of the next tick, running on_exit then on_enter once" {
    var w = TestWorld.init();
    var res: TestRes = .{};
    res.go.to = .play;
    try testing.expectEqualStrings("i", tickOnce(&w, &res, true)); // requested, not applied
    try testing.expect(res.states.in(.idle));
    try testing.expectEqual(@as(?Phase, .play), res.states.next);
    try testing.expectEqualStrings("Ehuv", tickOnce(&w, &res, true));
    try testing.expect(res.states.in(.play));
    try testing.expectEqual(@as(?Phase, null), res.states.next);
    try testing.expectEqualStrings("huv", tickOnce(&w, &res, true)); // entered once
}

test "a request for the current state is a restart: on_exit then on_enter" {
    var w = TestWorld.init();
    var res: TestRes = .{ .states = .{ .current = .play } };
    res.go.to = .play;
    try testing.expectEqualStrings("huv", tickOnce(&w, &res, true));
    try testing.expectEqualStrings("XEhuv", tickOnce(&w, &res, true));
    try testing.expect(res.states.in(.play));
}

test "handle runs while time is still and update does not" {
    var w = TestWorld.init();
    var res: TestRes = .{ .states = .{ .current = .play } };
    try testing.expectEqualStrings("h", tickOnce(&w, &res, false));
    try testing.expectEqualStrings("huv", tickOnce(&w, &res, true));
}

test "a state the table does not name has empty sets and ticks to nothing" {
    var w = TestWorld.init();
    var res: TestRes = .{ .states = .{ .current = .play } };
    res.go.to = .over;
    try testing.expectEqualStrings("huv", tickOnce(&w, &res, true));
    try testing.expectEqualStrings("X", tickOnce(&w, &res, true)); // leaving play, entering nothing
    try testing.expectEqualStrings("", tickOnce(&w, &res, true));
    try testing.expect(res.states.in(.over));
}

test "setOf reads a set in declared order, and an unnamed set as empty" {
    const update = comptime TestSchedule.setOf(.play, .update);
    try testing.expectEqual(@as(usize, 2), update.len);
    try testing.expect(comptime sameSystem(update[0], updateOne));
    try testing.expect(comptime !sameSystem(update[0], updateTwo));
    try testing.expectEqual(@as(?usize, 1), comptime TestSchedule.indexOf(.play, .update, updateTwo));
    try testing.expectEqual(@as(?usize, null), comptime TestSchedule.indexOf(.play, .update, enterPlay));
    try testing.expectEqual(@as(usize, 0), comptime TestSchedule.setOf(.over, .update).len);
    try testing.expectEqual(@as(usize, 0), comptime TestSchedule.setOf(.idle, .on_enter).len);
}
