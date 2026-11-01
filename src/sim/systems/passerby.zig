//! The passerby: the update system that advances the Act I encounter on the sim clock
//! (`market.tick`) and states each arrival and departure as a fact.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const market = @import("../rules/market.zig");
const res_mod = @import("../res.zig");

pub fn passerby(
    sim: *res_mod.Sim,
    time: *const res_mod.Time,
    cfg: *const res_mod.Config,
    arrived: ecs.EventWriter(events.Arrived),
    departed: ecs.EventWriter(events.Departed),
) void {
    switch (market.tick(&sim.encounter, time.dt, .{}, cfg.secs_per_day)) {
        .none => {},
        .arrived => _ = arrived.push(.{ .who = .passerby }),
        .departed => _ = departed.push(.{ .who = .passerby }),
    }
}

// ============================ Tests ==========================================

const testing = std.testing;

test "passerby emits Arrived when the encounter opens and Departed when it ends" {
    var w = ecs.World.init();
    var res = res_mod.Resources{};
    res.events.update();
    const sched = market.Schedule{};
    const spd = res.config.secs_per_day;
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
