//! The passerby: the update system that advances the Act I encounter on the sim clock
//! (`market.tick`) and states each arrival and departure as a fact. A departure is when the
//! passerby takes stock of the visit (`Encounter.remember`), on the run's own chance. The camp a
//! visit waits on is read here, from the world: the buildable good kinds the player owns
//! (`capital.goodsOwned`), none without a player.

const std = @import("std");
const ecs = @import("../ecs.zig");
const comp = @import("../components.zig");
const tag = @import("../tags.zig");
const events = @import("../events.zig");
const capital = @import("../rules/capital.zig");
const market = @import("../rules/market.zig");
const roster = @import("../data/roster.zig");
const res_mod = @import("../res.zig");

const World = ecs.World;
const Entity = ecs.Entity;

pub fn passerby(
    w: *const World,
    sim: *res_mod.Sim,
    time: *const res_mod.Time,
    cfg: *const res_mod.Config,
    cat: *const roster.Catalog,
    player: ecs.MaybeSingle(.{ Entity, comp.Goods, ecs.With(tag.Player) }),
    arrived: ecs.EventWriter(events.Arrived),
    departed: ecs.EventWriter(events.Departed),
) void {
    const kinds: u32 = if (player.get()) |p| capital.goodsOwned(w, p[0], cat) else 0;
    switch (market.tick(&sim.encounter, time.dt, .{}, cfg.secs_per_day, kinds)) {
        .none => {},
        .arrived => _ = arrived.push(.{ .who = .passerby }),
        .departed => {
            sim.encounter.remember(sim.prng.random());
            _ = departed.push(.{ .who = .passerby });
        },
    }
}

// ============================ Tests ==========================================

const testing = std.testing;

const spawn_player = @import("./run.zig").spawn_player;

/// Give `e` one each of the first `n` buildable goods of the catalog.
fn camp(w: *World, e: Entity, cat: *const roster.Catalog, n: u32) void {
    var left = n;
    for (cat.goods, 0..) |g, gi| {
        if (left == 0) return;
        if (!g.buildable) continue;
        w.get(e, comp.Goods).?.count[gi] = 1;
        left -= 1;
    }
}

test "passerby emits Arrived when the encounter opens and Departed when it ends" {
    var w = try ecs.World.init(std.testing.allocator);
    defer w.deinit();
    var res = res_mod.Resources{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
    defer res.catalog.deinit();
    res.events.update();
    const sched = market.Schedule{};
    const spd = res.config.secs_per_day;
    camp(&w, spawn_player(&w, &res.catalog), &res.catalog, sched.camp_kinds);
    res.time.dt = 0.001;
    ecs.run(&w, &res, passerby); // absent → approaching: no fact
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Arrived));
    res.time.dt = sched.approach_days * spd;
    ecs.run(&w, &res, passerby);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.Arrived));
    try testing.expect(res.sim.encounter.dealable());
    res.time.dt = sched.linger_days * spd;
    ecs.run(&w, &res, passerby);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.Departed));
    var cursor: u64 = 0;
    try testing.expectEqual(events.Who.passerby, res.events.readerAt(events.Departed, &cursor).next().?.who);
}

test "passerby waits for the player's camp, read from the goods the player owns" {
    var w = try ecs.World.init(std.testing.allocator);
    defer w.deinit();
    var res = res_mod.Resources{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
    defer res.catalog.deinit();
    res.events.update();
    const sched = market.Schedule{};
    // No player at all: no one comes.
    res.time.dt = 0.001;
    ecs.run(&w, &res, passerby);
    try testing.expectEqual(market.Phase.absent, res.sim.encounter.phase);
    // A bare-handed player, then one good short of a camp: still no one, however long.
    const e = spawn_player(&w, &res.catalog);
    camp(&w, e, &res.catalog, sched.camp_kinds - 1);
    res.time.dt = 20 * res.config.secs_per_day;
    ecs.run(&w, &res, passerby);
    try testing.expectEqual(market.Phase.absent, res.sim.encounter.phase);
    // The camp stands: the passerby is seen approaching on the next tick.
    camp(&w, e, &res.catalog, sched.camp_kinds);
    res.time.dt = 0.001;
    ecs.run(&w, &res, passerby);
    try testing.expectEqual(market.Phase.approaching, res.sim.encounter.phase);
}
