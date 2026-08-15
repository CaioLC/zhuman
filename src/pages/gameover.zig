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

pub fn ui_gameover(ctx: *uic.UiCtx, world: *World) !*uic.Node {
    const th = ctx.res.theme;

    const root = try el.root(ctx, "over");
    const center = try el.div(ctx, root, "c_div");
    _ = center.with_layout(.center).with_flow(.{ .dir = .column, .cross = .center }).with_gap(10);

    try t.figure(ctx, center, t.fig_dead, th.danger);
    _ = (try el.text(ctx, center, "dead_text", "You perished, cold and starved."))
        .with_style(.{Style{ .text = th.fg }});

    const restart = try t.button(ctx, center, "restart", "Start over", true);
    if (restart.query().clicked) {
        _ = app.spawn_player(world);
        ctx.res.time.elapsed = 0; // fresh run starts on Day 1
        ctx.res.log.clear();
        ctx.res.log.push(.dim, "You wake alone. Cold. Hungry.");
    }
    return root.get();
}
