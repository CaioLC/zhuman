//! `act_two/page` — the Act II **shared-shell instantiation** (ACT2-10) and the composition
//! root for the Act II catalogs.
//!
//! It fills the one shared `shell` with Act II's descriptors: the stockline PO, VI, FO, WA, FU,
//! ME, MI, BI, CO in its compact form, a runline carrying the energy rate, `Act II` and the day,
//! and the surface's three-view nav — ACTIONS / BUILD / STRUCTURE. The Merchant and Activity
//! strips appear on ACTIONS and BUILD and are suppressed on STRUCTURE (the research board owns
//! the surface there), yet their state is never lost because it lives in the page, not the
//! strips. Holdings/BODY ride the shell rail; the event log rides the shell footer.
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
};
/// Act II's BUILD content — the same pane as Act I's: the settlement's recipes of every tier.
/// The act authors no milestone card yet (the Exchange, ACT2-17). Its orders run to three
/// materials (`36me 24fu 20mi`), so its COST lane is wide and WHAT CHANGES gives the width up.
const build_shelf = t.BuildShelf{
    .act = 2,
    .subtitle = "Find the next recipe the settlement can raise.",
    .widths = .{ .cost = 112, .effect = 140 - t.build_scroll_gutter },
};
const a2_holdings = @import("./holdings.zig");
const coin_merchant = @import("./coin_merchant.zig").coin_merchant;

/// The surface's views. STRUCTURE (index 2) suppresses the strips.
const view_labels = [_][]const u8{ "ACTIONS", "BUILD", "STRUCTURE" };

/// The stocks the stockline reads from the ledger, in its order after Vigor.
const ledger_stocks = [_]struct { r: ha.roster.Resource, abbrev: []const u8, full: []const u8 }{
    .{ .r = .food, .abbrev = "FO", .full = "Food" },
    .{ .r = .water, .abbrev = "WA", .full = "Water" },
    .{ .r = .fuel, .abbrev = "FU", .full = "Fuel" },
    .{ .r = .metal, .abbrev = "ME", .full = "Metal" },
    .{ .r = .minerals, .abbrev = "MI", .full = "Minerals" },
    .{ .r = .biomass, .abbrev = "BI", .full = "Biomass" },
};

/// What a caller may ask of the page beyond the world.
pub const Options = struct {
    /// The view to open on (0 ACTIONS, 1 BUILD, 2 STRUCTURE), applied on the frame it is set;
    /// the tabs own the selection on every other frame.
    initial_view: ?usize = null,
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
        for (ledger_stocks) |s| {
            const amount = ledger.balance(world, e, s.r);
            stocks[n] = .{
                .abbrev = s.abbrev,
                .full = s.full,
                .value = amount,
                .tone = if (amount <= 0) .danger else .normal,
            };
            n += 1;
        }
    }
    stocks[n] = .{ .abbrev = "CO", .full = "Coin", .value = fx.coin };
    n += 1;

    // --- the rail: Act II Holdings/BODY ------------------------------------------------------
    if (regions.rail) |rail| {
        if (agent) |e| _ = try t.holdings(rail, "a2_holdings", try a2_holdings.content(ctx, world, e));
    }

    // The merchant dialog's open/mode/selection persists on an always-built node, surviving
    // view switches (STRUCTURE hides the strip, never the deal).
    const trade_owner = try regions.body.div("a2_trade_state");
    _ = trade_owner.with_size(.{ .fixed = 0 }, .{ .fixed = 0 });

    // --- the body: the shared act surface, then the active view ----------------------------
    const s = try t.act_surface(regions.body, "a2_surface", .{
        .labels = &view_labels,
        .bare_view = 2, // STRUCTURE owns the whole surface
        .market = .merchant,
        .activity = try t.activityOf(ctx, if (agent) |e| world.get(e, comp.Busy) else null),
        .nav_gap = 8, // `.act-two .surface-nav`
        .initial_view = opts.initial_view,
    });
    if (s.market_action) |m| {
        if (m.query().clicked) trade_owner.state(uic.UiState.TradeState).open = true;
    }

    if (agent) |e| switch (s.active) {
        0 => {
            const scroll = try t.scroll_view(s.view, "scroll", .{ .height = 0, .framed = false }, s.scroll);
            _ = try t.actions_section(scroll.content, world, e, "a2_actions", actions_shelf, s.catalog, s.owner);
        },
        // BUILD is the shared pane: it fills the view and scrolls only its table.
        1 => _ = try t.build_section(s.view, world, e, "a2_build", build_shelf, s.catalog, s.owner, s.scroll),
        else => {
            // STRUCTURE: the strips are suppressed here; the research board is not drawn yet.
            _ = try t.empty_state(s.view, "a2_structure", "STRUCTURE board", "The research board is not drawn yet.");
        },
    } else {
        _ = try t.empty_state(s.view, "a2_nobody", "No settlement", "There is no one here to act.");
    }

    // --- the Coin Merchant overlay (its own top-layer root) ---------------------------------
    const merchant = try coin_merchant(ctx, "a2_trade", trade_owner.state(uic.UiState.TradeState));
    if (merchant.confirmed) |i| {
        const lots = if (merchant.mode == 0) &fx.merchant_buys else &fx.merchant_sells;
        if (i < lots.len) {
            var buf: [64]u8 = undefined;
            const verb = if (merchant.mode == 0) "buy" else "sell";
            const msg = std.fmt.bufPrint(&buf, "You {s} {s} from the merchant.", .{ verb, lots[i].name }) catch "You trade.";
            ctx.res.sim.log.push(.good, msg);
        }
    }

    return page.finish(.{
        .stocks = stocks[0..n],
        .compact_stocks = true,
        .act_label = "Act II",
        .gen = fx.energy_gen,
        .consumed = fx.energy_consumed,
        .overlay = merchant.root,
    });
}

test {
    _ = @import("./fixtures.zig");
    _ = @import("./coin_merchant.zig");
    _ = @import("./holdings.zig");
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
