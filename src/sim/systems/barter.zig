//! The barter handler: `Barter` intents become `barter.resolve` calls against the passerby. A
//! refused trade changes nothing and is answered by `Refused`; one that settles emits `Traded`
//! from the rule.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const barter_rule = @import("../rules/barter.zig");
const Resources = @import("../res.zig").Resources;

const World = ecs.World;

pub fn barter(
    w: *World,
    res: *Resources,
    intents: ecs.EventReader(events.Barter, .barter),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (barter_rule.resolve(w, it.agent, res, &it.quote, it.lots)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .barter, .reason = reason });
        }
    }
}

// ============================ Tests ==========================================

const testing = std.testing;
const comp = @import("../components.zig");
const market = @import("../rules/market.zig");
const roster = @import("../data/roster.zig");

fn rig() !Resources {
    var res = Resources{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
    res.sim.encounter = .{ .phase = .present, .id = 1 };
    res.sim.encounter.stock = .{ 8, 20, 1, 1 };
    res.events.update();
    return res;
}

fn trader(w: *World) ecs.Entity {
    return w.spawn(.{ comp.Vigor{ .v = 10, .max = 10 }, comp.InventoryFood{ .v = 6, .quality = 1, .spoils = 0 }, comp.InventoryBiomass{ .v = 12 }, comp.Goods{}, comp.Granted{} });
}

/// Food for two materials a lot, eight in stock, against the visit `rev`.
fn foodQuote(rev: u32) market.Quote {
    return .{ .id = 1, .rev = rev, .direction = .buy, .give = market.Bundle.one(.biomass, 2), .receive = market.Bundle.one(.food, 1), .stock = 8 };
}

test "barter refuses a stale quote without mutating and emits Refused" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    const e = trader(&w);
    _ = res.events.writer(events.Barter).push(.{ .agent = e, .quote = foodQuote(2), .lots = 1 });
    ecs.run(&w, &res, barter);
    try testing.expectEqual(@as(f32, 12), w.get(e, comp.InventoryBiomass).?.v);
    try testing.expectEqual(@as(f32, 6), w.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Traded));
    var cursor: u64 = 0;
    try testing.expectEqual(events.Refused{ .agent = e, .intent = .barter, .reason = .stale }, res.events.readerAt(events.Refused, &cursor).next().?);
}

test "barter settles once and emits Traded with the passerby" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    const e = trader(&w);
    _ = res.events.writer(events.Barter).push(.{ .agent = e, .quote = foodQuote(1), .lots = 3 });
    ecs.run(&w, &res, barter);
    ecs.run(&w, &res, barter); // the intent is consumed once
    try testing.expectApproxEqAbs(@as(f32, 6), w.get(e, comp.InventoryBiomass).?.v, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 9), w.get(e, comp.InventoryFood).?.v, 1e-5);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Refused));
    var cursor: u64 = 0;
    const r = res.events.readerAt(events.Traded, &cursor);
    const got = r.next().?;
    try testing.expectEqual(events.Who.passerby, got.with);
    try testing.expectEqual(market.Direction.buy, got.direction);
    try testing.expectApproxEqAbs(@as(f32, 6), got.biomass_moved, 1e-5);
    try testing.expect(r.next() == null);
}
