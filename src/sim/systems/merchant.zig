//! The Act II Coin Merchant: its lots, the update system that runs its visits on the sim clock
//! (`market.tickMerchant`), and the handler for `MerchantDeal`. The visit, and the lots sold in
//! it, live on `Sim.merchant`; a deal revalidates against them and moves both sides here, in one
//! function. A refused deal changes nothing and is answered by `Refused`; one that settles emits
//! `Traded{ .with = .merchant }`.
//!
//! Within a visit every lot is finite and its coin price fixed. The merchant remembers the visit
//! when the cart leaves (`remember`): the lots of one item share a price level, rolled against
//! the lots dealt of it, whoever the agent was (`market.reprice`).

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
// a good by catalog id; a lot is one unit of trade, scaled linearly by the lots taken. `stock`
// is the lots dealt per visit: what the merchant carries of a BUY lot, what it takes of a SELL
// lot. The coin side is the board's price, scaled by the lot's price level (`amount`).

pub const MerchantTerm = struct { item: []const u8, n: f32 };

pub const MerchantLot = struct {
    id: u32,
    sell: bool = false,
    lot: []const u8,
    /// A note on the lot itself. A BUY lot of a good shows the good's roster `effect` instead
    /// (`effectOf`), so it carries none here.
    effect: []const u8 = "",
    price: []const MerchantTerm,
    receive: []const MerchantTerm,
    stock: u32,
    consequence: []const u8 = "",
};

pub const lots = [_]MerchantLot{
    .{ .id = 1, .lot = "Water \u{00d7}6", .price = &.{.{ .item = "coin", .n = 5 }}, .receive = &.{.{ .item = "water", .n = 6 }}, .stock = 3 },
    .{ .id = 2, .lot = "Minerals \u{00d7}5", .price = &.{.{ .item = "coin", .n = 7 }}, .receive = &.{.{ .item = "minerals", .n = 5 }}, .stock = 2 },
    .{ .id = 3, .lot = "Fuel \u{00d7}4", .price = &.{.{ .item = "coin", .n = 8 }}, .receive = &.{.{ .item = "fuel", .n = 4 }}, .stock = 2 },
    .{ .id = 4, .lot = "Metal \u{00d7}3", .price = &.{.{ .item = "coin", .n = 12 }}, .receive = &.{.{ .item = "metal", .n = 3 }}, .stock = 2 },
    .{ .id = 5, .lot = "Food \u{00d7}10", .effect = "preserved, keeps well", .price = &.{.{ .item = "coin", .n = 8 }}, .receive = &.{.{ .item = "food", .n = 10 }}, .stock = 3 },
    .{ .id = 6, .lot = "Materials \u{00d7}15", .effect = "baled fibre", .price = &.{.{ .item = "coin", .n = 5 }}, .receive = &.{.{ .item = "biomass", .n = 15 }}, .stock = 4 },
    .{ .id = 7, .lot = "Cut stone \u{00d7}4", .price = &.{.{ .item = "coin", .n = 9 }}, .receive = &.{.{ .item = "worked_stone", .n = 4 }}, .stock = 2 },
    .{ .id = 8, .lot = "Glass pane \u{00d7}1", .price = &.{.{ .item = "coin", .n = 22 }}, .receive = &.{.{ .item = "glass_pane", .n = 1 }}, .stock = 1 },
    .{ .id = 9, .lot = "Hand tools \u{00d7}1", .price = &.{.{ .item = "coin", .n = 26 }}, .receive = &.{.{ .item = "hand_tools", .n = 1 }}, .stock = 2 },
    .{ .id = 10, .lot = "Fishing net \u{00d7}1", .price = &.{.{ .item = "coin", .n = 18 }}, .receive = &.{.{ .item = "fishing_net", .n = 1 }}, .stock = 1, .consequence = "Replaces Fishing rod: Fish yield rises." },
    .{ .id = 11, .lot = "Carpenter bench \u{00d7}1", .price = &.{.{ .item = "coin", .n = 60 }}, .receive = &.{.{ .item = "carpenter_bench", .n = 1 }}, .stock = 1 },
    .{ .id = 101, .sell = true, .lot = "Materials \u{00d7}6", .price = &.{.{ .item = "biomass", .n = 6 }}, .receive = &.{.{ .item = "coin", .n = 5 }}, .stock = 4 },
    .{ .id = 102, .sell = true, .lot = "Food \u{00d7}8", .price = &.{.{ .item = "food", .n = 8 }}, .receive = &.{.{ .item = "coin", .n = 4 }}, .stock = 4 },
    .{ .id = 103, .sell = true, .lot = "Fuel \u{00d7}4", .price = &.{.{ .item = "fuel", .n = 4 }}, .receive = &.{.{ .item = "coin", .n = 6 }}, .stock = 4 },
    .{ .id = 104, .sell = true, .lot = "Minerals \u{00d7}3", .price = &.{.{ .item = "minerals", .n = 3 }}, .receive = &.{.{ .item = "coin", .n = 4 }}, .stock = 4 },
    .{ .id = 105, .sell = true, .lot = "Metal \u{00d7}3", .price = &.{.{ .item = "metal", .n = 3 }}, .receive = &.{.{ .item = "coin", .n = 9 }}, .stock = 4 },
    .{ .id = 106, .sell = true, .lot = "Water \u{00d7}5", .effect = "drawn this morning", .price = &.{.{ .item = "water", .n = 5 }}, .receive = &.{.{ .item = "coin", .n = 3 }}, .stock = 4 },
    .{ .id = 107, .sell = true, .lot = "Forge \u{00d7}1", .price = &.{.{ .item = "forge", .n = 1 }}, .receive = &.{.{ .item = "coin", .n = 30 }}, .stock = 1, .consequence = "A spare goes first; the forge you use keeps its verb." },
    .{ .id = 108, .sell = true, .lot = "Lean-to \u{00d7}1", .price = &.{.{ .item = "lean_to", .n = 1 }}, .receive = &.{.{ .item = "coin", .n = 7 }}, .stock = 2 },
};

comptime {
    // `Sim.merchant.taken` is sized by the rule, which may not import a system.
    std.debug.assert(lots.len == market.merchant_lot_count);
}

/// The item lot `i` deals in: what a BUY lot hands over, what a SELL lot takes.
fn itemOf(comptime i: usize) []const u8 {
    return if (lots[i].sell) lots[i].price[0].item else lots[i].receive[0].item;
}

/// For each lot, the first lot of its item: where the item's price level is kept, so a BUY lot
/// and the SELL lot of the same item move together and the spread between them holds.
pub const group_of: [lots.len]u8 = blk: {
    @setEvalBranchQuota(20_000);
    var g: [lots.len]u8 = undefined;
    for (0..lots.len) |i| {
        g[i] = i;
        for (0..i) |j| if (std.mem.eql(u8, itemOf(i), itemOf(j))) {
            g[i] = g[j];
            break;
        };
    }
    break :blk g;
};

/// Lot `i`'s price level this visit.
pub fn levelOf(visit: *const market.MerchantVisit, i: usize) i8 {
    return visit.level[group_of[i]];
}

/// What one of lot `i`'s terms moves this visit: a coin term at the lot's price level, any
/// other as authored.
pub fn amount(visit: *const market.MerchantVisit, i: usize, term: MerchantTerm) f32 {
    return if (std.mem.eql(u8, term.item, "coin")) market.priced(term.n, levelOf(visit, i)) else term.n;
}

/// The effect text lot `i` shows: a BUY lot of a good reads the good's roster `effect`, any
/// other lot its own note, which may be empty.
pub fn effectOf(cat: *const roster.Catalog, i: usize) []const u8 {
    const lot = &lots[i];
    if (!lot.sell) if (ledger.item(cat, lot.receive[0].item)) |item| switch (item) {
        .good => |gi| return cat.goods[gi].copy.effect,
        .resource => {},
    };
    return lot.effect;
}

/// Lot `i`'s stock left this visit.
pub fn stockLeft(visit: *const market.MerchantVisit, i: usize) ?u32 {
    return lots[i].stock -| visit.taken[i];
}

/// The visit is over: roll each item's price level against the lots dealt of it. What agents
/// took of its BUY lots is the flow out, what they brought to its SELL lots the flow in.
pub fn remember(visit: *market.MerchantVisit, rng: std.Random) void {
    for (0..lots.len) |g| {
        if (group_of[g] != g) continue;
        var flow = market.Flow{ .sells = false, .buys = false };
        for (lots, 0..) |lot, i| {
            if (group_of[i] != g) continue;
            if (lot.sell) {
                flow.buys = true;
                flow.in += visit.taken[i];
            } else {
                flow.sells = true;
                flow.out += visit.taken[i];
            }
        }
        visit.level[g] = market.reprice(visit.level[g], flow, rng);
    }
}

// —— The visits ————————————————————————————————————————————————————————————————————————

/// Advance the merchant's visit by `dt`; a departure and a return are facts. A departure is when
/// the merchant takes stock of the visit (`remember`); a return is a new visit with its lots
/// restocked.
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
        .departed => {
            remember(&sim.merchant, sim.prng.random());
            _ = departed.push(.{ .who = .merchant });
        },
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
        if (ledger.heldItem(w, it.agent, item) < amount(&res.sim.merchant, it.lot, term) * scale) {
            return if (item == .good) .not_owned else .unaffordable;
        }
    }
    moveSide(w, it.agent, res, it.lot, rec.price, scale, -1);
    moveSide(w, it.agent, res, it.lot, rec.receive, scale, 1);
    res.sim.merchant.taken[it.lot] +|= @intCast(@min(it.lots, std.math.maxInt(u16)));
    return null;
}

/// Move one side of a deal of lot `li` at `scale` lots: `sign` −1 pays out, +1 receives.
/// Resources move on the ledger; goods through `capital`, so an effect lands or leaves once.
fn moveSide(w: *World, e: Entity, res: *Resources, li: usize, terms: []const MerchantTerm, scale: f32, sign: f32) void {
    for (terms) |term| {
        const item = ledger.item(&res.catalog, term.item) orelse continue;
        const n = amount(&res.sim.merchant, li, term) * scale;
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

test "a BUY lot of a good shows the good's roster effect; a resource lot its own note" {
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const net = lotIndex(10);
    try testing.expectEqualStrings(cat.goods[cat.goodIndex("fishing_net").?].copy.effect, effectOf(&cat, net));
    try testing.expectEqualStrings("", effectOf(&cat, lotIndex(1)));
    try testing.expectEqualStrings("preserved, keeps well", effectOf(&cat, lotIndex(5)));
    try testing.expectEqualStrings("", effectOf(&cat, lotIndex(107))); // a SELL lot of a good
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

fn lotIndex(id: u32) u32 {
    return for (lots, 0..) |l, i| {
        if (l.id == id) break @intCast(i);
    } else unreachable;
}

test "a SELL lot is finite too: the merchant takes only so many lots a visit" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const e = settler(&w, 0);
    w.get(e, comp.InventoryWater).?.v = 100;
    const water = lotIndex(106); // 5 water for 3 coin, four lots a visit
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = water, .lots = 4 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectEqual(@as(f32, 12), ledger.balance(&w, e, .coin));
    try testing.expectEqual(@as(?u32, 0), stockLeft(&res.sim.merchant, water));
    res.events.update();
    res.events.update();
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = water, .lots = 1 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectEqual(Reason.sold_out, refusal(&res).?.reason);
    try testing.expectEqual(@as(f32, 80), ledger.balance(&w, e, .water));
}

test "the lots of one item share a price level, and a deal moves coin at it" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const buy_water = lotIndex(1);
    const sell_water = lotIndex(106);
    try testing.expectEqual(group_of[buy_water], group_of[sell_water]);
    try testing.expect(group_of[lotIndex(8)] == lotIndex(8)); // the glass pane stands alone
    const visit = &res.sim.merchant;
    visit.level[group_of[buy_water]] = 2; // water is dear this visit: 1.2 of the board
    try testing.expectApproxEqAbs(@as(f32, 6), amount(visit, buy_water, lots[buy_water].price[0]), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6), amount(visit, buy_water, lots[buy_water].receive[0]), 1e-4); // the water itself is as authored
    try testing.expectApproxEqAbs(@as(f32, 3.6), amount(visit, sell_water, lots[sell_water].receive[0]), 1e-4);

    const e = settler(&w, 10);
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = buy_water, .lots = 1 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectApproxEqAbs(@as(f32, 4), ledger.balance(&w, e, .coin), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6), ledger.balance(&w, e, .water), 1e-4);
    _ = res.events.writer(events.MerchantDeal).push(.{ .agent = e, .lot = sell_water, .lots = 1 });
    ecs.run(&w, &res, merchant_deal);
    try testing.expectApproxEqAbs(@as(f32, 7.6), ledger.balance(&w, e, .coin), 1e-4);
    // At every level a round trip through the board's own lots loses coin, item by item.
    for (lots, 0..) |lot, i| {
        if (lot.sell or std.mem.eql(u8, lot.receive[0].item, "biomass")) continue;
        for (lots, 0..) |back, j| {
            if (!back.sell or group_of[j] != group_of[i]) continue;
            var level: i8 = -market.max_level;
            while (level <= market.max_level) : (level += 1) {
                visit.level[group_of[i]] = level;
                const cost = amount(visit, i, lot.price[0]) / lot.receive[0].n;
                const fetch = amount(visit, j, back.receive[0]) / back.price[0].n;
                try testing.expect(fetch < cost);
            }
        }
    }
}

test "the merchant remembers when the cart leaves: levels carry into the next visit" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    res.sim.prng = std.Random.DefaultPrng.init(9);
    const spd = res.config.secs_per_day;
    const sched = market.MerchantSchedule{};
    const pane = lotIndex(8); // sold only: bought out every visit, it can only get dearer
    const forge = lotIndex(107); // bought only: never brought, the merchant can only pay more
    var visits: u32 = 0;
    while (visits < 12) : (visits += 1) {
        res.sim.merchant.taken[pane] = 1;
        res.time.dt = sched.stay_days * spd + 1;
        ecs.run(&w, &res, merchant); // the cart leaves and takes stock
        try testing.expect(!res.sim.merchant.dealable());
        res.time.dt = sched.away_days * spd;
        ecs.run(&w, &res, merchant); // and returns restocked
        try testing.expectEqual(@as(u16, 0), res.sim.merchant.taken[pane]);
    }
    try testing.expect(levelOf(&res.sim.merchant, pane) > 0);
    try testing.expect(levelOf(&res.sim.merchant, forge) > 0);
    try testing.expect(amount(&res.sim.merchant, pane, lots[pane].price[0]) > 22);
    for (res.sim.merchant.level) |l| try testing.expect(l >= -market.max_level and l <= market.max_level);
}
