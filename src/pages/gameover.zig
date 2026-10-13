//! The game-over screen builder (`src/pages/` game content), on the elements/templates
//! stack: a dead figure, a line, and a "Start over" button that respawns the player and
//! resets the run clock + log.

const ha = @import("ha");
const app = @import("../main.zig");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const World = ha.world.World;

const t = @import("./templates/root.zig");

pub fn ui_gameover(ctx: *uic.UiCtx, world: *World) !uic.Trees {
    const th = ctx.res.view.theme;

    // The game-over screen lives in the one terminal shell; it needs only the main
    // body (no header/footer/rail), so it fills `regions.body` with its centered content.
    const regions = try t.shell(ctx, .{
        .id = "over",
        .act = .act_one,
        .page_pad = ha.tokens.pad_page,
        .section_gap = ha.tokens.gap.section,
    });
    const center = try regions.body.div("c_div");
    _ = center.with_layout(.center).with_flow(.{ .dir = .column, .cross = .center }).with_gap(10);

    try t.figure(center, t.fig_dead, th.danger);
    _ = (try center.text("dead_text", "You perished, cold and starved."))
        .with_style(.{ style.h2, Style{ .text = th.fg } }); // the only line on the screen

    const restart = try t.button(center, "restart", "Start over", true);
    if (restart.query().clicked) {
        ctx.res.playback.paused = false;
        _ = app.spawn_player(world);
        ctx.res.sim.reset(); // clock, log and the teaching flag all start over together
        ctx.res.sim.log.push(.dim, "You wake alone. Cold. Hungry.");
    }
    return try uic.oneRoot(ctx.arena, regions.root.get());
}
