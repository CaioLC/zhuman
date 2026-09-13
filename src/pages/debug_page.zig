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
    "header",
    "log_view",
    "tabs",
    "view_nav",
    "select",
    "slider",
    "disclosure",
    "rail",
    "holdings",
    "action_tile",
    "actions_section",
    "build_section",
    "act_one_surface",
    "act_one_workspace",
    "act_one_page",
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
    // Unlike ordinary in-stage templates, the modal needs a persistent lifecycle so dismissing
    // it reveals the audit index instead of rebuilding an always-open local state next frame.
    const audit_trade = root.get().state(ctx, uic.UiState.TradeState);

    // --- the inspection stage: top-left, small, the selected template only ------------------
    // The whole page root is already `top_left`, so the padded wrap sits at the top-left; the
    // stage flows normally inside it (no extra absolute anchor, which would overlap siblings).
    // The selected template's name is shown highlighted in the right index, so no label here.
    const stage_wrap = try el.div(ctx, root, "stage_wrap");
    _ = stage_wrap.with_size(.grow, .{ .pct_of_parent = 1.0 }).with_flow(.{ .dir = .column }).with_gap(8)
        .with_style(.{style.pad(16)});
    const stage = try el.div(ctx, stage_wrap, "stage");
    _ = stage.with_flow(.{ .dir = .column }).with_gap(6);

    var overlay: ?*Node = null;
    overlay = try render_one(ctx, world, stage, entries[sel.active], audit_trade);

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
            audit_trade.open = eq(name, "trade_dialog");
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
fn render_one(ctx: *UiCtx, world: *World, stage: El, name: []const u8, audit_trade: *uic.UiState.TradeState) !?*Node {
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
    } else if (eq(name, "header")) {
        const demo = try el.div(ctx, stage, "header_demo");
        _ = demo.with_size(.{ .fixed = 620 }, .fit_children);
        const stocks = [_]t.Stock{
            .{ .abbrev = "Vi", .full = "Vigor", .value = "10/10" },
            .{ .abbrev = "Fo", .full = "Food", .value = "4", .danger = true },
            .{ .abbrev = "Ma", .full = "Materials", .value = "24" },
        };
        _ = try t.header(ctx, demo, "hud", .{
            .stocks = &stocks,
            .run = .{ .act_label = "Act I", .day = 3 },
        });
    } else if (eq(name, "log_view")) {
        try t.log_view(ctx, stage, "feed", &ctx.res.sim.log, 400, 4);
    } else if (eq(name, "tabs")) {
        _ = try t.tabs(ctx, stage, "tabs", &.{ "ACTIONS", "BUILD" });
    } else if (eq(name, "view_nav")) {
        _ = try t.view_nav(ctx, stage, "vn", &.{ "ACTIONS", "BUILD" });
    } else if (eq(name, "select")) {
        _ = try t.select(ctx, stage, "sel", "Sort", &.{ "reach", "inputs", "time", "name" }, true);
    } else if (eq(name, "slider")) {
        const demo = try el.div(ctx, stage, "slider_demo");
        _ = demo.with_size(.{ .fixed = 300 }, .fit_children);
        _ = try t.slider(ctx, demo, .{
            .id = "sld",
            .label = "Eating policy",
            .value = 50,
            .min = 0,
            .max = 100,
            .step = 1,
        });
    } else if (eq(name, "disclosure")) {
        // The production disclosure lives in a definite milestone column. Mirror that here;
        // percentage width under the audit stage's intrinsic width would collapse its stamped
        // hit rect even though the right-anchored affordance still paints outside it.
        const demo = try el.div(ctx, stage, "disclosure_demo");
        _ = demo.with_size(.{ .fixed = 420 }, .fit_children);
        const d = try t.disclosure(ctx, demo, "disc", "Disclosure summary", true);
        if (d.details) |det| _ = try el.text(ctx, det, "dt", "hidden detail, now shown");
    } else if (eq(name, "rail")) {
        // Production supplies a definite page-grid rail region. Mirror it here so one
        // interactive instance can be inspected in both states via its own toggle.
        const demo = try el.div(ctx, stage, "rail_demo");
        _ = demo.with_size(.{ .fixed = ha.tokens.rail.expanded }, .{ .fixed = 300 });
        const r = try t.rail(ctx, demo, .{ .id = "rail", .label = "HOLDINGS" });
        if (r.body) |rb| _ = try el.text(ctx, rb, "rb", "rail body");
    } else if (eq(name, "holdings")) {
        if (player.get()) |a| {
            // A coherent debug-only four-kind/six-unit fixture matching the reference anatomy.
            // Values remain ordinary live ECS data; the component performs all projections.
            if (world.get(a[0], comp.Sandals)) |held| held.count = 2 else world.add(a[0], comp.Sandals{ .count = 2 });
            if (world.get(a[0], comp.RootCellar)) |held| held.count = 1 else world.add(a[0], comp.RootCellar{});
            if (world.get(a[0], comp.LeafBed)) |held| held.count = 1 else world.add(a[0], comp.LeafBed{});
            if (world.get(a[0], comp.Hatchet)) |held| held.count = 2 else world.add(a[0], comp.Hatchet{ .count = 2 });
            if (world.get(a[0], comp.ActionForage)) |forage| forage.requires.energy = (comp.ActionForage{}).requires.energy * 0.85;
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

            const demo = try el.div(ctx, stage, "holdings_demo");
            _ = demo.with_size(.{ .fixed = ha.tokens.rail.expanded }, .{ .fixed = 400 });
            const r = try t.rail(ctx, demo, .{ .id = "holdings_rail", .label = "HOLDINGS" });
            if (r.body) |body| _ = try t.holdings(ctx, body, world, a[0], "content");
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "action_tile")) {
        if (player.get()) |a| {
            _ = try t.action_tile(ctx, stage, world, a[0], comp.ActionForage, "at", "Forage", actions.action_forage);
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "actions_section")) {
        if (player.get()) |a| {
            // The live debug player starts with only the two innate verbs. Grant canonical
            // unlocked components in this debug-only world so the assembly audit represents
            // the complete five-verb reference; production still follows capital unlocks.
            if (!world.has(a[0], comp.ActionChopWood)) world.add(a[0], comp.ActionChopWood{});
            if (!world.has(a[0], comp.ActionFish)) world.add(a[0], comp.ActionFish{});
            if (!world.has(a[0], comp.ActionCheckTraps)) world.add(a[0], comp.ActionCheckTraps{});
            const demo = try el.div(ctx, stage, "actions_demo");
            _ = demo.with_size(.{ .fixed = 620 }, .fit_children);
            _ = try t.actions_section(ctx, demo, world, a[0], "actions");
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "build_section")) {
        if (player.get()) |a| {
            // Give the debug-only catalog a representative stock level so ready and reach rows
            // appear together, matching the reference anatomy without changing production.
            if (world.get(a[0], comp.InventoryMaterial)) |stock| stock.v = 31;
            _ = try t.build_section(ctx, stage, world, a[0], "build");
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "act_one_surface")) {
        if (player.get()) |a| {
            // One interactive composition only: both authored sections switch beneath the same
            // nav and context strips. Debug grants the canonical unlocks/materials without
            // changing production progression.
            if (!world.has(a[0], comp.ActionChopWood)) world.add(a[0], comp.ActionChopWood{});
            if (!world.has(a[0], comp.ActionFish)) world.add(a[0], comp.ActionFish{});
            if (!world.has(a[0], comp.ActionCheckTraps)) world.add(a[0], comp.ActionCheckTraps{});
            if (world.get(a[0], comp.InventoryMaterial)) |stock| stock.v = 31;
            const demo = try el.div(ctx, stage, "surface_demo");
            _ = demo.with_size(.{ .fixed = 652 }, .fit_children);
            _ = try t.act_one_surface(ctx, demo, world, a[0], "surface", .{
                .activity = .{
                    .state = .working,
                    .subject = "Forage",
                    .metadata = "2h left",
                    .last = .working,
                },
            });
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "act_one_workspace")) {
        if (player.get()) |a| {
            // Populate the debug-only actor with the reference's representative holdings and
            // unlocked verbs; production remains entirely progression-driven.
            if (!world.has(a[0], comp.ActionChopWood)) world.add(a[0], comp.ActionChopWood{});
            if (!world.has(a[0], comp.ActionFish)) world.add(a[0], comp.ActionFish{});
            if (!world.has(a[0], comp.ActionCheckTraps)) world.add(a[0], comp.ActionCheckTraps{});
            if (world.get(a[0], comp.ActionForage)) |forage| forage.requires.energy = 1.7;
            if (world.get(a[0], comp.InventoryMaterial)) |stock| stock.v = 31;
            if (world.get(a[0], comp.Sandals)) |held| held.count = 2 else world.add(a[0], comp.Sandals{ .count = 2 });
            if (world.get(a[0], comp.RootCellar)) |held| held.count = 1 else world.add(a[0], comp.RootCellar{});
            if (world.get(a[0], comp.LeafBed)) |held| held.count = 1 else world.add(a[0], comp.LeafBed{});
            if (world.get(a[0], comp.Hatchet)) |held| held.count = 2 else world.add(a[0], comp.Hatchet{ .count = 2 });

            const demo = try el.div(ctx, stage, "workspace_demo");
            _ = demo.with_size(.{ .fixed = 926 }, .{ .fixed = 700 });
            _ = try t.act_one_workspace(ctx, demo, world, a[0], "workspace", .{
                .activity = .{
                    .state = .working,
                    .subject = "Forage",
                    .metadata = "2h left",
                    .last = .working,
                },
            });
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "act_one_page")) {
        if (player.get()) |a| {
            // One large reference composition: shared shell rows around one live workspace.
            // Debug-only grants make the authored five-verb/holdings state visible; production
            // continues to derive every stock, unlock, activity, and log line from live state.
            if (!world.has(a[0], comp.ActionChopWood)) world.add(a[0], comp.ActionChopWood{});
            if (!world.has(a[0], comp.ActionFish)) world.add(a[0], comp.ActionFish{});
            if (!world.has(a[0], comp.ActionCheckTraps)) world.add(a[0], comp.ActionCheckTraps{});
            if (world.get(a[0], comp.ActionForage)) |forage| forage.requires.energy = 1.7;
            if (world.get(a[0], comp.InventoryMaterial)) |stock| stock.v = 31;
            if (world.get(a[0], comp.InventoryFood)) |food| food.v = 11.6;
            if (world.get(a[0], comp.Vigor)) |vigor| {
                vigor.max = 15;
                vigor.v = 14;
            }
            if (world.get(a[0], comp.Sandals)) |held| held.count = 2 else world.add(a[0], comp.Sandals{ .count = 2 });
            if (world.get(a[0], comp.RootCellar)) |held| held.count = 1 else world.add(a[0], comp.RootCellar{});
            if (world.get(a[0], comp.LeafBed)) |held| held.count = 1 else world.add(a[0], comp.LeafBed{});
            if (world.get(a[0], comp.Hatchet)) |held| held.count = 2 else world.add(a[0], comp.Hatchet{ .count = 2 });

            const demo = try el.div(ctx, stage, "act_one_page_demo");
            _ = demo.with_size(.{ .fixed = 900 }, .{ .fixed = 820 })
                .with_overflow(.clip)
                .with_style(.{Style{ .fill = th.bg }});
            const regions = try t.shell_content(ctx, demo, demo, .{
                .id = "act_one_page",
                .act = .act_one,
                .page_pad = ha.tokens.pad_page,
                .section_gap = ha.tokens.gap.section,
                .footer = true,
            });
            const stocks = [_]t.Stock{
                .{ .abbrev = "Vi", .full = "Vigor", .value = "14/15" },
                .{ .abbrev = "Fo", .full = "Food", .value = "11.6" },
                .{ .abbrev = "Ma", .full = "Materials", .value = "31" },
            };
            _ = try t.header(ctx, regions.header, "hud", .{
                .stocks = &stocks,
                .run = .{ .act_label = "Act I", .day = 19 },
            });
            _ = try t.act_one_workspace(ctx, regions.body, world, a[0], "workspace", .{
                .activity = .{
                    .state = .idle,
                    .subject = "no work in progress",
                    .metadata = "ready",
                    .last = .idle,
                },
            });

            var feed: ha.log.Log = .{};
            feed.push(.normal, "You return with 4 materials.");
            feed.push(.good, "The Root cellar slows what the larder loses.");
            feed.push(.normal, "You finish a second Hatchet. One is effect; one is stock.");
            feed.push(.normal, "Someone is walking the shoreline. Their pack carries made goods.");
            if (regions.footer) |footer| {
                try t.log_view(ctx, footer, "feed", &feed, 900 - 2 * ha.tokens.pad_page, 4);
            }
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "eating_policy")) {
        const demo = try el.div(ctx, stage, "eating_policy_demo");
        _ = demo.with_size(.{ .fixed = 300 }, .fit_children);
        _ = try t.eating_policy(ctx, demo, "ep", 50, true);
    } else if (eq(name, "capital_row")) {
        if (player.get()) |a| {
            _ = try t.capital_row(ctx, stage, world, a[0], comp.Sandals, "cr", .ready, 1.0);
        } else {
            _ = try el.text(ctx, stage, "na", "(needs a live player)");
        }
    } else if (eq(name, "catalog_controls")) {
        _ = try t.catalog_controls(ctx, stage, "cc", &.{ "reach", "inputs", "time", "name" });
    } else if (eq(name, "milestone_goal")) {
        const demo = try el.div(ctx, stage, "milestone_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        const requirements = [_]t.MilestoneRequirement{
            .{ .label = "VIGOR", .value = "14/15" },
            .{ .label = "FOOD", .value = "11.6/12" },
            .{ .label = "RECIPES", .value = "4/5" },
            .{ .label = "MATERIALS", .value = "31/60" },
        };
        _ = try t.milestone_goal(ctx, demo, "mg", .{
            .state = .locked,
            .title = "Shelter",
            .summary = "materials 31/60",
            .readiness = "not ready \u{00B7} 1 condition",
            .kicker = "A PLACE FOR OTHERS",
            .cost = "60m 6e \u{00B7} 6.0d",
            .copy = "a roof with room for four. you're not alone anymore.",
            .requirements = &requirements,
            .explanation = "Hold 60 materials with a settled body and four kinds of goods.",
            .action = "NOT READY",
        });
    } else if (eq(name, "market_strip")) {
        const demo = try el.div(ctx, stage, "market_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        _ = try t.market_strip(ctx, demo, "ms", .passerby);
    } else if (eq(name, "activity_strip")) {
        const demo = try el.div(ctx, stage, "activity_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        _ = try t.activity_strip(ctx, demo, "as", .idle, "no work in progress", "ready", .idle);
    } else if (eq(name, "trade_dialog")) {
        if (!audit_trade.open) return null;
        const buys = [_]t.TradeOffer{
            .{ .name = "Fishing net", .detail = "better Fish tool", .give = "12 food + 16 materials", .receive = "Fishing net \u{00d7}1", .effect = "Replaces Fishing rod: Fish yield 1\u{2013}3 \u{2192} 2\u{2013}5. The unlock does not stack." },
            .{ .name = "Hand axe", .detail = "better wood tool", .give = "8 food + 24 materials", .receive = "Hand axe \u{00d7}1", .effect = "Replaces Hatchet margins: Split wood takes 20% less energy." },
            .{ .name = "Preserved food", .detail = "10 food \u{00b7} keeps well", .give = "8 materials", .receive = "Preserved food +10", .stock = 2 },
        };
        const sells = [_]t.TradeOffer{
            .{ .name = "Sandals", .detail = "your spare stock", .give = "Sandals \u{00d7}1", .receive = "6 food + 5 materials", .effect = "The first pair earns the most. Their next Sandals offer falls to 3 food + 2 materials." },
            .{ .name = "Hatchet", .detail = "your spare stock", .give = "Hatchet \u{00d7}1", .receive = "9 food + 8 materials", .effect = "A spare is sold first; the Hatchet you use keeps granting Split wood." },
        };
        const holdings = [_]t.TradeHolding{
            .{ .label = "Food", .value = "11.6" },
            .{ .label = "Materials", .value = "31" },
            .{ .label = "Sandals", .value = "\u{00d7}2" },
            .{ .label = "Hatchet", .value = "\u{00d7}2" },
            .{ .label = "Root cellar", .value = "\u{00d7}1" },
            .{ .label = "Leaf bed", .value = "\u{00d7}1" },
        };
        var overlay_root: *Node = undefined;
        const result = try t.trade_dialog(ctx, "trade", .passerby, "1.8 DAYS LEFT", &buys, &sells, &holdings, audit_trade, &overlay_root);
        if (result.dismissed) {
            audit_trade.open = false;
            return null;
        }
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
