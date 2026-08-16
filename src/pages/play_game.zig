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
const app = @import("../main.zig");

pub fn ui_playgame(ctx: *uic.UiCtx, world: *World) !*Node {
    const th = ctx.res.theme;
    var buf: [64]u8 = undefined;

    const root = try el.root(ctx, "play");
    _ = root.with_layout(.top_left).with_flow(.{ .dir = .column }).with_gap(16);
    // Padding is content-box (it *grows* a fixed box), so shrink the window-sized root by
    // the page pad to keep the padded box exactly window-sized — else full-width children
    // (header is pct 1.0) hang past the right edge by twice the pad.
    const page_pad: f32 = 16;
    const rn = root.get();
    const content_w = rn.size.w.fixed - 2 * page_pad;
    const content_h = rn.size.h.fixed - 2 * page_pad;
    _ = root.with_size(.{ .fixed = content_w }, .{ .fixed = content_h })
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

        // --- center: the production actions row. Gather leads — the teaching card until
        // the first resolved action (GameState.tutorial_done), then the compact tile
        // speaking the same grammar. Eat rides beside it in tile form from the start
        // (its `-1f → +2v` is grammar practice, not a new lesson). "Gather" is today's
        // presentation of ActionForage; more actions, more tiles in this row.
        const acts = try el.div(ctx, root, "acts");
        _ = acts.with_layout(.center).with_flow(.{ .dir = .row, .cross = .center }).with_gap(12);
        if (!ctx.res.game.tutorial_done) {
            _ = try t.action_card(ctx, acts, world, e, comp.ActionForage, "gather", "Gather", actions.action_forage);
        } else {
            _ = try t.action_tile(ctx, acts, world, e, comp.ActionForage, "gather_t", "Gather", actions.action_forage);
        }
        _ = try t.eat_tile(ctx, acts, world, e, "eat");
    }

    const run_line = try el.div(ctx, header, "run");
    _ = run_line.with_layout(.bottom_right).with_flow(.{ .dir = .row }).with_gap(6);
    _ = (try el.text(ctx, run_line, "act", "Act I ·"))
        .with_style(.{ style.h3, Style{ .text = th.dim } });
    const day = 1 + @as(u64, @intFromFloat(ctx.res.time.elapsed / app.secs_per_day));
    const day_txt = std.fmt.bufPrint(&buf, "Day {d}", .{day}) catch "?";
    _ = (try el.text(ctx, run_line, "day", day_txt))
        .with_style(.{ style.h3, Style{ .text = th.fg } });

    // --- footer: the event log, full width at the bottom, 4 lines tall --------------------
    // Anchored (out-of-flow), so the column flow above never pushes it — it owns the
    // bottom edge of the content box regardless of what the body sections grow into.
    const footer = try el.div(ctx, root, "footer");
    _ = footer.with_layout(.bottom_left);
    try t.log_view(ctx, footer, "feed", &ctx.res.log, content_w, 4);

    return root.get();
}
