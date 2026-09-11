//! `debug_page` — a **template audit harness**. One template at a time, rendered small and
//! anchored **top-left** so it can be eyeballed against the prototype HTML (`prototypes/act-i.html`)
//! with nothing else in the way. A thin **clickable index** is anchored on the **right** so it
//! never intrudes on the inspection area; clicking a name swaps which template is shown.
//!
//! Reached by setting the `HA_DEBUG_PAGE` environment variable to any truthy value before launch
//! (`build_ui` routes here when it is set) — it is a developer tool, not a game screen, so it is
//! off unless explicitly requested and never affects the shipped routes.
//!
//! Adding a template to audit: add a name to `entries` and a `case` arm in `render_one`. Each arm
//! builds exactly one template into the top-left `stage`, at a small size, with realistic sample
//! data (the template owns no domain math, so the samples are just plausible strings/values).

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const ecs = ha.ecs;
const actions = ha.actions;
const World = ha.world.World;
const Entity = ha.world.Entity;
const Node = uic.Node;
const UiCtx = uic.UiCtx;

const t = @import("./templates/root.zig");

/// The auditable templates, in a stable order. The index lists these; the selected one renders in
/// the stage. Keep the names short — they are the index labels and the `render_one` switch keys.
const entries = [_][]const u8{
    "button",
    "panel",
    "row",
    "stat",
    "figure",
    "actor_status",
    "stock_token",
    "stockline",
    "runline",
    "log_view",
    "tabs",
    "view_nav",
    "select",
    "slider",
    "disclosure",
    "rail",
    "action_tile",
    "ration_dial",
    "eating_policy",
    "capital_row",
    "catalog_controls",
    "milestone_goal",
    "market_strip",
    "activity_strip",
    "trade_dialog",
    "tag",
    "cost_list",
    "legend",
    "zoom_controls",
    "empty_state",
};

pub const DebugTrees = struct { root: *Node, overlay: ?*Node = null };

pub fn debug_page(ctx: *UiCtx, world: *World) !DebugTrees {
    const th = ctx.res.view.theme;

    const root = try el.root(ctx, "debug");
    _ = root.with_layout(.top_left).with_flow(.{ .dir = .row })
        .with_style(.{Style{ .fill = th.bg }});

    // Selection lives on a stable node's TabsState (`active` = the entry index).
    const sel = root.get().state(ctx, uic.UiState.TabsState);
    if (sel.active >= entries.len) sel.active = 0;

    // --- the inspection stage: top-left, small, the selected template only ------------------
    const stage_wrap = try el.div(ctx, root, "stage_wrap");
    _ = stage_wrap.with_size(.grow, .{ .pct_of_parent = 1.0 }).with_flow(.{ .dir = .column }).with_gap(8)
        .with_style(.{style.pad(16)});
    // A dim label so the audit always knows which template is on screen.
    _ = (try el.text(ctx, stage_wrap, "label", entries[sel.active]))
        .with_style(.{ style.eyebrow, Style{ .text = th.acc } });
    const stage = try el.div(ctx, stage_wrap, "stage");
    _ = stage.with_layout(.top_left).with_flow(.{ .dir = .column }).with_gap(6);

    var overlay: ?*Node = null;
    overlay = try render_one(ctx, world, stage, entries[sel.active]);

    // --- the clickable index: a thin column anchored on the RIGHT --------------------------
    const index = try el.div(ctx, root, "index");
    _ = index.with_size(.{ .fixed = 150 }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .column }).with_gap(2)
        .with_style(.{ Style{ .fill = th.panel }, style.pad_sym(10, 10) });
    _ = (try el.text(ctx, index, "ihdr", "TEMPLATES"))
        .with_style(.{ style.small, Style{ .text = th.dim } });
    for (entries, 0..) |name, i| {
        const key = try std.fmt.allocPrint(ctx.arena, "e{d}", .{i});
        const item = try el.div(ctx, index, key);
        ctx.registerFocus(item.get().key, true);
        const iq = item.query();
        if (iq.clicked) {
            _ = ctx.requestFocus(item.get().key);
            sel.active = i;
        }
        const focused = ctx.isFocused(item.get().key);
        if (iq.hovering) ctx.res.cursor.request(.pointer);
        uic.publishControlState(ctx, item.get().key, .{ .selected = i == sel.active, .focused = focused, .focus_visible = focused });
        const on = i == sel.active;
        const c = if (on) th.acc else if (iq.hovering or focused) th.fg else th.dim;
        _ = (try el.text(ctx, item, "t", name)).with_style(.{ style.small, Style{ .text = c } });
    }

    return .{ .root = root.get(), .overlay = overlay };
}

/// Build exactly one template into `stage` with sample data. Returns an optional overlay root
/// (only the trade dialog uses it). Everything else returns null.
fn render_one(ctx: *UiCtx, world: *World, stage: El, name: []const u8) !?*Node {
    const th = ctx.res.view.theme;
    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };

    if (eq(name, "button")) {
        _ = try t.button(ctx, stage, "b_on", "Enabled", true);
        _ = try t.button(ctx, stage, "b_off", "Disabled", false);
    } else if (eq(name, "panel")) {
        const p = try t.panel(ctx, stage, "p", "Panel Title");
        _ = try el.text(ctx, p, "body", "panel body content");
    } else if (eq(name, "row")) {
        const r = try t.row(ctx, stage, "r");
        _ = try el.text(ctx, r, "a", "one");
        _ = try el.text(ctx, r, "b", "two");
        _ = try el.text(ctx, r, "c", "three");
    } else if (eq(name, "stat")) {
        _ = try t.stat(ctx, stage, "s1", "Materials", "24");
        _ = try t.stat(ctx, stage, "s2", "Food", "4");
    } else if (eq(name, "figure")) {
        try t.figure(ctx, stage, t.fig_robust, th.acc);
        try t.figure(ctx, stage, t.fig_weary, th.warn);
    } else if (eq(name, "actor_status")) {
        if (player.get()) |a| {
            const s = t.actor_status(th, a[1], ctx.res.config);
            _ = (try el.text(ctx, stage, "st", s.word)).with_style(.{Style{ .text = s.color }});
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "stock_token")) {
        try t.stock_token(ctx, stage, "tok", .{ .abbrev = "Vi", .full = "Vigor", .value = "3/10", .danger = false });
    } else if (eq(name, "stockline")) {
        const stocks = [_]t.Stock{
            .{ .abbrev = "Vi", .full = "Vigor", .value = "10/10" },
            .{ .abbrev = "Fo", .full = "Food", .value = "4", .danger = true },
            .{ .abbrev = "Ma", .full = "Materials", .value = "24" },
        };
        _ = try t.stockline(ctx, stage, "sl", &stocks);
    } else if (eq(name, "runline")) {
        _ = try t.runline(ctx, stage, "run", .{ .act_label = "Act I", .day = 3 });
    } else if (eq(name, "log_view")) {
        try t.log_view(ctx, stage, "feed", &ctx.res.sim.log, 400, 4);
    } else if (eq(name, "tabs")) {
        _ = try t.tabs(ctx, stage, "tabs", &.{ "ACTIONS", "BUILD" });
    } else if (eq(name, "view_nav")) {
        _ = try t.view_nav(ctx, stage, "vn", &.{ "ACTIONS", "BUILD" });
    } else if (eq(name, "select")) {
        _ = try t.select(ctx, stage, "sel", "Sort", &.{ "reach", "inputs", "time", "name" }, true);
    } else if (eq(name, "slider")) {
        _ = try t.slider(ctx, stage, "sld", "Rate", 1.0, 0.5, 2.0, 0.1, true);
    } else if (eq(name, "disclosure")) {
        const d = try t.disclosure(ctx, stage, "disc", "Disclosure summary", true);
        if (d.details) |det| _ = try el.text(ctx, det, "dt", "hidden detail, now shown");
    } else if (eq(name, "rail")) {
        const r = try t.rail(ctx, stage, .{ .id = "rail", .label = "HOLDINGS" });
        if (r.body) |rb| _ = try el.text(ctx, rb, "rb", "rail body");
    } else if (eq(name, "action_tile")) {
        if (player.get()) |a| {
            _ = try t.action_tile(ctx, stage, world, a[0], comp.ActionForage, "at", "Forage", actions.action_forage);
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "ration_dial")) {
        if (player.get()) |a| {
            _ = try t.ration_dial(ctx, stage, world, a[0], "rd");
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "eating_policy")) {
        _ = try t.eating_policy(ctx, stage, "ep", 1.0, ha.eating.Config.act_one, true);
    } else if (eq(name, "capital_row")) {
        if (player.get()) |a| {
            _ = try t.capital_row(ctx, stage, world, a[0], comp.Sandals, "cr", .ready, 1.0);
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "catalog_controls")) {
        _ = try t.catalog_controls(ctx, stage, "cc", &.{ "reach", "inputs", "time", "name" });
    } else if (eq(name, "milestone_goal")) {
        _ = try t.milestone_goal(ctx, stage, "mg", .{
            .state = .ready,
            .title = "Shelter",
            .summary = "a roof with room for four",
            .kicker = "THE END OF ACT I",
            .cost = "60m 6e \u{00B7} 6.0d",
            .copy = "A shelter is how Act I ends.",
            .requirement = "vigor 15/15 \u{00B7} food 12/12",
            .action = "Raise the shelter",
        });
    } else if (eq(name, "market_strip")) {
        _ = try t.market_strip(ctx, stage, "ms", .passerby);
    } else if (eq(name, "activity_strip")) {
        _ = try t.activity_strip(ctx, stage, "as", .working, "foraging", "", .working);
    } else if (eq(name, "trade_dialog")) {
        const buys = [_]t.TradeOffer{
            .{ .give = "2m", .receive = "1 food" },
            .{ .give = "2 food, 8m", .receive = "a fishing net" },
        };
        const sells = [_]t.TradeOffer{
            .{ .give = "1 food", .receive = "2m", .effect = "next unit: 1.9m" },
        };
        var st = uic.UiState.TradeState{ .open = true };
        var overlay_root: *Node = undefined;
        _ = try t.trade_dialog(ctx, "trade", .passerby, &buys, &sells, "4 food \u{00B7} 24m", &st, &overlay_root);
        return overlay_root;
    } else if (eq(name, "tag")) {
        _ = try t.tag(ctx, stage, "tg", "crude");
    } else if (eq(name, "cost_list")) {
        const costs = [_]t.Cost{ .{ .label = "Biomass", .amount = "80" }, .{ .label = "Minerals", .amount = "40" } };
        _ = try t.cost_list(ctx, stage, "cl", &costs);
    } else if (eq(name, "legend")) {
        const items = [_]t.LegendItem{
            .{ .resource = .food, .label = "Food" },
            .{ .resource = .metal, .label = "Metal" },
            .{ .resource = .biomass, .label = "Biomass" },
        };
        _ = try t.legend(ctx, stage, "lg", &items);
    } else if (eq(name, "zoom_controls")) {
        _ = try t.zoom_controls(ctx, stage, "zc");
    } else if (eq(name, "empty_state")) {
        _ = try t.empty_state(ctx, stage, "es", "Nothing here yet.", "Try widening the filter.");
    } else {
        _ = try el.text(ctx, stage, "unknown", "(unknown template)");
    }
    return null;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
