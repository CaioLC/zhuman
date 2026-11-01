//! `act_two/coin_merchant` — the Act II **Coin Merchant** (ACT2-14) on the shared trade dialog.
//!
//! The lots are fixture records (`fixtures.merchant_lots`) priced in the stub Coin; the balances
//! are the settlement's live ledger and goods. A settlement moves real stocks and goods — Coin
//! and resources through `ledger.move`, goods through `capital` — and the merchant's sold lots
//! and the visit's tally live on the page's `TradeState` until ACT2-14 gives the merchant its own
//! stock and departure clock.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const ledger = ha.sim.rules.ledger;
const capital = ha.sim.rules.capital;
const roster = ha.sim.data.roster;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;
const uic = ha.ui_client;
const Node = uic.Node;
const UiCtx = uic.UiCtx;
const TradeState = uic.UiState.TradeState;

const fx = @import("./fixtures.zig");
const t = @import("../templates/root.zig");

/// The stocks the merchant's balances list, in order; goods the lots name follow.
const stocks = [_]roster.Resource{ .coin, .food, .water, .fuel, .metal, .minerals, .biomass };

/// A term's item resolved against the catalog, with the player's word for it.
const Resolved = struct { item: ledger.Item, key: []const u8 };

fn resolve(arena: std.mem.Allocator, cat: *const roster.Catalog, id: []const u8) !?Resolved {
    const item = ledger.item(cat, id) orelse return null;
    return switch (item) {
        .resource => |r| .{ .item = item, .key = r.wordIn(2) },
        .good => |gi| .{ .item = item, .key = try std.ascii.allocLowerString(arena, cat.goods[gi].name) },
    };
}

fn heldOf(world: *World, e: Entity, item: ledger.Item) f32 {
    return switch (item) {
        .resource => |r| ledger.balance(world, e, r),
        .good => |gi| if (world.get(e, comp.Goods)) |g| @floatFromInt(g.count[gi]) else 0,
    };
}

fn termsOf(arena: std.mem.Allocator, cat: *const roster.Catalog, terms: []const fx.MerchantTerm) ![]t.TradeTerm {
    var out: std.ArrayList(t.TradeTerm) = .empty;
    for (terms) |term| {
        const r = (try resolve(arena, cat, term.item)) orelse continue;
        try out.append(arena, .{ .key = r.key, .n = term.n, .stock = r.item == .resource });
    }
    return out.items;
}

/// Move one side of `lots` lots: `sign` −1 pays out, +1 receives.
fn moveSide(world: *World, e: Entity, res: *ha.res.Resources, terms: []const fx.MerchantTerm, lots: u32, sign: f32) void {
    const cat = &res.game.catalog;
    for (terms) |term| {
        const item = ledger.item(cat, term.item) orelse continue;
        const n = term.n * @as(f32, @floatFromInt(lots));
        switch (item) {
            .resource => |r| _ = ledger.move(world, e, r, sign * n),
            .good => |gi| {
                const units: u32 = @intFromFloat(@round(n));
                if (sign > 0) capital.acquire(world, e, &res.game, gi, units) else _ = capital.release(world, e, &res.game, gi, units);
            },
        }
    }
}

/// Build the merchant dialog when `ts.open` and settle what it asks this frame. Returns the
/// overlay root (or null when closed).
pub fn coin_merchant(ctx: *UiCtx, world: *World, e: Entity, id: []const u8, ts: *TradeState) !?*Node {
    const standing = ctx.res.game.sim.exchange.standing;
    const visit_now = &ctx.res.game.sim.merchant;
    // The merchant's books belong to one visit: a return restocks the lots and starts a new tally.
    if (ts.visit_id != visit_now.id) {
        ts.taken = @splat(0);
        ts.visit = @splat(0);
        ts.visit_id = visit_now.id;
    }
    // The cart leaving closes the dialog; a standing Exchange never leaves.
    if (!standing and !visit_now.dealable()) ts.open = false;
    if (!ts.open) return null;
    const a = ctx.arena;
    const cat = &ctx.res.game.catalog;

    // Balances: the stocks, then every good a lot names, once each.
    var balances: std.ArrayList(t.TradeBalance) = .empty;
    for (stocks) |r| {
        try balances.append(a, .{ .key = r.wordIn(2), .held = ledger.balance(world, e, r) });
    }
    for (fx.merchant_lots) |lot| for ([_][]const fx.MerchantTerm{ lot.price, lot.receive }) |side| for (side) |term| {
        const r = (try resolve(a, cat, term.item)) orelse continue;
        if (r.item != .good) continue;
        var seen = false;
        for (balances.items) |b| seen = seen or std.mem.eql(u8, b.key, r.key);
        if (seen) continue;
        try balances.append(a, .{ .key = r.key, .held = heldOf(world, e, r.item) });
    };

    const lots = try a.alloc(t.TradeLot, fx.merchant_lots.len);
    for (fx.merchant_lots, lots, 0..) |src, *dst, i| {
        dst.* = .{
            .id = src.id,
            .mode = if (src.sell) .sell else .buy,
            .lot = src.lot,
            .effect = src.effect,
            .price = try termsOf(a, cat, src.price),
            .receive = try termsOf(a, cat, src.receive),
            .stock = if (src.stock) |s| s -| ts.taken[i % ts.taken.len] else null,
            .consequence = src.consequence,
        };
    }
    const book = t.TradeBook{ .lots = lots, .balances = balances.items };

    const visit = try a.alloc(t.TradeDelta, @min(balances.items.len, ts.visit.len));
    for (visit, 0..) |*d, i| d.* = .{ .key = balances.items[i].key, .n = ts.visit[i] };

    // A standing Exchange speaks through the same dialog under its own identity (ACT2-19); the
    // merchant's kicker counts down its stay.
    const meta = if (standing) fx.exchange_meta else try a.print("MARKET OPEN {d:.1} DAYS", .{fx.merchantDaysLeft(ctx.res)});
    const res = try t.trade_dialog(ctx, id, if (standing) .exchange else .merchant, meta, book, visit, ts);

    if (res.settle) |s| settle: {
        // Revalidate the venue: still here, still the visit the dialog was built against.
        if (!standing and (!visit_now.dealable() or ts.visit_id != visit_now.id)) break :settle;
        for (fx.merchant_lots, 0..) |src, i| {
            if (src.id != s.id) continue;
            const lot = &lots[i];
            // Revalidate against live state: the book's own gate, at this many lots.
            if (s.lots == 0 or s.lots > book.maxLots(lot)) break :settle;
            moveSide(world, e, ctx.res, src.price, s.lots, -1);
            moveSide(world, e, ctx.res, src.receive, s.lots, 1);
            if (src.stock != null) ts.taken[i % ts.taken.len] += @intCast(s.lots);
            // The visit's tally, by balance.
            for (balances.items, 0..) |b, bi| {
                if (bi >= ts.visit.len) break;
                for (lot.price) |term| if (std.mem.eql(u8, term.key, b.key)) {
                    ts.visit[bi] -= term.n * @as(f32, @floatFromInt(s.lots));
                };
                for (lot.receive) |term| if (std.mem.eql(u8, term.key, b.key)) {
                    ts.visit[bi] += term.n * @as(f32, @floatFromInt(s.lots));
                };
            }
            ctx.res.game.sim.log.push(.good, try a.print("You trade {d} lot{s} of {s} with the merchant.", .{ s.lots, if (s.lots == 1) "" else "s", src.lot }));
            ts.settled = true;
        }
    }

    // Escape / × / LEAVE closes.
    if (res.dismissed) ts.open = false;
    return if (ts.open) res.root else null;
}

test "every merchant lot names items the catalog knows" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    for (fx.merchant_lots) |lot| {
        for (lot.price) |term| try std.testing.expect(ledger.item(&cat, term.item) != null);
        for (lot.receive) |term| try std.testing.expect(ledger.item(&cat, term.item) != null);
    }
}
