//! `act_two/coin_merchant` — the Act II **Coin Merchant** on the shared trade dialog.
//!
//! The lots are the merchant's records (`sim.systems.merchant.lots`) priced in the stand-in Coin,
//! with the stock left this visit from `Sim.merchant`; the balances are the settlement's live
//! ledger and goods. A settlement is a `MerchantDeal` intent: the handler revalidates it and
//! moves both sides, and the dialog reads the `Traded` fact back to flash the slip and keep the
//! visit's tally, which is display state on the page's `TradeState`.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const ledger = ha.sim.rules.ledger;
const roster = ha.sim.data.roster;
const merchant = ha.sim.systems.merchant;
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

fn heldOf(world: *const World, e: Entity, item: ledger.Item) f32 {
    return switch (item) {
        .resource => |r| ledger.balance(world, e, r),
        .good => |gi| if (world.get(e, comp.Goods)) |g| @floatFromInt(g.count[gi]) else 0,
    };
}

fn termsOf(arena: std.mem.Allocator, cat: *const roster.Catalog, terms: []const merchant.MerchantTerm) ![]t.TradeTerm {
    var out: std.ArrayList(t.TradeTerm) = .empty;
    for (terms) |term| {
        const r = (try resolve(arena, cat, term.item)) orelse continue;
        try out.append(arena, .{ .key = r.key, .n = term.n, .stock = r.item == .resource });
    }
    return out.items;
}

/// The balances' keys in order: the stocks, then every good a lot names, once each. Fixed by
/// the records, so the visit's tally indexes them whether or not the dialog is open.
fn balanceKeys(arena: std.mem.Allocator, cat: *const roster.Catalog) ![]const Resolved {
    var keys: std.ArrayList(Resolved) = .empty;
    for (stocks) |r| try keys.append(arena, .{ .item = .{ .resource = r }, .key = r.wordIn(2) });
    for (merchant.lots) |lot| for ([_][]const merchant.MerchantTerm{ lot.price, lot.receive }) |side| for (side) |term| {
        const r = (try resolve(arena, cat, term.item)) orelse continue;
        if (r.item != .good) continue;
        var seen = false;
        for (keys.items) |k| seen = seen or std.mem.eql(u8, k.key, r.key);
        if (seen) continue;
        try keys.append(arena, r);
    };
    return keys.items;
}

/// Add a settled trade of `lots` of lot `li` to the visit's tally, by balance.
fn tally(arena: std.mem.Allocator, cat: *const roster.Catalog, keys: []const Resolved, ts: *TradeState, li: usize, lots: u32) !void {
    if (li >= merchant.lots.len) return;
    const rec = merchant.lots[li];
    const scale: f32 = @floatFromInt(lots);
    for ([_][]const merchant.MerchantTerm{ rec.price, rec.receive }, [_]f32{ -1, 1 }) |side, sign| for (side) |term| {
        const r = (try resolve(arena, cat, term.item)) orelse continue;
        for (keys, 0..) |k, bi| {
            if (bi >= ts.visit.len) break;
            if (std.mem.eql(u8, k.key, r.key)) ts.visit[bi] += sign * term.n * scale;
        }
    };
}

/// Build the merchant dialog when `ts.open` and settle what it asks this frame. Returns the
/// overlay root (or null when closed).
pub fn coin_merchant(ctx: *UiCtx, world: *const World, e: Entity, id: []const u8, ts: *TradeState) !?*Node {
    const standing = ctx.res.game.sim.exchange.standing;
    const visit_now = &ctx.res.game.sim.merchant;
    const a = ctx.arena;
    const cat = &ctx.res.game.catalog;

    // The trades the handler settled since the last build: the slip flashes, the tally moves.
    const heard = ctx.res.game.events.readerAt(ha.sim.events.Traded, &ts.heard);
    while (heard.next()) |f| {
        if (f.with != .merchant or f.agent != e) continue;
        ts.settled = true;
        try tally(a, cat, try balanceKeys(a, cat), ts, f.lot, f.lots);
    }
    // The cart leaving closes the dialog and ends the visit's tally; a standing Exchange never
    // leaves.
    if (!standing and !visit_now.dealable()) {
        ts.open = false;
        ts.visit = @splat(0);
    }
    if (!ts.open) return null;

    // Balances: the stocks, then every good a lot names, once each.
    const keys = try balanceKeys(a, cat);
    const balances = try a.alloc(t.TradeBalance, keys.len);
    for (keys, balances) |k, *b| b.* = .{ .key = k.key, .held = heldOf(world, e, k.item) };

    const lots = try a.alloc(t.TradeLot, merchant.lots.len);
    for (merchant.lots, lots, 0..) |src, *dst, i| {
        dst.* = .{
            .id = src.id,
            .mode = if (src.sell) .sell else .buy,
            .lot = src.lot,
            .effect = src.effect,
            .price = try termsOf(a, cat, src.price),
            .receive = try termsOf(a, cat, src.receive),
            .stock = merchant.stockLeft(visit_now, i),
            .consequence = src.consequence,
        };
    }
    const book = t.TradeBook{ .lots = lots, .balances = balances };

    const visit = try a.alloc(t.TradeDelta, @min(balances.len, ts.visit.len));
    for (visit, 0..) |*d, i| d.* = .{ .key = balances[i].key, .n = ts.visit[i] };

    // A standing Exchange speaks through the same dialog under its own identity; the
    // merchant's kicker counts down its stay.
    const meta = if (standing) fx.exchange_meta else try a.print("MARKET OPEN {d:.1} DAYS", .{fx.merchantDaysLeft(ctx.res)});
    const res = try t.trade_dialog(ctx, id, if (standing) .exchange else .merchant, meta, book, visit, ts);

    // A settlement is an intent; the handler revalidates it against the visit and the ledger.
    if (res.settle) |s| for (merchant.lots, 0..) |src, i| {
        if (src.id != s.id) continue;
        _ = ctx.res.game.events.writer(ha.sim.events.MerchantDeal).push(.{ .agent = e, .lot = @intCast(i), .lots = s.lots });
    };

    // Escape / × / LEAVE closes.
    if (res.dismissed) ts.open = false;
    return if (ts.open) res.root else null;
}
