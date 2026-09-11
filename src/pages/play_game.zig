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
    const th = ctx.res.view.theme;
    var buf: [64]u8 = undefined;

    // KIT-04: build inside the one terminal shell, supplying region descriptors instead of
    // hand-building the header/body/footer graph. Act I wants the header, the main body, the
    // footer log, and — once the run is underway — the collapsible Holdings rail (KIT-05).
    // VIEW-04: the responsive page padding is the screen's choice (the shell does not re-derive
    // it). The rail region is always allocated; it stays zero-width until we fill it, so the
    // pre-tutorial "one card" moment is unaffected.
    const compact = ctx.res.view.metrics.width_class.atMost(.w560);
    const page_pad: f32 = if (compact) ha.tokens.pad_page_compact else ha.tokens.pad_page;
    const regions = try t.shell(ctx, .{
        .id = "play",
        .act = .act_one,
        .page_pad = page_pad,
        .section_gap = ha.tokens.gap.section,
        .rail = true,
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
        const bar = try t.resource_bar(ctx, header, "stocks", vigor, food, materials);
        _ = bar.with_layout(.bottom_left);

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
                // KIT-07: retain the inactive BUILD view's pooled sort/filter state by key so
                // returning to it restores exactly where it was; the view's nodes are not built.
                _ = t.retain_view(ctx, center, "buildlist", uic.UiState.BuildViewState);

                // Production row, in the grammar the card taught. A tile exists iff the
                // agent holds the action component — so an unlocked verb appears here the
                // frame its tool is finished, and not before. Innate: Forage, Scavenge.
                const acts = try el.div(ctx, center, "acts");
                _ = acts.with_size(.{ .fixed = 640 }, .fit_children)
                    .with_flow(.{ .dir = .row, .wrap = true, .cross = .center }).with_gap(12);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionForage, "forage_t", "Forage", actions.action_forage);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionScavenge, "scav_t", "Scavenge", actions.action_scavenge);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionChopWood, "chop_t", "Split wood", actions.action_chop_wood);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionFish, "fish_t", "Fish", actions.action_fish);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionCheckTraps, "traps_t", "Check traps", actions.action_check_traps);
                _ = try t.action_tile(ctx, acts, world, e, comp.ActionHunt, "hunt_t", "Hunt", actions.action_hunt);
                // Eating is no longer an action — the metabolism loop runs regardless;
                // the dial below sets its rate (the standing ration/feast policy).
                _ = try t.ration_dial(ctx, center, world, e, "ration");
            } else {
                _ = try t.build_list(ctx, center, world, e, "buildlist");
            }
        }

        // KIT-05: Holdings now lives in the collapsible rail (the shell's left region),
        // where the prototype puts it — a persistent, collapsible column rather than the
        // cramped in-centre placement it had before (which did not fit the 640-wide column).
        // Shown once the run is underway (a click has happened); the rail is a no-op before.
        if (ctx.res.sim.tutorial_done) {
            if (regions.rail) |rail_region| {
                const r = try t.rail(ctx, rail_region, .{ .id = "holdings_rail", .label = "HOLDINGS" });
                if (r.body) |rb| _ = try t.holdings(ctx, rb, world, e, "holdings");
            }
        }
    }

    const run_line = try el.div(ctx, header, "run");
    _ = run_line.with_layout(.bottom_right).with_flow(.{ .dir = .row }).with_gap(6);
    // VIEW-04: at ≤560 the optional run-context label ("Act I ·") is dropped to save width;
    // the functional Day counter always stays. Reachability is preserved (nothing interactive
    // is hidden — the act label is decorative context).
    if (!compact) {
        _ = (try el.text(ctx, run_line, "act", "Act I ·"))
            .with_style(.{ style.h3, Style{ .text = th.dim } });
    }
    const day = 1 + @as(u64, @intFromFloat(ctx.res.sim.elapsed / ctx.res.config.secs_per_day));
    const day_txt = std.fmt.bufPrint(&buf, "Day {d}", .{day}) catch "?";
    _ = (try el.text(ctx, run_line, "day", day_txt))
        .with_style(.{ style.h3, Style{ .text = th.fg } });

    // --- footer: the event log, full width at the bottom, 4 lines tall (the shell's footer
    // region, bottom-anchored). log_view authors in logical px (VIEW-02); the content column
    // in logical is the terminal's logical width minus the page padding.
    if (regions.footer) |footer| {
        const content_w_logical = ctx.res.view.metrics.terminal.w - 2 * page_pad;
        try t.log_view(ctx, footer, "feed", &ctx.res.sim.log, content_w_logical, 4);
    }

    return regions.root.get();
}
