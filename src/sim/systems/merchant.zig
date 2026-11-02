//! The Act II Coin Merchant: its lots, the update system that runs its visits on the sim clock
//! (`market.tickMerchant`), and the handler for `MerchantDeal`. The visit, and the lots sold in
//! it, live on `Sim.merchant`; a deal revalidates against them and moves both sides here, in one
//! function. A refused deal changes nothing and is answered by `Refused`; one that settles emits
//! `Traded{ .with = .merchant }`.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const market = @import("../rules/market.zig");
const ledger = @import("../rules/ledger.zig");
const capital = @import("../rules/capital.zig");
const migration = @import("../data/migration.zig");
const roster = @import("../data/roster.zig");
const res_mod = @import("../res.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const Resources = res_mod.Resources;
const Reason = events.Refused.Reason;

// —— The merchant's lots (a stand-in) ————————————————————————————————————————————————
// The merchant's finite lots, priced in the stub Coin and authored here in place of a stock and
// a valuation of the merchant's own (`docs/roadmap.md`). A term names a `Resource` or
// a good by catalog id; a lot is one unit of trade, scaled linearly by the lots taken. BUY lots
// carry the merchant's stock per visit; SELL lots are bounded by what the settlement holds.

pub const MerchantTerm = struct { item: []const u8, n: f32 };

pub const MerchantLot = struct {
    id: u32,
    sell: bool = false,
    lot: []const u8,
    effect: []const u8,
    price: []const MerchantTerm,
    receive: []const MerchantTerm,
    stock: ?u32 = null,
    consequence: []const u8 = "",
};

pub const lots = [_]MerchantLot{
    .{ .id = 1, .lot = "Water \u{00d7}6", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 5 }}, .receive = &.{.{ .item = "water", .n = 6 }}, .stock = 3 },
    .{ .id = 2, .lot = "Minerals \u{00d7}5", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 7 }}, .receive = &.{.{ .item = "minerals", .n = 5 }}, .stock = 2 },
    .{ .id = 3, .lot = "Fuel \u{00d7}4", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 8 }}, .receive = &.{.{ .item = "fuel", .n = 4 }}, .stock = 2 },
    .{ .id = 4, .lot = "Metal \u{00d7}3", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 12 }}, .receive = &.{.{ .item = "metal", .n = 3 }}, .stock = 2 },
    .{ .id = 5, .lot = "Food \u{00d7}10", .effect = "preserved, keeps well", .price = &.{.{ .item = "coin", .n = 8 }}, .receive = &.{.{ .item = "food", .n = 10 }}, .stock = 3 },
    .{ .id = 6, .lot = "Biomass \u{00d7}15", .effect = "baled fibre", .price = &.{.{ .item = "coin", .n = 5 }}, .receive = &.{.{ .item = "biomass", .n = 15 }}, .stock = 4 },
    .{ .id = 7, .lot = "Cut stone \u{00d7}4", .effect = "dressed downriver", .price = &.{.{ .item = "coin", .n = 9 }}, .receive = &.{.{ .item = "worked_stone", .n = 4 }}, .stock = 2 },
    .{ .id = 8, .lot = "Glass pane \u{00d7}1", .effect = "no kiln here can make it", .price = &.{.{ .item = "coin", .n = 22 }}, .receive = &.{.{ .item = "glass_pane", .n = 1 }}, .stock = 1 },
    .{ .id = 9, .lot = "Hand tools \u{00d7}1", .effect = "forged beyond the valley", .price = &.{.{ .item = "coin", .n = 26 }}, .receive = &.{.{ .item = "hand_tools", .n = 1 }}, .stock = 2 },
    .{ .id = 10, .lot = "Fishing net \u{00d7}1", .effect = "better Fish tool", .price = &.{.{ .item = "coin", .n = 18 }}, .receive = &.{.{ .item = "fishing_net", .n = 1 }}, .stock = 1, .consequence = "Replaces Fishing rod: Fish yield rises. The unlock does not stack." },
    .{ .id = 11, .lot = "Carpenter bench \u{00d7}1", .effect = "finished capital", .price = &.{.{ .item = "coin", .n = 60 }}, .receive = &.{.{ .item = "carpenter_bench", .n = 1 }}, .stock = 1 },
    .{ .id = 101, .sell = true, .lot = "Biomass \u{00d7}6", .effect = "leaves your stock", .price = &.{.{ .item = "biomass", .n = 6 }}, .receive = &.{.{ .item = "coin", .n = 5 }} },
    .{ .id = 102, .sell = true, .lot = "Food \u{00d7}8", .effect = "leaves your larder", .price = &.{.{ .item = "food", .n = 8 }}, .receive = &.{.{ .item = "coin", .n = 4 }} },
    .{ .id = 103, .sell = true, .lot = "Fuel \u{00d7}4", .effect = "burned down the ridge", .price = &.{.{ .item = "fuel", .n = 4 }}, .receive = &.{.{ .item = "coin", .n = 6 }} },
    .{ .id = 104, .sell = true, .lot = "Minerals \u{00d7}3", .effect = "they would take it", .price = &.{.{ .item = "minerals", .n = 3 }}, .receive = &.{.{ .item = "coin", .n = 4 }} },
    .{ .id = 105, .sell = true, .lot = "Metal \u{00d7}3", .effect = "they would take it", .price = &.{.{ .item = "metal", .n = 3 }}, .receive = &.{.{ .item = "coin", .n = 9 }} },
    .{ .id = 106, .sell = true, .lot = "Water \u{00d7}5", .effect = "drawn this morning", .price = &.{.{ .item = "water", .n = 5 }}, .receive = &.{.{ .item = "coin", .n = 3 }} },
    .{ .id = 107, .sell = true, .lot = "Forge \u{00d7}1", .effect = "your spare stock", .price = &.{.{ .item = "forge", .n = 1 }}, .receive = &.{.{ .item = "coin", .n = 30 }}, .consequence = "A spare goes first; the forge you use keeps its verb." },
    .{ .id = 108, .sell = true, .lot = "Lean-to \u{00d7}1", .effect = "your spare stock", .price = &.{.{ .item = "lean_to", .n = 1 }}, .receive = &.{.{ .item = "coin", .n = 7 }} },
};

comptime {
    // `Sim.merchant.taken` is sized by the rule, which may not import a system.
    std.debug.assert(lots.len == market.merchant_lot_count);
}

/// Lot `i`'s stock left this visit, or null for a SELL lot (bounded by the agent's holdings).
pub fn stockLeft(visit: *const market.MerchantVisit, i: usize) ?u32 {
    const s = lots[i].stock orelse return null;
    return s -| visit.taken[i];
}

// —— The visits ————————————————————————————————————————————————————————————————————————

/// Advance the merchant's visit by `dt`; a departure and a return are facts, and a return is a
/// new visit with its lots restocked.
pub fn merchant(
    sim: *res_mod.Sim,
    time: *const res_mod.Time,
    cfg: *const res_mod.Config,
    arrived: ecs.EventWriter(events.Arrived),
    departed: ecs.EventWriter(events.Departed),
) void {
    switch (market.tickMerchant(&sim.merchant, time.dt, .{}, cfg.secs_per_day)) {
        .none => {},
        .arrived => {
            sim.merchant.taken = @splat(0);
            _ = arrived.push(.{ .who = .merchant });
        },
        .departed => _ = departed.push(.{ .who = .merchant }),
    }
}

// —— The deal ——————————————————————————————————————————————————————————————————————————

pub fn merchant_deal(
    w: *World,
    res: *Resources,
    intents: ecs.EventReader(events.MerchantDeal, .merchant),
    traded: ecs.EventWriter(events.Traded),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (deal(w, res, it)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .merchant_deal, .reason = reason });
        } else {
            _ = traded.push(.{
                .agent = it.agent,
                .with = .merchant,
                .direction = if (lots[it.lot].sell) .sell else .buy,
                .lot = it.lot,
                .lots = it.lots,
                .act = migration.actOf(w, it.agent),
            });
        }
    }
}

/// Revalidate `it` against the visit and the agent's holdings; on any failure return the reason
/// and change nothing, else move both sides and mark the lots taken.
fn deal(w: *World, res: *Resources, it: events.MerchantDeal) ?Reason {
    // A standing Exchange never leaves; the cart does.
    if (!res.sim.exchange.standing and !res.sim.merchant.dealable()) return .departed;
    if (it.lot >= lots.len) return .unavailable;
    if (it.lots == 0) return .sold_out;
    const rec = &lots[it.lot];
    if (stockLeft(&res.sim.merchant, it.lot)) |left| if (left < it.lots) return .sold_out;
    const scale: f32 = @floatFromInt(it.lots);
    for (rec.price) |term| {
        const item = ledger.item(&res.catalog, term.item) orelse continue;
        if (ledger.held(w, it.agent, &res.catalog, .{ .item = term.item, .n = term.n }) < term.n * scale) {
            return if (item == .good) .not_owned else .unaffordable;
        }
    }
    moveSide(w, it.agent, res, rec.price, scale, -1);
    moveSide(w, it.agent, res, rec.receive, scale, 1);
    if (rec.stock != null) res.sim.merchant.taken[it.lot] +|= @intCast(@min(it.lots, std.math.maxInt(u16)));
    return null;
}

/// Move one side of a deal at `scale` lots: `sign` −1 pays out, +1 receives. Resources move on
/// the ledger; goods through `capital`, so an effect lands or leaves once.
fn moveSide(w: *World, e: Entity, res: *Resources, terms: []const MerchantTerm, scale: f32, sign: f32) void {
    for (terms) |term| {
        const item = ledger.item(&res.catalog, term.item) orelse continue;
        const n = term.n * scale;
        switch (item) {
            .resource => |r| _ = ledger.move(w, e, r, sign * n),
            .good => |gi| {
                const units: u32 = @intFromFloat(@round(n));
                if (sign > 0) capital.acquire(w, e, res, gi, units) else _ = capital.release(w, e, res, gi, units);
            },
        }
    }
}

// ============================ Tests ==========================================

const testing = std.testing;
const comp = @import("../components.zig");

fn rig() !Resources {
    var res = Resources{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
    res.events.update();
    return res;
}

fn settler(w: *World, coin: f32) Entity {
    return w.spawn(.{ comp.Vigor{ .v = 10, .max = 10 }, comp.InventoryFood{}, comp.InventoryBiomass{}, comp.InventoryWater{}, comp.InventoryCoin{ .v = coin }, comp.Goods{}, comp.Granted{} });
}

fn refusal(res: *Resources) ?events.Refused {
    var cursor: u64 = 0;
    return res.events.readerAt(events.Refused, &cursor).next();
}

test "every merchant lot names items the catalog knows" {
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    for (lots) |lot| {
        for (lot.price) |term| try testing.expect(ledger.item(&cat, term.item) != null);
        for (lot.receive) |term| try testing.expect(ledger.item(&cat, term.item) != null);
    }
}

test "merchant_deal refuses without mutating: short of coin, sold out, the cart away" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const e = settler(&w, 4); // water costs 5 coin a lot
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = 0, .lots = 1 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectEqual(@as(f32, 4), ledger.balance(&w, e, .coin));
    try testing.expectEqual(@as(f32, 0), ledger.balance(&w, e, .water));
    try testing.expectEqual(events.Refused{ .agent = e, .intent = .merchant_deal, .reason = .unaffordable }, refusal(&res).?);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Traded));

    res.events.update();
    res.events.update();
    w.get(e, comp.InventoryCoin).?.v = 100;
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = 0, .lots = 4 }); // three in stock
    ecs.run(&w, &res, merchant_deal);
    try testing.expectEqual(Reason.sold_out, refusal(&res).?.reason);

    res.events.update();
    res.events.update();
    res.sim.merchant.present = false;
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = 0, .lots = 1 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectEqual(Reason.departed, refusal(&res).?.reason);
    try testing.expectEqual(@as(f32, 100), ledger.balance(&w, e, .coin));
    try testing.expectEqual(@as(u16, 0), res.sim.merchant.taken[0]);
}

test "merchant_deal moves both sides, takes the stock and emits Traded; a new visit restocks" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const e = settler(&w, 20);
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = 0, .lots = 2 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectEqual(@as(f32, 10), ledger.balance(&w, e, .coin));
    try testing.expectEqual(@as(f32, 12), ledger.balance(&w, e, .water));
    try testing.expectEqual(@as(u16, 2), res.sim.merchant.taken[0]);
    try testing.expectEqual(@as(?u32, 1), stockLeft(&res.sim.merchant, 0));
    try testing.expect(refusal(&res) == null);
    var cursor: u64 = 0;
    const got = res.events.readerAt(events.Traded, &cursor).next().?;
    try testing.expectEqual(events.Who.merchant, got.with);
    try testing.expectEqual(market.Direction.buy, got.direction);
    try testing.expectEqual(@as(u32, 0), got.lot);
    try testing.expectEqual(@as(u32, 2), got.lots);

    // The cart leaves and comes back: a new visit, the lot restocked.
    const spd = res.config.secs_per_day;
    const sched = market.MerchantSchedule{};
    res.time.dt = sched.stay_days * spd + 1;
    ecs.run(&w, &res, merchant);
    try testing.expect(!res.sim.merchant.dealable());
    try testing.expectEqual(@as(u16, 2), res.sim.merchant.taken[0]); // the books keep until the return
    res.time.dt = sched.away_days * spd;
    ecs.run(&w, &res, merchant);
    try testing.expect(res.sim.merchant.dealable());
    try testing.expectEqual(@as(u16, 0), res.sim.merchant.taken[0]);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.Departed));
    try testing.expectEqual(@as(usize, 1), res.events.len(events.Arrived));
}

test "a SELL lot of a good the agent does not own is refused" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const e = settler(&w, 0);
    const forge: u32 = for (lots, 0..) |l, i| {
        if (l.id == 107) break @intCast(i);
    } else unreachable;
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = forge, .lots = 1 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectEqual(Reason.not_owned, refusal(&res).?.reason);
    try testing.expectEqual(@as(f32, 0), ledger.balance(&w, e, .coin));
}
