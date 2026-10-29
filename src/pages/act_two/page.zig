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
/// Its milestone, the Exchange, is composed by the page (`exchangeGoal`) because its
/// conditions are research and population. Its orders run to three
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
    /// Open the Exchange card's details on this frame (a fixture's first frame).
    exchange_open: bool = false,
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
    stocks[n] = .{ .abbrev = "PO", .full = "Population", .value = population(ctx) };
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
        .market = if (ctx.res.sim.exchange.standing) .exchange else .merchant,
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
        .build => {
            var shelf = build_shelf;
            var raised = false;
            shelf.goal = try exchangeGoal(ctx, world, e);
            if (opts.exchange_open or ctx.res.sim.exchange.reveal) shelf.goal.?.expand = true;
            ctx.res.sim.exchange.reveal = false;
            shelf.raised = &raised;
            _ = try t.build_section(s.view, world, e, "a2_build", shelf, s.catalog, s.owner, s.scroll);
            if (raised) raiseExchange(ctx, world, e);
        },
        .generators => {
            const scroll = try t.scroll_view(s.view, "scroll", .{ .height = 0, .framed = false }, s.scroll);
            _ = try t.generator_section(scroll.content, world, e, "a2_generators", generator_shelf);
        },
        .research => try researchView(ctx, world, e, s),
        .market => try market(ctx, world, e, s, opts.market),
    } else {
        _ = try t.empty_state(s.view, "a2_nobody", "No settlement", "There is no one here to act.");
    }

    // --- the Coin Merchant overlay (its own top-layer root) ---------------------------------
    const merchant_root: ?*Node = if (agent) |e| try coin_merchant(ctx, world, e, "a2_trade", trade_owner.state(uic.UiState.TradeState)) else null;

    return page.finish(.{
        .stocks = stocks[0..n],
        .compact_stocks = true,
        .act_label = if (ctx.res.sim.exchange.standing) "Act III" else "Act II",
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

/// The Exchange's price and the population it waits on (`act-ii.html`).
const exchange_cost = [_]struct { ha.roster.Resource, f32 }{ .{ .biomass, 80 }, .{ .minerals, 40 }, .{ .metal, 24 } };

/// The settlement's population: the fixture's stand-in, or the stub override a fixture sets.
fn population(ctx: *UiCtx) f32 {
    return fx.populationOf(&ctx.res.sim);
}

/// The first ring-4 technology established, alphabetically (the prototype names one).
fn ringFour(ctx: *UiCtx, world: *World, e: Entity) ?[]const u8 {
    const research = world.get(e, comp.Research) orelse return null;
    var best: ?[]const u8 = null;
    for (ctx.res.catalog.technologies, 0..) |tech, i| {
        if (tech.coord.ring() != 4 or research.state[i] != .researched) continue;
        if (best == null or std.mem.order(u8, tech.name, best.?) == .lt) best = tech.name;
    }
    return best;
}

/// The Exchange's lifecycle: standing once raised; locked until a ring-4 technology stands and
/// the settlement is strictly more than 500 people; then unfunded while any input is short.
fn exchangeLifecycle(standing: bool, people: f32, ring_four: bool, short_kinds: u32) t.MilestoneLifecycle {
    if (standing) return .done;
    if (!(ring_four and people > 500)) return .locked;
    return if (short_kinds > 0) .unfunded else .ready;
}

test "the Exchange unlocks past 500 people with a ring-4 technology, and funds separately" {
    const x = std.testing.expectEqual;
    try x(t.MilestoneLifecycle.locked, exchangeLifecycle(false, 500, true, 0));
    try x(t.MilestoneLifecycle.ready, exchangeLifecycle(false, 501, true, 0));
    try x(t.MilestoneLifecycle.locked, exchangeLifecycle(false, 501, false, 0));
    // Each short input keeps it unfunded on its own.
    try x(t.MilestoneLifecycle.unfunded, exchangeLifecycle(false, 501, true, 1));
    try x(t.MilestoneLifecycle.unfunded, exchangeLifecycle(false, 501, true, 3));
    try x(t.MilestoneLifecycle.done, exchangeLifecycle(true, 0, false, 3));
}

/// The Exchange card: locked until a ring-4 technology stands and the settlement passes 500
/// people, unfunded until the biomass, minerals and metal are held, ready, then standing.
fn exchangeGoal(ctx: *UiCtx, world: *World, e: Entity) !t.MilestoneGoal {
    const a = ctx.arena;
    const standing = ctx.res.sim.exchange.standing;
    const people = population(ctx);
    const four = ringFour(ctx, world, e);
    const research_met = four != null;
    const people_met = people > 500;
    var short_kinds: u32 = 0;
    var short: std.ArrayList(u8) = .empty;
    var reqs: std.ArrayList(t.MilestoneRequirement) = .empty;
    try reqs.append(a, .{ .label = "RING 4", .value = if (research_met or standing) "1/1" else "0/1", .met = research_met or standing });
    try reqs.append(a, .{ .label = "PEOPLE", .value = try a.print("{}/501", .{@as(u32, @intFromFloat(people))}), .met = people_met or standing });
    for (exchange_cost) |c| {
        const have = ledger.balance(world, e, c[0]);
        const word = c[0].wordIn(2);
        if (have < c[1]) {
            short_kinds += 1;
            if (short.items.len > 0) try short.appendSlice(a, " \u{00b7} ");
            try short.appendSlice(a, try a.print("{} {s}", .{ @as(u32, @intFromFloat(c[1] - @floor(have))), word }));
        }
        try reqs.append(a, .{
            .label = try std.ascii.allocUpperString(a, word),
            .value = if (standing) try a.print("{} paid", .{@as(u32, @intFromFloat(c[1]))}) else try a.print("{}/{}", .{ @as(i64, @intFromFloat(@floor(have))), @as(u32, @intFromFloat(c[1])) }),
            .met = standing or have >= c[1],
        });
    }
    const state = exchangeLifecycle(standing, people, research_met, short_kinds);
    const people_n: u32 = @intFromFloat(people);
    const unmet: u32 = @as(u32, @intFromBool(!research_met)) + @intFromBool(!people_met);
    return .{
        .state = state,
        .title = "Exchange",
        .readiness = switch (state) {
            .locked => try a.print("locked \u{00b7} {} condition{s}", .{ unmet, if (unmet == 1) "" else "s" }),
            .unfunded => "inputs short",
            .ready => "ready to raise",
            .done => "standing \u{00b7} ACT III",
        },
        .summary = switch (state) {
            .locked => try a.print("ring 4 {}/1 \u{00b7} people {}/501", .{ @intFromBool(research_met), people_n }),
            .unfunded => try a.print("inputs short \u{00b7} {} kind{s}", .{ short_kinds, if (short_kinds == 1) "" else "s" }),
            .ready => try a.print("{s} \u{00b7} {} people \u{00b7} inputs ready", .{ four.?, people_n }),
            .done => "permanent market \u{00b7} Act III",
        },
        .kicker = "ACT II CURTAIN \u{00b7} A MARKET WITH A PLACE",
        .cost = "80 biomass \u{00b7} 40 minerals \u{00b7} 24 metal \u{00b7} 18d",
        .copy = if (standing)
            "The Exchange gives trade a permanent place. Passing lots become posted offers and the settlement enters Act III."
        else
            "Raise a standing trading floor. Once it opens, passing lots give way to a permanent market and Act III begins.",
        .requirements = reqs.items,
        .explanation = switch (state) {
            .locked => if (!research_met and !people_met) "Research any ring-4 technology and grow beyond 500 people." else if (!research_met) "Research any ring-4 technology." else try a.print("Grow beyond 500 people \u{00b7} {}/501.", .{people_n}),
            .unfunded => try a.print("needs {s}", .{short.items}),
            .ready => try a.print("{s} established \u{00b7} {} people \u{00b7} all inputs held", .{ four.?, people_n }),
            .done => try a.print("opened after {s} \u{00b7} permanent market established", .{four orelse "ring-4 research"}),
        },
        .action = switch (state) {
            .locked => "LOCKED",
            .unfunded => "NEEDS INPUTS",
            .ready => "RAISE EXCHANGE \u{2192}",
            .done => "ACT III OPEN",
        },
    };
}

/// Raise the Exchange: pay its price from the ledger and stand it; the settlement reads as
/// Act III from the next frame.
fn raiseExchange(ctx: *UiCtx, world: *World, e: Entity) void {
    if (ctx.res.sim.exchange.standing) return;
    for (exchange_cost) |c| if (ledger.balance(world, e, c[0]) < c[1]) return;
    for (exchange_cost) |c| _ = ledger.move(world, e, c[0], -c[1]);
    ctx.res.sim.exchange.standing = true;
    ctx.res.sim.exchange.reveal = true;
    ctx.res.sim.log.push(.good, "The Exchange stands. Passing merchants become a permanent market; Act III opens.");
}

/// RESEARCH: the hex board over the agent's `comp.Research`. RESEARCH → pays the tile's cost
/// from the ledger and establishes it through `grid/board`, which opens its outward neighbours.
fn researchView(ctx: *UiCtx, world: *World, e: Entity, s: t.ActSurface) !void {
    const board = ha.grid.board;
    const cat = &ctx.res.catalog;
    const research = world.get(e, comp.Research) orelse {
        _ = try t.empty_state(s.view, "a2_research", "No research board", "The settlement has not crossed the curtain.");
        return;
    };
    const wedges = [6]ha.roster.Resource{ .food, .water, .fuel, .metal, .minerals, .biomass };
    var held: [6]f32 = undefined;
    for (wedges, 0..) |r, i| held[i] = ledger.balance(world, e, r);
    const st = s.owner.state(uic.UiState.ResearchState);
    const query_owner = try s.owner.div("research_query");
    const out = try t.research_board(s.view, "a2_research", .{ .cat = cat, .research = research, .held = held }, st, query_owner);
    const idx = out.research orelse return;

    var bal = board.Balances{};
    for (wedges, 0..) |r, i| bal.set(r, @intFromFloat(@max(0, @floor(held[i]))));
    var before: u64 = 0;
    for (0..cat.technologies.len) |i| if (research.state[i] == .available) {
        before |= @as(u64, 1) << @intCast(i);
    };
    if (board.research(cat, research, idx, &bal) != .researched) return;
    const tech = &cat.technologies[idx];
    for (tech.cost) |line| {
        const r = ha.roster.Catalog.resource(line.item) orelse continue;
        _ = ledger.move(world, e, r, -@round(line.n));
    }
    var newly: u64 = 0;
    var suffix: std.ArrayList(u8) = .empty;
    for (0..cat.technologies.len) |i| {
        const bit = @as(u64, 1) << @intCast(i);
        if (research.state[i] == .available and before & bit == 0) {
            newly |= bit;
            try suffix.appendSlice(ctx.arena, if (suffix.items.len == 0) " " else ", ");
            try suffix.appendSlice(ctx.arena, cat.technologies[i].name);
        }
    }
    if (suffix.items.len > 0) try suffix.appendSlice(ctx.arena, " now available.");
    st.last = idx;
    st.newly = newly;
    const cost = try t.researchCostLine(ctx.arena, tech);
    ctx.res.sim.log.push(.good, try ctx.arena.print("{s} is established. {s} paid.{s}", .{ tech.name, cost, suffix.items }));
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
    // Stacked (≤760) the page scrolls as one, so the view gets a definite height of its own.
    const host = if (t.stacked(ctx)) blk: {
        const box = try s.view.div("a2_market_box");
        _ = box.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 640 });
        break :blk box;
    } else s.view;
    const r = try t.market_view(host, "a2_market", m, st, player, s.owner, stall_owner);
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
