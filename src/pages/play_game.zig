/// The live Act-I page while the actor is alive: header and run context, the complete
/// HOLDINGS/ACTIONS/BUILD/GENERATORS workspace, the event log, and an optional trade overlay.
const std = @import("std");
// general lib ECS
const ha = @import("ha");
const ecs = ha.sim.ecs;
const comp = ha.sim.comp;
const tag = ha.sim.tag;
const actions = ha.sim.rules.actions;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;
// Ui Interface
const uic = ha.ui_client;
const Node = uic.Node;
// Game templates + helpers
const t = @import("./templates/root.zig");
const act_one_holdings = @import("./act_one/holdings.zig");

pub const Options = struct {
    /// Open the work surface on this view (a fixture's first frame); null keeps the selection.
    initial_view: ?usize = null,
    /// Collapse the Household rail on this frame (a fixture's first frame); null leaves it.
    initial_collapsed: ?bool = null,
    /// Open the trade dialog on this frame if the passerby is dealable (a fixture's first frame).
    open_trade: bool = false,
    /// Seed the active view's search and sort, open the Shelter card, and pick the trade
    /// dialog's tab and lot (a fixture's first frame).
    initial_query: ?[]const u8 = null,
    initial_sort: ?uic.UiState.CatalogState = null,
    milestone_open: bool = false,
    trade_mode: ?usize = null,
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
        const act = ha.sim.data.migration.actOf(world, e);
        // The stockline is a row of StockTokens whose order/membership is this act's
        // descriptor. Act I lists Vigor/Food/Materials; each token shows a two-letter abbrev
        // (full label on hover/focus), tints danger on a low/zero value, and owns compact versus
        // detailed number formatting.
        header_stocks = .{
            t.vigorStock("VI", vigor, world.get(e, comp.Condition)),
            .{ .abbrev = ha.sim.data.roster.Resource.food.abbrevIn(act), .full = ha.sim.data.roster.Resource.food.labelIn(act), .value = food.v, .verdict = uic.style.verdict.when(food.v <= 0, .low) },
            .{ .abbrev = ha.sim.data.roster.Resource.biomass.abbrevIn(act), .full = ha.sim.data.roster.Resource.biomass.labelIn(act), .value = biomass.v },
        };
        header_stock_count = header_stocks.len;

        const workspace = try t.act_one_workspace(body, world, e, "act_one_workspace", .{
            .holdings = try act_one_holdings.content(ctx, world, e),
            .initial_collapsed = opts.initial_collapsed,
            .surface = .{
                .market_available = ctx.res.game.sim.encounter.dealable(),
                .initial_view = opts.initial_view,
                .initial_query = opts.initial_query,
                .initial_sort = opts.initial_sort,
                .milestone_open = opts.milestone_open,
                .activity = try t.activityOf(ctx, world.get(e, comp.Busy)),
            },
        });

        // The nested surface returns the phase-aware Passerby strip control; encounter eligibility
        // and modal state remain page responsibilities rather than presentation concerns.
        trade_ts = workspace.surface.market_action.state(uic.UiState.TradeState);
        if ((workspace.surface.market_action.consume(.clicked) or opts.open_trade) and ctx.res.game.sim.encounter.dealable()) {
            trade_ts.?.open = true;
        }
        if (opts.trade_mode) |mode| trade_ts.?.mode = mode;

        // The TradeDialog. Built last, as its own overlay root (drawn on top), only while
        // open. Offers are built from live `market.Quote`s — buys from the passerby's satchel
        // wares, sells from the diminishing schedule for the player's surplus/goods — so BUY/SELL
        // tabs, stock, preview, and both `YOU GIVE` directions are authoritative, and a confirmed
        // offer is a `Barter` intent, which the handler resolves at the top of the next frame.
        overlay = try trade_overlay(ctx, world, e, trade_ts);
    }

    // The header (stocks left, run context right; Act I has no energy rate) and the log.
    return page.finish(.{
        .stocks = header_stocks[0..header_stock_count],
        .act_label = "Act I",
        .overlay = overlay,
    });
}
const market = ha.sim.rules.market;
const barter = ha.sim.rules.barter;
const Ware = market.Ware;

/// The passerby's wares in the order the dialog lists their balances (the AFTER rows, the
/// visit ledger): the two stocks, then the two tools.
const ware_order = [_]Ware{ .food, .biomass, .fish_hook, .whetstone };

/// The player's word for a ware (`food`, `materials`, `fishing rod`, `hatchet`).
fn wareKey(act: u8, w: Ware) []const u8 {
    return switch (w) {
        .food => ha.sim.data.roster.Resource.food.wordIn(act),
        .biomass => ha.sim.data.roster.Resource.biomass.wordIn(act),
        .fish_hook => "fishing rod",
        .whetstone => "hatchet",
    };
}

/// A bundle as the dialog's terms.
fn termsOf(arena: std.mem.Allocator, act: u8, b: *const market.Bundle) ![]t.TradeTerm {
    const out = try arena.alloc(t.TradeTerm, b.len);
    for (b.slice(), out) |line, *term| term.* = .{
        .key = wareKey(act, line.item),
        .n = line.qty,
        .stock = barter.goodOf(line.item) == null,
    };
    return out;
}

/// One lot the dialog shows and the quote that backs it.
const Backed = struct { lot: t.TradeLot, quote: market.Quote };

fn buyQuote(enc: *const market.Encounter, ware: Ware) market.Quote {
    var q = market.Quote{ .id = 1 + @as(u32, @backingInt(ware)), .rev = enc.id, .direction = .buy, .give = .{}, .receive = .{}, .stock = enc.stockOf(ware) };
    switch (ware) {
        // A modest posted price: the passerby wants materials for food, food for materials,
        // and both for a tool.
        .food => {
            q.give = market.Bundle.one(.biomass, 2);
            q.receive = market.Bundle.one(.food, 1);
        },
        .biomass => {
            q.give = market.Bundle.one(.food, 1);
            q.receive = market.Bundle.one(.biomass, 3);
        },
        .fish_hook => {
            q.give.add(.food, 2);
            q.give.add(.biomass, 8);
            q.receive = market.Bundle.one(.fish_hook, 1);
        },
        .whetstone => {
            q.give.add(.food, 2);
            q.give.add(.biomass, 6);
            q.receive = market.Bundle.one(.whetstone, 1);
        },
    }
    return q;
}

/// The lots the player can sell: surplus food, a bundle of materials, and either tool. Lots
/// scale linearly; a sell is bounded by what the player holds.
fn sellQuote(enc: *const market.Encounter, ware: Ware) market.Quote {
    const id = 101 + @as(u32, @backingInt(ware));
    return switch (ware) {
        .biomass => .{ .id = id, .rev = enc.id, .direction = .sell, .give = market.Bundle.one(.biomass, 10), .receive = market.Bundle.one(.food, 3), .stock = std.math.maxInt(u16) },
        else => blk: {
            var q = market.sell_quote(ware, 0, id, enc.id);
            q.stock = std.math.maxInt(u16);
            break :blk q;
        },
    };
}

fn buyCopy(act: u8, ware: Ware) struct { lot: []const u8, effect: []const u8, consequence: []const u8 } {
    _ = act;
    return switch (ware) {
        .food => .{ .lot = "Preserved food \u{00d7}1", .effect = "keeps well", .consequence = "" },
        .biomass => .{ .lot = "Materials \u{00d7}3", .effect = "useful stock", .consequence = "" },
        .fish_hook => .{ .lot = "Fishing rod \u{00d7}1", .effect = "unlocks Fish", .consequence = "Fishing becomes available while you own it." },
        .whetstone => .{ .lot = "Hatchet \u{00d7}1", .effect = "unlocks Split wood", .consequence = "Split wood becomes available while you own it." },
    };
}

fn sellCopy(ware: Ware) struct { lot: []const u8, effect: []const u8, consequence: []const u8 } {
    return switch (ware) {
        .food => .{ .lot = "Food \u{00d7}1", .effect = "leaves your larder", .consequence = "" },
        .biomass => .{ .lot = "Materials \u{00d7}10", .effect = "raw stock", .consequence = "" },
        .fish_hook => .{ .lot = "Fishing rod \u{00d7}1", .effect = "your spare stock", .consequence = "A spare goes first; the rod you use keeps Fish open." },
        .whetstone => .{ .lot = "Hatchet \u{00d7}1", .effect = "your spare stock", .consequence = "A spare goes first; the hatchet you use keeps granting Split wood." },
    };
}

/// Build the trade dialog overlay when open: the passerby's satchel as BUY lots and the
/// player's stocks and tools as SELL lots, each backed by a live `market.Quote`; a settlement
/// writes a `Barter` intent with its lot count. Returns the dialog's overlay root (or null
/// when closed).
fn trade_overlay(ctx: *uic.UiCtx, world: *World, e: Entity, ts_opt: ?*uic.UiState.TradeState) !?*Node {
    const ts = ts_opt orelse return null;
    if (!ts.open) return null;
    const a = ctx.arena;
    const act = ha.sim.data.migration.actOf(world, e);
    const enc = &ctx.res.game.sim.encounter;
    const cat = &ctx.res.game.catalog;

    // Balances, in the dialog's order.
    var balances: [ware_order.len]t.TradeBalance = undefined;
    for (ware_order, &balances) |ware, *b| {
        const held: f32 = switch (ware) {
            .food => world.get(e, comp.InventoryFood).?.v,
            .biomass => world.get(e, comp.InventoryBiomass).?.v,
            else => blk: {
                const gi = cat.goodIndex(barter.goodOf(ware).?) orelse break :blk 0;
                const goods = world.get(e, comp.Goods) orelse break :blk 0;
                break :blk @floatFromInt(goods.count[gi]);
            },
        };
        b.* = .{ .key = wareKey(act, ware), .held = held };
    }

    var backed: std.ArrayList(Backed) = .empty;
    for (ware_order) |ware| {
        const q = buyQuote(enc, ware);
        const c = buyCopy(act, ware);
        try backed.append(a, .{ .quote = q, .lot = .{
            .id = q.id,
            .mode = .buy,
            .lot = c.lot,
            .effect = c.effect,
            .price = try termsOf(a, act, &q.give),
            .receive = try termsOf(a, act, &q.receive),
            .stock = q.stock,
            .consequence = c.consequence,
        } });
    }
    for (ware_order) |ware| {
        const q = sellQuote(enc, ware);
        const c = sellCopy(ware);
        try backed.append(a, .{ .quote = q, .lot = .{
            .id = q.id,
            .mode = .sell,
            .lot = c.lot,
            .effect = c.effect,
            .price = try termsOf(a, act, &q.give),
            .receive = try termsOf(a, act, &q.receive),
            .consequence = c.consequence,
        } });
    }
    const lots = try a.alloc(t.TradeLot, backed.items.len);
    for (backed.items, lots) |b, *l| l.* = b.lot;

    const book = t.TradeBook{
        .lots = lots,
        .balances = &balances,
        .notation = .{ .abbrev = &.{
            .{ .key = ha.sim.data.roster.Resource.food.wordIn(act), .letter = ha.sim.data.roster.Resource.food.letterIn(act) },
            .{ .key = ha.sim.data.roster.Resource.biomass.wordIn(act), .letter = ha.sim.data.roster.Resource.biomass.letterIn(act) },
        } },
    };

    // What this visit has moved, from the encounter's own tally.
    var visit: [ware_order.len]t.TradeDelta = undefined;
    for (ware_order, &visit) |ware, *d| d.* = .{ .key = wareKey(act, ware), .n = enc.visit[@backingInt(ware)] };

    const days_left = enc.remaining / ctx.res.game.config.secs_per_day;
    const meta = try a.print("{d:.1} DAYS LEFT", .{days_left});
    const res = try t.trade_dialog(ctx, "trade", .passerby, meta, book, &visit, ts);

    // A settlement is a `Barter` intent; the handler resolves it next frame, and the slip
    // flashes the new values once its `Traded` fact is read here.
    if (res.settle) |s| {
        for (backed.items) |b| {
            if (b.quote.id != s.id) continue;
            _ = ctx.res.game.events.writer(ha.sim.events.Barter).push(.{ .agent = e, .quote = b.quote, .lots = @intCast(@min(s.lots, std.math.maxInt(u16))) });
        }
    }
    const traded = ctx.res.game.events.readerAt(ha.sim.events.Traded, &ts.heard);
    while (traded.next()) |f| {
        if (f.with == .passerby and f.agent == e) ts.settled = true;
    }
    // Escape / × / LEAVE closes; so does the passerby leaving.
    if (res.dismissed or !enc.dealable()) ts.open = false;

    return if (ts.open) res.root else null;
}