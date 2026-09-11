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

    const root = try el.root(ctx, "play");
    _ = root.with_layout(.top_left).with_flow(.{ .dir = .column }).with_gap(16);
    // Padding is content-box (it *grows* a fixed box), so shrink the window-sized root by
    // the page pad to keep the padded box exactly window-sized — else full-width children
    // (header is pct 1.0) hang past the right edge by twice the pad.
    const page_pad: f32 = 16;
    const rn = root.get();
    // `rn.size.*.fixed` is the root's **device-px** size (VIEW-02: the layout is device px);
    // the page pad is logical, so scale it to device before subtracting, and set the result
    // with `with_size_px` so it is not scaled a second time.
    const pad_px = uic.view.dp(2 * page_pad, ctx.res.view.scale);
    const content_w = rn.size.w.fixed - pad_px;
    const content_h = rn.size.h.fixed - pad_px;
    _ = root.with_size_px(.{ .fixed = content_w }, .{ .fixed = content_h })
        .with_style(.{style.pad(page_pad)});

    // --- header: a thin strip — stocks left, run context right ----------------------------
    // Kept as an in-flow row (not a bare anchored line) so the strip reserves its height
    // and the body sections below never slide under it.
    const header = try el.div(ctx, root, "header");
    _ = header.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

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
            if (try t.action_card(ctx, root, world, e, comp.ActionForage, "gather", "Forage", actions.action_forage)) |card| {
                _ = card.with_layout(.center);
            }
        } else {
            // `.cross = .start`: the strip left-aligns over the content's edge — the
            // classic tab silhouette — instead of floating centered above it.
            const center = try el.div(ctx, root, "center");
            _ = center.with_layout(.center).with_flow(.{ .dir = .column, .cross = .start }).with_gap(10);
            const tb = try t.tabs(ctx, center, "tabs", &.{ "ACTIONS", "BUILD" });
            if (tb.active == 0) {
                // BUILD owns this state on its conditional root. Retain only the existing
                // slot while hidden; this call cannot allocate the child or its state.
                _ = center.get().retainChildState(ctx, "buildlist", uic.UiState.BuildViewState);

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
                // Holdings rides under the dial rather than beside the resource bar,
                // which is where it belongs and where it does not fit: the centre column
                // is 640 wide inside an 868 content box, leaving 114px of margin against
                // the ~300 this needs. It wants the reflow (docs/roadmap.md, Act I) — and
                // meanwhile this is the tab where "why does Forage cost 1.7?" gets asked.
                _ = try t.holdings(ctx, center, world, e, "holdings");
            } else {
                _ = try t.build_list(ctx, center, world, e, "buildlist");
            }
        }
    }

    const run_line = try el.div(ctx, header, "run");
    _ = run_line.with_layout(.bottom_right).with_flow(.{ .dir = .row }).with_gap(6);
    _ = (try el.text(ctx, run_line, "act", "Act I ·"))
        .with_style(.{ style.h3, Style{ .text = th.dim } });
    const day = 1 + @as(u64, @intFromFloat(ctx.res.sim.elapsed / ctx.res.config.secs_per_day));
    const day_txt = std.fmt.bufPrint(&buf, "Day {d}", .{day}) catch "?";
    _ = (try el.text(ctx, run_line, "day", day_txt))
        .with_style(.{ style.h3, Style{ .text = th.fg } });

    // --- footer: the event log, full width at the bottom, 4 lines tall --------------------
    // Anchored (out-of-flow), so the column flow above never pushes it — it owns the
    // bottom edge of the content box regardless of what the body sections grow into.
    const footer = try el.div(ctx, root, "footer");
    _ = footer.with_layout(.bottom_left);
    // log_view authors in logical px (VIEW-02); the content box in logical is the logical
    // viewport minus the page padding.
    const content_w_logical = ctx.res.view.metrics.logical_w - 2 * page_pad;
    try t.log_view(ctx, footer, "feed", &ctx.res.sim.log, content_w_logical, 4);

    return root.get();
}
