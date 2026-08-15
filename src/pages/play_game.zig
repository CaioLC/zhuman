/// The live HUD while the actor is alive. Currently just the header bar: title + act on
/// the left, the run day + condition badge on the right. The body (resources, log,
/// actions) is being rebuilt section by section on the template shelf. The actor is
/// fetched with `MaybeSingle` (it can be despawned mid-run): the badge is skipped when
/// it's gone — `build_ui` routes to the game-over screen then.
const std = @import("std");
// general lib ECS
const ha = @import("ha");
const ecs = ha.ecs;
const comp = ha.comp;
const tag = ha.tag;
const World = ha.world.World;
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

    // --- header bar: identity left, run status right --------------------------------------
    const header = try el.div(ctx, root, "header");
    _ = header.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    const header_left = try el.div(ctx, header, "hleft");
    _ = header_left.with_layout(.bottom_left).with_flow(.{ .dir = .row }).with_gap(6);
    _ = (try el.text(ctx, header_left, "title", "Human Action")).with_style(.{style.h1});
    _ = (try el.text(ctx, header_left, "subtitle", "Act 1")).with_style(.{style.h2});

    const header_right = try el.div(ctx, header, "hright");
    _ = header_right.with_layout(.bottom_right).with_flow(.{ .dir = .row }).with_gap(12);
    const day = 1 + @as(u64, @intFromFloat(ctx.res.time.elapsed / app.secs_per_day));
    const day_txt = std.fmt.bufPrint(&buf, "Day {d}", .{day}) catch "?";
    _ = (try el.text(ctx, header_right, "dcounter", day_txt)).with_style(.{style.h2});

    // Condition badge — the status word in its severity color, boxed like a button.
    const q = ecs.MaybeSingle(.{ comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    if (q.get()) |vigor| {
        const status = t.actor_status(th, vigor);
        _ = (try el.text(ctx, header_right, "status", status.word))
            .with_style(.{ Style{ .text = status.color, .outline_color = status.color }, style.pad_sym(8, 4) });
    }

    // --- footer: the event log, full width at the bottom, 4 lines tall --------------------
    // Anchored (out-of-flow), so the column flow above never pushes it — it owns the
    // bottom edge of the content box regardless of what the body sections grow into.
    const footer = try el.div(ctx, root, "footer");
    _ = footer.with_layout(.bottom_left);
    try t.log_view(ctx, footer, "feed", &ctx.res.log, content_w, 4);

    return root.get();
}
