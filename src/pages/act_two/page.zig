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
//! catalog, and write the labor and build intents as Act I does. What no
//! system models yet — population, coin, the energy rate, flows and body projections — comes
//! from `fixtures.zig`.
//!
//! Each catalog view owns a persistent `CatalogState`, search editor and scroll offset on an
//! always-built owner node, so switching views keeps each view's query, sort and position where
//! the player left them (the `tabs` persistence contract). The Coin Merchant dialog is the
//! page's own top-layer overlay root, listed after the shell.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const tag = ha.sim.tag;
const ecs = ha.sim.ecs;
const actions = ha.sim.rules.actions;
const ledger = ha.sim.rules.ledger;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

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
const ledger_stocks = [_]ha.sim.data.roster.Resource{
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
    /// Seed the RESEARCH board on this frame (a fixture's first frame).
    research: ?t.ResearchSeed = null,
    /// Seed the active view's search and sort, and the merchant dialog's tab (a fixture's
    /// first frame).
    initial_query: ?[]const u8 = null,
    initial_sort: ?uic.UiState.CatalogState = null,
    trade_mode: ?usize = null,
};

pub const ResearchSeed = t.ResearchSeed;

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
    stocks[n] = .{ .abbrev = "PO", .full = "Population", .value = population(ctx), .max = fx.capacityOf(population(ctx)) };
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
                .verdict = uic.style.verdict.when(amount <= 0, .low),
            };
            n += 1;
        }
    }
    stocks[n] = .{
        .abbrev = ha.sim.data.roster.Resource.coin.abbrevIn(2),
        .full = ha.sim.data.roster.Resource.coin.labelIn(2),
        .value = if (agent) |e| ledger.balance(world, e, .coin) else 0,
        .tone = .accent,
    };
    n += 1;

    // The merchant dialog's open/mode/selection persists on an always-built node, surviving
    // view switches (a focus view hides the strip, never the deal).
    const trade_owner = try regions.body.box("a2_trade_state", .{ .w = .{ .fixed = 0 }, .h = .{ .fixed = 0 } }, .{});

    // --- the body: the shared act surface, then the active view ----------------------------
    const s = try t.act_surface(regions.body, "a2_surface", .{
        .labels = &view_labels,
        .nav_name = "Act II surfaces",
        .focus_views = &focus_views,
        .market = if (ctx.res.game.sim.exchange.standing) .exchange else .merchant,
        .market_available = ctx.res.game.sim.exchange.standing or ctx.res.game.sim.merchant.dealable(),
        .activity = blk: {
            var act = try t.activityOf(ctx, if (agent) |e| world.get(e, comp.Busy) else null);
            // A standing Exchange is what the idle settlement reports (`setActivity('idle',
            // 'Exchange standing', 'Act III open')`).
            if (act.state == .idle and ctx.res.game.sim.exchange.standing) {
                act.subject = "Exchange standing";
                act.metadata = "Act III open";
            }
            break :blk act;
        },
        .nav_gap = 8, // `.act-two .surface-nav`
        .initial_view = opts.initial_view,
        .initial_query = opts.initial_query,
        .initial_sort = opts.initial_sort,
    });
    if (s.market_action) |m| {
        if ((m.query().clicked or opts.open_trade) and (ctx.res.game.sim.exchange.standing or ctx.res.game.sim.merchant.dealable()))
            trade_owner.state(uic.UiState.TradeState).open = true;
    }
    if (opts.trade_mode) |mode| trade_owner.state(uic.UiState.TradeState).mode = mode;

    // --- the rail: the Household column, collapsing with it ---------------------------------
    // Each view keys its own rail, so ACTIONS, BUILD and GENERATORS remember their collapse
    // separately; a focus view collapses its rail on entry without touching those memories,
    // and the player may open it again while there.
    const vm = trade_owner.state(uic.UiState.ViewMemory);
    const entered = vm.last == null or vm.last.? != s.active;
    vm.last = s.active;
    if (regions.rail) |rail_region| {
        const r = try t.rail(rail_region, .{
            .id = rail_ids[@min(s.active, rail_ids.len - 1)],
            .label = "HOUSEHOLD",
            // A fixture that opens the rail on its first frame (`initial_collapsed = false`)
            // overrides the entry collapse.
            .force_collapsed = s.focus and entered and opts.initial_collapsed != false,
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
            // The card opens its details once, the frame the raise is read back (ACT2-18).
            var stood = false;
            const heard = ctx.res.game.events.readerAt(ha.sim.events.ExchangeRaised, &trade_owner.state(uic.UiState.ViewMemory).heard);
            while (heard.next()) |f| stood = stood or f.agent == e;
            if (opts.exchange_open or stood) shelf.goal.?.expand = true;
            shelf.raised = &raised;
            _ = try t.build_section(s.view, world, e, "a2_build", shelf, s.catalog, s.owner, s.scroll);
            if (raised) _ = ctx.res.game.events.writer(ha.sim.events.RaiseExchange).push(.{ .agent = e });
        },
        .generators => {
            const scroll = try t.scroll_view(s.view, "scroll", .{ .height = 0, .framed = false, .name = "Owned generators" }, s.scroll);
            _ = try t.generator_section(scroll.content, world, e, "a2_generators", generator_shelf);
        },
        .research => try researchView(ctx, world, e, s, opts.research),
        .market => try market(ctx, world, e, s, opts.market),
    } else {
        _ = try t.empty_state(s.view, "a2_nobody", "No settlement", "There is no one here to act.");
    }

    // --- the Coin Merchant overlay (its own top-layer root) ---------------------------------
    const merchant_root: ?*Node = if (agent) |e| try coin_merchant(ctx, world, e, "a2_trade", trade_owner.state(uic.UiState.TradeState)) else null;

    return page.finish(.{
        .stocks = stocks[0..n],
        .compact_stocks = true,
        .act_label = if (ctx.res.game.sim.exchange.standing) "Act III" else "Act II",
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

const nb = ha.sim.rules.neighbours;
const neighbours = ha.sim.systems.neighbours;

const exchange = ha.sim.systems.exchange;

/// The settlement's population: the stand-in until the population model exists (ACT2-01).
fn population(ctx: *UiCtx) f32 {
    return ctx.res.game.sim.population;
}

/// The Exchange card: locked until a ring-4 technology stands and the settlement passes 500
/// people, unfunded until the biomass, minerals and metal are held, ready, then standing.
fn exchangeGoal(ctx: *UiCtx, world: *World, e: Entity) !t.MilestoneGoal {
    const a = ctx.arena;
    const standing = ctx.res.game.sim.exchange.standing;
    const people = population(ctx);
    const four = if (world.get(e, comp.Research)) |board| exchange.ringFour(&ctx.res.game.catalog, board) else null;
    const research_met = four != null;
    const people_met = people > exchange.people_needed;
    var short_kinds: u32 = 0;
    var short: std.ArrayList(u8) = .empty;
    var reqs: std.ArrayList(t.MilestoneRequirement) = .empty;
    try reqs.append(a, .{ .label = "RING 4", .value = if (research_met or standing) "1/1" else "0/1", .met = research_met or standing });
    try reqs.append(a, .{ .label = "PEOPLE", .value = try a.print("{}/501", .{@as(u32, @intFromFloat(people))}), .met = people_met or standing });
    for (exchange.cost) |c| {
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
    const state: t.MilestoneLifecycle = switch (exchange.lifecycle(standing, people, research_met, short_kinds)) {
        inline else => |l| @field(t.MilestoneLifecycle, @tagName(l)),
    };
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

/// RESEARCH: the hex board over the agent's `comp.Research`. RESEARCH → a `Research` intent;
/// the handler pays the tile's cost and establishes it, and the board highlights what it opened
/// once the `Researched` fact is read back.
fn researchView(ctx: *UiCtx, world: *World, e: Entity, s: t.ActSurface, seed: ?t.ResearchSeed) !void {
    const cat = &ctx.res.game.catalog;
    const research = world.get(e, comp.Research) orelse {
        _ = try t.empty_state(s.view, "a2_research", "No research board", "The settlement has not crossed the curtain.");
        return;
    };
    const wedges = [6]ha.sim.data.roster.Resource{ .food, .water, .fuel, .metal, .minerals, .biomass };
    var held: [6]f32 = undefined;
    for (wedges, 0..) |r, i| held[i] = ledger.balance(world, e, r);
    const st = s.owner.state(uic.UiState.ResearchState);
    const heard = ctx.res.game.events.readerAt(ha.sim.events.Researched, &st.heard);
    while (heard.next()) |f| {
        if (f.agent != e) continue;
        st.last = f.ti;
        st.newly = f.newly;
    }
    const query_owner = try s.owner.div("research_query");
    if (seed) |sd| t.researchApplySeed(cat, st, query_owner, sd);
    const out = try t.research_board(s.view, "a2_research", .{ .cat = cat, .research = research, .held = held }, st, query_owner);
    const idx = out.research orelse return;
    _ = ctx.res.game.events.writer(ha.sim.events.Research).push(.{ .agent = e, .ti = @intCast(idx) });
}

/// MARKET: the neighbours view over the stub neighbour book; a deal the neighbour accepts is a
/// `NeighbourDeal` intent, which the handler settles on both sides.
fn market(ctx: *UiCtx, world: *World, e: Entity, s: t.ActSurface, initial: ?uic.UiState.MarketState) !void {
    const m = &ctx.res.game.sim.neighbours;
    if (!m.seeded) m.seed(neighbours.people);
    var player = t.MarketPlayer{ .trade = "forager", .held = undefined, .reserved = undefined, .coin = ledger.balance(world, e, .coin) };
    for (0..nb.item_count) |i| {
        player.held[i] = neighbours.heldItem(world, e, &ctx.res.game.catalog, i);
        player.reserved[i] = @min(player.held[i], neighbours.reserve[i]);
    }
    const st = s.owner.state(uic.UiState.MarketState);
    if (initial) |seed| st.* = seed;
    const stall_owner = try s.owner.div("stall_query");
    // Stacked (≤760) the page scrolls as one, so the view gets a definite height of its own.
    const host = if (t.stacked(ctx)) blk: {
        const box = try s.view.box("a2_market_box", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 640 } }, .{});
        break :blk box;
    } else s.view;
    const r = try t.market_view(host, "a2_market", m, st, player, s.owner, stall_owner);
    if (r.settled) |deal| _ = ctx.res.game.events.writer(ha.sim.events.NeighbourDeal).push(.{ .agent = e, .neighbour = deal.neighbour, .give = deal.give, .take = deal.take });
}

test "Act II's BUILD widths fill the lane and hold every Act II build order unelided" {
    const roster = ha.sim.data.roster;
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    try std.testing.expectEqual(t.build_lane_width, build_shelf.widths.laneTotal());
    if (t.buildCostOverflow(&cat, build_shelf)) |g| {
        std.debug.print("{s}'s order elides in Act II's COST lane\n", .{g.id});
        return error.TestUnexpectedResult;
    }
}
