//! The neighbours: the handler for `NeighbourDeal`, which settles a deal with one of Act II's
//! stub neighbours (`rules/neighbours.zig`) on both sides in one function: the neighbour's books
//! and the agent's ledger and goods. It seeds the stub book on first use. A refused deal changes
//! nothing and is answered by `Refused`; one that settles emits `NeighbourSettled`.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const comp = @import("../components.zig");
const nb = @import("../rules/neighbours.zig");
const ledger = @import("../rules/ledger.zig");
const capital = @import("../rules/capital.zig");
const res_mod = @import("../res.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const Resources = res_mod.Resources;
const Reason = events.Refused.Reason;

/// The neighbours the stub book is seeded with.
pub const people = 24;

/// What the settlement keeps back from trade, by item (`nb.items`): a larder floor, a little
/// water, and some biomass to build with. A stand-in until HOLDINGS owns the reserve
/// (`docs/roadmap.md`, PORT-06). What is held beyond it is spare, which is what a neighbour's
/// verdict weighs.
pub const reserve = blk: {
    var r: [nb.item_count]f32 = @splat(0);
    r[0] = 6;
    r[1] = 2;
    r[5] = 10;
    break :blk r;
};

/// How much of item `i` (`nb.items`) the agent holds.
pub fn heldItem(w: *World, e: Entity, cat: *const @import("../data/roster.zig").Catalog, i: usize) f32 {
    const item = ledger.item(cat, nb.items[i]) orelse return 0;
    return switch (item) {
        .resource => |r| ledger.balance(w, e, r),
        .good => |gi| if (w.get(e, comp.Goods)) |g| @floatFromInt(g.count[gi]) else 0,
    };
}

pub fn neighbour_deal(
    w: *World,
    res: *Resources,
    intents: ecs.EventReader(events.NeighbourDeal, .neighbours),
    settled: ecs.EventWriter(events.NeighbourSettled),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (deal(w, res, it)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .neighbour_deal, .reason = reason });
        } else {
            _ = settled.push(.{ .agent = it.agent, .neighbour = it.neighbour });
        }
    }
}

/// Judge `it` in the neighbour's own valuation and against what the agent holds; on any failure
/// return the reason and change nothing, else settle both sides.
fn deal(w: *World, res: *Resources, it: events.NeighbourDeal) ?Reason {
    const m = &res.sim.neighbours;
    if (!m.seeded) m.seed(people);
    if (it.neighbour >= m.n) return .unavailable;
    var held: [nb.item_count]f32 = undefined;
    var spare: [nb.item_count]f32 = undefined;
    for (0..nb.item_count) |i| {
        held[i] = heldItem(w, it.agent, &res.catalog, i);
        spare[i] = @max(0, held[i] - reserve[i]);
    }
    if (nb.verdict(m.agents[it.neighbour], it.give, it.take, spare) != .accept) return .not_wanted;
    for (0..nb.item_count) |i| if (@as(f32, @floatFromInt(it.give[i])) > held[i]) return .short;
    if (@as(f32, @floatFromInt(it.give[nb.coin])) > ledger.balance(w, it.agent, .coin)) return .short;

    m.settle(it.neighbour, it.give, it.take);
    for (0..nb.item_count) |i| {
        if (it.give[i] > 0) moveItem(w, it.agent, res, i, -@as(f32, @floatFromInt(it.give[i])));
        if (it.take[i] > 0) moveItem(w, it.agent, res, i, @floatFromInt(it.take[i]));
    }
    _ = ledger.move(w, it.agent, .coin, @as(f32, @floatFromInt(it.take[nb.coin])) - @as(f32, @floatFromInt(it.give[nb.coin])));
    return null;
}

/// Move `n` of item `i` into (or, negative, out of) the agent's holdings: a resource on the
/// ledger, a good through `capital`, so its effect lands or leaves once.
fn moveItem(w: *World, e: Entity, res: *Resources, i: usize, n: f32) void {
    const item = ledger.item(&res.catalog, nb.items[i]) orelse return;
    switch (item) {
        .resource => |r| _ = ledger.move(w, e, r, n),
        .good => |gi| {
            const units: u32 = @intFromFloat(@abs(n));
            if (n > 0) capital.acquire(w, e, res, gi, units) else _ = capital.release(w, e, res, gi, units);
        },
    }
}

// ============================ Tests ==========================================

const testing = std.testing;
const roster = @import("../data/roster.zig");

fn rig() !Resources {
    var res = Resources{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
    res.events.update();
    return res;
}

fn settler(w: *World, coin: f32) Entity {
    return w.spawn(.{ comp.InventoryFood{}, comp.InventoryWater{}, comp.InventoryBiomass{}, comp.InventoryCoin{ .v = coin }, comp.Goods{}, comp.Granted{} });
}

/// One unit of what neighbour 0 sells (a forager's biomass) for its asking price in coin.
fn fairDeal(m: *const nb.Market, e: Entity) events.NeighbourDeal {
    var d = events.NeighbourDeal{ .agent = e, .neighbour = 0, .give = @splat(0), .take = @splat(0) };
    d.take[5] = 1;
    d.give[nb.coin] = m.agents[0].ask[5];
    return d;
}

fn refusal(res: *Resources) ?events.Refused {
    var cursor: u64 = 0;
    return res.events.readerAt(events.Refused, &cursor).next();
}

test "neighbour_deal seeds the book, and refuses an unwanted or unpaid deal without settling" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    const e = settler(&w, 0);

    // Coin the agent does not hold.
    var probe: nb.Market = .{};
    probe.seed(people);
    _ = res.events.writer(events.NeighbourDeal).push(fairDeal(&probe, e));
    ecs.run(&w, &res, neighbour_deal);
    try testing.expect(res.sim.neighbours.seeded);
    try testing.expectEqual(events.Refused{ .agent = e, .intent = .neighbour_deal, .reason = .short }, refusal(&res).?);
    try testing.expectEqual(probe.agents[0].sells, res.sim.neighbours.agents[0].sells);
    try testing.expectEqual(@as(f32, 0), ledger.balance(&w, e, .biomass));

    // Nothing offered for it: the neighbour does not want the deal.
    res.events.update();
    res.events.update();
    var none = fairDeal(&probe, e);
    none.give[nb.coin] = 0;
    _ = res.events.writer(events.NeighbourDeal).push(none);
    ecs.run(&w, &res, neighbour_deal);
    try testing.expectEqual(Reason.not_wanted, refusal(&res).?.reason);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.NeighbourSettled));
}

test "neighbour_deal settles both sides and emits NeighbourSettled" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    const e = settler(&w, 50);
    res.sim.neighbours.seed(people);
    const d = fairDeal(&res.sim.neighbours, e);
    const ask = d.give[nb.coin];
    const sells = res.sim.neighbours.agents[0].sells[5];
    const coin = res.sim.neighbours.agents[0].coin;
    _ = res.events.writer(events.NeighbourDeal).push(d);
    ecs.run(&w, &res, neighbour_deal);
    ecs.run(&w, &res, neighbour_deal); // the intent is consumed once

    // The neighbour's side: one fewer to sell, the coin received, evidence left.
    try testing.expectEqual(sells - 1, res.sim.neighbours.agents[0].sells[5]);
    try testing.expectEqual(coin + ask, res.sim.neighbours.agents[0].coin);
    try testing.expect(res.sim.neighbours.evidence(5) != null);
    // The agent's side: the biomass in, the coin out.
    try testing.expectEqual(@as(f32, 1), ledger.balance(&w, e, .biomass));
    try testing.expectEqual(50 - @as(f32, @floatFromInt(ask)), ledger.balance(&w, e, .coin));
    try testing.expect(refusal(&res) == null);
    var cursor: u64 = 0;
    try testing.expectEqual(events.NeighbourSettled{ .agent = e, .neighbour = 0 }, res.events.readerAt(events.NeighbourSettled, &cursor).next().?);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.NeighbourSettled));
}
