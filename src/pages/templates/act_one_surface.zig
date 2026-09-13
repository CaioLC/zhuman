//! `act_one_surface` — the complete reusable right-hand Act I work surface from the authored
//! references: ACTIONS/BUILD navigation, passerby and activity context strips, and exactly one
//! active section. The tab owns persistent selection; inactive BUILD controls retain their pooled
//! catalog/editor state without remaining in the tree or focus order.

const ha = @import("ha");
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const UiCtx = uic.UiCtx;
const El = el.El;

const view_nav_mod = @import("./view_nav.zig");
const market_strip_mod = @import("./market_strip.zig");
const actions_section_mod = @import("./actions_section.zig");
const build_section_mod = @import("./build_section.zig");

const nav_height: f32 = 29;
const nav_to_market: f32 = 12;
const market_to_activity: f32 = 6;
const activity_to_section: f32 = 14;

pub const Activity = struct {
    state: market_strip_mod.ActivityState,
    subject: []const u8,
    metadata: []const u8,
    last: market_strip_mod.ActivityState,
};

pub const Options = struct {
    market: market_strip_mod.MarketKind = .passerby,
    activity: Activity,
};

pub const Result = struct {
    el: El,
    active: usize,
    market_action: El,
};

fn spacer(ctx: *UiCtx, parent: El, id: []const u8, height: f32) !void {
    const gap = try el.div(ctx, parent, id);
    _ = gap.with_size(.{ .fixed = 1 }, .{ .fixed = height }).pass_through();
}

fn retainBuildCatalog(ctx: *UiCtx, surface: El) void {
    const section_key = ha.ui.key(surface.get().key, "buildsection");
    const build_key = ha.ui.key(section_key, "buildlist");
    const controls_key = ha.ui.key(build_key, "build_ctl");
    _ = ctx.retainState(controls_key, uic.UiState.CatalogState);

    const row_key = ha.ui.key(controls_key, "row");
    _ = ctx.retainState(ha.ui.key(row_key, "search"), uic.UiState.TextInputState);
}

/// Compose the tabbed Act I work surface. The returned market action is the strip's TRADE link;
/// callers own encounter eligibility and modal lifecycle, while this template owns placement.
pub fn act_one_surface(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8, opts: Options) !Result {
    // The workspace owns the constant total width. This surface takes the entire growing
    // content lane, so collapsing HOLDINGS transfers every released pixel to the strips and
    // active view instead of leaving a fixed-width island.
    const surface = try el.div(ctx, parent, id);
    _ = surface.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start });

    const nav = try el.div(ctx, surface, "nav");
    _ = nav.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = nav_height });
    const tabs = try view_nav_mod.view_nav(ctx, nav, "tabs", &.{ "ACTIONS", "BUILD" });
    _ = tabs.el.with_layout(.bottom_left);

    try spacer(ctx, surface, "nav_gap", nav_to_market);
    const market_action = try market_strip_mod.market_strip(ctx, surface, "market", opts.market);
    try spacer(ctx, surface, "market_gap", market_to_activity);
    _ = try market_strip_mod.activity_strip(
        ctx,
        surface,
        "activity",
        opts.activity.state,
        opts.activity.subject,
        opts.activity.metadata,
        opts.activity.last,
    );
    try spacer(ctx, surface, "activity_gap", activity_to_section);

    if (tabs.active == 0) {
        retainBuildCatalog(ctx, surface);
        _ = try actions_section_mod.actions_section(ctx, surface, world, e, "actions_section");
    } else {
        _ = try build_section_mod.build_section(ctx, surface, world, e, "buildsection");
    }

    return .{ .el = surface, .active = tabs.active, .market_action = market_action };
}
