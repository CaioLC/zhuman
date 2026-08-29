//! The game's screen builders (`ui_*`) and `build_ui` live in this module.
//! This is how we display game *content* into UI components.

const std = @import("std");
const ha = @import("ha");
const app = @import("../main.zig");

const comp = ha.comp;
const tag = ha.tag;
const uic = ha.ui_client;
const ecs = ha.ecs;
const actions = ha.actions;
const World = ha.world.World;
const Entity = ha.world.Entity;

// Pages
const p_playgame = @import("./play_game.zig").ui_playgame;
const p_gameover = @import("./gameover.zig").ui_gameover;
const mock_page = @import("./mock.zig").mock_page;

/// Returns a flattened list of *Nodes for the render stage
pub fn build_ui(ui_ctx: *uic.UiCtx, world: *World) !uic.Trees {
    ui_ctx.res.view.theme = ha.theme.lerp(0.6);
    var trees: std.ArrayList(*uic.Node) = .empty;
    // const mock = try mock_page(ui_ctx, world);

    // Route on the actor: alive → the HUD; despawned (vigor hit 0) → game over.
    const player = ecs.MaybeSingle(.{ comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    const screen = if (player.get() != null)
        try p_playgame(ui_ctx, world)
    else
        try p_gameover(ui_ctx, world);

    try uic.collect(&trees, ui_ctx.arena, screen);
    return trees.items;
}
