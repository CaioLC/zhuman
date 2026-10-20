/// The live Act-I page while the actor is alive: header and run context, the complete
/// HOLDINGS/ACTIONS/BUILD/GENERATORS workspace, the event log, and an optional trade overlay.
const std = @import("std");
// general lib ECS
const ha = @import("ha");
const ecs = ha.ecs;
const comp = ha.comp;
const tag = ha.tag;
const actions = ha.actions;
const World = ha.world.World;
const Entity = ha.world.Entity;
// Ui Interface
const uic = ha.ui_client;
const Node = uic.Node;
// Game templates + helpers
const t = @import("./templates/root.zig");
const act_one_holdings = @import("./act_one/holdings.zig");

pub const Options = struct {
    /// Open the work surface on this view (a fixture's first frame); null keeps the selection.
    initial_view: ?usize = null,
};

/// Build the page. Returns its roots in draw order: the shell, then the trade dialog's root
/// while the dialog is open, so the dialog covers the screen by construction.
pub fn ui_playgame(ctx: *uic.UiCtx, world: *World, opts: Options) !uic.Trees {
    // The reviewed Act-I composition is the normal live page from the first frame. `shell`
    // supplies the same responsive terminal geometry used by the debug fixture's `shell_content`;
    // the workspace owns HOLDINGS plus the market/activity and ACTIONS/BUILD/GENERATORS surface.
    const page = try t.act_page(ctx, .{ .id = "play", .act = .act_one });
    const body = page.regions.body;
    // Header stock data is passed raw, then assembled with the run context by `header`.
    // An empty stock slice keeps only the right-pinned runline when no live actor remains.
    var overlay: ?*Node = null; // the trade dialog's own overlay root, when open
    var trade_ts: ?*uic.UiState.TradeState = null; // the market strip's open/mode/sel state
    var header_stocks: [3]t.Stock = undefined;
    var header_stock_count: usize = 0;
    const q = ecs.MaybeSingle(.{
        Entity, comp.Vigor, comp.InventoryFood, comp.InventoryBiomass, ecs.With(tag.Player),
    }){ .world = world };
    if (q.get()) |a| {
        const e, const vigor, const food, const biomass = a;
        const act = ha.migration.actOf(world, e);
        // The stockline is a row of StockTokens whose order/membership is this act's
        // descriptor. Act I lists Vigor/Food/Materials; each token shows a two-letter abbrev
        // (full label on hover/focus), tints danger on a low/zero value, and owns compact versus
        // detailed number formatting.
        header_stocks = .{
            t.vigorStock(ctx, "VI", vigor),
            .{ .abbrev = ha.roster.Resource.food.abbrevIn(act), .full = ha.roster.Resource.food.labelIn(act), .value = food.v, .tone = if (food.v <= 0) .danger else .normal },
            .{ .abbrev = ha.roster.Resource.biomass.abbrevIn(act), .full = ha.roster.Resource.biomass.labelIn(act), .value = biomass.v },
        };
        header_stock_count = header_stocks.len;

        const workspace = try t.act_one_workspace(body, world, e, "act_one_workspace", .{
            .holdings = try act_one_holdings.content(ctx, world, e),
            .surface = .{
                .market_available = ctx.res.sim.encounter.dealable(),
                .initial_view = opts.initial_view,
                .activity = try t.activityOf(ctx, world.get(e, comp.Busy)),
            },
        });

        // The nested surface returns the phase-aware Passerby strip control; encounter eligibility
        // and modal state remain page responsibilities rather than presentation concerns.
        trade_ts = workspace.surface.market_action.state(uic.UiState.TradeState);
        if (workspace.surface.market_action.consume(.clicked) and ctx.res.sim.encounter.dealable()) {
            trade_ts.?.open = true;
        }

        // The TradeDialog. Built last, as its own overlay root (drawn on top), only while
        // open. Offers are built from live `market.Quote`s — buys from the passerby's satchel
        // wares, sells from the diminishing schedule for the player's surplus/goods — so BUY/SELL
        // tabs, stock, preview, and both `YOU GIVE` directions are authoritative, and a confirmed
        // offer routes straight to `ha.barter.resolve`. Header/Holdings/log refresh the same frame
        // because they read live world state after the resolve.
        overlay = try trade_overlay(ctx, world, e, trade_ts);
    }

    // The header (stocks left, run context right; Act I has no energy rate) and the log.
    return page.finish(.{
        .stocks = header_stocks[0..header_stock_count],
        .act_label = "Act I",
        .overlay = overlay,
    });
}
const market = ha.market;
const barter = ha.barter;
const Ware = market.Ware;

/// A buy/sell offer paired with the authoritative `market.Quote` that backs it — the dialog shows
/// the strings, `resolve` runs the quote. Built into the frame arena.
const BackedOffer = struct { offer: t.TradeOffer, quote: market.Quote };

/// Format a bundle side into a short `NfF`, `NmM`, or tool-name string for the dialog.
fn wareLabel(act: u8, w: Ware) []const u8 {
    return switch (w) {
        .food => ha.roster.Resource.food.wordIn(act),
        .biomass => ha.roster.Resource.biomass.wordIn(act),
        .fish_hook => "a fishing rod",
        .whetstone => "a hatchet",
    };
}

fn bundleLabel(act: u8, buf: []u8, b: *const market.Bundle) []const u8 {
    // A single-line summary of the bundle's lines: "2 food, 4m", or "a hand axe".
    var w: usize = 0;
    for (b.slice(), 0..) |line, i| {
        const sep = if (i == 0) "" else " + ";
        const piece = switch (line.item) {
            .food => std.fmt.bufPrint(buf[w..], "{s}{d:.0} {s}", .{ sep, line.qty, ha.roster.Resource.food.wordIn(act) }) catch "",
            .biomass => std.fmt.bufPrint(buf[w..], "{s}{d:.0} {s}", .{ sep, line.qty, ha.roster.Resource.biomass.wordIn(act) }) catch "",
            else => std.fmt.bufPrint(buf[w..], "{s}{s}", .{ sep, wareLabel(act, line.item) }) catch "",
        };
        w += piece.len;
    }
    return buf[0..w];
}

fn wareTradeName(act: u8, w: Ware) []const u8 {
    return switch (w) {
        .food => "Preserved food",
        .biomass => ha.roster.Resource.biomass.labelIn(act),
        .fish_hook => "Fishing rod",
        .whetstone => "Hatchet",
    };
}

fn wareTradeDetail(w: Ware) []const u8 {
    return switch (w) {
        .food => "provisions \u{00b7} keeps well",
        .biomass => "useful stock",
        .fish_hook => "unlocks Fish",
        .whetstone => "unlocks Split wood",
    };
}

/// Build the trade dialog overlay when open, wiring confirm → `barter.resolve`. Returns the
/// dialog's overlay root (or null when closed). The offers are the passerby's satchel wares (buy)
/// and the player's sellable goods + surplus (sell), each backed by a live `market.Quote`.
fn trade_overlay(ctx: *uic.UiCtx, world: *World, e: Entity, ts_opt: ?*uic.UiState.TradeState) !?*Node {
    const ts = ts_opt orelse return null;
    if (!ts.open) return null;
    const act = ha.migration.actOf(world, e);

    const enc = &ctx.res.sim.encounter;
    const food = world.get(e, comp.InventoryFood).?;
    const stock = world.get(e, comp.InventoryBiomass).?;

    // --- buy offers: what the passerby will hand over from the satchel --------------------
    var buys = std.ArrayList(BackedOffer).empty;
    var gbuf = try ctx.arena.alloc(u8, 512);
    var gw: usize = 0;
    inline for (.{ Ware.food, Ware.biomass, Ware.fish_hook, Ware.whetstone }) |ware| {
        const have = enc.stockOf(ware);
        if (have > 0) {
            // A simple posted buy price: the passerby wants Materials (bulk) or Food+Materials
            // (tools) for what it carries. Kept modest; the sell side is where diminishing value
            // is taught.
            var q = market.Quote{ .id = @as(u32, @intFromEnum(ware)), .rev = enc.id, .direction = .buy, .give = undefined, .receive = undefined, .stock = have };
            switch (ware) {
                .food => {
                    q.give = market.Bundle.one(.biomass, 2);
                    q.receive = market.Bundle.one(.food, 1);
                },
                .biomass => {
                    q.give = market.Bundle.one(.food, 1);
                    q.receive = market.Bundle.one(.biomass, 3);
                },
                .fish_hook => {
                    var g = market.Bundle{};
                    g.add(.food, 2);
                    g.add(.biomass, 8);
                    q.give = g;
                    q.receive = market.Bundle.one(.fish_hook, 1);
                },
                .whetstone => {
                    var g = market.Bundle{};
                    g.add(.food, 2);
                    g.add(.biomass, 6);
                    q.give = g;
                    q.receive = market.Bundle.one(.whetstone, 1);
                },
            }
            const give_s = bundleLabel(act, gbuf[gw..], &q.give);
            gw += give_s.len;
            const recv_s = bundleLabel(act, gbuf[gw..], &q.receive);
            gw += recv_s.len;
            const refusal = q.refusal(enc, food.v, stock.v);
            try buys.append(ctx.arena, .{
                .offer = .{ .id = q.id, .name = wareTradeName(act, ware), .detail = wareTradeDetail(ware), .give = give_s, .receive = recv_s, .stock = have, .refusal = refusal.reason() },
                .quote = q,
            });
        }
    }

    // --- sell offers: the player's surplus + owned goods, at the diminishing schedule -----
    var sells = std.ArrayList(BackedOffer).empty;
    // Surplus resources (a token "sell 1 unit" at the first-unit value; the schedule teaches the
    // decline via `next_unit`, shown in the effect line).
    inline for (.{ Ware.food, Ware.biomass }) |ware| {
        const held: f32 = if (ware == .food) food.v else stock.v;
        if (held >= 1) {
            const q = market.sell_quote(ware, 0, 100 + @as(u32, @intFromEnum(ware)), enc.id);
            const give_s = bundleLabel(act, gbuf[gw..], &q.give);
            gw += give_s.len;
            const recv_s = bundleLabel(act, gbuf[gw..], &q.receive);
            gw += recv_s.len;
            const eff = try std.fmt.allocPrint(ctx.arena, "next unit: {d:.1}{s}", .{ q.next_unit orelse 0, ha.roster.Resource.biomass.letterIn(act) });
            try sells.append(ctx.arena, .{
                .offer = .{ .id = q.id, .name = wareTradeName(act, ware), .detail = "your surplus", .give = give_s, .receive = recv_s, .effect = eff, .stock = 1 },
                .quote = q,
            });
        }
    }
    // Owned tradeable goods (the wares the passerby recognizes, by their roster id).
    const cat = &ctx.res.catalog;
    const goods = world.get(e, comp.Goods);
    for ([_]Ware{ .fish_hook, .whetstone }) |ware| {
        const gi = cat.goodIndex(barter.goodOf(ware).?) orelse continue;
        const owned: u32 = if (goods) |g| g.count[gi] else 0;
        if (owned > 0) {
            const q = market.sell_quote(ware, 0, 200 + @as(u32, @intFromEnum(ware)), enc.id);
            const give_s = try std.fmt.allocPrint(ctx.arena, "{s}", .{wareLabel(act, ware)});
            const recv_s = bundleLabel(act, gbuf[gw..], &q.receive);
            gw += recv_s.len;
            try sells.append(ctx.arena, .{
                .offer = .{ .id = q.id, .name = wareTradeName(act, ware), .detail = "your spare stock", .give = give_s, .receive = recv_s, .stock = @intCast(@min(owned, std.math.maxInt(u16))) },
                .quote = q,
            });
        }
    }

    // Flatten the offer views for the dialog.
    var buy_views = try ctx.arena.alloc(t.TradeOffer, buys.items.len);
    for (buys.items, 0..) |b, i| buy_views[i] = b.offer;
    var sell_views = try ctx.arena.alloc(t.TradeOffer, sells.items.len);
    for (sells.items, 0..) |s, i| sell_views[i] = s.offer;

    // Live holdings line.
    // Live header metadata and structured YOU HOLD rows.
    var meta_buf: [32]u8 = undefined;
    const days_left = enc.remaining / ctx.res.config.secs_per_day;
    const meta = std.fmt.bufPrint(&meta_buf, "{d:.1} DAYS LEFT", .{days_left}) catch "DAYS LEFT";
    var food_buf: [24]u8 = undefined;
    var material_buf: [24]u8 = undefined;
    var holding_views = std.ArrayList(t.TradeHolding).empty;
    try holding_views.append(ctx.arena, .{ .label = ha.roster.Resource.food.labelIn(act), .value = std.fmt.bufPrint(&food_buf, "{d:.1}", .{food.v}) catch "?" });
    try holding_views.append(ctx.arena, .{ .label = ha.roster.Resource.biomass.labelIn(act), .value = std.fmt.bufPrint(&material_buf, "{d:.0}", .{stock.v}) catch "?" });
    // The manufactured unlockers the passerby's deal turns on, plus one common crude holding.
    for ([_][]const u8{ "sandals", "hatchet", "fish_rod" }) |gid| {
        const gi = cat.goodIndex(gid) orelse continue;
        const owned: u32 = if (goods) |g| g.count[gi] else 0;
        if (owned > 0) {
            try holding_views.append(ctx.arena, .{ .label = cat.goods[gi].name, .value = try std.fmt.allocPrint(ctx.arena, "\u{00d7}{d}", .{owned}) });
        }
    }

    const res = try t.trade_dialog(ctx, "trade", .passerby, meta, buy_views, sell_views, holding_views.items, ts);

    // Confirm → resolve the backing quote atomically. Header/Holdings/log read live world state,
    // so they refresh this same frame.
    if (res.confirmed) |i| {
        const backing = if (res.mode == 0) buys.items else sells.items;
        if (i < backing.len) _ = barter.resolve(world, e, ctx.res, &backing[i].quote);
    }
    // Escape / outside-click closes; also close if the passerby has left.
    if (res.dismissed or !enc.dealable()) ts.open = false;

    return if (ts.open) res.root else null;
}
