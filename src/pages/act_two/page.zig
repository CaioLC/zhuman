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
//! the player left them (the `view_nav` persistence contract). The Coin Merchant dialog is the
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
const fmt = @import("../fmt.zig");
const fx = @import("./fixtures.zig");
const action_browser = @import("./action_browser.zig").action_browser;
const recipe_browser = @import("./recipe_browser.zig").recipe_browser;
const a2_holdings = @import("./holdings.zig").holdings;
const coin_merchant = @import("./coin_merchant.zig").coin_merchant;

const nav_height: f32 = 29;
/// `.act-two .surface-nav` margin: the tabs sit 8px above whatever follows them.
const nav_gap: f32 = 8;
const market_to_activity: f32 = 6;
const activity_to_section: f32 = 14;

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
    const compact = ctx.res.view.metrics.width_class.atMost(.w560);
    const page_pad: f32 = if (compact) ha.tokens.pad_page_compact else ha.tokens.pad_page;

    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    const agent: ?Entity = if (player.get()) |a| a[0] else null;

    // The shared shell with Act II regions: rail (Holdings/BODY) and the framed footer (event
    // log). The view tabs and the Market/Activity strips are the surface's own rows, as in Act I:
    // the tabs head the surface they switch, and STRUCTURE can suppress the strips.
    const regions = try t.shell(ctx, .{
        .id = "act2",
        .act = .act_two,
        .page_pad = page_pad,
        .section_gap = ha.tokens.gap.section,
        .rail = true,
        .footer = true,
    });

    // --- header: PO..CO, then the runline (energy rate, Act II, day) -------------------------
    // Vigor and the six stocks are the player's; population and coin have no model yet.
    var vbuf: [16]u8 = undefined;
    var sbufs: [ledger_stocks.len][16]u8 = undefined;
    var stocks: [2 + 1 + ledger_stocks.len]t.Stock = undefined;
    var n: usize = 0;
    stocks[n] = .{ .abbrev = "PO", .full = "Population", .value = fx.population };
    n += 1;
    if (agent) |e| {
        const vigor = world.get(e, comp.Vigor).?;
        stocks[n] = .{
            .abbrev = "VI",
            .full = "Vigor",
            .value = std.fmt.bufPrint(&vbuf, "{d:.0}/{d:.0}", .{ vigor.v, vigor.max }) catch "?",
            .tone = switch (ctx.res.config.condition(vigor.v / vigor.max)) {
                .alive => .normal,
                .weary => .warn,
                .spent => .danger,
            },
        };
        n += 1;
        for (ledger_stocks, 0..) |s, i| {
            const amount = ledger.balance(world, e, s.r);
            stocks[n] = .{
                .abbrev = s.abbrev,
                .full = s.full,
                .value = fmt.fmt_num(&sbufs[i], amount),
                .tone = if (amount <= 0) .danger else .normal,
            };
            n += 1;
        }
    }
    stocks[n] = .{ .abbrev = "CO", .full = "Coin", .value = fx.coin };
    n += 1;
    const day = 1 + @as(u64, @intFromFloat(ctx.res.sim.elapsed / ctx.res.config.secs_per_day));
    _ = try t.header(regions.header, "hud", .{
        .stocks = stocks[0..n],
        .compact_stocks = true,
        .run = .{
            .gen = fx.energy_gen,
            .consumed = fx.energy_consumed,
            .act_label = "Act II",
            .day = day,
            .compact = compact,
        },
    });

    // --- the rail: Act II Holdings/BODY ------------------------------------------------------
    if (regions.rail) |rail| {
        if (agent) |e| _ = try a2_holdings(rail, world, e, "a2_holdings");
    }

    // Persistent per-view catalog/search state on always-built owner nodes under the body, so
    // each view restores its query/sort/selection after a view switch (view_nav contract).
    const state_owner = try regions.body.div("a2_state");
    _ = state_owner.with_size(.{ .fixed = 0 }, .{ .fixed = 0 });
    const actions_owner = try state_owner.div("actions_owner");
    const build_owner = try state_owner.div("build_owner");
    const actions_catalog = actions_owner.state(uic.UiState.CatalogState);
    _ = actions_owner.state(uic.UiState.TextInputState);
    const build_catalog = build_owner.state(uic.UiState.CatalogState);
    _ = build_owner.state(uic.UiState.TextInputState);
    // The merchant dialog's open/mode/selection persists here too, surviving view switches.
    const trade_ts = state_owner.state(uic.UiState.TradeState);
    // So do each catalog's scroll offset and the active view itself.
    const actions_scroll = actions_owner.state(uic.UiState.ScrollState);
    const build_scroll = build_owner.state(uic.UiState.ScrollState);
    const view_state = state_owner.state(uic.UiState.TabsState);
    if (opts.initial_view) |v| view_state.active = v;

    // --- the body: tabs, strips (outside STRUCTURE), and the active view --------------------
    // The column fills the body. The view takes what the rows above it leave and scrolls inside
    // that, so a long catalog never runs under the footer (`.act-two .surface`).
    const column = try regions.body.div("a2_surface");
    _ = column.with_size(.{ .pct_of_parent = 1.0 }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_overflow(.clip);

    const nav = try column.div("nav");
    _ = nav.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = nav_height });
    const vn = try t.view_nav(nav, "a2_tabs", &.{ "ACTIONS", "BUILD", "STRUCTURE" }, &view_state.active);
    _ = vn.el.with_layout(.bottom_left);
    const active = vn.active;
    _ = try column.spacer("nav_gap", 1, nav_gap);

    const on_structure = active == 2;
    if (!on_structure) {
        const market_action = try t.market_strip(column, "a2_market", .merchant, true);
        if (market_action.query().clicked) trade_ts.open = true;
        _ = try column.spacer("market_gap", 1, market_to_activity);

        // The activity strip projects the player's work in progress, as Act I's does.
        const busy = if (agent) |e| world.get(e, comp.Busy) else null;
        const state: t.ActivityState = if (busy) |b|
            (if (actions.is_build(b.doing)) .building else .working)
        else
            .idle;
        var meta_buf: [24]u8 = undefined;
        const subject: []const u8 = if (busy) |b| actions.doing_label(&ctx.res.catalog, b.doing) else "no work in progress";
        const meta: []const u8 = if (busy) |b| blk: {
            if (actions.is_build(b.doing)) {
                break :blk std.fmt.bufPrint(&meta_buf, "{d:.1}d left", .{b.remaining / ctx.res.config.secs_per_day}) catch "?";
            }
            break :blk std.fmt.bufPrint(&meta_buf, "{d:.0}h left", .{b.remaining * 24.0 / ctx.res.config.secs_per_day}) catch "?";
        } else "ready";
        _ = try t.activity_strip(column, "a2_activity", state, subject, meta, state);
        _ = try column.spacer("activity_gap", 1, activity_to_section);
    }

    const view = try column.div("a2_view");
    _ = view.with_size(.{ .pct_of_parent = 1.0 }, .grow);
    const scroll_state: ?*uic.UiState.ScrollState = switch (active) {
        0 => actions_scroll,
        1 => build_scroll,
        else => null,
    };
    const scroll = try t.scroll_view(view, "scroll", .{ .height = 0, .framed = false }, scroll_state);
    const surface = scroll.content;

    if (agent) |e| switch (active) {
        0 => {
            if (try action_browser(surface, world, e, "a2_actions", actions_catalog, actions_owner)) |ai|
                actions.begin(world, e, ctx.res, ai);
        },
        1 => {
            if (try recipe_browser(surface, world, e, "a2_build", build_catalog, build_owner)) |gi|
                capital.begin(world, e, ctx.res, gi);
        },
        else => {
            // STRUCTURE: the strips are suppressed here; the research board is not drawn yet.
            _ = try t.empty_state(surface, "a2_structure", "STRUCTURE board", "The research board is not drawn yet.");
        },
    } else {
        _ = try t.empty_state(surface, "a2_nobody", "No settlement", "There is no one here to act.");
    }

    // --- footer: the event log --------------------------------------------------------------
    if (regions.footer) |footer| {
        const content_w_logical = ctx.res.view.metrics.terminal.w - 2 * page_pad;
        try t.log_view(footer, "feed", &ctx.res.sim.log, content_w_logical, 4);
    }

    // --- the Coin Merchant overlay (its own top-layer root) ---------------------------------
    const merchant = try coin_merchant(ctx, "a2_trade", trade_ts);
    if (merchant.confirmed) |i| {
        const lots = if (merchant.mode == 0) &fx.merchant_buys else &fx.merchant_sells;
        if (i < lots.len) {
            var buf: [64]u8 = undefined;
            const verb = if (merchant.mode == 0) "buy" else "sell";
            const msg = std.fmt.bufPrint(&buf, "You {s} {s} from the merchant.", .{ verb, lots[i].name }) catch "You trade.";
            ctx.res.sim.log.push(.good, msg);
        }
    }

    var roots: std.ArrayList(*Node) = .empty;
    try roots.append(ctx.arena, regions.root.get());
    if (merchant.root) |dialog| try roots.append(ctx.arena, dialog);
    return roots.items;
}

test {
    _ = @import("./fixtures.zig");
    _ = @import("./action_browser.zig");
    _ = @import("./recipe_browser.zig");
    _ = @import("./coin_merchant.zig");
    _ = @import("./holdings.zig");
}
