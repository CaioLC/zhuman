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

pub fn ui_playgame(ctx: *uic.UiCtx, world: *World) !*Node {
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

        // ACT1-07: the Passerby (market) strip and the activity strip fill the shell's optional
        // strip regions, present in both the pre-tutorial and the underway states so the chrome
        // never shifts. The Passerby is a placeholder venue here — the live merchant encounter
        // state is ACT1-12 and the trade wiring is ACT1-17; the activity strip reads the agent's
        // `Busy` (idle vs the verb in progress). The live state-change announcement is ACT1-16,
        // so `last` is passed as the current state for now (renders, does not yet announce).
        if (regions.market) |market| {
            _ = try t.market_strip(ctx, market, "passerby", .passerby);
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

    return regions.root.get();
}
