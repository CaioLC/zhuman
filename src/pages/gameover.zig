//! The game-over screen builder (`src/pages/` game content).

const ha = @import("ha");
const app = @import("../main.zig");

const ui = ha.ui;
const uic = ha.ui_client;
const World = ha.world.World;

const ui_root = @import("./root.zig").ui_root;
const ui_figure = @import("./templates.zig").ui_figure;
const fig_dead = @import("./templates.zig").fig_dead;

/// The game-over screen: a dead figure, a line, and a "Start over" button that respawns
/// the player and resets the run clock + log.
pub fn ui_gameover(ui_ctx: *uic.UiCtx, world: *World) !*uic.Node {
    const over = try ui_root(ui_ctx, "over");
    const center_div = try uic.Node.pcreate(ui_ctx.arena, "c_div", over);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    try ui_figure(ui_ctx, center_div, fig_dead, ui_ctx.res.theme.danger);
    _ = try uic.label(ui_ctx, center_div, "dead_text", "You perished, cold and starved.");
    const restart = try uic.button(ui_ctx, center_div, "restart", "Start over", true);
    if (restart.query(ui_ctx).clicked) {
        _ = app.spawn_player(world);
        ui_ctx.res.time.elapsed = 0; // fresh run starts on Day 1
        ui_ctx.res.log.clear();
        ui_ctx.res.log.push(.dim, "You wake alone. Cold. Hungry.");
    }
    return over;
}
