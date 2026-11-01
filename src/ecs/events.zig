//! `Events`: one bounded ring per event type, written through `Writer(T)` and read through a
//! cursor, generated at comptime from the public declarations of a namespace the host supplies
//! (the way `World` generates its storages).
//!
//! **Plain data.** An event is fixed-size and owns everything it says: a type holding a slice or
//! a pointer anywhere inside it is a compile error naming it, so an event cannot outlive an
//! arena it points into.
//!
//! **Nothing is silently lost.** A ring holds `capacity` events. A push into a full ring is
//! refused: `push` returns false and the ring counts it in `dropped`.
//!
//! **The two-tick lifetime.** Every event gets the store's next monotonic id. The store keeps
//! `tick_start`, the id the current tick began at, and `expire_before`. `update()`, once at the
//! top of each tick, sets `expire_before = tick_start` and `tick_start = next_id`, then drops
//! every entry with `id < expire_before`. An event written during tick N, or between N and N+1
//! (where the UI writes), has `id >= tick_start(N)`: the update opening N+1 keeps it, because it
//! expires only what came before N, and the update opening N+2 drops it. So it is readable
//! through tick N+1 and gone at the top of N+2, wherever in the tick its writer and its reader
//! run.
//!
//! **Cursors.** A reader yields the live events with `id >= cursor` in id order, advancing the
//! cursor past each as it yields it, so a reader that stops early resumes where it stopped and a
//! reader that runs every tick sees each event exactly once. A scheduled reader's cursor lives in
//! the store, one per event type per `ReaderId`; a reader outside the schedule (the UI) keeps its
//! own `u64` and reads through `readerAt`. A cursor older than everything live simply starts at
//! the oldest live event.

const std = @import("std");
const ParamKind = @import("./query.zig").ParamKind;

/// Events per ring (`Events(…).capacity`). One constant for every type: a tick writes a handful
/// of each, and a ring that fills is a counted refusal, never a silent overwrite.
const ring_capacity = 64;

/// Refuse at comptime any event type `T` that holds a slice or a pointer anywhere inside it.
fn assertPlain(comptime Ev: type, comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("event " ++ @typeName(Ev) ++ " holds " ++ @typeName(T) ++
            "; an event is plain fixed-size data, with no slice or pointer"),
        .array => |a| assertPlain(Ev, a.child),
        .optional => |o| assertPlain(Ev, o.child),
        .@"struct" => |s| for (s.field_types) |FT| assertPlain(Ev, FT),
        .@"union" => |u| for (u.field_types) |FT| assertPlain(Ev, FT),
        .int, .float, .bool, .@"enum", .void, .vector => {},
        else => @compileError("event " ++ @typeName(Ev) ++ " holds " ++ @typeName(T) ++
            ", which is not plain fixed-size data"),
    }
}

fn Ring(comptime T: type, comptime readers: usize) type {
    return struct {
        const Self = @This();

        buf: [ring_capacity]T = undefined,
        ids: [ring_capacity]u64 = undefined,
        /// The slot of the oldest live entry.
        head: u32 = 0,
        len: u32 = 0,
        /// Pushes refused because the ring was full.
        dropped: u32 = 0,
        /// One per scheduled reader: the lowest id that reader has not yet seen.
        cursors: [readers]u64 = @splat(0),

        fn push(self: *Self, id: u64, ev: T) void {
            const slot = (self.head + self.len) % ring_capacity;
            self.buf[slot] = ev;
            self.ids[slot] = id;
            self.len += 1;
        }

        fn expire(self: *Self, before: u64) void {
            while (self.len > 0 and self.ids[self.head] < before) {
                self.head = (self.head + 1) % ring_capacity;
                self.len -= 1;
            }
        }

        /// The oldest live entry at or past `cursor.*`, advancing the cursor past it.
        fn after(self: *const Self, cursor: *u64) ?T {
            for (0..self.len) |i| {
                const slot = (self.head + i) % ring_capacity;
                if (self.ids[slot] >= cursor.*) {
                    cursor.* = self.ids[slot] + 1;
                    return self.buf[slot];
                }
            }
            return null;
        }
    };
}

/// The store over the event namespace `ns`, with one stored cursor per ring for each field of
/// the enum `ReaderId`. Every public struct declared in `ns` is an event and must be plain data;
/// a public type that is not a struct (an enum the events share, such as the reader ids) is not
/// an event; any other public declaration is a compile error.
pub fn Events(comptime ns: type, comptime ReaderId: type) type {
    const id_info = switch (@typeInfo(ReaderId)) {
        .@"enum" => |e| e,
        else => @compileError("Events: ReaderId must be an enum; got " ++ @typeName(ReaderId)),
    };
    const readers = id_info.field_names.len;

    const Rings = blk: {
        const decls = @typeInfo(ns).@"struct".decl_names;
        var names: [decls.len][:0]const u8 = undefined;
        var types: [decls.len]type = undefined;
        var attrs: [decls.len]std.lang.Type.Struct.FieldAttributes = undefined;
        var n: usize = 0;
        for (decls) |name| {
            const v = @field(ns, name);
            if (@TypeOf(v) != type) {
                @compileError("only type declarations allowed in " ++ @typeName(ns) ++ " (offending decl: " ++ name ++ ")");
            }
            const T: type = v;
            if (@typeInfo(T) != .@"struct") continue; // an enum the events share, such as ReaderId
            assertPlain(T, T);
            names[n] = name;
            types[n] = Ring(T, readers);
            const empty: Ring(T, readers) = .{};
            attrs[n] = .{ .default_value_ptr = &empty };
            n += 1;
        }
        break :blk @Struct(.auto, null, names[0..n], types[0..n], attrs[0..n]);
    };

    return struct {
        const Self = @This();

        /// Events per ring, the same for every type.
        pub const capacity = ring_capacity;

        /// The id the next push gets. Store-wide and monotonic.
        next_id: u64 = 0,
        /// The id the current tick began at.
        tick_start: u64 = 0,
        /// Entries below this id are gone.
        expire_before: u64 = 0,
        rings: Rings = .{},

        /// Open a tick: expire everything written before the previous tick began.
        pub fn update(self: *Self) void {
            self.expire_before = self.tick_start;
            self.tick_start = self.next_id;
            inline for (@typeInfo(Rings).@"struct".field_names) |name| {
                @field(self.rings, name).expire(self.expire_before);
            }
        }

        fn RingOf(comptime T: type) type {
            const RT = Ring(T, readers);
            for (@typeInfo(Rings).@"struct".field_types) |FT| {
                if (FT == RT) return RT;
            }
            @compileError("no event " ++ @typeName(T) ++ " in " ++ @typeName(ns));
        }

        fn ring(self: anytype, comptime T: type) if (@typeInfo(@TypeOf(self)).pointer.attrs.@"const") *const RingOf(T) else *RingOf(T) {
            const info = @typeInfo(Rings).@"struct";
            inline for (info.field_names, info.field_types) |name, FT| {
                if (FT == RingOf(T)) return &@field(self.rings, name);
            }
            unreachable;
        }

        fn slot(comptime id: ReaderId) usize {
            for (id_info.field_names, 0..) |name, i| {
                if (std.mem.eql(u8, name, @tagName(id))) return i;
            }
            unreachable;
        }

        /// Appends `T`; a system param (`run` builds it from the store's resource group).
        pub fn Writer(comptime T: type) type {
            _ = RingOf(T);
            return struct {
                store: *Self,

                pub const Store = Self;
                pub const _system_param_kind: ParamKind = .event_writer;

                pub fn init(store: *Self) @This() {
                    return .{ .store = store };
                }

                /// Append `ev` with the next id. A full ring refuses it, counts it in `dropped`
                /// and returns false.
                pub fn push(self: @This(), ev: T) bool {
                    const r = self.store.ring(T);
                    if (r.len == Self.capacity) {
                        r.dropped += 1;
                        return false;
                    }
                    r.push(self.store.next_id, ev);
                    self.store.next_id += 1;
                    return true;
                }
            };
        }

        /// Reads `T` with the cursor the store keeps for `id`; a system param.
        pub fn Reader(comptime T: type, comptime id: ReaderId) type {
            _ = RingOf(T);
            return struct {
                store: *Self,

                pub const Store = Self;
                pub const _system_param_kind: ParamKind = .event_reader;

                pub fn init(store: *Self) @This() {
                    return .{ .store = store };
                }

                /// The next live event this reader has not seen, or null.
                pub fn next(self: @This()) ?T {
                    const r = self.store.ring(T);
                    return r.after(&r.cursors[comptime slot(id)]);
                }
            };
        }

        /// Reads `T` with a cursor the caller owns; not a system param.
        pub fn ExternalReader(comptime T: type) type {
            _ = RingOf(T);
            return struct {
                store: *const Self,
                cursor: *u64,

                /// The next live event past the caller's cursor, or null.
                pub fn next(self: @This()) ?T {
                    return self.store.ring(T).after(self.cursor);
                }
            };
        }

        pub fn writer(self: *Self, comptime T: type) Writer(T) {
            return .{ .store = self };
        }

        pub fn reader(self: *Self, comptime T: type, comptime id: ReaderId) Reader(T, id) {
            return .{ .store = self };
        }

        pub fn readerAt(self: *const Self, comptime T: type, cursor: *u64) ExternalReader(T) {
            return .{ .store = self, .cursor = cursor };
        }

        /// Live events of `T`.
        pub fn len(self: *const Self, comptime T: type) usize {
            return self.ring(T).len;
        }

        /// Pushes of `T` refused because its ring was full.
        pub fn dropped(self: *const Self, comptime T: type) u32 {
            return self.ring(T).dropped;
        }
    };
}

// ============================ Tests ==========================================

const testing = std.testing;

const test_events = struct {
    pub const Ping = struct { n: u32 };
    pub const Pong = struct { n: u32, side: Side = .a, pair: [2]u16 = .{ 0, 0 } };
    /// Not an event: an enum the events share.
    pub const Side = enum { a, b };
};
const TestReader = enum { first, second };

test "every public struct of the namespace is a ring, and an enum is not" {
    const fields = @typeInfo(@FieldType(TestEvents, "rings")).@"struct".field_names;
    try testing.expectEqual(@as(usize, 2), fields.len);
}
const TestEvents = Events(test_events, TestReader);

fn drain(r: anytype) [8]u32 {
    var out: [8]u32 = @splat(0);
    var i: usize = 0;
    while (r.next()) |ev| : (i += 1) out[i] = ev.n;
    return out;
}

test "an event written in tick N is read in N and N+1 and gone in N+2" {
    var ev: TestEvents = .{};
    ev.update(); // tick N opens
    try testing.expect(ev.writer(test_events.Ping).push(.{ .n = 1 }));
    try testing.expectEqual(@as(usize, 1), ev.len(test_events.Ping));
    var cursor: u64 = 0;
    try testing.expectEqual(@as(u32, 1), ev.readerAt(test_events.Ping, &cursor).next().?.n);

    ev.update(); // N+1: still live
    try testing.expectEqual(@as(usize, 1), ev.len(test_events.Ping));
    cursor = 0;
    try testing.expectEqual(@as(u32, 1), ev.readerAt(test_events.Ping, &cursor).next().?.n);

    ev.update(); // N+2: gone
    try testing.expectEqual(@as(usize, 0), ev.len(test_events.Ping));
    cursor = 0;
    try testing.expect(ev.readerAt(test_events.Ping, &cursor).next() == null);
}

test "an event written between ticks lives through the next tick" {
    var ev: TestEvents = .{};
    ev.update(); // tick N
    // ... tick N's systems ran; now the UI writes ...
    _ = ev.writer(test_events.Ping).push(.{ .n = 7 });
    ev.update(); // N+1: the handlers read it here
    try testing.expectEqual(@as(u32, 7), ev.reader(test_events.Ping, .first).next().?.n);
    ev.update(); // N+2
    try testing.expectEqual(@as(usize, 0), ev.len(test_events.Ping));
}

test "a full ring refuses the push and counts it" {
    var ev: TestEvents = .{};
    const w = ev.writer(test_events.Ping);
    for (0..TestEvents.capacity) |i| try testing.expect(w.push(.{ .n = @intCast(i) }));
    try testing.expect(!w.push(.{ .n = 999 }));
    try testing.expect(!w.push(.{ .n = 1000 }));
    try testing.expectEqual(@as(u32, 2), ev.dropped(test_events.Ping));
    try testing.expectEqual(@as(usize, TestEvents.capacity), ev.len(test_events.Ping));
    try testing.expectEqual(@as(u32, 0), ev.dropped(test_events.Pong)); // per ring
    // Expiry makes room again.
    ev.update();
    ev.update();
    try testing.expect(w.push(.{ .n = 1 }));
}

test "a scheduled reader sees each event once; reader ids are independent; an early break resumes" {
    var ev: TestEvents = .{};
    const w = ev.writer(test_events.Ping);
    ev.update();
    _ = w.push(.{ .n = 1 });
    _ = w.push(.{ .n = 2 });
    _ = w.push(.{ .n = 3 });

    // `first` stops after one.
    const r1 = ev.reader(test_events.Ping, .first);
    try testing.expectEqual(@as(u32, 1), r1.next().?.n);
    // `second` is untouched by `first`'s cursor.
    try testing.expectEqual([8]u32{ 1, 2, 3, 0, 0, 0, 0, 0 }, drain(ev.reader(test_events.Ping, .second)));
    // `first` resumes where it stopped.
    try testing.expectEqual([8]u32{ 2, 3, 0, 0, 0, 0, 0, 0 }, drain(r1));

    ev.update(); // the next tick: nothing new, and nothing seen twice
    try testing.expect(ev.reader(test_events.Ping, .first).next() == null);
    _ = w.push(.{ .n = 4 });
    try testing.expectEqual([8]u32{ 4, 0, 0, 0, 0, 0, 0, 0 }, drain(ev.reader(test_events.Ping, .first)));
    try testing.expectEqual([8]u32{ 4, 0, 0, 0, 0, 0, 0, 0 }, drain(ev.reader(test_events.Ping, .second)));

    // A cursor is per (type, id): Pong's `first` has seen nothing.
    _ = ev.writer(test_events.Pong).push(.{ .n = 9 });
    try testing.expectEqual(@as(u32, 9), ev.reader(test_events.Pong, .first).next().?.n);
}

test "an external cursor sees each event once, resumes, and a stale one starts at the oldest live" {
    var ev: TestEvents = .{};
    const w = ev.writer(test_events.Ping);
    var cursor: u64 = 0;
    ev.update();
    _ = w.push(.{ .n = 1 });
    _ = w.push(.{ .n = 2 });
    try testing.expectEqual(@as(u32, 1), ev.readerAt(test_events.Ping, &cursor).next().?.n);
    try testing.expectEqual([8]u32{ 2, 0, 0, 0, 0, 0, 0, 0 }, drain(ev.readerAt(test_events.Ping, &cursor)));
    try testing.expect(ev.readerAt(test_events.Ping, &cursor).next() == null);

    // A reader that stopped looking for two ticks: its cursor is below everything live.
    var stale: u64 = 0;
    ev.update();
    _ = w.push(.{ .n = 3 });
    ev.update();
    _ = w.push(.{ .n = 4 });
    ev.update(); // 1, 2 and 3 are gone
    try testing.expect(stale < ev.expire_before);
    try testing.expectEqual([8]u32{ 4, 0, 0, 0, 0, 0, 0, 0 }, drain(ev.readerAt(test_events.Ping, &stale)));
}
