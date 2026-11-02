//! The game-over screen builder (`src/pages/` game content): the shared `curtain` with the dead
//! figure, one line, and "Start over", which writes `NewRun` and unpauses; the schedule begins
//! the fresh run (`systems/run.zig`).

const ha = @import("ha");

const uic = ha.ui_client;
const World = ha.sim.ecs.World;

const t = @import("./templates/root.zig");

pub fn ui_gameover(ctx: *uic.UiCtx, world: *const World) !uic.Trees {
    _ = world;
    // The game-over screen lives in the one terminal shell; it needs only the main body.
    const regions = try t.shell(ctx, .{
        .id = "over",
        .act = .act_one,
        .page_pad = ha.tokens.pad_page,
        .section_gap = ha.tokens.gap.section,
        // A curtain centred in the window; it never scrolls.
        .scroll = false,
    });
    const c = try t.curtain(regions.body, "c_div", .{
        .figure = t.fig_dead,
        .figure_color = ctx.res.view.theme.danger,
        .line = "You perished, cold and starved.", // the only line on the screen
        .button = "Start over",
    });
    if (c.clicked) {
        _ = ctx.res.game.events.writer(ha.sim.events.NewRun).push(.{});
        ctx.res.playback.paused = false;
    }
    return try uic.oneRoot(ctx.arena, regions.root.get());
}
