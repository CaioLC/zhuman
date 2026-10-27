//! Host-side frame capture — the development baseline the UI layer is measured against.
//!
//! One capture pairs the engine's `FrameProfiler` (the five-pass timings: intrinsic sizing,
//! relative/grow resolution, placement, stamping, drawing) with the state counts the engine
//! never aggregates: the arena tree size across every root, the interaction slots alive this
//! frame, and the live and persistent slot counts of every `UiState` pool. Both halves
//! accumulate average and maximum over the same report window and reset together, so one
//! report describes one window. The host loop records once per frame after the draw pass and
//! logs the report every `window` frames.
//!
//! The capture is a development switch. It runs only when `HA_UI_PROFILE` is truthy (read once,
//! on the first recorded frame) and exists only in builds where `std.log.info` is compiled in:
//! a release build carries neither the counting nor the lines.
//!
//! "Live" means touched this frame — a slot the build acquired or retained — so the count is the
//! same whether it is read before or after `endFrame` prunes. "Slots" is the pool's backing
//! storage, holes included: the number that must stay bounded as the tree churns.

const std = @import("std");
const ui = @import("ui");
const cb = @import("./ctx_binding.zig");
const motion = @import("./motion.zig");

/// The environment switch. Parsed with the same truth table as `HA_REDUCED_MOTION`
/// (`motion.parseOverride`); unset, empty, or unrecognized means off.
pub const env_var_name = "HA_UI_PROFILE";

/// Whether the capture exists in this build. It follows info-level logging, which the
/// default `std.log` policy compiles out of ReleaseFast and ReleaseSmall.
pub const compiled_in = std.log.logEnabled(.info, .default);

/// How many `UiState` pools the registry declares — one per `pub const` type.
pub const pool_count = @typeInfo(cb.UiState).@"struct".decl_names.len;

/// The registered pool names, in registry order — the order `Pools` lays its fields out in,
/// which is the order every per-pool array here is indexed by.
pub const pool_names: [pool_count][]const u8 = blk: {
    const decls = @typeInfo(cb.UiState).@"struct".decl_names;
    var names: [decls.len][]const u8 = undefined;
    for (decls, 0..) |name, i| names[i] = name;
    break :blk names;
};

/// The per-pool array index of state type `T` (must be registered in `UiState`).
pub fn poolIndex(comptime T: type) usize {
    inline for (pool_names, 0..) |name, i| {
        if (@field(cb.UiState, name) == T) return i;
    }
    @compileError("no UI pool registered for " ++ @typeName(T));
}

/// Running sum and maximum of one per-frame count.
pub const Stat = struct {
    total: u64 = 0,
    max: u64 = 0,

    pub fn add(self: *Stat, v: u64) void {
        self.total +|= v;
        self.max = @max(self.max, v);
    }

    /// The window average; `0` for an empty window.
    pub fn mean(self: Stat, frames: u64) f64 {
        if (frames == 0) return 0;
        return @as(f64, @floatFromInt(self.total)) / @as(f64, @floatFromInt(frames));
    }
};

/// Average/maximum accumulation of the state counts over a window, generic over the pool
/// count so the aggregation is tested without the host registry.
pub fn StateStats(comptime n: usize) type {
    return struct {
        const Self = @This();

        /// One frame's counts.
        pub const Sample = struct {
            /// Arena nodes built this frame, summed over every root.
            nodes: u64 = 0,
            /// Interaction slots touched this frame.
            interaction_live: u64 = 0,
            /// Interaction slot storage, holes included.
            interaction_slots: u64 = 0,
            /// Per pool: slots touched this frame.
            pool_live: [n]u64 = @splat(0),
            /// Per pool: slot storage, holes included.
            pool_slots: [n]u64 = @splat(0),
        };

        frames: u64 = 0,
        nodes: Stat = .{},
        interaction_live: Stat = .{},
        interaction_slots: Stat = .{},
        pool_live: [n]Stat = @splat(.{}),
        pool_slots: [n]Stat = @splat(.{}),

        pub fn record(self: *Self, s: Sample) void {
            self.frames +|= 1;
            self.nodes.add(s.nodes);
            self.interaction_live.add(s.interaction_live);
            self.interaction_slots.add(s.interaction_slots);
            for (&self.pool_live, s.pool_live) |*stat, v| stat.add(v);
            for (&self.pool_slots, s.pool_slots) |*stat, v| stat.add(v);
        }

        pub fn reset(self: *Self) void {
            self.* = .{};
        }
    };
}

/// The host's state accumulator and its per-frame sample.
pub const HostStats = StateStats(pool_count);
pub const HostSample = HostStats.Sample;

/// Every node across `trees`, each root walked in pre-order.
pub fn countNodes(trees: []const *cb.Node) u64 {
    var n: u64 = 0;
    for (trees) |root| {
        var it = root.iterate();
        while (it.next()) |_| n += 1;
    }
    return n;
}

/// Slots alive and touched on `frame`. Generic over the pool's slot type: every `Pool(T)`
/// slot carries `live` and `touched`.
fn countLive(slots: anytype, frame: u64) u64 {
    var n: u64 = 0;
    for (slots) |slot| {
        if (slot.live and slot.touched == frame) n += 1;
    }
    return n;
}

/// This frame's counts, read through the engine's public pool fields.
pub fn sample(ctx: *cb.UiCtx, trees: []const *cb.Node) HostSample {
    var s: HostSample = .{};
    s.nodes = countNodes(trees);
    s.interaction_live = countLive(ctx.interactions.slots.items, ctx.frame);
    s.interaction_slots = ctx.interactions.slots.items.len;
    inline for (@typeInfo(@TypeOf(ctx.pools)).@"struct".field_names, 0..) |name, i| {
        comptime std.debug.assert(std.mem.eql(u8, name, pool_names[i]));
        const p = &@field(ctx.pools, name);
        s.pool_live[i] = countLive(p.slots.items, ctx.frame);
        s.pool_slots[i] = p.slots.items.len;
    }
    return s;
}

/// Whether an `HA_UI_PROFILE` value (null when unset) asks for the capture.
pub fn requestedFromEnv(raw: ?[]const u8) bool {
    return motion.parseOverride(raw orelse return false) orelse false;
}

/// The host loop's capture: timings and state counts over one shared window.
pub const FrameCapture = struct {
    timings: ui.FrameProfiler = .{},
    state: HostStats = .{},
    /// The `HA_UI_PROFILE` decision, resolved on the first `record`; null until then.
    enabled: ?bool = null,

    pub const Report = struct {
        timings: ui.FrameProfileReport,
        state: HostStats,

        /// Emit the report as info log lines: the two five-pass lines, two state lines, and
        /// one line per registered pool.
        pub fn log(self: Report) void {
            const avg = self.timings.average;
            const max = self.timings.maximum;
            const stamp_share: f64 = @as(f64, @floatFromInt(self.timings.stampingPermille())) / 10.0;
            std.log.info(
                "ui five-pass {d}f avg us intrinsic={d:.1} relative={d:.1} place={d:.1} stamp={d:.1} draw={d:.1}; stamp={d:.1}%",
                .{ self.timings.frames, us(avg.intrinsic), us(avg.relative), us(avg.placement), us(avg.stamping), us(avg.drawing), stamp_share },
            );
            std.log.info(
                "ui five-pass max us intrinsic={d:.1} relative={d:.1} place={d:.1} stamp={d:.1} draw={d:.1}",
                .{ us(max.intrinsic), us(max.relative), us(max.placement), us(max.stamping), us(max.drawing) },
            );
            const s = self.state;
            std.log.info(
                "ui state {d}f avg nodes={d:.1} ia_live={d:.1} ia_slots={d:.1}",
                .{ s.frames, s.nodes.mean(s.frames), s.interaction_live.mean(s.frames), s.interaction_slots.mean(s.frames) },
            );
            std.log.info(
                "ui state max nodes={d} ia_live={d} ia_slots={d}",
                .{ s.nodes.max, s.interaction_live.max, s.interaction_slots.max },
            );
            inline for (pool_names, 0..) |name, i| {
                std.log.info(
                    "ui pool {s} live avg={d:.1} max={d} slots avg={d:.1} max={d}",
                    .{ name, s.pool_live[i].mean(s.frames), s.pool_live[i].max, s.pool_slots[i].mean(s.frames), s.pool_slots[i].max },
                );
            }
        }
    };

    /// Record one frame: the host-timed five-pass sample plus this frame's state counts read
    /// from `ctx` and `trees`. A no-op when the capture is compiled out or not requested.
    pub fn record(self: *FrameCapture, timings: ui.FrameProfileSample, ctx: *cb.UiCtx, trees: []const *cb.Node) void {
        if (comptime !compiled_in) return;
        if (!self.isEnabled(ctx.res)) return;
        self.timings.record(timings);
        self.state.record(sample(ctx, trees));
    }

    /// Return and reset both halves once `window` frames have accumulated.
    pub fn takeIfReady(self: *FrameCapture, window: u64) ?Report {
        const timings = self.timings.takeIfReady(window) orelse return null;
        const state = self.state;
        self.state.reset();
        return .{ .timings = timings, .state = state };
    }

    fn isEnabled(self: *FrameCapture, res: *const @import("../res.zig").Resources) bool {
        if (self.enabled) |on| return on;
        const on = requestedFromEnv(res.env(env_var_name));
        self.enabled = on;
        return on;
    }
};

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

// ============================ Tests ==========================================

const testing = std.testing;

test "state stats accumulate sum and max per count and per pool" {
    var stats: StateStats(2) = .{};
    try testing.expectEqual(@as(u64, 0), stats.frames);
    try testing.expectEqual(@as(f64, 0), stats.nodes.mean(stats.frames));

    stats.record(.{ .nodes = 10, .interaction_live = 4, .interaction_slots = 6, .pool_live = .{ 1, 7 }, .pool_slots = .{ 2, 9 } });
    stats.record(.{ .nodes = 30, .interaction_live = 2, .interaction_slots = 6, .pool_live = .{ 3, 5 }, .pool_slots = .{ 2, 11 } });

    try testing.expectEqual(@as(u64, 2), stats.frames);
    try testing.expectEqual(@as(f64, 20), stats.nodes.mean(stats.frames));
    try testing.expectEqual(@as(u64, 30), stats.nodes.max);
    try testing.expectEqual(@as(f64, 3), stats.interaction_live.mean(stats.frames));
    try testing.expectEqual(@as(u64, 4), stats.interaction_live.max);
    try testing.expectEqual(@as(f64, 6), stats.interaction_slots.mean(stats.frames));
    try testing.expectEqual(@as(u64, 6), stats.interaction_slots.max);
    try testing.expectEqual(@as(f64, 2), stats.pool_live[0].mean(stats.frames));
    try testing.expectEqual(@as(u64, 3), stats.pool_live[0].max);
    try testing.expectEqual(@as(f64, 6), stats.pool_live[1].mean(stats.frames));
    try testing.expectEqual(@as(u64, 7), stats.pool_live[1].max);
    try testing.expectEqual(@as(f64, 2), stats.pool_slots[0].mean(stats.frames));
    try testing.expectEqual(@as(f64, 10), stats.pool_slots[1].mean(stats.frames));
    try testing.expectEqual(@as(u64, 11), stats.pool_slots[1].max);

    stats.reset();
    try testing.expectEqual(StateStats(2){}, stats);
}

test "pool names follow the registry and poolIndex resolves a registered type" {
    try testing.expect(pool_count > 0);
    try testing.expectEqualStrings("TabsState", pool_names[poolIndex(cb.UiState.TabsState)]);
    try testing.expectEqualStrings("TextState", pool_names[poolIndex(cb.UiState.TextState)]);
    try testing.expect(poolIndex(cb.UiState.TabsState) != poolIndex(cb.UiState.ScrollState));
}

test "countNodes walks every node of every root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(@as(u64, 0), countNodes(&.{}));

    const a = try cb.Node.create(alloc, "a");
    const a1 = try cb.Node.pcreate(alloc, "a1", a);
    _ = try cb.Node.pcreate(alloc, "a1x", a1);
    _ = try cb.Node.pcreate(alloc, "a2", a);
    const b = try cb.Node.create(alloc, "b");
    _ = try cb.Node.pcreate(alloc, "b1", b);

    try testing.expectEqual(@as(u64, 4), countNodes(&.{a}));
    try testing.expectEqual(@as(u64, 6), countNodes(&.{ a, b }));
}

test "sample counts slots touched this frame separately from pool storage" {
    var u = cb.UiCtx.init(undefined, testing.allocator, undefined);
    defer u.deinit();
    const tabs = poolIndex(cb.UiState.TabsState);
    const text = poolIndex(cb.UiState.TextState);

    // Frame 1: two interaction slots and two TabsState slots come alive.
    u.beginFrame();
    u.setFlag(1, .hovering, true);
    u.setFlag(2, .hovering, true);
    _ = u.cache(10, cb.UiState.TabsState);
    _ = u.cache(11, cb.UiState.TabsState);
    var s = sample(&u, &.{});
    try testing.expectEqual(@as(u64, 0), s.nodes);
    try testing.expectEqual(@as(u64, 2), s.interaction_live);
    try testing.expectEqual(@as(u64, 2), s.interaction_slots);
    try testing.expectEqual(@as(u64, 2), s.pool_live[tabs]);
    try testing.expectEqual(@as(u64, 2), s.pool_slots[tabs]);
    try testing.expectEqual(@as(u64, 0), s.pool_live[text]);
    try testing.expectEqual(@as(u64, 0), s.pool_slots[text]);
    u.endFrame();

    // Frame 2: only one of each is touched. Before the prune the untouched slots are still
    // stored but no longer live-this-frame.
    u.beginFrame();
    u.setFlag(1, .hovering, true);
    _ = u.cache(10, cb.UiState.TabsState);
    s = sample(&u, &.{});
    try testing.expectEqual(@as(u64, 1), s.interaction_live);
    try testing.expectEqual(@as(u64, 2), s.interaction_slots);
    try testing.expectEqual(@as(u64, 1), s.pool_live[tabs]);
    try testing.expectEqual(@as(u64, 2), s.pool_slots[tabs]);
    u.endFrame();

    // Frame 3: the pruned slots are holes — gone from live, still counted as storage.
    u.beginFrame();
    u.setFlag(1, .hovering, true);
    _ = u.cache(10, cb.UiState.TabsState);
    s = sample(&u, &.{});
    try testing.expectEqual(@as(u64, 1), s.interaction_live);
    try testing.expectEqual(@as(u64, 2), s.interaction_slots);
    try testing.expectEqual(@as(u64, 1), s.pool_live[tabs]);
    try testing.expectEqual(@as(u64, 2), s.pool_slots[tabs]);
    u.endFrame();
}

test "frame capture records only when enabled and resets both halves on a ready window" {
    if (comptime !compiled_in) return error.SkipZigTest;
    var u = cb.UiCtx.init(undefined, testing.allocator, undefined);
    defer u.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try cb.Node.create(arena.allocator(), "root");
    _ = try cb.Node.pcreate(arena.allocator(), "leaf", root);
    const trees: []const *cb.Node = &.{root};

    var capture: FrameCapture = .{ .enabled = false };
    u.beginFrame();
    capture.record(.{ .stamping = 5 }, &u, trees);
    try testing.expectEqual(@as(?FrameCapture.Report, null), capture.takeIfReady(1));
    try testing.expectEqual(@as(u64, 0), capture.state.frames);

    capture.enabled = true;
    capture.record(.{ .stamping = 5, .drawing = 100 }, &u, trees);
    try testing.expectEqual(@as(?FrameCapture.Report, null), capture.takeIfReady(2));
    u.setFlag(7, .hovering, true);
    capture.record(.{ .stamping = 7, .drawing = 200 }, &u, trees);

    const report = capture.takeIfReady(2).?;
    try testing.expectEqual(@as(u64, 2), report.timings.frames);
    try testing.expectEqual(@as(u64, 7), report.timings.maximum.stamping);
    try testing.expectEqual(@as(u64, 150), report.timings.average.drawing);
    try testing.expectEqual(@as(u64, 2), report.state.frames);
    try testing.expectEqual(@as(f64, 2), report.state.nodes.mean(report.state.frames));
    try testing.expectEqual(@as(u64, 2), report.state.nodes.max);
    try testing.expectEqual(@as(u64, 1), report.state.interaction_live.max);
    try testing.expectEqual(@as(f64, 0.5), report.state.interaction_live.mean(report.state.frames));
    report.log();

    try testing.expectEqual(@as(u64, 0), capture.timings.frames);
    try testing.expectEqual(@as(u64, 0), capture.state.frames);
    try testing.expectEqual(@as(?FrameCapture.Report, null), capture.takeIfReady(2));
}
