//! The schedule: every system the simulation runs, per `GameState`, in the order it runs, and
//! `tick`, the one call the host makes per frame.
//!
//! A state's `handle` set reads the intents and runs every tick, paused or not, so an intent
//! the UI wrote applies the next frame and a slider does not snap back while the menu is open.
//! Its `update` set spends time and detects what time changed, and runs only while time passes
//! (`time.dt > 0`). `log` is last in both of an act's sets, after every writer of a fact: a fact
//! a handler writes while the run is paused becomes its line in the same tick instead of
//! expiring unread, and its cursor makes the second run of a tick read nothing twice. The
//! transitions are systems too: `new_run` in every `handle` set, `begin_run` entering Act I,
//! `cross_curtain` entering Act II, and the detectors `detect_death`, `detect_shelter` and
//! `detect_exchange` late in the acts' `update` sets. Act III runs Act II's sets without the
//! merchant's clock and the Exchange detector.
//!
//! The derived components' writers close both of an act's sets just before `log`: `condition`,
//! then `outlook` and `quotes`, so an intent a handler applies while the run is paused, or a build
//! that finished this tick, shows in the band, the BODY lines and the tiles the next frame reads.
//! `condition` also runs right after `metabolize`, so the metabolism's crossing is a fact in the
//! tick it happens.

const std = @import("std");
const engine = @import("ecs");
const ecs = @import("./ecs.zig");
const GameState = @import("./state.zig").GameState;
const Resources = @import("./res.zig").Resources;

const tick_sys = @import("./systems/tick.zig");
const labor = @import("./systems/labor.zig");
const build = @import("./systems/build.zig");
const generators = @import("./systems/generators.zig");
const passerby = @import("./systems/passerby.zig");
const ration = @import("./systems/ration.zig");
const barter = @import("./systems/barter.zig");
const merchant = @import("./systems/merchant.zig");
const research = @import("./systems/research.zig");
const exchange = @import("./systems/exchange.zig");
const neighbours = @import("./systems/neighbours.zig");
const run = @import("./systems/run.zig");
const curtain = @import("./systems/curtain.zig");
const log = @import("./systems/log.zig");
const condition = @import("./systems/condition.zig");
const outlook = @import("./systems/outlook.zig");
const quotes = @import("./systems/quotes.zig");

const act_two_handle = .{ labor.labor, build.build, build.cancel, generators.generators_toggle, generators.generators_collect, ration.ration, merchant.merchant_deal, research.research, exchange.raise_exchange, neighbours.neighbour_deal, run.new_run, condition.condition, outlook.outlook, quotes.quotes, log.log };

/// The systems per state, in the order they run.
pub const schedule = engine.Schedule(GameState, .{
    .title = .{ .handle = .{run.new_run} },
    .act_one = .{
        .on_enter = .{run.begin_run},
        .handle = .{ labor.labor, build.build, build.cancel, generators.generators_toggle, generators.generators_collect, ration.ration, barter.barter, run.new_run, condition.condition, outlook.outlook, quotes.quotes, log.log },
        .update = .{ tick_sys.advance_clock, tick_sys.update_food, tick_sys.metabolize, condition.condition, tick_sys.resolve_busy, tick_sys.track_reach, passerby.passerby, generators.generators, tick_sys.mark_dead, tick_sys.despawn_dead, run.detect_death, curtain.detect_shelter, condition.condition, outlook.outlook, quotes.quotes, log.log },
    },
    .act_two = .{
        .on_enter = .{curtain.cross_curtain},
        .handle = act_two_handle,
        .update = .{ tick_sys.advance_clock, tick_sys.update_food, tick_sys.metabolize, condition.condition, tick_sys.resolve_busy, generators.generators, merchant.merchant, tick_sys.mark_dead, tick_sys.despawn_dead, run.detect_death, curtain.detect_exchange, condition.condition, outlook.outlook, quotes.quotes, log.log },
    },
    .act_three = .{
        .handle = act_two_handle,
        .update = .{ tick_sys.advance_clock, tick_sys.update_food, tick_sys.metabolize, condition.condition, tick_sys.resolve_busy, generators.generators, tick_sys.mark_dead, tick_sys.despawn_dead, run.detect_death, condition.condition, outlook.outlook, quotes.quotes, log.log },
    },
    .game_over = .{ .handle = .{run.new_run} },
});

/// One frame of the simulation: open the frame's events, apply a pending transition, run the
/// current state's `handle` set, and its `update` set while time passes.
pub fn tick(w: *ecs.World, res: *Resources) void {
    res.events.update();
    schedule.tick(w, res, &res.states, res.time.dt > 0);
}

// ============================ Tests ==========================================

const testing = std.testing;
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const events = @import("./events.zig");
const roster = @import("./data/roster.zig");
const migration = @import("./data/migration.zig");
const states_list = @typeInfo(GameState).@"enum".field_names;

/// Whether system `f` reads an intent or fact through a scheduled reader: a handler.
fn readsEvents(comptime f: anytype) bool {
    for (@typeInfo(@TypeOf(f)).@"fn".param_types) |PT| {
        const T = PT.?;
        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "_system_param_kind") and T._system_param_kind == .event_reader) return true;
    }
    return false;
}

test "log is last in every update set that runs anything" {
    inline for (states_list) |name| {
        const s = @field(GameState, name);
        const update = comptime schedule.setOf(s, .update);
        if (update.len > 0) {
            try testing.expectEqual(@as(?usize, update.len - 1), comptime schedule.indexOf(s, .update, log.log));
        }
    }
}

test "log is last in every act's handle set" {
    inline for ([_]GameState{ .act_one, .act_two, .act_three }) |s| {
        const handle = comptime schedule.setOf(s, .handle);
        try testing.expectEqual(@as(?usize, handle.len - 1), comptime schedule.indexOf(s, .handle, log.log));
    }
}

test "new_run is in every state's handle set" {
    inline for (states_list) |name| {
        try testing.expect(comptime schedule.indexOf(@field(GameState, name), .handle, run.new_run) != null);
    }
}

test "no handler is in an update set" {
    inline for (states_list) |name| {
        const update = comptime schedule.setOf(@field(GameState, name), .update);
        inline for (update) |sys| try testing.expect(comptime !readsEvents(sys));
    }
    try testing.expect(comptime readsEvents(labor.labor)); // the test can tell a handler
}

test "condition follows metabolize in every update set that runs it" {
    inline for (states_list) |name| {
        const s = @field(GameState, name);
        if (comptime schedule.indexOf(s, .update, tick_sys.metabolize)) |m| {
            try testing.expect(comptime engine.sameSystem(schedule.setOf(s, .update)[m + 1], condition.condition));
        }
    }
}

test "outlook and quotes are the last two before log in every update set and every act's handle set" {
    inline for ([_]GameState{ .act_one, .act_two, .act_three }) |s| {
        inline for (.{ .update, .handle }) |kind| {
            const set = comptime schedule.setOf(s, kind);
            try testing.expect(comptime set.len >= 3);
            try testing.expect(comptime engine.sameSystem(set[set.len - 3], outlook.outlook));
            try testing.expect(comptime engine.sameSystem(set[set.len - 2], quotes.quotes));
            try testing.expect(comptime engine.sameSystem(set[set.len - 1], log.log));
        }
    }
    // Every update set with anything in it is an act's.
    inline for ([_]GameState{ .title, .game_over }) |s| try testing.expectEqual(@as(usize, 0), comptime schedule.setOf(s, .update).len);
}

test "the band is current before the frame's last readers in every act's sets" {
    inline for ([_]GameState{ .act_one, .act_two, .act_three }) |s| {
        inline for (.{ .update, .handle }) |kind| {
            const set = comptime schedule.setOf(s, kind);
            try testing.expect(comptime engine.sameSystem(set[set.len - 4], condition.condition));
        }
    }
}

test "the merchant's clock and the Exchange detector run in Act II only" {
    try testing.expect(comptime schedule.indexOf(.act_two, .update, merchant.merchant) != null);
    try testing.expect(comptime schedule.indexOf(.act_three, .update, merchant.merchant) == null);
    try testing.expect(comptime schedule.indexOf(.act_two, .update, curtain.detect_exchange) != null);
    try testing.expect(comptime schedule.indexOf(.act_three, .update, curtain.detect_exchange) == null);
    try testing.expect(comptime schedule.indexOf(.act_one, .update, run.detect_death).? >
        schedule.indexOf(.act_one, .update, tick_sys.despawn_dead).?);
}

fn rig() !Resources {
    var res: Resources = .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
    res.time.dt = 0.05;
    return res;
}

fn players(w: *ecs.World) usize {
    var it = (ecs.Query(.{ ecs.Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = w }).iter();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn player(w: *ecs.World) ecs.Entity {
    return (ecs.Single(.{ ecs.Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = w }).get()[0];
}

fn logHas(res: *const Resources, text: []const u8) bool {
    for (0..res.sim.log.count) |i| if (std.mem.eql(u8, res.sim.log.get(i).text(), text)) return true;
    return false;
}

fn newRun(w: *ecs.World, res: *Resources) void {
    _ = res.events.writer(events.NewRun).push(.{});
    tick(w, res);
    tick(w, res);
}

test "a run begins, crosses the Act I curtain once, and restarts whole" {
    var w = ecs.World.init();
    var res = try rig();
    defer res.catalog.deinit();
    try testing.expect(res.states.in(.title));
    try testing.expectEqual(@as(usize, 0), players(&w));

    newRun(&w, &res);
    try testing.expect(res.states.in(.act_one));
    try testing.expectEqual(@as(usize, 1), players(&w));
    try testing.expect(logHas(&res, "You wake alone. Cold. Hungry."));

    // The shelter stands: the act ends this tick and Act II is entered on the next.
    const e = player(&w);
    for (res.catalog.goods, 0..) |g, gi| if (g.milestone == .act_one) {
        w.get(e, comp.Goods).?.count[gi] = 1;
    };
    var heard: u64 = 0;
    tick(&w, &res);
    try testing.expect(res.states.in(.act_one));
    try testing.expectEqual(@as(?GameState, .act_two), res.states.next);
    try testing.expectEqual(events.ActEnded{ .act = .act_one }, res.events.readerAt(events.ActEnded, &heard).next().?);

    tick(&w, &res);
    try testing.expect(res.states.in(.act_two));
    try testing.expect(migration.is_migrated(&w, e));
    try testing.expect(res.events.readerAt(events.ActEnded, &heard).next() == null);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.ActEnded));

    // A new run from Act II: one fresh player, a fresh Sim.
    res.sim.exchange.standing = true;
    newRun(&w, &res);
    try testing.expect(res.states.in(.act_one));
    try testing.expectEqual(@as(usize, 1), players(&w));
    try testing.expect(player(&w) != e);
    try testing.expect(!migration.is_migrated(&w, player(&w)));
    try testing.expect(!res.sim.exchange.standing);
    try testing.expect(res.sim.elapsed <= res.time.dt);
}

test "a player at vigor 0 ends the run in game over, where the clock stands still" {
    var w = ecs.World.init();
    var res = try rig();
    defer res.catalog.deinit();
    newRun(&w, &res);
    const e = player(&w);
    w.get(e, comp.Vigor).?.v = 0;
    w.get(e, comp.InventoryFood).?.v = 0;
    tick(&w, &res);
    try testing.expectEqual(@as(usize, 0), players(&w));
    tick(&w, &res);
    try testing.expect(res.states.in(.game_over));
    const elapsed = res.sim.elapsed;
    tick(&w, &res);
    try testing.expectEqual(elapsed, res.sim.elapsed);
}

test "paused, the intents apply and nothing spends time" {
    var w = ecs.World.init();
    var res = try rig();
    defer res.catalog.deinit();
    newRun(&w, &res);
    const e = player(&w);
    res.time.dt = 0;
    const elapsed = res.sim.elapsed;
    _ = res.events.writer(events.SetRation).push(.{ .agent = e, .rate = 1.5 });
    tick(&w, &res);
    try testing.expectApproxEqAbs(@as(f32, 1.5), w.get(e, comp.Metabolism).?.rate, 1e-6);
    try testing.expectEqual(elapsed, res.sim.elapsed);
}

test "paused, a handler's fact still becomes its log line before it expires" {
    var w = ecs.World.init();
    var res = try rig();
    defer res.catalog.deinit();
    newRun(&w, &res);
    const e = player(&w);
    res.time.dt = 0;
    const lines = res.sim.log.count;
    const forage = res.catalog.actionIndex("forage").?;
    _ = res.events.writer(events.BeginLabor).push(.{ .agent = e, .ai = forage });
    tick(&w, &res); // the handler begins the work and the log words WorkBegun, paused
    try testing.expect(w.has(e, comp.Busy));
    try testing.expectEqual(lines + 1, res.sim.log.count);
    tick(&w, &res);
    tick(&w, &res); // the fact has expired; nothing was read twice
    try testing.expectEqual(lines + 1, res.sim.log.count);
}
