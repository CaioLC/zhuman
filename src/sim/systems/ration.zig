//! The ration handler: a `SetRation` intent sets the agent's metabolism rate, clamped into the
//! configured band by `Config.clampMetabolism`, the one place a rate is made legal. An agent with
//! no metabolism refuses it with `Refused`.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const comp = @import("../components.zig");
const res_mod = @import("../res.zig");

const World = ecs.World;

pub fn ration(
    w: *World,
    cfg: *const res_mod.Config,
    intents: ecs.EventReader(events.SetRation, .ration),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        const met = w.get(it.agent, comp.Metabolism) orelse {
            _ = refused.push(.{ .agent = it.agent, .intent = .set_ration, .reason = .unavailable });
            continue;
        };
        met.rate = cfg.clampMetabolism(it.rate);
    }
}

// ============================ Tests ==========================================

const testing = std.testing;

test "ration refuses an agent with no metabolism without mutating and emits Refused" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = res_mod.Resources{};
    res.events.update();
    const e = w.spawn(.{comp.Vigor{}});
    _ = res.events.writer(events.SetRation).push(.{ .agent = e, .rate = 1.5 });
    ecs.run(&w, &res, ration);
    try testing.expect(!w.has(e, comp.Metabolism));
    var cursor: u64 = 0;
    try testing.expectEqual(events.Refused{ .agent = e, .intent = .set_ration, .reason = .unavailable }, res.events.readerAt(events.Refused, &cursor).next().?);
}

test "ration sets the rate, clamped into the band, once per intent" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = res_mod.Resources{};
    res.events.update();
    const e = w.spawn(.{comp.Metabolism{}});
    _ = res.events.writer(events.SetRation).push(.{ .agent = e, .rate = 1.5 });
    ecs.run(&w, &res, ration);
    try testing.expectEqual(@as(f32, 1.5), w.get(e, comp.Metabolism).?.rate);
    _ = res.events.writer(events.SetRation).push(.{ .agent = e, .rate = res.config.metabolism_rate_max * 2 });
    ecs.run(&w, &res, ration);
    try testing.expectEqual(res.config.metabolism_rate_max, w.get(e, comp.Metabolism).?.rate);
    w.get(e, comp.Metabolism).?.rate = 1;
    ecs.run(&w, &res, ration); // nothing new to read
    try testing.expectEqual(@as(f32, 1), w.get(e, comp.Metabolism).?.rate);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Refused));
}
