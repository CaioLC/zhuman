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
    "actions_section",
    "build_section",
    "act_one_surface",
    "generator_section",
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
pub fn debug_page(ctx: *UiCtx, world: *World) !uic.Trees {
    const th = ctx.res.view.theme;

    const root = try el.root(ctx, "debug");
    _ = root.with_layout(.top_left).with_flow(.{ .dir = .row })
        .with_style(.{Style{ .fill = th.bg }});

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
    const stage_wrap = try root.div("stage_wrap");
    _ = stage_wrap.with_size(.grow, .{ .pct_of_parent = 1.0 }).with_flow(.{ .dir = .column }).with_gap(8)
        .with_style(.{style.pad(16)});
    const stage = try stage_wrap.div("stage");
    _ = stage.with_flow(.{ .dir = .column }).with_gap(6);

    const overlay = try render_one(stage, world, entries[active], root.state(uic.UiState.TradeState));
    const sel = root.state(uic.UiState.TabsState);
    const audit_trade = root.state(uic.UiState.TradeState);

    // --- the clickable index: a thin column anchored on the RIGHT --------------------------
    const index = try root.div("index");
    _ = index.with_size(.{ .fixed = 150 }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .column }).with_gap(2)
        .with_style(.{ Style{ .fill = th.panel }, style.pad_sym(10, 10) });
    _ = (try index.text("ihdr", "TEMPLATES"))
        .with_style(.{ style.small, Style{ .text = th.dim } });
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
        const c = if (on) th.acc else if (iq.hovering or iq.focused) th.fg else th.dim;
        _ = (try item.text("t", name)).with_style(.{ style.small, Style{ .text = c } });
    }

    var roots: std.ArrayList(*Node) = .empty;
    try roots.append(ctx.arena, root.get());
    if (overlay) |dialog| try roots.append(ctx.arena, dialog);
    return roots.items;
}

/// Build exactly one template into `stage` with sample data. Returns an optional overlay root
/// (only the trade dialog uses it). Everything else returns null.
fn render_one(stage: El, world: *World, name: []const u8, audit_trade: *uic.UiState.TradeState) !?*Node {
    const ctx = stage.ctx;
    const th = ctx.res.view.theme;
    const act: u8 = 1;
    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };

    if (eq(name, "button")) {
        _ = try t.button(stage, "b_on", "Enabled", true);
        _ = try t.button(stage, "b_off", "Disabled", false);
    } else if (eq(name, "panel")) {
        const p = try t.panel(stage, "p", "Panel Title");
        _ = try p.text("body", "panel body content");
    } else if (eq(name, "figure")) {
        try t.figure(stage, "dead", t.fig_dead, th.danger);
    } else if (eq(name, "stock_token")) {
        try t.stock_token(stage, "tok", .{ .abbrev = ha.roster.Resource.food.abbrevIn(act), .full = ha.roster.Resource.food.labelIn(act), .value = 3.6, .tone = .warn });
    } else if (eq(name, "stockline")) {
        const stocks = [_]t.Stock{
            .{ .abbrev = "VI", .full = "Vigor", .value = 10, .max = 10 },
            .{ .abbrev = ha.roster.Resource.food.abbrevIn(act), .full = ha.roster.Resource.food.labelIn(act), .value = 3.6, .tone = .danger },
            .{ .abbrev = ha.roster.Resource.biomass.abbrevIn(act), .full = ha.roster.Resource.biomass.labelIn(act), .value = 24 },
        };
        _ = try t.stockline(stage, "sl", &stocks, false);
    } else if (eq(name, "runline")) {
        // Act I (no energy flow) above Act II (the `⚡ +gen/−consumed` rate).
        const col = try stage.div("runs");
        _ = col.with_flow(.{ .dir = .column, .cross = .start }).with_gap(10);
        _ = try t.runline(col, "run", .{ .act_label = "Act I", .day = 3 });
        _ = try t.runline(col, "run2", .{ .gen = 12, .consumed = 9, .act_label = "Act II", .day = 43 });
    } else if (eq(name, "header")) {
        const demo = try stage.div("header_demo");
        _ = demo.with_size(.{ .fixed = 620 }, .fit_children);
        const stocks = [_]t.Stock{
            .{ .abbrev = "VI", .full = "Vigor", .value = 10, .max = 10 },
            .{ .abbrev = ha.roster.Resource.food.abbrevIn(act), .full = ha.roster.Resource.food.labelIn(act), .value = 3.6, .tone = .danger },
            .{ .abbrev = ha.roster.Resource.biomass.abbrevIn(act), .full = ha.roster.Resource.biomass.labelIn(act), .value = 24 },
        };
        _ = try t.header(demo, "hud", .{
            .stocks = &stocks,
            .run = .{ .act_label = "Act I", .day = 3 },
        });
    } else if (eq(name, "log_view")) {
        try t.log_view(stage, "feed", &ctx.res.sim.log, 400, 4);
    } else if (eq(name, "tabs")) {
        _ = try t.tabs(stage, "tabs", &.{ "ACTIONS", "BUILD" }, null);
    } else if (eq(name, "slider")) {
        const demo = try stage.div("slider_demo");
        _ = demo.with_size(.{ .fixed = 300 }, .fit_children);
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
        const demo = try stage.div("rail_demo");
        _ = demo.with_size(.{ .fixed = ha.tokens.rail.expanded }, .{ .fixed = 300 });
        const r = try t.rail(demo, .{ .id = "rail", .label = "HOUSEHOLD" });
        if (r.body) |rb| _ = try rb.text("rb", "rail body");
    } else if (eq(name, "holdings")) {
        if (player.get()) |a| {
            // A coherent debug-only four-kind/six-unit fixture matching the reference anatomy.
            // Values remain ordinary live ECS data; the component performs all projections.
            fixtureGoods(world, a[0], ctx, &.{ .{ "sandals", 2 }, .{ "root_cellar", 1 }, .{ "leaf_bed", 1 }, .{ "hatchet", 2 } });
            if (world.get(a[0], comp.InventoryFood)) |food| {
                food.v = 7.8;
                food.quality = 1;
                food.spoils = ha.baselines.food_spoils;
            }
            if (world.get(a[0], comp.Vigor)) |vigor| {
                vigor.max = 15;
                vigor.v = 14.4;
            }
            if (world.get(a[0], comp.Metabolism)) |met| met.rate = 0.5;

            const demo = try stage.div("holdings_demo");
            _ = demo.with_size(.{ .fixed = ha.tokens.rail.expanded }, .{ .fixed = 400 });
            const r = try t.rail(demo, .{ .id = "holdings_rail", .label = "HOUSEHOLD" });
            if (r.body) |body| _ = try t.holdings(body, "content", try act_one_holdings.content(ctx, world, a[0]));
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "action_tile")) {
        if (player.get()) |a| {
            const forage = ctx.res.catalog.actionIndex("forage").?;
            // Both densities, sized as their sections size them: Act I's regular grid tile
            // above Act II's compact catalog tile.
            const col = try stage.div("densities");
            _ = col.with_size(.{ .fixed = 300 }, .fit_children)
                .with_flow(.{ .dir = .column, .cross = .start }).with_gap(10);
            inline for (.{ .{ "at", t.ActionDensity.regular }, .{ "atc", t.ActionDensity.compact } }) |d| {
                if (try t.action_tile(col, world, a[0], forage, d[0], d[1])) |tl| {
                    _ = tl.el.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = t.actionTileHeight(d[1]) })
                        .with_flow(.{ .dir = .column, .main = .center });
                    if (tl.clicked) actions.begin(world, a[0], ctx.res, forage);
                }
            }
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "actions_section")) {
        if (player.get()) |a| {
            // The live debug player starts with only the two innate verbs. Own the three tools
            // that grant the rest, so the assembly audit shows the complete five-verb reference.
            fixtureGoods(world, a[0], ctx, &.{ .{ "hatchet", 1 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            const demo = try stage.div("actions_demo");
            _ = demo.with_size(.{ .fixed = 620 }, .fit_children);
            _ = try t.actions_section(demo, world, a[0], "actions", @import("./templates/act_one_surface.zig").actions_shelf, null, null);
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "build_section")) {
        if (player.get()) |a| {
            // Give the debug-only catalog a representative stock level so ready and reach rows
            // appear together, matching the reference anatomy without changing production.
            if (world.get(a[0], comp.InventoryBiomass)) |stock| stock.v = 31;
            // The pane fills a definite height and scrolls only its table.
            const demo = try stage.div("build_demo");
            _ = demo.with_size(.fit_children, .{ .fixed = 560 });
            _ = try t.build_section(demo, world, a[0], "build", @import("./templates/act_one_surface.zig").build_shelf, null, null, null);
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "act_one_surface")) {
        if (player.get()) |a| {
            // One interactive composition only: both authored sections switch beneath the same
            // nav and context strips. Debug owns the three unlocking tools and stocks materials.
            fixtureGoods(world, a[0], ctx, &.{ .{ "hatchet", 1 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            if (world.get(a[0], comp.InventoryBiomass)) |stock| stock.v = 31;
            // The surface fills its parent's height (its views scroll inside), so the demo
            // gives it a definite one, as the workspace's content lane does in production.
            const demo = try stage.div("surface_demo");
            _ = demo.with_size(.{ .fixed = 652 }, .{ .fixed = 560 });
            _ = try t.act_one_surface(demo, world, a[0], "surface", .{
                .activity = .{
                    .state = .working,
                    .subject = "Forage",
                    .metadata = "2h left",
                    .last = .working,
                },
            });
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "act_one_workspace")) {
        if (player.get()) |a| {
            // Populate the debug-only actor with the reference's representative holdings and
            // unlocked verbs; production remains entirely progression-driven.
            // The verbs come with their tools: the hatchet, a rod and snares unlock three more.
            fixtureGoods(world, a[0], ctx, &.{ .{ "sandals", 2 }, .{ "root_cellar", 1 }, .{ "leaf_bed", 1 }, .{ "hatchet", 2 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            if (world.get(a[0], comp.InventoryBiomass)) |stock| stock.v = 31;

            const demo = try stage.div("workspace_demo");
            _ = demo.with_size(.{ .fixed = 926 }, .{ .fixed = 700 });
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
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "act_one_page")) {
        if (player.get()) |a| {
            // One large reference composition: shared shell rows around one live workspace.
            // Debug-only grants make the authored five-verb/holdings state visible; production
            // continues to derive every stock, unlock, activity, and log line from live state.
            fixtureGoods(world, a[0], ctx, &.{ .{ "sandals", 2 }, .{ "root_cellar", 1 }, .{ "leaf_bed", 1 }, .{ "hatchet", 2 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            if (world.get(a[0], comp.InventoryBiomass)) |stock| stock.v = 31;
            if (world.get(a[0], comp.InventoryFood)) |food| food.v = 11.6;
            if (world.get(a[0], comp.Vigor)) |vigor| {
                vigor.max = 15;
                vigor.v = 14;
            }

            const demo = try stage.div("act_one_page_demo");
            _ = demo.with_size(.{ .fixed = 900 }, .{ .fixed = 820 })
                .with_overflow(.clip)
                .with_style(.{Style{ .fill = th.bg }});
            const regions = try t.shell_content(demo, demo, .{
                .id = "act_one_page",
                .act = .act_one,
                .page_pad = ha.tokens.pad_page,
                .section_gap = ha.tokens.gap.section,
                .footer = true,
            });
            const stocks = [_]t.Stock{
                .{ .abbrev = "VI", .full = "Vigor", .value = 14, .max = 15 },
                .{ .abbrev = ha.roster.Resource.food.abbrevIn(act), .full = ha.roster.Resource.food.labelIn(act), .value = 11.6 },
                .{ .abbrev = ha.roster.Resource.biomass.abbrevIn(act), .full = ha.roster.Resource.biomass.labelIn(act), .value = 31 },
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

            var feed: ha.log.Log = .{};
            feed.push(.normal, try ctx.arena.print("You return with 4 {s}.", .{ha.roster.Resource.biomass.wordIn(act)}));
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
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "eating_policy")) {
        const demo = try stage.div("eating_policy_demo");
        _ = demo.with_size(.{ .fixed = 300 }, .fit_children);
        _ = try t.eating_policy(demo, "ep", 50, true);
    } else if (eq(name, "capital_row")) {
        if (player.get()) |a| {
            const gi = ctx.res.catalog.goodIndex("sandals").?;
            if (ha.capital.quote(world, a[0], &ctx.res.catalog, gi)) |q| {
                _ = try t.capital_row(stage, world, a[0], .{}, q, .ready);
            }
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "catalog_controls")) {
        // The field spans its parent, so the audit gives it a catalog-sized width.
        const demo = try stage.div("cc_demo");
        _ = demo.with_size(.{ .fixed = 560 }, .fit_children);
        _ = try t.catalog_controls(demo, "cc", t.recipes_placeholder, null, null);
    } else if (eq(name, "milestone_goal")) {
        const demo = try stage.div("milestone_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        var resource_label_buf: [16]u8 = undefined;
        const resource_label = std.ascii.upperString(&resource_label_buf, ha.roster.Resource.biomass.labelIn(act));
        const requirements = [_]t.MilestoneRequirement{
            .{ .label = "VIGOR", .value = "14/15" },
            .{ .label = "FOOD", .value = "11.6/12" },
            .{ .label = "RECIPES", .value = "4/5" },
            .{ .label = resource_label, .value = "31/60" },
        };
        _ = try t.milestone_goal(demo, "mg", .{
            .state = .locked,
            .title = "Shelter",
            .summary = try ctx.arena.print("{s} 31/60", .{ha.roster.Resource.biomass.wordIn(act)}),
            .readiness = "locked \u{00B7} 1 condition",
            .kicker = "A PLACE FOR OTHERS",
            .cost = "60m 6e \u{00B7} 6.0d",
            .copy = "a roof with room for four. you're not alone anymore.",
            .requirements = &requirements,
            .explanation = try ctx.arena.print("Hold 60 {s} with a settled body and four kinds of goods.", .{ha.roster.Resource.biomass.wordIn(act)}),
            .action = "LOCKED",
        });
    } else if (eq(name, "market_strip")) {
        const demo = try stage.div("market_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        _ = try t.market_strip(demo, "ms", .passerby, true);
    } else if (eq(name, "activity_strip")) {
        const demo = try stage.div("activity_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        _ = try t.activity_strip(demo, "as", .idle, "no work in progress", "ready", .idle);
    } else if (eq(name, "trade_dialog")) {
        return auditTradeOverlay(ctx, audit_trade);
    } else if (eq(name, "coin_merchant")) {
        const m = try coin_merchant(ctx, "merchant", audit_trade);
        return m.root;
    } else if (eq(name, "menu_dialog")) {
        _ = try stage.text("note", "The session menu opens over this page; reselect the entry to reopen it.");
    } else if (eq(name, "curtain")) {
        const demo = try stage.div("curtain_demo");
        _ = demo.with_size(.{ .fixed = 520 }, .{ .fixed = 260 });
        _ = try t.curtain(demo, "c", .{ .title = "ACT I", .line = "You have a house to live in.", .note = "Room enough for four under one roof.", .button = "Continue" });
    } else if (eq(name, "speed_stepper")) {
        _ = try t.speed_stepper(stage, "speed");
        _ = try stage.text("hint", "<< / >> step PAUSE, 1x, 2x, 3x; arrows, Home and End when focused.");
    } else if (eq(name, "scroll_view")) {
        const sv = try t.scroll_view(stage, "sv", .{ .width = 300, .height = 140 }, null);
        for (0..20) |i| {
            var buf: [24]u8 = undefined;
            _ = try (try sv.content.item("row", i)).text("t", std.mem.print(&buf, "row {d}", .{i}) catch "row");
        }
    } else if (eq(name, "sort_header")) {
        // A sortable header row as BUILD's table builds it: click a label to sort, again to flip.
        const st = stage.state(uic.UiState.CatalogState);
        const row = try t.table_row(stage, "hdr", 8, 6, 4);
        const labels = [_][]const u8{ "RECIPE", "COST", "STATE" };
        var members: [labels.len]u64 = undefined;
        for (labels, 0..) |label, i| {
            const shown: t.SortShown = if (st.sort != i) .none else if (st.dir == .descending) .descending else .ascending;
            const cell = try t.sort_header_cell(row, label, 90, label, shown, row.get().key);
            members[i] = cell.key;
            if (cell.clicked) {
                const next = t.nextSort(st.sort, if (st.dir == .none) .ascending else st.dir, i, .ascending);
                st.sort = next.sort;
                st.dir = next.dir;
            }
        }
    } else if (eq(name, "generator_section")) {
        if (player.get()) |a| {
            // Own the two generator goods so both rows show.
            fixtureGoods(world, a[0], ctx, &.{ .{ "wire_snares", 1 }, .{ "garden_bed", 1 } });
            const demo = try stage.div("gen_demo");
            _ = demo.with_size(.{ .fixed = 594 }, .fit_children);
            _ = try t.generator_section(demo, world, a[0], "gens");
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "act_two_holdings")) {
        if (player.get()) |a| {
            const demo = try stage.div("a2h_demo");
            _ = demo.with_size(.{ .fixed = ha.tokens.rail.expanded }, .{ .fixed = 400 });
            // As the Act II rail composes it: Holdings/BODY, then the eating policy.
            const column = try t.holdings(demo, "content", try act_two_holdings.content(ctx, world, a[0]));
            _ = try t.eating_policy(column, "eating_policy", 50, true);
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "act_two_actions")) {
        // The shared ACTIONS pane with Act II's shelf. The debug actor has not crossed the
        // curtain, so it holds no Act II verb: this shows the pane's empty state.
        if (player.get()) |a| {
            const demo = try stage.div("a2a_demo");
            _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
            _ = try t.actions_section(demo, world, a[0], "a2_actions", .{ .act = 2, .subtitle = "What will the settlement do now?", .density = .compact }, null, null);
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "tooltip")) {
        // An overlay root: the tooltip is its own tree, returned as the frame's second root so
        // it floats above the stage and the index. Placed just under its anchor label, in device
        // px, and kept inside the terminal by its prior-frame size, as a production caller does
        // (null until it has been laid out once, when a zero size pins nothing).
        _ = try stage.text("anchor", "a control the tooltip describes");
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
        _ = try t.readout_heading(p, "heading", "HOLDINGS", "2 KINDS, 3");
        _ = try p.spacer("heading_gap", 1, 8);
        try t.kv_line(p, "sandals", "Sandals \u{00d7}2", "forage costs less", th.dim);
        try t.kv_line(p, "hatchet", "Hatchet", "unlocks Split wood", th.dim);
        try t.divider(p, "divider", 9, 7);
        _ = try t.section_label(p, "margins_title", "MARGINS");
        _ = try p.spacer("margins_gap", 1, 8);
        try t.kv_line(p, "forage", "Forage", "1.7e \u{2192} 1.4e", th.good);
        try t.sentence(p, "coverage", "Food lasts ", "3.2d", ".", th.fg);
    } else if (eq(name, "table")) {
        // The pieces BUILD's table composes: a header row of labels, and body rows of cells.
        const demo = try stage.div("table_demo");
        _ = demo.with_flow(.{ .dir = .column });
        const h = try t.table_row(demo, "header", 8, 6, 4);
        try t.table_header_cell(h, "recipe", 150, "RECIPE");
        try t.table_header_cell(h, "inputs", 110, "INPUTS");
        try t.table_header_cell(h, "state", 90, "STATE");
        const r1 = try t.table_row(demo, "r1", 8, 6, 5);
        try t.table_cell(r1, "recipe", 150, "Reinforced Timber Frame", th.fg, false);
        try t.table_cell(r1, "inputs", 110, "12mi 4me", th.dim, false);
        try t.table_cell(r1, "state", 90, "ready", th.good, true);
        const r2 = try t.table_row(demo, "r2", 8, 6, 5);
        try t.table_cell(r2, "recipe", 150, "Kiln", th.fg, false);
        try t.table_cell(r2, "inputs", 110, "30mi", th.dim, false);
        try t.table_cell(r2, "state", 90, "reach 60%", th.warn, true);
    } else if (eq(name, "browser_heading")) {
        const demo = try stage.div("heading_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        _ = try t.browser_heading(demo, "bh", "ACTIONS", "What will the settlement do now?", "20 VERBS");
    } else if (eq(name, "tile_lanes")) {
        const demo = try stage.div("lanes_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        const grid = try t.tile_lanes(demo, "grid", false, 10);
        _ = try t.button(grid.lanes[0], "a", "first tile, left lane", true);
        _ = try t.button(grid.lanes[1], "b", "second tile, right lane", true);
        _ = try t.button(grid.lanes[0], "c", "third tile, left again", true);
    } else if (eq(name, "copy")) {
        const demo = try stage.div("copy_demo");
        _ = demo.with_flow(.{ .dir = .column }).with_gap(6);
        _ = try t.headline(demo, "h", "Two others asked to move in.");
        _ = try t.lede(demo, "l", "You are not alone here anymore. Act I ends, and the settlement begins with whoever walked in.", 320);
        _ = try t.summary_line(demo, "s", "20 of 20 actions shown");
        _ = try t.empty_line(demo, "e", "No action matches your search.");
    } else {
        _ = try stage.text("unknown", "(unknown template)");
    }
    return null;
}

/// Build the sample trade dialog used by both its standalone audit entry and the complete Act-I
/// page. `audit_trade` lives on the debug root, so dismissal persists after the overlay disappears.
fn auditTradeOverlay(ctx: *UiCtx, audit_trade: *uic.UiState.TradeState) !?*Node {
    if (!audit_trade.open) return null;
    const act: u8 = 1;

    const food_word = ha.roster.Resource.food.wordIn(act);
    const biomass_word = ha.roster.Resource.biomass.wordIn(act);
    const buys = [_]t.TradeOffer{
        .{ .id = 1, .name = "Fishing rod", .detail = "unlocks Fish", .give = try ctx.arena.print("2 {s} + 8 {s}", .{ food_word, biomass_word }), .receive = "Fishing rod \u{00d7}1", .effect = "Fishing becomes available while you own it." },
        .{ .id = 2, .name = "Hatchet", .detail = "unlocks Split wood", .give = try ctx.arena.print("2 {s} + 6 {s}", .{ food_word, biomass_word }), .receive = "Hatchet \u{00d7}1", .effect = "Split wood becomes available while you own it." },
        .{ .id = 3, .name = "Preserved food", .detail = "10 food \u{00b7} keeps well", .give = try ctx.arena.print("8 {s}", .{biomass_word}), .receive = "Preserved food +10", .stock = 2 },
    };
    const sells = [_]t.TradeOffer{
        .{ .id = 11, .name = "Sandals", .detail = "your spare stock", .give = "Sandals \u{00d7}1", .receive = try ctx.arena.print("6 {s} + 5 {s}", .{ food_word, biomass_word }), .effect = try ctx.arena.print("The first pair earns the most. Their next Sandals offer falls to 3 {s} + 2 {s}.", .{ food_word, biomass_word }) },
        .{ .id = 12, .name = "Hatchet", .detail = "your spare stock", .give = "Hatchet \u{00d7}1", .receive = try ctx.arena.print("9 {s} + 8 {s}", .{ food_word, biomass_word }), .effect = "A spare is sold first; the Hatchet you use keeps granting Split wood." },
    };
    const holdings = [_]t.TradeHolding{
        .{ .label = ha.roster.Resource.food.labelIn(act), .value = "11.6" },
        .{ .label = ha.roster.Resource.biomass.labelIn(act), .value = "31" },
        .{ .label = "Sandals", .value = "\u{00d7}2" },
        .{ .label = "Hatchet", .value = "\u{00d7}2" },
        .{ .label = "Root cellar", .value = "\u{00d7}1" },
        .{ .label = "Leaf bed", .value = "\u{00d7}1" },
    };

    const result = try t.trade_dialog(ctx, "trade", .passerby, "1.8 DAYS LEFT", &buys, &sells, &holdings, audit_trade);
    if (result.dismissed) {
        audit_trade.open = false;
        return null;
    }
    return result.root;
}

/// Debug-only holdings: set the counts of the named goods and settle, so the verbs they
/// grant and the margins they move are derived exactly as in production.
fn fixtureGoods(world: *World, e: Entity, ctx: *UiCtx, counts: []const struct { []const u8, u32 }) void {
    const cat = &ctx.res.catalog;
    const goods = world.get(e, comp.Goods) orelse return;
    for (counts) |c| {
        if (cat.goodIndex(c[0])) |gi| goods.count[gi] = c[1];
    }
    ha.capital.settle(world, e, cat);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
