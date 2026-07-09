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

// Screens are mid-redesign (plan Phase 6): the mock showcase stands in for them. Restore
// these imports + the actor-dispatch block in `build_ui` when play_game/gameover land.
const p_playgame = @import("./play_game.zig").ui_playgame;
// const ui_gameover = @import("./gameover.zig").ui_gameover;
const mock_page = @import("./mock.zig").mock_page;

/// A fullscreen root: the anchor box a whole screen's content positions against. Sized to
/// the live window so `.center`/`.top_left`/… anchors resolve against the full display.
pub fn ui_root(ui_ctx: *uic.UiCtx, id: []const u8) !*uic.Node {
    return (try uic.elements.root(ui_ctx, id)).get();
}

pub fn build_ui(ui_ctx: *uic.UiCtx, world: *World) !uic.Trees {
    ui_ctx.res.theme = ha.theme.lerp(0.6);
    var trees: std.ArrayList(*uic.Node) = .empty;
    // const mock = try mock_page(ui_ctx, world);
    const play_game = try p_playgame(ui_ctx, world);

    try uic.collect(&trees, ui_ctx.arena, play_game);
    return trees.items;

    // -- Actor-dispatch HUD (parked while the screens are rebuilt) --
    // MaybeSingle: the actor is despawned on death, so it may be absent. `Entity` yields
    // the id (to call `actions.action_*`); the stocks co-spawn on the one player entity.
    // const q = ecs.MaybeSingle(.{ Entity, comp.Vigor, comp.InventoryFood, comp.InventoryMaterial, ecs.With(tag.Player) }){ .world = world };
    // const actor = q.get();
    // ui_ctx.res.theme = if (actor) |a| ha.theme.lerp(compute_warmth(a[1])) else ha.theme.cold;
    // var trees: std.ArrayList(*uic.Node) = .empty;
    // if (actor) |a| {
    //     const e, const vigor, const food, const materials = a;
    //     try uic.collect(&trees, ui_ctx.arena, try ui_playgame(ui_ctx, world, e, vigor, food, materials));
    // } else {
    //     try uic.collect(&trees, ui_ctx.arena, try ui_gameover(ui_ctx, world));
    // }
    // return trees.items;
}

// -- HELPER FUNCTIONS --
