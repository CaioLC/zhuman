//! The game-over screen builder (`src/pages/` game content): the shared `curtain` with the dead
//! figure, one line, and "Start over", which begins a fresh run (`start_over`).

const ha = @import("ha");
const app = @import("../main.zig");

const uic = ha.ui_client;
const World = ha.world.World;

const t = @import("./templates/root.zig");

pub fn ui_gameover(ctx: *uic.UiCtx, world: *World) !uic.Trees {
    // The game-over screen lives in the one terminal shell; it needs only the main body.
    const regions = try t.shell(ctx, .{
        .id = "over",
        .act = .act_one,
        .page_pad = ha.tokens.pad_page,
        .section_gap = ha.tokens.gap.section,
    });
    const c = try t.curtain(regions.body, "c_div", .{
        .figure = t.fig_dead,
        .figure_color = ctx.res.view.theme.danger,
        .line = "You perished, cold and starved.", // the only line on the screen
        .button = "Start over",
    });
    if (c.clicked) app.start_over(world, ctx.res);
    return try uic.oneRoot(ctx.arena, regions.root.get());
}
