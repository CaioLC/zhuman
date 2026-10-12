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
    "tooltip",
    "tag",
    "cost_list",
    "legend",
    "zoom_controls",
    "empty_state",
};

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
        if (sel.active >= entries.len) sel.active = 0;
        break :blk sel.active;
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
            audit_trade.open = eq(name, "trade_dialog");
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
    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };

    if (eq(name, "button")) {
        _ = try t.button(stage, "b_on", "Enabled", true);
        _ = try t.button(stage, "b_off", "Disabled", false);
    } else if (eq(name, "panel")) {
        const p = try t.panel(stage, "p", "Panel Title");
        _ = try p.text("body", "panel body content");
    } else if (eq(name, "row")) {
        const r = try t.row(stage, "r");
        _ = try r.text("a", "one");
        _ = try r.text("b", "two");
        _ = try r.text("c", "three");
    } else if (eq(name, "stat")) {
        _ = try t.stat(stage, "s1", "Materials", "24");
        _ = try t.stat(stage, "s2", "Food", "4");
    } else if (eq(name, "figure")) {
        try t.figure(stage, t.fig_robust, th.acc);
        try t.figure(stage, t.fig_weary, th.warn);
    } else if (eq(name, "actor_status")) {
        if (player.get()) |a| {
            const s = t.actor_status(th, a[1], ctx.res.config);
            _ = (try stage.text("st", s.word)).with_style(.{Style{ .text = s.color }});
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "stock_token")) {
        try t.stock_token(stage, "tok", .{ .abbrev = "Vi", .full = "Vigor", .value = "3/10", .tone = .warn });
    } else if (eq(name, "stockline")) {
        const stocks = [_]t.Stock{
            .{ .abbrev = "Vi", .full = "Vigor", .value = "10/10" },
            .{ .abbrev = "Fo", .full = "Food", .value = "4", .tone = .danger },
            .{ .abbrev = "Ma", .full = "Materials", .value = "24" },
        };
        _ = try t.stockline(stage, "sl", &stocks);
    } else if (eq(name, "runline")) {
        _ = try t.runline(stage, "run", .{ .act_label = "Act I", .day = 3 });
    } else if (eq(name, "header")) {
        const demo = try stage.div("header_demo");
        _ = demo.with_size(.{ .fixed = 620 }, .fit_children);
        const stocks = [_]t.Stock{
            .{ .abbrev = "Vi", .full = "Vigor", .value = "10/10" },
            .{ .abbrev = "Fo", .full = "Food", .value = "4", .tone = .danger },
            .{ .abbrev = "Ma", .full = "Materials", .value = "24" },
        };
        _ = try t.header(demo, "hud", .{
            .stocks = &stocks,
            .run = .{ .act_label = "Act I", .day = 3 },
        });
    } else if (eq(name, "log_view")) {
        try t.log_view(stage, "feed", &ctx.res.sim.log, 400, 4);
    } else if (eq(name, "tabs")) {
        _ = try t.tabs(stage, "tabs", &.{ "ACTIONS", "BUILD" }, null);
    } else if (eq(name, "view_nav")) {
        _ = try t.view_nav(stage, "vn", &.{ "ACTIONS", "BUILD" });
    } else if (eq(name, "select")) {
        _ = try t.select(stage, "sel", "Sort", &.{ "reach", "inputs", "time", "name" }, true, null);
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
    } else if (eq(name, "disclosure")) {
        // The production disclosure lives in a definite milestone column. Mirror that here;
        // percentage width under the audit stage's intrinsic width would collapse its stamped
        // hit rect even though the right-anchored affordance still paints outside it.
        const demo = try stage.div("disclosure_demo");
        _ = demo.with_size(.{ .fixed = 420 }, .fit_children);
        const d = try t.disclosure(demo, "disc", "Disclosure summary", true, null);
        if (d.details) |det| _ = try det.text("dt", "hidden detail, now shown");
    } else if (eq(name, "rail")) {
        // Production supplies a definite page-grid rail region. Mirror it here so one
        // interactive instance can be inspected in both states via its own toggle.
        const demo = try stage.div("rail_demo");
        _ = demo.with_size(.{ .fixed = ha.tokens.rail.expanded }, .{ .fixed = 300 });
        const r = try t.rail(demo, .{ .id = "rail", .label = "HOLDINGS" });
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
            const r = try t.rail(demo, .{ .id = "holdings_rail", .label = "HOLDINGS" });
            if (r.body) |body| _ = try t.holdings(body, world, a[0], "content");
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "action_tile")) {
        if (player.get()) |a| {
            const forage = ctx.res.catalog.actionIndex("forage").?;
            if (try t.action_tile(stage, world, a[0], forage, "at")) |tl| {
                if (tl.clicked) actions.begin(world, a[0], ctx.res, forage);
            }
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "actions_section")) {
        if (player.get()) |a| {
            // The live debug player starts with only the two innate verbs. Grant canonical
            // unlocked components in this debug-only world so the assembly audit represents
            // the complete five-verb reference; production still follows capital unlocks.
            if (!world.has(a[0], comp.ActionChopWood)) world.add(a[0], comp.ActionChopWood{});
            if (!world.has(a[0], comp.ActionFish)) world.add(a[0], comp.ActionFish{});
            if (!world.has(a[0], comp.ActionCheckTraps)) world.add(a[0], comp.ActionCheckTraps{});
            const demo = try stage.div("actions_demo");
            _ = demo.with_size(.{ .fixed = 620 }, .fit_children);
            _ = try t.actions_section(demo, world, a[0], "actions");
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "build_section")) {
        if (player.get()) |a| {
            // Give the debug-only catalog a representative stock level so ready and reach rows
            // appear together, matching the reference anatomy without changing production.
            if (world.get(a[0], comp.InventoryMaterial)) |stock| stock.v = 31;
            _ = try t.build_section(stage, world, a[0], "build", null, null);
        } else {
            _ = try stage.text("na", "(needs a live player)");
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
            const demo = try stage.div("surface_demo");
            _ = demo.with_size(.{ .fixed = 652 }, .fit_children);
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
            if (world.get(a[0], comp.InventoryMaterial)) |stock| stock.v = 31;

            const demo = try stage.div("workspace_demo");
            _ = demo.with_size(.{ .fixed = 926 }, .{ .fixed = 700 });
            _ = try t.act_one_workspace(demo, world, a[0], "workspace", .{
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
    } else if (eq(name, "act_one_page")) {
        if (player.get()) |a| {
            // One large reference composition: shared shell rows around one live workspace.
            // Debug-only grants make the authored five-verb/holdings state visible; production
            // continues to derive every stock, unlock, activity, and log line from live state.
            fixtureGoods(world, a[0], ctx, &.{ .{ "sandals", 2 }, .{ "root_cellar", 1 }, .{ "leaf_bed", 1 }, .{ "hatchet", 2 }, .{ "fish_rod", 1 }, .{ "wire_snares", 1 } });
            if (world.get(a[0], comp.InventoryMaterial)) |stock| stock.v = 31;
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
                .{ .abbrev = "Vi", .full = "Vigor", .value = "14/15" },
                .{ .abbrev = "Fo", .full = "Food", .value = "11.6" },
                .{ .abbrev = "Ma", .full = "Materials", .value = "31" },
            };
            _ = try t.header(regions.header, "hud", .{
                .stocks = &stocks,
                .run = .{ .act_label = "Act I", .day = 19 },
            });
            const workspace = try t.act_one_workspace(regions.body, world, a[0], "workspace", .{
                .activity = .{
                    .state = .idle,
                    .subject = "no work in progress",
                    .metadata = "ready",
                    .last = .idle,
                },
            });
            if (workspace.surface.market_action.consume(.clicked)) audit_trade.open = true;

            var feed: ha.log.Log = .{};
            feed.push(.normal, "You return with 4 materials.");
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
                _ = try t.capital_row(stage, world, a[0], q, .ready);
            }
        } else {
            _ = try stage.text("na", "(needs a live player)");
        }
    } else if (eq(name, "catalog_controls")) {
        _ = try t.catalog_controls(stage, "cc", &.{ "reach", "inputs", "time", "name" }, null, null);
    } else if (eq(name, "milestone_goal")) {
        const demo = try stage.div("milestone_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        const requirements = [_]t.MilestoneRequirement{
            .{ .label = "VIGOR", .value = "14/15" },
            .{ .label = "FOOD", .value = "11.6/12" },
            .{ .label = "RECIPES", .value = "4/5" },
            .{ .label = "MATERIALS", .value = "31/60" },
        };
        _ = try t.milestone_goal(demo, "mg", .{
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
        const demo = try stage.div("market_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        _ = try t.market_strip(demo, "ms", .passerby);
    } else if (eq(name, "activity_strip")) {
        const demo = try stage.div("activity_demo");
        _ = demo.with_size(.{ .fixed = 608 }, .fit_children);
        _ = try t.activity_strip(demo, "as", .idle, "no work in progress", "ready", .idle);
    } else if (eq(name, "trade_dialog")) {
        return auditTradeOverlay(ctx, audit_trade);
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
    } else if (eq(name, "tag")) {
        _ = try t.tag(stage, "tg", "crude");
    } else if (eq(name, "cost_list")) {
        const costs = [_]t.Cost{ .{ .label = "Biomass", .amount = "80" }, .{ .label = "Minerals", .amount = "40" } };
        _ = try t.cost_list(stage, "cl", &costs);
    } else if (eq(name, "legend")) {
        const items = [_]t.LegendItem{
            .{ .resource = .food, .label = "Food" },
            .{ .resource = .metal, .label = "Metal" },
            .{ .resource = .biomass, .label = "Biomass" },
        };
        _ = try t.legend(stage, "lg", &items);
    } else if (eq(name, "zoom_controls")) {
        _ = try t.zoom_controls(stage, "zc");
    } else if (eq(name, "empty_state")) {
        _ = try t.empty_state(stage, "es", "Nothing here yet.", "Try widening the filter.");
    } else {
        _ = try stage.text("unknown", "(unknown template)");
    }
    return null;
}

/// Build the sample trade dialog used by both its standalone audit entry and the complete Act-I
/// page. `audit_trade` lives on the debug root, so dismissal persists after the overlay disappears.
fn auditTradeOverlay(ctx: *UiCtx, audit_trade: *uic.UiState.TradeState) !?*Node {
    if (!audit_trade.open) return null;

    const buys = [_]t.TradeOffer{
        .{ .id = 1, .name = "Fishing net", .detail = "better Fish tool", .give = "12 food + 16 materials", .receive = "Fishing net \u{00d7}1", .effect = "Replaces Fishing rod: Fish yield 1\u{2013}3 \u{2192} 2\u{2013}5. The unlock does not stack." },
        .{ .id = 2, .name = "Hand axe", .detail = "better wood tool", .give = "8 food + 24 materials", .receive = "Hand axe \u{00d7}1", .effect = "Replaces Hatchet margins: Split wood takes 20% less energy." },
        .{ .id = 3, .name = "Preserved food", .detail = "10 food \u{00b7} keeps well", .give = "8 materials", .receive = "Preserved food +10", .stock = 2 },
    };
    const sells = [_]t.TradeOffer{
        .{ .id = 11, .name = "Sandals", .detail = "your spare stock", .give = "Sandals \u{00d7}1", .receive = "6 food + 5 materials", .effect = "The first pair earns the most. Their next Sandals offer falls to 3 food + 2 materials." },
        .{ .id = 12, .name = "Hatchet", .detail = "your spare stock", .give = "Hatchet \u{00d7}1", .receive = "9 food + 8 materials", .effect = "A spare is sold first; the Hatchet you use keeps granting Split wood." },
    };
    const holdings = [_]t.TradeHolding{
        .{ .label = "Food", .value = "11.6" },
        .{ .label = "Materials", .value = "31" },
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
