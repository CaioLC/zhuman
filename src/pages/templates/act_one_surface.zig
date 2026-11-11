//! `act_one_surface` — Act I's content on the shared `act_surface`: the ACTIONS / BUILD views
//! under the passerby and activity strips, and MARKET, a focus view as Act II's is (the strips
//! step aside there). The surface owns the tabs, strips and per-view state; this file only says
//! what Act I's three views are.
//!
//! MARKET is `market_view` with nobody in it: the lone actor's own row, and its INVENTORY of what
//! it holds (`Player.own`), where a stepped offer is a `PostOffer` intent.

const std = @import("std");
const ha = @import("ha");
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const El = el.El;

const surface_mod = @import("./act_surface.zig");
const scroll_view_mod = @import("./scroll_view.zig");
const market_strip_mod = @import("./market_strip.zig");
const actions_section_mod = @import("./actions_section.zig");
const build_section_mod = @import("./build_section.zig");
const market_view_mod = @import("./market_view.zig");

const comp = ha.sim.comp;
const nb = ha.sim.rules.neighbours;
const nb_sys = ha.sim.systems.neighbours;

/// The surface's views, in tab order.
pub const View = enum(usize) { actions, build, market };
const view_labels = [_][]const u8{ "ACTIONS", "BUILD", "MARKET" };
/// MARKET owns the whole surface: no strips, no log, the Household collapsed on entry.
pub const focus_views = [_]usize{@intFromEnum(View.market)};

/// Act I's ACTIONS content: one body's verbs. Its eating policy rides the Household rail.
pub const actions_shelf = actions_section_mod.Shelf{
    .act = 1,
    .subtitle = "Work available to you.",
};

/// Act I's BUILD content: personal crafting — the recipes whose gates pass, so a gated recipe
/// (the chicken coop) appears once the good before it is owned — and the Shelter that ends the act.
pub const build_shelf = build_section_mod.Shelf{
    .act = 1,
    .gates_hide = true,
    .subtitle = "Recipes available to you.",
    .milestone = .{
        .which = .act_one,
        .kicker = "A PLACE FOR OTHERS",
        .copy = "a roof with room for four. you're not alone anymore.",
        .explanation = std.fmt.comptimePrint("Hold 120 {s} with a settled body and five kinds of goods, a rope bag and a leaf bed among them.", .{ha.sim.data.roster.Resource.biomass.wordIn(1)}),
        .building = "The Shelter is going up.",
        .waiting = "Everything is on hand; the Shelter waits for free hands.",
        .action = "BUILD SHELTER \u{2192}",
    },
};

pub const Activity = surface_mod.Activity;

pub const Options = struct {
    market: market_strip_mod.MarketKind = .passerby,
    market_available: bool = true,
    activity: Activity,
    /// Open on this view (a `View`'s index) instead of the remembered one — a fixture's first
    /// frame. Null keeps the tabs' own selection.
    initial_view: ?usize = null,
    /// Seed the view's search text and sort, and open the Shelter card (a fixture's first frame).
    initial_query: ?[]const u8 = null,
    initial_sort: ?uic.UiState.CatalogState = null,
    milestone_open: bool = false,
    /// Seed the MARKET view's state (a fixture's first frame).
    market_state: ?uic.UiState.MarketState = null,
};

pub const Result = struct {
    el: El,
    active: usize,
    /// Whether the active view is a focus view (MARKET): no strips, no log, the rail collapsed
    /// on entry.
    focus: bool,
    /// The strip's trailing action, or null on a focus view.
    market_action: ?El,
};

/// Compose Act I's work surface. The returned market control is the strip's trailing action;
/// callers own eligibility and modal lifecycle.
pub fn act_one_surface(parent: El, world: *const World, e: Entity, id: []const u8, opts: Options) !Result {
    const s = try surface_mod.act_surface(parent, id, .{
        .labels = &view_labels,
        .nav_name = "Act I surfaces",
        .focus_views = &focus_views,
        .market = opts.market,
        .market_available = opts.market_available,
        .activity = opts.activity,
        .initial_view = opts.initial_view,
        .initial_query = opts.initial_query,
        .initial_sort = opts.initial_sort,
    });

    // ACTIONS scrolls whole; BUILD keeps its heading, search and column header put and scrolls
    // only its table, so it takes the view directly.
    switch (@as(View, @enumFromInt(s.active))) {
        .actions => {
            const scroll = try scroll_view_mod.scroll_view(s.view, "scroll", .{ .height = 0, .framed = false, .name = "Available actions" }, s.scroll);
            _ = try actions_section_mod.actions_section(scroll.content, world, e, "actions_section", actions_shelf, s.catalog, s.owner, null);
        },
        .build => {
            var shelf = build_shelf;
            if (opts.milestone_open) shelf.milestone.?.expand = true;
            _ = try build_section_mod.build_section(s.view, world, e, "buildsection", shelf, s.catalog, s.owner, s.scroll);
        },
        .market => try market(s, world, e, opts.market_state),
    }
    return .{ .el = s.el, .active = s.active, .focus = s.focus, .market_action = s.market_action };
}

/// What the lone actor holds, in the INVENTORY's order: food, materials, then each good owned
/// in the catalog's order, with its spare (`nb.spareOf`).
pub fn inventory(ctx: *uic.UiCtx, world: *const World, e: Entity) ![]const market_view_mod.Own {
    var list: std.ArrayList(market_view_mod.Own) = .empty;
    for ([_]nb.Holding{ .food, .biomass }) |h| try list.append(ctx.arena, .{ .item = h, .held = nb_sys.heldOf(world, e, h), .spare = nb_sys.spareOf(world, e, h) });
    if (world.get(e, comp.Goods)) |goods| for (ctx.res.game.catalog.goods, 0..) |_, gi| {
        if (goods.count[gi] == 0) continue;
        const h: nb.Holding = .{ .good = @intCast(gi) };
        try list.append(ctx.arena, .{ .item = h, .held = nb_sys.heldOf(world, e, h), .spare = nb_sys.spareOf(world, e, h) });
    };
    return list.items;
}

/// MARKET: the neighbours view before anyone else exists. Its offers stand on the book's
/// Act I offers; a stepped one is a `PostOffer` intent, which the handler caps at the spare.
fn market(s: surface_mod.Result, world: *const World, e: Entity, initial: ?uic.UiState.MarketState) !void {
    const ctx = s.view.ctx;
    const st = s.owner.state(uic.UiState.MarketState);
    if (initial) |seed| st.* = seed;
    const stall_owner = try s.owner.div("stall_query");
    const player = market_view_mod.Player{ .trade = "", .held = @splat(0), .reserved = @splat(0), .coin = 0, .own = try inventory(ctx, world, e) };
    // Stacked (≤760) the page scrolls as one, so the view gets a definite height of its own.
    const host = if (@import("./terminal.zig").stacked(ctx))
        try s.view.box("market_box", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 640 } }, .{})
    else
        s.view;
    const r = try market_view_mod.market_view(host, "market", &ctx.res.game.sim.neighbours, st, player, s.owner, stall_owner);
    if (r.offer) |o| _ = ctx.res.game.events.writer(ha.sim.events.PostOffer).push(.{ .agent = e, .item = o.item, .qty = o.qty });
}

test "Act I's BUILD widths fill the lane and hold every Act I build order unelided" {
    var cat = try ha.sim.data.roster.load(std.testing.allocator, ha.sim.data.roster.shipped, null);
    defer cat.deinit();
    try std.testing.expectEqual(@import("./capital_row.zig").lane_width, build_shelf.widths.laneTotal());
    try std.testing.expect(@import("./build_list.zig").costOverflow(&cat, build_shelf) == null);
}
