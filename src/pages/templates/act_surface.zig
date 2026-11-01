//! `act_surface` — the right-hand work surface every act shares: the view tabs heading it, the
//! market and activity strips under them, and the active view filling what remains. Only the
//! content differs per act (`Options`: the tab labels, which views are focus views, the market
//! venue, the activity); the caller builds the active view into the returned `view`.
//!
//! **Per-view state.** Each view gets an always-built zero-size owner holding its
//! `CatalogState`, search editor (`TextInputState`) and `ScrollState`, so switching away prunes
//! nothing and a view restores exactly where the player left it. The selected tab persists on
//! the surface. Pool pointers are valid only until the next same-type acquire, so every slot is
//! touched first and the active view's pointers are re-derived after the tabs are built.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const actions = ha.actions;
const uic = ha.ui_client;
const el = uic.elements;
const UiCtx = uic.UiCtx;
const El = el.El;
const CatalogState = uic.UiState.CatalogState;
const ScrollState = uic.UiState.ScrollState;

const tabs_mod = @import("./tabs.zig");
const market_strip_mod = @import("./market_strip.zig");
const terminal_mod = @import("./terminal.zig");

const nav_height: f32 = 29;
const market_to_activity: f32 = 6;
const activity_to_section: f32 = 14;
/// The most views a surface carries.
pub const max_views = 5;

/// What the activity strip shows: the actor's work state, its subject, and time left.
pub const Activity = struct {
    state: market_strip_mod.ActivityState,
    subject: []const u8,
    metadata: []const u8,
    last: market_strip_mod.ActivityState,
};

/// Project an actor's work in progress into the activity strip — the one reading every act
/// uses. A build reports days left, any other work hours left; no work reads `ready`.
pub fn activity(ctx: *UiCtx, busy: ?*const comp.Busy) !Activity {
    const b = busy orelse return .{ .state = .idle, .subject = "no work in progress", .metadata = "ready", .last = .idle };
    const build = actions.is_build(b.doing);
    const spd = ctx.res.game.config.secs_per_day;
    const state: market_strip_mod.ActivityState = if (build) .building else .working;
    return .{
        .state = state,
        .subject = actions.doing_label(&ctx.res.game.catalog, b.doing),
        .metadata = if (build)
            try ctx.arena.print("{d:.1}d left", .{b.remaining / spd})
        else
            try ctx.arena.print("{d:.0}h left", .{b.remaining * 24.0 / spd}),
        .last = state,
    };
}

pub const Options = struct {
    /// The view tabs, in order. At most `max_views`.
    labels: []const []const u8,
    /// The tab strip's accessible name (`nav.surface-nav[aria-label]`).
    nav_name: []const u8 = "Surfaces",
    /// The focus views (Act II's RESEARCH and MARKET): each owns the whole surface, so the
    /// strips are suppressed there, and the page drops its log (`Result.focus`).
    focus_views: []const usize = &.{},
    market: market_strip_mod.MarketKind,
    market_available: bool = true,
    activity: Activity,
    /// Gap under the tabs, logical px (Act II's surface nav sits 8px above the strips).
    nav_gap: f32 = 12,
    /// Open on this view this frame instead of the remembered one (a fixture's first frame).
    initial_view: ?usize = null,
    /// Seed the active view's search text and sort this frame (a fixture's first frame).
    initial_query: ?[]const u8 = null,
    initial_sort: ?CatalogState = null,
};

pub const Result = struct {
    el: El,
    active: usize,
    /// Whether the active view is a focus view: no strips here, and no log on the page.
    focus: bool,
    /// The market strip's trailing action, or null on a focus view. The caller owns what a
    /// click opens.
    market_action: ?El,
    /// The area the active view fills: the surface's remaining height, definite.
    view: El,
    /// The active view's always-built state owner (its search editor lives here), and its
    /// catalog and scroll state. Valid until the next acquire of the same state type.
    owner: El,
    catalog: *CatalogState,
    scroll: *ScrollState,
};

/// Compose the surface into `parent`, filling it. The caller builds the active view into
/// `Result.view`.
pub fn act_surface(parent: El, id: []const u8, opts: Options) !Result {
    std.debug.assert(opts.labels.len > 0 and opts.labels.len <= max_views);
    const surface = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = terminal_mod.fill_h(parent.ctx),
        .flow = .{ .dir = .column, .cross = .start }, .overflow = .clip,
    }, .{});

    // Per-view owners, every slot touched each frame so none is pruned while hidden.
    const owners_root = try surface.box("view_state", .{ .w = .{ .fixed = 0 }, .h = .{ .fixed = 0 } }, .{});
    var owners: [max_views]El = undefined;
    for (opts.labels, 0..) |_, i| {
        owners[i] = try owners_root.item("view", i);
        _ = owners[i].state(CatalogState);
        _ = owners[i].state(uic.UiState.TextInputState);
        _ = owners[i].state(ScrollState);
    }

    // The selection is copied out and written back: `tabs` acquires its own TabsState.
    var selected = surface.state(uic.UiState.TabsState).active;
    if (opts.initial_view) |v| selected = v;
    if (selected >= opts.labels.len) selected = 0;

    const nav = try surface.box("nav", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = nav_height }, .margin = .{ .after = opts.nav_gap },
    }, .{});
    const tabs = try tabs_mod.tabs_named(nav, "tabs", opts.nav_name, opts.labels, &selected);
    tabs.el.set(.{ .anchor = .bottom_left }, .{});
    surface.state(uic.UiState.TabsState).active = tabs.active; // existing slot: no growth

    const focus = std.mem.findScalar(usize, opts.focus_views, tabs.active) != null;
    var market_action: ?El = null;
    if (!focus) {
        market_action = try market_strip_mod.market_strip(surface, "market", opts.market, opts.market_available);
        try surface.leaf("market_gap", .{ .w = .{ .fixed = 1 }, .h = .{ .fixed = market_to_activity } }, .{});
        const a = opts.activity;
        _ = try market_strip_mod.activity_strip(surface, "activity", a.state, a.subject, a.metadata, a.last);
    }

    const view = try surface.box("view", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = terminal_mod.grow_h(parent.ctx),
        .margin = .{ .before = if (focus) 0 else activity_to_section },
    }, .{});
    const owner = owners[tabs.active];
    if (opts.initial_query) |q| {
        const ed = owner.state(uic.UiState.TextInputState);
        _ = ed.clear();
        _ = ed.insert(q);
    }
    if (opts.initial_sort) |cs| owner.state(CatalogState).* = cs;
    return .{
        .el = surface,
        .active = tabs.active,
        .focus = focus,
        .market_action = market_action,
        .view = view,
        .owner = owner,
        // Already acquired above, so these re-derivations cannot grow (move) a pool.
        .catalog = owner.state(CatalogState),
        .scroll = owner.state(ScrollState),
    };
}
