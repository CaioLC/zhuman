//! `act_one_surface` — Act I's content on the shared `act_surface`: the ACTIONS / BUILD /
//! GENERATORS views under the passerby and activity strips. The surface owns the tabs, strips
//! and per-view state; this file only says what Act I's three views are.

const std = @import("std");
const ha = @import("ha");
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const El = el.El;

const surface_mod = @import("./act_surface.zig");
const scroll_view_mod = @import("./scroll_view.zig");
const market_strip_mod = @import("./market_strip.zig");
const actions_section_mod = @import("./actions_section.zig");
const build_section_mod = @import("./build_section.zig");
const generator_section_mod = @import("./generator_section.zig");

const view_labels = [_][]const u8{ "ACTIONS", "BUILD", "GENERATORS" };

/// Act I's ACTIONS content: one body's verbs, with the eating policy at the foot of the grid.
pub const actions_shelf = actions_section_mod.Shelf{
    .act = 1,
    .subtitle = "What will this body do now?",
    .eating_policy = true,
};

/// Act I's BUILD content: personal crafting (the crude tier) and the Shelter that ends the act.
pub const build_shelf = build_section_mod.Shelf{
    .act = 1,
    .crude_only = true,
    .subtitle = "Find the next useful recipe your own hands can raise.",
    .milestone = .{
        .which = .act_one,
        .kicker = "A PLACE FOR OTHERS",
        .copy = "a roof with room for four. you're not alone anymore.",
        .explanation = std.fmt.comptimePrint("Hold 60 {s} with a settled body and four kinds of goods.", .{ha.roster.Resource.biomass.wordIn(1)}),
        .action = "RAISE SHELTER \u{2192}",
    },
};

pub const Activity = surface_mod.Activity;

pub const Options = struct {
    market: market_strip_mod.MarketKind = .passerby,
    market_available: bool = true,
    activity: Activity,
    /// Open on this view (0 ACTIONS, 1 BUILD, 2 GENERATORS) instead of the remembered one —
    /// a fixture's first frame. Null keeps the tabs' own selection.
    initial_view: ?usize = null,
};

pub const Result = struct {
    el: El,
    active: usize,
    market_action: El,
};

/// Compose Act I's work surface. The returned market control is the strip's trailing action;
/// callers own eligibility and modal lifecycle.
pub fn act_one_surface(parent: El, world: *World, e: Entity, id: []const u8, opts: Options) !Result {
    const s = try surface_mod.act_surface(parent, id, .{
        .labels = &view_labels,
        .market = opts.market,
        .market_available = opts.market_available,
        .activity = opts.activity,
        .initial_view = opts.initial_view,
    });

    // ACTIONS and GENERATORS scroll whole; BUILD keeps its heading, search and column header
    // put and scrolls only its table, so it takes the view directly.
    switch (s.active) {
        0 => {
            const scroll = try scroll_view_mod.scroll_view(s.view, "scroll", .{ .height = 0, .framed = false }, s.scroll);
            _ = try actions_section_mod.actions_section(scroll.content, world, e, "actions_section", actions_shelf, s.catalog, s.owner);
        },
        1 => _ = try build_section_mod.build_section(s.view, world, e, "buildsection", build_shelf, s.catalog, s.owner, s.scroll),
        2 => {
            const scroll = try scroll_view_mod.scroll_view(s.view, "scroll", .{ .height = 0, .framed = false }, s.scroll);
            _ = try generator_section_mod.generator_section(scroll.content, world, e, "generator_section");
        },
        else => unreachable,
    }
    return .{ .el = s.el, .active = s.active, .market_action = s.market_action.? };
}

test "Act I's BUILD widths fill the lane and hold every Act I build order unelided" {
    var cat = try ha.roster.load(std.testing.allocator, ha.roster.shipped, null);
    defer cat.deinit();
    try std.testing.expectEqual(@import("./capital_row.zig").lane_width, build_shelf.widths.laneTotal());
    try std.testing.expect(@import("./build_list.zig").costOverflow(&cat, build_shelf) == null);
}
