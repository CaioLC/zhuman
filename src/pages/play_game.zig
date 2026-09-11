/// The live HUD while the actor is alive. The header is a thin strip: run context
/// ("Act I · Day N") pinned right — the game's name belongs to a future title screen,
/// and actor condition reads from the vitals/theme, not a header badge. The event log
/// rides as a bottom-anchored footer; the body sections (resources, actions) return one
/// at a time as the shelf grows.
const std = @import("std");
// general lib ECS
const ha = @import("ha");
const ecs = ha.ecs;
const comp = ha.comp;
const tag = ha.tag;
const actions = ha.actions;
const World = ha.world.World;
const Entity = ha.world.Entity;
// Ui Interface
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const Node = uic.Node;
// Game templates + helpers
const t = @import("./templates/root.zig");

pub const PlayTrees = struct { root: *Node, overlay: ?*Node = null };

pub fn ui_playgame(ctx: *uic.UiCtx, world: *World) !PlayTrees {
    // ACT1-07: the Act I HUD is composed entirely from the shared terminal shell (KIT-04) —
    // header, the optional Passerby (market) and activity strips, the persistent Holdings rail,
    // the main body (ACTIONS/BUILD), and the four-line footer log. The **same** shell chrome is
    // built whether or not the run is underway; only the body's centre content differs (the
    // pre-first-action teaching card vs the tabbed surfaces), so the first click cannot drift the
    // layout — the terminal box, header, strips, rail region, and footer stay put.
    const compact = ctx.res.view.metrics.width_class.atMost(.w560);
    const page_pad: f32 = if (compact) ha.tokens.pad_page_compact else ha.tokens.pad_page;
    const regions = try t.shell(ctx, .{
        .id = "play",
        .act = .act_one,
        .page_pad = page_pad,
        .section_gap = ha.tokens.gap.section,
        .rail = true,
        .market = true,
        .activity = true,
        .footer = true,
    });
    const header = regions.header;
    const body = regions.body;

    // Left: the always-on V/F/M stock summary (skipped once the actor is gone).
    var overlay: ?*Node = null; // ACT1-17: the trade dialog's own overlay root, when open
    var trade_ts: ?*uic.UiState.TradeState = null; // the market strip's open/mode/sel state
    const q = ecs.MaybeSingle(.{
        Entity, comp.Vigor, comp.InventoryFood, comp.InventoryMaterial, ecs.With(tag.Player),
    }){ .world = world };
    if (q.get()) |a| {
        const e, const vigor, const food, const materials = a;
        // KIT-12: the stockline is a row of StockTokens whose order/membership is this act's
        // descriptor. Act I lists Vigor/Food/Materials; each token shows a two-letter abbrev
        // (full label on hover/focus), tints danger on a low/zero value, and keeps a stable
        // footprint (fixed cell) so a swap never shifts its neighbors. The values are formatted
        // here (the token owns no domain math).
        var vbuf: [24]u8 = undefined;
        var fbuf: [24]u8 = undefined;
        var mnum: [16]u8 = undefined;
        const vtxt = std.fmt.bufPrint(&vbuf, "{d:.0}/{d:.0}", .{ vigor.v, vigor.max }) catch "?";
        const ftxt = std.fmt.bufPrint(&fbuf, "{d:.0}", .{food.v}) catch "?";
        const mtxt = @import("./fmt.zig").fmt_num(&mnum, materials.v);
        const vcond = ctx.res.config.condition(vigor.v / vigor.max);
        const stocks = [_]t.Stock{
            .{ .abbrev = "Vi", .full = "Vigor", .value = vtxt, .danger = vcond == .spent },
            .{ .abbrev = "Fo", .full = "Food", .value = ftxt, .danger = food.v <= 0 },
            .{ .abbrev = "Ma", .full = "Materials", .value = mtxt, .danger = false },
        };
        const bar = try t.stockline(ctx, header, "stocks", &stocks);
        _ = bar.with_layout(.bottom_left);

        // ACT1-07/17: the Passerby (market) strip fills the shell's market region in both the
        // pre-tutorial and underway states. The strip's Hail button opens the TradeDialog when a
        // passerby is actually present (ACT1-12 `dealable`); the dialog is built last, below, as
        // its own overlay root. The open flag rides on a `TradeState` keyed to the (stable) market
        // strip node, so it survives the frame-arena rebuild.
        if (regions.market) |market_region| {
            const kind: t.MarketKind = .passerby;
            const strip = try t.market_strip(ctx, market_region, "passerby", kind);
            trade_ts = strip.get().state(ctx, uic.UiState.TradeState);
            if (strip.consume(.clicked) and ctx.res.sim.encounter.dealable()) {
                trade_ts.?.open = true;
            }
        }
        if (regions.activity) |activity| {
            const busy = world.get(e, comp.Busy);
            const act_state: t.ActivityState = if (busy) |b|
                (if (actions.is_build(b.doing)) .building else .working)
            else
                .idle;
            const subject: []const u8 = if (busy) |b| actions.doing_label(b.doing) else "resting";
            _ = try t.activity_strip(ctx, activity, "activity", act_state, subject, "", act_state);
        }

        // --- center. Before the very first resolved action (GameState.tutorial_done),
        // the teaching card stands alone — no tabs, no Eat, no Build: one thing to
        // learn, one thing to click. The first click unfolds the full center: tabbed
        // action families — ACTIONS (production: flows you repeat) and BUILD (capital:
        // pay once, own a thing that changes which flows exist). The tab switch itself
        // enacts the now-vs-later margin; selection persists in the strip's TabsState.
        if (!ctx.res.sim.tutorial_done) {
            if (try t.action_card(ctx, body, world, e, comp.ActionForage, "gather", "Forage", actions.action_forage)) |card| {
                _ = card.with_layout(.center);
            }
        } else {
            // `.cross = .start`: the strip left-aligns over the content's edge — the
            // classic tab silhouette — instead of floating centered above it.
            const center = try el.div(ctx, body, "center");
            _ = center.with_layout(.center).with_flow(.{ .dir = .column, .cross = .start }).with_gap(10);
            // KIT-07: the shared view navigation drives which body view builds. Exactly one
            // tab is selected + globally focusable, arrows rove within it, Enter/Space switches;
            // the inactive view is not built but its pooled state is retained below.
            const tb = try t.view_nav(ctx, center, "tabs", &.{ "ACTIONS", "BUILD" });
            if (tb.active == 0) {
                // KIT-07 / ACT1-09: retain the inactive BUILD view's search/sort state so
                // returning to it restores exactly where it was. The BUILD tab's state now lives
                // in a `CatalogState` on its controls node (`build_list` → "buildlist" → the KIT-15
                // controls "build_ctl"), so retain that nested key — the view's nodes are not
                // built while ACTIONS is active, and pool retention ends the moment we stop asking.
                const build_key = ha.ui.key(center.get().key, "buildlist");
                const ctl_key = ha.ui.key(build_key, "build_ctl");
                _ = ctx.retainState(ctl_key, uic.UiState.CatalogState);
                // The search text lives in the field's own editor state, nested under the
                // controls' first row ("build_ctl" → "row" → "search").
                const row_key = ha.ui.key(ctl_key, "row");
                _ = ctx.retainState(ha.ui.key(row_key, "search"), uic.UiState.TextInputState);

                // ACT1-08: the finalized ACTIONS surface is exactly the five verbs of the
                // catalog's Act I surface — Forage, Scavenge, Split wood, Fish, Check traps —
                // in authored order, plus the Eating Policy, laid out as a two-column grid (one
                // column at ≤440). Hunt exists as a component but is off the Act I surface
                // (`catalog`), so it is deliberately not rendered here. Tile metrics/bands derive
                // from the live records (KIT-17), so this is presentation, not duplicated numbers.
                const one_col = ctx.res.view.metrics.width_class.atMost(.w440);
                const grid_w: f32 = if (one_col) 300 else 620; // 1 vs 2 columns of ~300px tiles
                const acts = try el.div(ctx, center, "acts");
                _ = acts.with_size(.{ .fixed = grid_w }, .fit_children)
                    .with_flow(.{ .dir = .row, .wrap = true, .cross = .start }).with_gap(12);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionForage, "forage_t", "Forage", actions.action_forage);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionScavenge, "scav_t", "Scavenge", actions.action_scavenge);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionChopWood, "chop_t", "Split wood", actions.action_chop_wood);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionFish, "fish_t", "Fish", actions.action_fish);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionCheckTraps, "traps_t", "Check traps", actions.action_check_traps);
                // Eating Policy sits in the grid alongside the action tiles — the metabolism
                // loop runs regardless; the dial sets its standing rate.
                _ = try t.ration_dial(ctx, acts, world, e, "ration");
            } else {
                _ = try t.build_list(ctx, center, world, e, "buildlist");
            }
        }

        // KIT-05 / ACT1-07: Holdings lives in the collapsible rail (the shell's left region),
        // present in **both** states so the chrome never shifts — before the first action it
        // reads "nothing built yet", after it lists what's owned. The first click swaps only the
        // body's centre (card → tabs), not the surrounding shell.
        if (regions.rail) |rail_region| {
            const r = try t.rail(ctx, rail_region, .{ .id = "holdings_rail", .label = "HOLDINGS" });
            if (r.body) |rb| _ = try t.holdings(ctx, rb, world, e, "holdings");
        }

        // ACT1-17: the TradeDialog. Built last, as its own overlay root (drawn on top), only while
        // open. Offers are built from live `market.Quote`s — buys from the passerby's satchel
        // wares, sells from the diminishing schedule for the player's surplus/goods — so BUY/SELL
        // tabs, stock, preview, and both `YOU GIVE` directions are authoritative, and a confirmed
        // offer routes straight to `ha.barter.resolve`. Header/Holdings/log refresh the same frame
        // because they read live world state after the resolve.
        overlay = try trade_overlay(ctx, world, e, trade_ts);
    }

    // KIT-12: the runline — energy rate (0 in Act I → omitted), act label, and day. VIEW-04
    // drops the optional act label at ≤560; the functional Day counter always stays.
    const day = 1 + @as(u64, @intFromFloat(ctx.res.sim.elapsed / ctx.res.config.secs_per_day));
    const run_line = try t.runline(ctx, header, "run", .{
        .act_label = "Act I",
        .day = day,
        .compact = compact,
    });
    _ = run_line.with_layout(.bottom_right);

    // --- footer: the event log, full width at the bottom, 4 lines tall (the shell's footer
    // region, bottom-anchored). log_view authors in logical px (VIEW-02); the content column
    // in logical is the terminal's logical width minus the page padding.
    if (regions.footer) |footer| {
        const content_w_logical = ctx.res.view.metrics.terminal.w - 2 * page_pad;
        try t.log_view(ctx, footer, "feed", &ctx.res.sim.log, content_w_logical, 4);
    }

    return .{ .root = regions.root.get(), .overlay = overlay };
}

const market = ha.market;
const barter = ha.barter;
const Ware = market.Ware;

/// A buy/sell offer paired with the authoritative `market.Quote` that backs it — the dialog shows
/// the strings, `resolve` runs the quote. Built into the frame arena.
const BackedOffer = struct { offer: t.TradeOffer, quote: market.Quote };

/// Format a bundle side into a short `NfF`, `NmM`, or tool-name string for the dialog.
fn wareLabel(w: Ware) []const u8 {
    return switch (w) {
        .food => "food",
        .materials => "materials",
        .fish_hook => "a fishing net",
        .whetstone => "a hand axe",
    };
}

fn bundleLabel(buf: []u8, b: *const market.Bundle) []const u8 {
    // A single-line summary of the bundle's lines: "2 food, 4m", or "a hand axe".
    var w: usize = 0;
    for (b.slice(), 0..) |line, i| {
        const sep = if (i == 0) "" else ", ";
        const piece = switch (line.item) {
            .food => std.fmt.bufPrint(buf[w..], "{s}{d:.0} food", .{ sep, line.qty }) catch "",
            .materials => std.fmt.bufPrint(buf[w..], "{s}{d:.0}m", .{ sep, line.qty }) catch "",
            else => std.fmt.bufPrint(buf[w..], "{s}{s}", .{ sep, wareLabel(line.item) }) catch "",
        };
        w += piece.len;
    }
    return buf[0..w];
}

/// Build the trade dialog overlay when open, wiring confirm → `barter.resolve`. Returns the
/// dialog's overlay root (or null when closed). The offers are the passerby's satchel wares (buy)
/// and the player's sellable goods + surplus (sell), each backed by a live `market.Quote`.
fn trade_overlay(ctx: *uic.UiCtx, world: *World, e: Entity, ts_opt: ?*uic.UiState.TradeState) !?*Node {
    const ts = ts_opt orelse return null;
    if (!ts.open) return null;

    const enc = &ctx.res.sim.encounter;
    const food = world.get(e, comp.InventoryFood).?;
    const stock = world.get(e, comp.InventoryMaterial).?;

    // --- buy offers: what the passerby will hand over from the satchel --------------------
    var buys = std.ArrayList(BackedOffer).empty;
    var gbuf = try ctx.arena.alloc(u8, 512);
    var gw: usize = 0;
    inline for (.{ Ware.food, Ware.materials, Ware.fish_hook, Ware.whetstone }) |ware| {
        const have = enc.stockOf(ware);
        if (have > 0) {
            // A simple posted buy price: the passerby wants Materials (bulk) or Food+Materials
            // (tools) for what it carries. Kept modest; the sell side is where diminishing value
            // is taught (ACT1-15).
            var q = market.Quote{ .id = @as(u32, @intFromEnum(ware)), .rev = enc.id, .direction = .buy, .give = undefined, .receive = undefined, .stock = have };
            switch (ware) {
                .food => {
                    q.give = market.Bundle.one(.materials, 2);
                    q.receive = market.Bundle.one(.food, 1);
                },
                .materials => {
                    q.give = market.Bundle.one(.food, 1);
                    q.receive = market.Bundle.one(.materials, 3);
                },
                .fish_hook => {
                    var g = market.Bundle{};
                    g.add(.food, 2);
                    g.add(.materials, 8);
                    q.give = g;
                    q.receive = market.Bundle.one(.fish_hook, 1);
                },
                .whetstone => {
                    var g = market.Bundle{};
                    g.add(.food, 2);
                    g.add(.materials, 6);
                    q.give = g;
                    q.receive = market.Bundle.one(.whetstone, 1);
                },
            }
            const give_s = bundleLabel(gbuf[gw..], &q.give);
            gw += give_s.len;
            const recv_s = bundleLabel(gbuf[gw..], &q.receive);
            gw += recv_s.len;
            const refusal = q.refusal(enc, food.v, stock.v);
            try buys.append(ctx.arena, .{
                .offer = .{ .give = give_s, .receive = recv_s, .stock = have, .refusal = refusal.reason() },
                .quote = q,
            });
        }
    }

    // --- sell offers: the player's surplus + owned goods, at the diminishing schedule -----
    var sells = std.ArrayList(BackedOffer).empty;
    // Surplus resources (a token "sell 1 unit" at the first-unit value; the schedule teaches the
    // decline via `next_unit`, shown in the effect line).
    inline for (.{ Ware.food, Ware.materials }) |ware| {
        const held: f32 = if (ware == .food) food.v else stock.v;
        if (held >= 1) {
            const q = market.sell_quote(ware, 0, 100 + @as(u32, @intFromEnum(ware)), enc.id);
            const give_s = bundleLabel(gbuf[gw..], &q.give);
            gw += give_s.len;
            const recv_s = bundleLabel(gbuf[gw..], &q.receive);
            gw += recv_s.len;
            const eff = try std.fmt.allocPrint(ctx.arena, "next unit: {d:.1}m", .{q.next_unit orelse 0});
            try sells.append(ctx.arena, .{
                .offer = .{ .give = give_s, .receive = recv_s, .effect = eff, .stock = 1 },
                .quote = q,
            });
        }
    }
    // Owned tradeable goods (map to a ware the passerby recognizes).
    inline for (.{ .{ comp.FishNet, Ware.fish_hook }, .{ comp.HandAxe, Ware.whetstone } }) |pair| {
        const G = pair[0];
        const ware = pair[1];
        if (world.has(e, G)) {
            const q = market.sell_quote(ware, 0, 200 + @as(u32, @intFromEnum(ware)), enc.id);
            const give_s = try std.fmt.allocPrint(ctx.arena, "{s}", .{wareLabel(ware)});
            const recv_s = bundleLabel(gbuf[gw..], &q.receive);
            gw += recv_s.len;
            try sells.append(ctx.arena, .{
                .offer = .{ .give = give_s, .receive = recv_s, .stock = 1 },
                .quote = q,
            });
        }
    }

    // Flatten the offer views for the dialog.
    var buy_views = try ctx.arena.alloc(t.TradeOffer, buys.items.len);
    for (buys.items, 0..) |b, i| buy_views[i] = b.offer;
    var sell_views = try ctx.arena.alloc(t.TradeOffer, sells.items.len);
    for (sells.items, 0..) |s, i| sell_views[i] = s.offer;

    // Live holdings line.
    var hbuf: [48]u8 = undefined;
    const holdings = std.fmt.bufPrint(&hbuf, "{d:.0} food · {d:.0}m", .{ food.v, stock.v }) catch "";

    var root: *Node = undefined;
    const res = try t.trade_dialog(ctx, "trade", .passerby, buy_views, sell_views, holdings, ts, &root);

    // Confirm → resolve the backing quote atomically. Header/Holdings/log read live world state,
    // so they refresh this same frame.
    if (res.confirmed) |i| {
        const backing = if (res.mode == 0) buys.items else sells.items;
        if (i < backing.len) _ = barter.resolve(world, e, ctx.res, &backing[i].quote);
    }
    // Escape / outside-click closes; also close if the passerby has left.
    if (res.dismissed or !enc.dealable()) ts.open = false;

    return if (ts.open) root else null;
}
