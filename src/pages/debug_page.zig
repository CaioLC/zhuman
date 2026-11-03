//! `debug_page` — a **template audit harness**. One template at a time, rendered small and
//! anchored **top-left** so it can be eyeballed against the prototype HTML (`prototypes/act-i.html`)
//! with nothing else in the way. A thin **clickable index** is anchored on the **right** so it
//! never intrudes on the inspection area; clicking a name swaps which template is shown.
//!
//! Reached by setting the `HA_DEBUG_PAGE` environment variable to any truthy value before launch
//! (`build_ui` routes here when it is set); a value naming an entry (`HA_DEBUG_PAGE=tabs`) opens on it,
//! which `tools/capture_templates.ps1` uses — it is a developer tool, not a game screen, so it is
//! off unless explicitly requested and never affects the shipped routes.
//!
//! Adding a template to audit: add a name to `entries` and a `case` arm in `render_one`. Each arm
//! builds exactly one template into the top-left `stage`, at a small size, with realistic sample
//! data (the template owns no domain math, so the samples are just plausible strings/values).

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const tag = ha.sim.tag;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const ecs = ha.sim.ecs;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;
const Node = uic.Node;
const UiCtx = uic.UiCtx;

const t = @import("./templates/root.zig");
const act_one_holdings = @import("./act_one/holdings.zig");
const act_two_holdings = @import("./act_two/holdings.zig");
const coin_merchant = @import("./act_two/coin_merchant.zig").coin_merchant;

/// The auditable templates, in a stable order. The index lists these; the selected one renders in
/// the stage. Keep the names short — they are the index labels and the `render_one` switch keys.
const entries = [_][]const u8{
    "button",
    "panel",
    "figure",
    "stock_token",
    "stockline",
    "runline",
    "header",
    "log_view",
    "tabs",
    "slider",
    "rail",
    "holdings",
    "action_tile",
    "generator_tile",
    "actions_section",
    "build_section",
    "act_one_surface",
    "act_two_holdings",
    "act_two_actions",
    "act_one_workspace",
    "act_one_page",
    "eating_policy",
    "capital_row",
    "catalog_controls",
    "milestone_goal",
    "market_strip",
    "activity_strip",
    "trade_dialog",
    "coin_merchant",
    "menu_dialog",
    "curtain",
    "speed_stepper",
    "scroll_view",
    "sort_header",
    "tooltip",
    "empty_state",
    "readout",
    "table",
    "browser_heading",
    "tile_lanes",
    "copy",
};

/// The entry `HA_DEBUG_PAGE` names, if its value is one of `entries` (any other truthy value
/// just opens the page on its first entry).
fn requestedEntry(res: *const ha.res.Resources) ?usize {
    const raw = res.env("HA_DEBUG_PAGE") orelse return null;
    for (entries, 0..) |name, i| if (eq(name, raw)) return i;
    return null;
}

/// Build the audit page. Returns its roots in draw order: the page, then the trade dialog's
/// root while that entry is open.
pub fn debug_page(ctx: *UiCtx, world: *const World) !uic.Trees {
    const th = ctx.res.view.theme;

    const root = try el.root(ctx, "debug");
    root.set(.{ .anchor = .top_left, .flow = .{ .dir = .row } }, .{Style{ .fill_ink = .bg }});

    // Selection lives on a stable node's TabsState (`active` = the entry index); the modal's
    // open/closed lifecycle on a TradeState, so dismissing it reveals the audit index instead of
    // rebuilding an always-open local state next frame. A pool pointer is valid only until a
    // same-type acquire, and the template under audit may acquire either type (a tabs strip's
    // TabsState), so neither pointer is held across `render_one`: read before, re-acquired after.
    const active = blk: {
        const sel = root.state(uic.UiState.TabsState);
        if (ctx.frame == 1) {
            // `HA_DEBUG_PAGE=<entry>` opens on that entry (the capture script's way in).
            if (requestedEntry(ctx.res)) |i| {
                sel.active = i;
                const name = entries[i];
                root.state(uic.UiState.TradeState).open = eq(name, "trade_dialog") or eq(name, "coin_merchant");
                if (eq(name, "menu_dialog")) ctx.res.menu.show(&ctx.res.playback);
            }
        }
        const s = root.state(uic.UiState.TabsState); // re-derive: the TradeState acquire is another pool
        if (s.active >= entries.len) s.active = 0;
        break :blk s.active;
    };

    // --- the inspection stage: top-left, small, the selected template only ------------------
    // The whole page root is already `top_left`, so the padded wrap sits at the top-left; the
    // stage flows normally inside it (no extra absolute anchor, which would overlap siblings).
    // The selected template's name is shown highlighted in the right index, so no label here.
    const stage_wrap = try root.box("stage_wrap", .{
        .w = .grow, .h = .{ .pct_of_parent = 1.0 }, .flow = .{ .dir = .column }, .gap = 8,
    }, .{style.pad(16)});
    const stage = try stage_wrap.box("stage", .{ .flow = .{ .dir = .column }, .gap = 6 }, .{});

    const overlay = try render_one(stage, world, entries[active], root.state(uic.UiState.TradeState));
    const sel = root.state(uic.UiState.TabsState);
    const audit_trade = root.state(uic.UiState.TradeState);

    // --- the clickable index: a thin column anchored on the RIGHT --------------------------
    const index = try root.box("index", .{
        .w = .{ .fixed = 150 }, .h = .{ .pct_of_parent = 1.0 }, .flow = .{ .dir = .column }, .gap = 2,
    }, .{ Style{ .fill_ink = .panel }, style.pad_sym(10, 10) });
    try index.label("ihdr", "TEMPLATES", .{ style.small, style.muted });
    for (entries, 0..) |name, i| {
        const item = try index.item("e", i);
        // Selection changes on the click before the lifecycle publishes it, so the published
        // `selected` is current on the click frame.
        if (item.query().clicked) {
            sel.active = i;
            audit_trade.open = eq(name, "trade_dialog") or eq(name, "coin_merchant");
            // The session menu is a host overlay (`withMenu`); opening it is the audit.
            if (eq(name, "menu_dialog")) ctx.res.menu.show(&ctx.res.playback);
        }
        const on = i == sel.active;
        const iq = item.control(.{ .name = name, .role = .button, .selected = on });
        const c = if (on) th.acc else if (iq.hover_focus()) th.fg else th.dim;
        try item.label("t", name, .{ style.small, Style{ .text = c } });
    }

    var roots: std.ArrayList(*Node) = .empty;
    try roots.append(ctx.arena, root.get());
    if (overlay) |dialog| try roots.append(ctx.arena, dialog);
    return roots.items;
}

/// Build exactly one template into `stage` with sample data. Returns an optional overlay root
/// (only the trade dialog uses it). Everything else returns null.
fn render_one(stage: El, world: *const World, name: []const u8, audit_trade: *uic.UiState.TradeState) !?*Node {
    const ctx = stage.ctx;
    const th = ctx.res.view.theme;
    const act: u8 = 1;
    const player = ecs.ConstMaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };

    if (eq(name, "button")) {
        _ = try t.button(stage, "b_on", "Enabled", true);
        _ = try t.button(stage, "b_off", "Disabled", false);
    } else if (eq(name, "panel")) {
        const p = try t.panel(stage, "p", "Panel Title");
        try p.label("body", "panel body content", .{});
    } else if (eq(name, "figure")) {
        try t.figure(stage, "dead", t.fig_dead, th.danger);
    } else if (eq(name, "stock_token")) {
        try t.stock_token(stage, "tok", .{ .abbrev = ha.sim.data.roster.Resource.food.abbrevIn(act), .full = ha.sim.data.roster.Resource.food.labelIn(act), .value = 3.6, .tone = .warn });
    } else if (eq(name, "stockline")) {
        const stocks = [_]t.Stock{
            .{ .abbrev = "VI", .full = "Vigor", .value = 10, .max = 10 },
            .{ .abbrev = ha.sim.data.roster.Resource.food.abbrevIn(act), .full = ha.sim.data.roster.Resource.food.labelIn(act), .value = 3.6, .tone = .danger },
            .{ .abbrev = ha.sim.data.roster.Resource.biomass.abbrevIn(act), .full = ha.sim.data.roster.Resource.biomass.labelIn(act), .value = 24 },
        };
        _ = try t.stockline(stage, "sl", &stocks, false);
    } else if (eq(name, "runline")) {
        // Act I (no energy flow) above Act II (the `⚡ +gen/−consumed` rate).
        const col = try stage.box("runs", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 10 }, .{});
        _ = try t.runline(col, "run", .{ .act_label = "Act I", .day = 3 });
        _ = try t.runline(col, "run2", .{ .gen = 12, .consumed = 9, .act_label = "Act II", .day = 43 });
    } else if (eq(name, "header")) {
        const demo = try stage.box("header_demo", .{ .w = .{ .fixed = 620 }, .h = .fit_children }, .{});
        const stocks = [_]t.Stock{
            .{ .abbrev = "VI", .full = "Vigor", .value = 10, .max = 10 },
            .{ .abbrev = ha.sim.data.roster.Resource.food.abbrevIn(act), .full = ha.sim.data.roster.Resource.food.labelIn(act), .value = 3.6, .tone = .danger },
            .{ .abbrev = ha.sim.data.roster.Resource.biomass.abbrevIn(act), .full = ha.sim.data.roster.Resource.biomass.labelIn(act), .value = 24 },
        };
        _ = try t.header(demo, "hud", .{
            .stocks = &stocks,
            .run = .{ .act_label = "Act I", .day = 3 },
        });
    } else if (eq(name, "log_view")) {
        try t.log_view(stage, "feed", &ctx.res.game.sim.log, 400, 4);
    } else if (eq(name, "tabs")) {
        _ = try t.tabs(stage, "tabs", &.{ "ACTIONS", "BUILD" }, null);
    } else if (eq(name, "slider")) {
        const demo = try stage.box("slider_demo", .{ .w = .{ .fixed = 300 }, .h = .fit_children }, .{});
        _ = try t.slider(demo, .{
            .id = "sld",
            .label = "Eating policy",
            .value = 50,
            .min = 0,
            .max = 100,
            .step = 1,
        });
    } else if (eq(name, "rail")) {
        // Production supplies a definite page-grid rail region. Mirror it here so one
        // interactive instance can be inspected in both states via its own toggle.
        const demo = try stage.box("rail_demo", .{ .w = .{ .fixed = ha.tokens.rail.expanded }, .h = .{ .fixed = 300 } }, .{});
        const r = try t.rail(demo, .{ .id = "rail", .label = "HOUSEHOLD" });
        if (r.body) |rb| _ = try rb.text("rb", "rail body");
    } else if (eq(name, "holdings")) {
        if (player.get()) |a| {
            // A coherent debug-only four-kind/six-unit fixture matching the reference anatomy.
            // Values remain ordinary live ECS data; the component performs all projections.
            fixtureGoods(ctx, a[0], &.{ .{ "sandals", 2 }, .{ "root_cellar", 1 }, .{ "leaf_bed", 1 }, .{ "hatchet", 2 } });
            poke(ctx, a[0], .{ .food = 7.8 });
            poke(ctx, a[0], .{ .vigor = .{ .v = 14.4, .max = 15 } });
            poke(ctx, a[0], .{ .rate = 0.5 });

            const demo = try stage.box("holdings_demo", .{ .w = .{ .fixed = ha.tokens.rail.expanded }, .h = .{ .fixed = 400 } }, .{});
            const r = try t.rail(demo, .{ .id = "holdings_rail", .label = "HOUSEHOLD" });
            if (r.body) |body| _ = try t.holdings(body, "content", try act_one_holdings.content(ctx, world, a[0]));
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "action_tile")) {
        if (player.get()) |a| {
            const forage = ctx.res.game.catalog.actionIndex("forage").?;
            // Both densities, sized as their sections size them: Act I's regular grid tile
            // above Act II's compact catalog tile.
            const col = try stage.box("densities", .{
                .w = .{ .fixed = 300 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
                .gap = 10,
            }, .{});
            inline for (.{ .{ "at", t.ActionDensity.regular }, .{ "atc", t.ActionDensity.compact } }) |d| {
                if (try t.action_tile(col, world, a[0], forage, d[0], d[1], .none)) |tl| {
                    tl.el.set(.{
                        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = t.actionTileHeight(d[1]) },
                        .flow = .{ .dir = .column, .main = .center },
                    }, .{});
                    if (tl.clicked) _ = ctx.res.game.events.writer(ha.sim.events.BeginLabor).push(.{ .agent = a[0], .ai = forage });
                }
            }
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "generator_tile")) {
        if (player.get()) |a| {
            // Both densities of one owned generator, sized as the ACTIONS pane sizes them: Act
            // I's regular tile above Act II's compact one. The corner cycles the mode live and a
            // ready tile collects, as in the pane.
            fixtureGoods(ctx, a[0], &.{.{ "wire_snares", 1 }});
            const gi: u16 = @intCast(ctx.res.game.catalog.goodIndex("wire_snares").?);
            const col = try stage.box("densities", .{
                .w = .{ .fixed = 300 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
                .gap = 10,
            }, .{});
            // The tile is keyed by the good's id, so each density gets a lane of its own.
            inline for (.{ .{ "gt", t.ActionDensity.regular }, .{ "gtc", t.ActionDensity.compact } }) |d| {
                const lane = try col.box(d[0], .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children }, .{});
                _ = try t.generatorTile(lane, world, a[0], act, gi, d[1], .none);
            }
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "actions_section")) {
        if (player.get()) |a| {
            // The complete Act I pane: the four verbs (the hatchet and the rod grant the two
            // beyond the innate pair), then the two generators, the snares and the garden bed on
            // auto; the kind toggles count both, and the toolbar holds the summary and the sort
            // chips.
            fixtureGoods(ctx, a[0], &.{ .{ "hatchet", 1 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 }, .{ "garden_bed", 1 } });
            fixtureMode(ctx, a[0], "garden_bed", .auto);
            const demo = try stage.box("actions_demo", .{ .w = .{ .fixed = 620 }, .h = .fit_children }, .{});
            _ = try t.actions_section(demo, world, a[0], "actions", @import("./templates/act_one_surface.zig").actions_shelf, null, null, null);
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "build_section")) {
        if (player.get()) |a| {
            // Give the debug-only catalog a representative stock level so ready and reach rows
            // appear together, matching the reference anatomy without changing production.
            poke(ctx, a[0], .{ .biomass = 31 });
            // The pane fills a definite height and scrolls only its table, and spans a
            // definite width: the framed content lane.
            const demo = try stage.box("build_demo", .{ .w = .{ .fixed = t.build_lane_width }, .h = .{ .fixed = 560 } }, .{});
            _ = try t.build_section(demo, world, a[0], "build", @import("./templates/act_one_surface.zig").build_shelf, null, null, null);
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "act_one_surface")) {
        if (player.get()) |a| {
            // One interactive composition only: both authored sections switch beneath the same
            // nav and context strips. Debug owns the three unlocking tools and stocks materials.
            fixtureGoods(ctx, a[0], &.{ .{ "hatchet", 1 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            poke(ctx, a[0], .{ .biomass = 31 });
            // The surface fills its parent's height (its views scroll inside), so the demo
            // gives it a definite one, as the workspace's content lane does in production.
            const demo = try stage.box("surface_demo", .{ .w = .{ .fixed = 652 }, .h = .{ .fixed = 560 } }, .{});
            _ = try t.act_one_surface(demo, world, a[0], "surface", .{
                .activity = .{
                    .state = .working,
                    .subject = "Forage",
                    .metadata = "2h left",
                    .last = .working,
                },
            });
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "act_one_workspace")) {
        if (player.get()) |a| {
            // Populate the debug-only actor with the reference's representative holdings and
            // unlocked verbs; production remains entirely progression-driven.
            // The verbs come with their tools: the hatchet, a rod and snares unlock three more.
            fixtureGoods(ctx, a[0], &.{ .{ "sandals", 2 }, .{ "root_cellar", 1 }, .{ "leaf_bed", 1 }, .{ "hatchet", 2 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            poke(ctx, a[0], .{ .biomass = 31 });

            const demo = try stage.box("workspace_demo", .{ .w = .{ .fixed = 926 }, .h = .{ .fixed = 700 } }, .{});
            _ = try t.act_one_workspace(demo, world, a[0], "workspace", .{
                .holdings = try act_one_holdings.content(ctx, world, a[0]),
                .surface = .{ .activity = .{
                    .state = .working,
                    .subject = "Forage",
                    .metadata = "2h left",
                    .last = .working,
                } },
            });
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "act_one_page")) {
        if (player.get()) |a| {
            // One large reference composition: shared shell rows around one live workspace.
            // Debug-only grants make the authored five-verb/holdings state visible; production
            // continues to derive every stock, unlock, activity, and log line from live state.
            fixtureGoods(ctx, a[0], &.{ .{ "sandals", 2 }, .{ "root_cellar", 1 }, .{ "leaf_bed", 1 }, .{ "hatchet", 2 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            poke(ctx, a[0], .{ .biomass = 31 });
            poke(ctx, a[0], .{ .food = 11.6 });
            poke(ctx, a[0], .{ .vigor = .{ .v = 14, .max = 15 } });

            const demo = try stage.box("act_one_page_demo", .{
                .w = .{ .fixed = 900 }, .h = .{ .fixed = 820 }, .overflow = .clip,
            }, .{Style{ .fill_ink = .bg }});
            const regions = try t.shell_content(demo, demo, .{
                .id = "act_one_page",
                .act = .act_one,
                .page_pad = ha.tokens.pad_page,
                .section_gap = ha.tokens.gap.section,
                .footer = true,
            });
            const stocks = [_]t.Stock{
                .{ .abbrev = "VI", .full = "Vigor", .value = 14, .max = 15 },
                .{ .abbrev = ha.sim.data.roster.Resource.food.abbrevIn(act), .full = ha.sim.data.roster.Resource.food.labelIn(act), .value = 11.6 },
                .{ .abbrev = ha.sim.data.roster.Resource.biomass.abbrevIn(act), .full = ha.sim.data.roster.Resource.biomass.labelIn(act), .value = 31 },
            };
            _ = try t.header(regions.header, "hud", .{
                .stocks = &stocks,
                .run = .{ .act_label = "Act I", .day = 19 },
            });
            const workspace = try t.act_one_workspace(regions.body, world, a[0], "workspace", .{
                .holdings = try act_one_holdings.content(ctx, world, a[0]),
                .surface = .{ .activity = .{
                    .state = .idle,
                    .subject = "no work in progress",
                    .metadata = "ready",
                    .last = .idle,
                } },
            });
            if (workspace.surface.market_action.consume(.clicked)) audit_trade.open = true;

            var feed: ha.sim.log.Log = .{};
            feed.push(.normal, try ctx.arena.print("You return with 4 {s}.", .{ha.sim.data.roster.Resource.biomass.wordIn(act)}));
            feed.push(.good, "The Root cellar slows what the larder loses.");
            feed.push(.normal, "You finish a second Hatchet. One is effect; one is stock.");
            feed.push(.normal, "Someone is walking the shoreline. Their pack carries made goods.");
            if (regions.footer) |footer| {
                try t.log_view(footer, "feed", &feed, 900 - 2 * ha.tokens.pad_page, 4);
            }

            // Match production's overlay lifecycle: the workspace owns placement of the TRADE
            // action, while this page owns stable open state and renders the dialog last.
            return auditTradeOverlay(ctx, audit_trade);
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "eating_policy")) {
        const demo = try stage.box("eating_policy_demo", .{ .w = .{ .fixed = 300 }, .h = .fit_children }, .{});
        _ = try t.eating_policy(demo, "ep", 50, true);
    } else if (eq(name, "capital_row")) {
        if (player.get()) |a| {
            const gi = ctx.res.game.catalog.goodIndex("sandals").?;
            if (if (world.get(a[0], comp.Quotes)) |quotes| quotes.builds[gi] else null) |q| {
                // Act I's lanes; the demo owns the row's tracks, as the BUILD list does, and is
                // the framed table's width (the lane less the scroll gutter), which the row spans.
                const set = try t.build_table_tracks(ctx, .{});
                const demo = try stage.box("capital_row_demo", .{
                    .w = .{ .fixed = t.build_lane_width - t.build_scroll_gutter }, .h = .fit_children,
                    .flow = .{ .dir = .column }, .tracks = set,
                }, .{});
                _ = try t.capital_row(demo, world, a[0], set, &ctx.res.game.catalog.goods[gi], q, .ready);
            }
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "catalog_controls")) {
        // The field spans its parent, so the audit gives it a catalog-sized width. Under it, the
        // ACTIONS toolbar's sort chips on the demo's own catalog state: click a chip to sort, again
        // to flip.
        const demo = try stage.box("cc_demo", .{ .w = .{ .fixed = 560 }, .h = .fit_children, .flow = .{ .dir = .column }, .gap = 10 }, .{});
        _ = try t.catalog_controls(demo, "cc", t.recipes_placeholder, null, null);
        _ = try t.sort_chips(demo, "sort", "Sort actions", &t.actions_sort_keys, demo.state(uic.UiState.CatalogState));
    } else if (eq(name, "milestone_goal")) {
        const demo = try stage.box("milestone_demo", .{ .w = .{ .fixed = 608 }, .h = .fit_children }, .{});
        var resource_label_buf: [16]u8 = undefined;
        const resource_label = std.ascii.upperString(&resource_label_buf, ha.sim.data.roster.Resource.biomass.labelIn(act));
        const requirements = [_]t.MilestoneRequirement{
            .{ .label = "VIGOR", .value = "14/15" },
            .{ .label = "FOOD", .value = "11.6/12" },
            .{ .label = "RECIPES", .value = "4/5" },
            .{ .label = resource_label, .value = "31/60" },
        };
        _ = try t.milestone_goal(demo, "mg", .{
            .state = .locked,
            .title = "Shelter",
            .summary = try ctx.arena.print("{s} 31/60", .{ha.sim.data.roster.Resource.biomass.wordIn(act)}),
            .readiness = "locked \u{00B7} 1 condition",
            .kicker = "A PLACE FOR OTHERS",
            .cost = "60m 6e \u{00B7} 6.0d",
            .copy = "a roof with room for four. you're not alone anymore.",
            .requirements = &requirements,
            .explanation = try ctx.arena.print("Hold 60 {s} with a settled body and four kinds of goods.", .{ha.sim.data.roster.Resource.biomass.wordIn(act)}),
            .action = "LOCKED",
        });
    } else if (eq(name, "market_strip")) {
        const demo = try stage.box("market_demo", .{ .w = .{ .fixed = 608 }, .h = .fit_children }, .{});
        _ = try t.market_strip(demo, "ms", .passerby, true);
    } else if (eq(name, "activity_strip")) {
        const demo = try stage.box("activity_demo", .{ .w = .{ .fixed = 608 }, .h = .fit_children }, .{});
        _ = try t.activity_strip(demo, "as", .idle, "no work in progress", "ready", .idle);
    } else if (eq(name, "trade_dialog")) {
        return auditTradeOverlay(ctx, audit_trade);
    } else if (eq(name, "coin_merchant")) {
        // The merchant over the debug actor: it has not crossed the curtain, so its Act II
        // stocks read empty and most buys are short of coin.
        const a = player.get() orelse return null;
        return try coin_merchant(ctx, world, a[0], "merchant", audit_trade);
    } else if (eq(name, "menu_dialog")) {
        try stage.label("note", "The session menu opens over this page; reselect the entry to reopen it.", .{});
    } else if (eq(name, "curtain")) {
        const demo = try stage.box("curtain_demo", .{ .w = .{ .fixed = 520 }, .h = .{ .fixed = 260 } }, .{});
        _ = try t.curtain(demo, "c", .{ .title = "ACT I", .line = "You have a house to live in.", .note = "Room enough for four under one roof.", .button = "Continue" });
    } else if (eq(name, "speed_stepper")) {
        _ = try t.speed_stepper(stage, "speed");
        try stage.label("hint", "<< / >> step PAUSE, 1x, 2x, 3x; arrows, Home and End when focused.", .{});
    } else if (eq(name, "scroll_view")) {
        const sv = try t.scroll_view(stage, "sv", .{ .width = 300, .height = 140 }, null);
        for (0..20) |i| {
            var buf: [24]u8 = undefined;
            try (try sv.content.item("row", i)).label("t", std.mem.print(&buf, "row {d}", .{i}) catch "row", .{});
        }
    } else if (eq(name, "sort_header")) {
        // A sortable header row as BUILD's table builds it: click a label to sort, again to flip.
        const st = stage.state(uic.UiState.CatalogState);
        const set = try uic.tracks(ctx, &.{ .{ .basis = .{ .px = 90 } }, .{ .basis = .{ .px = 90 } }, .{ .basis = .{ .px = 90 } } }, 8);
        stage.set(.{ .tracks = set }, .{});
        const row = try t.table_row(stage, "hdr", set, 6, 4);
        const labels = [_][]const u8{ "RECIPE", "COST", "STATE" };
        var members: [labels.len]u64 = undefined;
        for (labels, 0..) |label, i| {
            const shown: t.SortShown = if (st.sort != i) .none else if (st.dir == .descending) .descending else .ascending;
            const cell = try t.sort_header_cell(row, label, label, shown, row.get().key);
            members[i] = cell.key;
            if (cell.clicked) {
                const next = t.nextSort(st.sort, if (st.dir == .none) .ascending else st.dir, i, .ascending);
                st.sort = next.sort;
                st.dir = next.dir;
            }
        }
    } else if (eq(name, "act_two_holdings")) {
        if (player.get()) |a| {
            const demo = try stage.box("a2h_demo", .{ .w = .{ .fixed = ha.tokens.rail.expanded }, .h = .{ .fixed = 400 } }, .{});
            // As the Act II rail composes it: the Household column with the eating policy.
            _ = try t.household(demo, world, a[0], "content", try act_two_holdings.content(ctx, world, a[0]));
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "act_two_actions")) {
        // The shared ACTIONS pane with Act II's shelf, compact: the settlement's verbs, then
        // both acts' generators as slim tiles with their mode corners (the garden bed on auto,
        // the second bed off), under the kind toggles and the toolbar.
        if (player.get()) |a| {
            fixtureGoods(ctx, a[0], &.{
                .{ "firepit", 1 },     .{ "spring_well", 1 }, .{ "forge", 1 },          .{ "lean_to", 1 },
                .{ "wire_snares", 1 }, .{ "garden_bed", 1 },  .{ "garden_bed_two", 1 },
            });
            fixtureMode(ctx, a[0], "garden_bed", .auto);
            fixtureMode(ctx, a[0], "garden_bed_two", .off);
            const demo = try stage.box("a2a_demo", .{ .w = .{ .fixed = 608 }, .h = .fit_children }, .{});
            _ = try t.actions_section(demo, world, a[0], "a2_actions", .{ .act = 2, .subtitle = "What will the settlement do now?", .density = .compact }, null, null, null);
        } else {
            try stage.label("na", "(needs a live player)", .{});
        }
    } else if (eq(name, "tooltip")) {
        // An overlay root: the tooltip is its own tree, returned as the frame's second root so
        // it floats above the stage and the index. Placed just under its anchor label, in device
        // px, and kept inside the terminal by its prior-frame size, as a production caller does
        // (null until it has been laid out once, when a zero size pins nothing).
        try stage.label("anchor", "a control the tooltip describes", .{});
        const tip = try uic.tooltip(ctx, "tip", "Vigor \u{00b7} 7 / 10");
        const s = ctx.res.view.scale;
        const prior = tip.prior_geometry();
        const at = uic.clampToTerminal(ctx, uic.view.dp(40, s), uic.view.dp(44, s), if (prior) |g| g.rect.w else 0, if (prior) |g| g.rect.h else 0);
        _ = tip.with_offset_px(at.x, at.y);
        return tip.get();
    } else if (eq(name, "empty_state")) {
        _ = try t.empty_state(stage, "es", "Nothing here yet.", "Try widening the filter.");
    } else if (eq(name, "readout")) {
        // The readout panel with every primitive inside it, as HOLDINGS composes them.
        const p = try t.readout_panel(stage, "rp", 214, .{ .up = 10, .right = 16, .down = 9, .left = 10 });
        (try t.readout_heading(p, "heading", "HOLDINGS", "2 KINDS, 3")).set(.{ .margin = .{ .after = 8 } }, .{});
        try t.kv_line(p, "sandals", "Sandals \u{00d7}2", "forage costs less", th.dim);
        try t.kv_line(p, "hatchet", "Hatchet", "unlocks Split wood", th.dim);
        try t.divider(p, "divider", 9, 7);
        (try t.section_label(p, "margins_title", "MARGINS")).set(.{ .margin = .{ .after = 8 } }, .{});
        try t.kv_line(p, "forage", "Forage", "1.7e \u{2192} 1.4e", th.good);
        try t.sentence(p, "coverage", "Food lasts ", "3.2d", ".", th.fg);
    } else if (eq(name, "table")) {
        // The pieces BUILD's table composes: a header row of labels, and body rows of cells.
        const demo = try stage.div("table_demo");
        const set = try uic.tracks(ctx, &.{ .{ .basis = .{ .px = 150 } }, .{ .basis = .{ .px = 110 } }, .{ .basis = .{ .px = 90 } } }, 8);
        demo.set(.{ .flow = .{ .dir = .column }, .tracks = set }, .{});
        const h = try t.table_row(demo, "header", set, 6, 4);
        _ = try t.table_header_cell(h, "recipe", "RECIPE");
        _ = try t.table_header_cell(h, "inputs", "INPUTS");
        _ = try t.table_header_cell(h, "state", "STATE");
        const r1 = try t.table_row(demo, "r1", set, 6, 5);
        _ = try t.table_cell(r1, "recipe", "Reinforced Timber Frame", style.ink(.fg), false);
        _ = try t.table_cell(r1, "inputs", "12mi 4me", style.ink(.dim), false);
        _ = try t.table_cell(r1, "state", "ready", style.ink(.good), true);
        const r2 = try t.table_row(demo, "r2", set, 6, 5);
        _ = try t.table_cell(r2, "recipe", "Kiln", style.ink(.fg), false);
        _ = try t.table_cell(r2, "inputs", "30mi", style.ink(.dim), false);
        _ = try t.table_cell(r2, "state", "reach 60%", style.ink(.warn), true);
    } else if (eq(name, "browser_heading")) {
        const demo = try stage.box("heading_demo", .{ .w = .{ .fixed = 608 }, .h = .fit_children }, .{});
        _ = try t.browser_heading(demo, "bh", "ACTIONS", "What will the settlement do now?", "20 VERBS");
    } else if (eq(name, "tile_lanes")) {
        const demo = try stage.box("lanes_demo", .{ .w = .{ .fixed = 608 }, .h = .fit_children }, .{});
        const grid = try t.tile_lanes(demo, "grid", false, 10);
        _ = try t.button(grid.lanes[0], "a", "first tile, left lane", true);
        _ = try t.button(grid.lanes[1], "b", "second tile, right lane", true);
        _ = try t.button(grid.lanes[0], "c", "third tile, left again", true);
    } else if (eq(name, "copy")) {
        const demo = try stage.box("copy_demo", .{ .flow = .{ .dir = .column }, .gap = 6 }, .{});
        _ = try t.headline(demo, "h", "Two others asked to move in.");
        _ = try t.lede(demo, "l", "You are not alone here anymore. Act I ends, and the settlement begins with whoever walked in.", 320);
        _ = try t.empty_line(demo, "e", "No action matches your search.");
    } else {
        try stage.label("unknown", "(unknown template)", .{});
    }
    return null;
}

/// Build the sample trade dialog used by both its standalone audit entry and the complete Act-I
/// page. `audit_trade` lives on the debug root, so dismissal persists after the overlay disappears.
fn auditTradeOverlay(ctx: *UiCtx, audit_trade: *uic.UiState.TradeState) !?*Node {
    if (!audit_trade.open) return null;
    // The prototype's Act I passerby, as numbers (`trade.html`'s `ACTS.i`).
    const lots = [_]t.TradeLot{
        .{ .id = 1, .mode = .buy, .lot = "Fishing rod \u{00d7}1", .effect = "unlocks Fish", .price = &.{ .{ .key = "food", .n = 2 }, .{ .key = "materials", .n = 8 } }, .receive = &.{.{ .key = "fishing rod", .n = 1, .stock = false }}, .stock = 1, .consequence = "Fishing becomes available while you own it." },
        .{ .id = 2, .mode = .buy, .lot = "Hand axe \u{00d7}1", .effect = "splitting costs less", .price = &.{ .{ .key = "food", .n = 6 }, .{ .key = "materials", .n = 40 } }, .receive = &.{.{ .key = "hand axe", .n = 1, .stock = false }}, .stock = 1 },
        .{ .id = 3, .mode = .buy, .lot = "Preserved food \u{00d7}10", .effect = "keeps well", .price = &.{.{ .key = "materials", .n = 8 }}, .receive = &.{.{ .key = "food", .n = 10 }}, .stock = 2 },
        .{ .id = 11, .mode = .sell, .lot = "Sandals \u{00d7}1", .effect = "your spare stock", .price = &.{.{ .key = "sandals", .n = 1, .stock = false }}, .receive = &.{ .{ .key = "food", .n = 6 }, .{ .key = "materials", .n = 5 } }, .consequence = "A spare pair goes first; the pair you wear keeps its Forage margin." },
        .{ .id = 12, .mode = .sell, .lot = "Hatchet \u{00d7}1", .effect = "your spare stock", .price = &.{.{ .key = "hatchet", .n = 1, .stock = false }}, .receive = &.{ .{ .key = "food", .n = 9 }, .{ .key = "materials", .n = 8 } } },
        .{ .id = 13, .mode = .sell, .lot = "Materials \u{00d7}10", .effect = "raw stock", .price = &.{.{ .key = "materials", .n = 10 }}, .receive = &.{.{ .key = "food", .n = 3 }} },
    };
    const balances = [_]t.TradeBalance{
        .{ .key = "food", .held = 11.6 },
        .{ .key = "materials", .held = 31 },
        .{ .key = "fishing rod", .held = 0 },
        .{ .key = "hand axe", .held = 0 },
        .{ .key = "sandals", .held = 2 },
        .{ .key = "hatchet", .held = 2 },
    };
    const book = t.TradeBook{ .lots = &lots, .balances = &balances, .notation = .{ .abbrev = &.{ .{ .key = "food", .letter = "f" }, .{ .key = "materials", .letter = "m" } } } };

    const result = try t.trade_dialog(ctx, "trade", .passerby, "1.8 DAYS LEFT", book, &.{}, audit_trade);
    if (result.dismissed) {
        audit_trade.open = false;
        return null;
    }
    return result.root;
}
/// Debug-only sample state: one `DebugPoke`, which `systems/debug.zig` applies in the next tick
/// before the derived writers run. An entry pushes its pokes every frame it renders (each is
/// idempotent), so its first frame renders unpoked and every frame after renders the sample.
fn poke(ctx: *UiCtx, e: Entity, what: ha.sim.events.DebugPoke.What) void {
    _ = ctx.res.game.events.writer(ha.sim.events.DebugPoke).push(.{ .agent = e, .what = what });
}

/// Debug-only holdings: poke the counts of the named goods, then settle, so the verbs they
/// grant and the margins they move are derived exactly as in production.
fn fixtureGoods(ctx: *UiCtx, e: Entity, counts: []const struct { []const u8, u32 }) void {
    const cat = &ctx.res.game.catalog;
    for (counts) |c| {
        if (cat.goodIndex(c[0])) |gi| poke(ctx, e, .{ .good = .{ .gi = @intCast(gi), .count = c[1] } });
    }
    poke(ctx, e, .settle);
}

/// Debug-only generator mode: poke good `id`'s mode, as the tile's corner would leave it.
fn fixtureMode(ctx: *UiCtx, e: Entity, id: []const u8, mode: comp.Generators.Mode) void {
    if (ctx.res.game.catalog.goodIndex(id)) |gi| poke(ctx, e, .{ .generator_mode = .{ .gi = @intCast(gi), .mode = mode } });
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
