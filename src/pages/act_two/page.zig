//! `act_two/page` — the Act II **shared-shell instantiation** (ACT2-10) and the composition
//! root for the Act II catalogs.
//!
//! It fills the one shared `shell` with Act II's descriptors: the stockline PO, VI, FO, WA, FU,
//! ME, MI, BI, CO in its compact form, a runline carrying the energy rate, `Act II` and the day,
//! and the surface's five-view nav — ACTIONS / BUILD / GENERATORS / RESEARCH / MARKET. RESEARCH
//! and MARKET are focus views: the Merchant and Activity strips and the event log step aside
//! there and the Household collapses, yet the strips' state is never lost because it lives in
//! the page, not the strips. The Household column (holdings, BODY, the eating policy) rides the
//! shell rail; the event log rides the shell footer.
//!
//! The page reads the player. Its stocks fill the stockline, its goods the holdings, its work
//! the activity strip; the two browsers list the verbs it holds and the act's recipes from the
//! catalog, and begin work through `actions.begin` and `capital.begin` as Act I does. What no
//! system models yet — population, coin, the energy rate, the merchant's lots, flows and body
//! projections — comes from `fixtures.zig`, and a merchant trade is only logged.
//!
//! Each catalog view owns a persistent `CatalogState`, search editor and scroll offset on an
//! always-built owner node, so switching views keeps each view's query, sort and position where
//! the player left them (the `tabs` persistence contract). The Coin Merchant dialog is the
//! page's own top-layer overlay root, listed after the shell.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const ecs = ha.ecs;
const actions = ha.actions;
const capital = ha.capital;
const ledger = ha.ledger;
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const Node = uic.Node;
const UiCtx = uic.UiCtx;
const El = el.El;

const t = @import("../templates/root.zig");
const fx = @import("./fixtures.zig");
/// Act II's ACTIONS content — the same pane as Act I's: the settlement's verbs.
const actions_shelf = t.ActionsShelf{
    .act = 2,
    .subtitle = "What will the settlement do now?",
    // Twenty-odd verbs: the compact tile keeps the catalog scannable above the fold.
    .density = .compact,
};
/// Act II's BUILD content — the same pane as Act I's: the settlement's recipes of every tier.
/// The act authors no milestone card yet (the Exchange, ACT2-17). Its orders run to three
/// materials (`36me 24fu 20mi`), so its COST lane is wide and WHAT CHANGES gives the width up.
const build_shelf = t.BuildShelf{
    .act = 2,
    .subtitle = "Find the next useful recipe across a growing settlement catalog.",
    .widths = .{ .cost = 112, .effect = 140 - t.build_scroll_gutter },
    // The Act I goods the settlement owns stay buildable: another unit is stock to sell.
    .carry_owned = true,
};
/// Act II's GENERATORS content — the same view as Act I's, over both acts' generators: the
/// settlement keeps what the household planted. Compact, like the action catalog.
const generator_shelf = t.GeneratorShelf{
    .through_act = 2,
    .density = .compact,
    .subtitle = "Let time accumulate, then collect without stopping the work.",
};
const a2_holdings = @import("./holdings.zig");
const coin_merchant = @import("./coin_merchant.zig").coin_merchant;

/// The surface's views, in tab order.
pub const View = enum(usize) { actions, build, generators, research, market };
const view_labels = [_][]const u8{ "ACTIONS", "BUILD", "GENERATORS", "RESEARCH", "MARKET" };
/// RESEARCH and MARKET own the whole surface: no strips, no log, the Household collapsed.
const focus_views = [_]usize{ @intFromEnum(View.research), @intFromEnum(View.market) };
/// Each view keys its own rail, so each remembers its collapse.
const rail_ids = [_][]const u8{ "a2_rail_actions", "a2_rail_build", "a2_rail_generators", "a2_rail_research", "a2_rail_market" };

/// The stocks the stockline reads from the ledger, in its order after Vigor.
const ledger_stocks = [_]ha.roster.Resource{
    .food,
    .water,
    .fuel,
    .metal,
    .minerals,
    .biomass,
};

/// What a caller may ask of the page beyond the world.
pub const Options = struct {
    /// The view to open on (a `View`'s index), applied on the frame it is set; the tabs own
    /// the selection on every other frame.
    initial_view: ?usize = null,
    /// Collapse the Household rail on this frame (a fixture's first frame); null leaves it.
    initial_collapsed: ?bool = null,
    /// Open the merchant dialog on this frame (a fixture's first frame).
    open_trade: bool = false,
    /// Seed the MARKET view's state on this frame (a fixture's first frame).
    market: ?uic.UiState.MarketState = null,
};

/// Build the Act II page. Returns its roots in draw order: the shell, then the merchant dialog's
/// overlay root while it is open.
pub fn ui_act_two(ctx: *UiCtx, world: *World, opts: Options) !uic.Trees {
    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    const agent: ?Entity = if (player.get()) |a| a[0] else null;

    // The shared act page with a shell rail (Holdings/BODY) and the log footer.
    const page = try t.act_page(ctx, .{ .id = "act2", .act = .act_two, .rail = true });
    const regions = page.regions;
    // --- header: PO..CO, then the runline (energy rate, Act II, day) -------------------------
    // Vigor and the six stocks are the player's; population and coin have no model yet.
    var stocks: [2 + 1 + ledger_stocks.len]t.Stock = undefined;
    var n: usize = 0;
    stocks[n] = .{ .abbrev = "PO", .full = "Population", .value = fx.population };
    n += 1;
    if (agent) |e| {
        const vigor = world.get(e, comp.Vigor).?;
        stocks[n] = t.vigorStock(ctx, "VI", vigor);
        n += 1;
        for (ledger_stocks) |resource| {
            const amount = ledger.balance(world, e, resource);
            stocks[n] = .{
                .abbrev = resource.abbrevIn(2),
                .full = resource.labelIn(2),
                .value = amount,
                .tone = if (amount <= 0) .danger else .normal,
            };
            n += 1;
        }
    }
    stocks[n] = .{
        .abbrev = ha.roster.Resource.coin.abbrevIn(2),
        .full = ha.roster.Resource.coin.labelIn(2),
        .value = if (agent) |e| ledger.balance(world, e, .coin) else 0,
    };
    n += 1;

    // The merchant dialog's open/mode/selection persists on an always-built node, surviving
    // view switches (a focus view hides the strip, never the deal).
    const trade_owner = try regions.body.div("a2_trade_state");
    _ = trade_owner.with_size(.{ .fixed = 0 }, .{ .fixed = 0 });

    // --- the body: the shared act surface, then the active view ----------------------------
    const s = try t.act_surface(regions.body, "a2_surface", .{
        .labels = &view_labels,
        .focus_views = &focus_views,
        .market = .merchant,
        .activity = try t.activityOf(ctx, if (agent) |e| world.get(e, comp.Busy) else null),
        .nav_gap = 8, // `.act-two .surface-nav`
        .initial_view = opts.initial_view,
    });
    if (s.market_action) |m| {
        if (m.query().clicked or opts.open_trade) trade_owner.state(uic.UiState.TradeState).open = true;
    }

    // --- the rail: the Household column, collapsing with it ---------------------------------
    // Each view keys its own rail, so ACTIONS, BUILD and GENERATORS remember their collapse
    // separately; a focus view collapses on every entry without touching those memories.
    if (regions.rail) |rail_region| {
        const r = try t.rail(rail_region, .{
            .id = rail_ids[@min(s.active, rail_ids.len - 1)],
            .label = "HOUSEHOLD",
            .force_collapsed = s.focus,
            .initial_collapsed = opts.initial_collapsed,
        });
        if (r.body) |body| if (agent) |e| {
            _ = try t.household(body, world, e, "a2_holdings", try a2_holdings.content(ctx, world, e));
        };
    }

    if (agent) |e| switch (@as(View, @enumFromInt(s.active))) {
        // ACTIONS fills the view: its heading, search and summary stay put, only the tiles scroll.
        .actions => _ = try t.actions_section(s.view, world, e, "a2_actions", actions_shelf, s.catalog, s.owner, s.scroll),
        // BUILD is the shared pane: it fills the view and scrolls only its table.
        .build => _ = try t.build_section(s.view, world, e, "a2_build", build_shelf, s.catalog, s.owner, s.scroll),
        .generators => {
            const scroll = try t.scroll_view(s.view, "scroll", .{ .height = 0, .framed = false }, s.scroll);
            _ = try t.generator_section(scroll.content, world, e, "a2_generators", generator_shelf);
        },
        .research => _ = try t.empty_state(s.view, "a2_research", "RESEARCH board", "The research board is not drawn yet."),
        .market => try market(ctx, world, e, s, opts.market),
    } else {
        _ = try t.empty_state(s.view, "a2_nobody", "No settlement", "There is no one here to act.");
    }

    // --- the Coin Merchant overlay (its own top-layer root) ---------------------------------
    const merchant_root: ?*Node = if (agent) |e| try coin_merchant(ctx, world, e, "a2_trade", trade_owner.state(uic.UiState.TradeState)) else null;

    return page.finish(.{
        .stocks = stocks[0..n],
        .compact_stocks = true,
        .act_label = "Act II",
        .gen = fx.energy_gen,
        .consumed = fx.energy_consumed,
        .log = !s.focus,
        .overlay = merchant_root,
    });
}

test {
    _ = @import("./fixtures.zig");
    _ = @import("./coin_merchant.zig");
    _ = @import("./holdings.zig");
}

const nb = ha.neighbours;

/// What the settlement keeps back from trade (the reserve HOLDINGS will own): a larder floor, a
/// little water, and some biomass to build with. A stub until the reserve exists.
const reserve = blk: {
    var r: [nb.item_count]f32 = @splat(0);
    r[0] = 6;
    r[1] = 2;
    r[5] = 10;
    break :blk r;
};

fn heldItem(world: *World, e: Entity, cat: *const ha.roster.Catalog, i: usize) f32 {
    const item = ledger.item(cat, nb.items[i]) orelse return 0;
    return switch (item) {
        .resource => |r| ledger.balance(world, e, r),
        .good => |gi| if (world.get(e, comp.Goods)) |g| @floatFromInt(g.count[gi]) else 0,
    };
}

/// Move `n` of item `i` into (or, negative, out of) the agent's holdings.
fn moveItem(world: *World, e: Entity, res: *ha.res.Resources, i: usize, n: f32) void {
    const item = ledger.item(&res.catalog, nb.items[i]) orelse return;
    switch (item) {
        .resource => |r| _ = ledger.move(world, e, r, n),
        .good => |gi| {
            const units: u32 = @intFromFloat(@abs(n));
            if (n > 0) capital.acquire(world, e, res, gi, units) else _ = capital.release(world, e, res, gi, units);
        },
    }
}

/// MARKET: the neighbours view over the stub neighbour book; an accepted deal moves the
/// player's real stocks and goods.
fn market(ctx: *UiCtx, world: *World, e: Entity, s: t.ActSurface, initial: ?uic.UiState.MarketState) !void {
    const m = &ctx.res.sim.neighbours;
    if (!m.seeded) m.seed(24);
    var player = t.MarketPlayer{ .trade = "forager", .held = undefined, .reserved = undefined, .coin = ledger.balance(world, e, .coin) };
    for (0..nb.item_count) |i| {
        player.held[i] = heldItem(world, e, &ctx.res.catalog, i);
        player.reserved[i] = @min(player.held[i], reserve[i]);
    }
    const st = s.owner.state(uic.UiState.MarketState);
    if (initial) |seed| st.* = seed;
    const stall_owner = try s.owner.div("stall_query");
    const r = try t.market_view(s.view, "a2_market", m, st, player, s.owner, stall_owner);
    if (r.settled) |deal| {
        for (0..nb.item_count) |i| {
            if (deal.give[i] > 0) moveItem(world, e, ctx.res, i, -@as(f32, @floatFromInt(deal.give[i])));
            if (deal.take[i] > 0) moveItem(world, e, ctx.res, i, @floatFromInt(deal.take[i]));
        }
        _ = ledger.move(world, e, .coin, @as(f32, @floatFromInt(deal.take[nb.coin])) - @as(f32, @floatFromInt(deal.give[nb.coin])));
        ctx.res.sim.log.push(.good, "A neighbour takes your deal. Both sides settle.");
    }
}

test "Act II's BUILD widths fill the lane and hold every Act II build order unelided" {
    const roster = ha.roster;
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    try std.testing.expectEqual(t.build_lane_width, build_shelf.widths.laneTotal());
    if (t.buildCostOverflow(&cat, build_shelf)) |g| {
        std.debug.print("{s}'s order elides in Act II's COST lane\n", .{g.id});
        return error.TestUnexpectedResult;
    }
}
