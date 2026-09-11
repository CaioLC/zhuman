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
const p_act_one_end = @import("./act_one_end.zig").ui_act_one_end;
const p_debug = @import("./debug_page.zig").debug_page;
const mock_page = @import("./mock.zig").mock_page;

/// Returns a flattened list of *Nodes for the render stage
pub fn build_ui(ui_ctx: *uic.UiCtx, world: *World) !uic.Trees {
    ui_ctx.res.view.theme = ha.palette.theme;
    ui_ctx.res.view.ground = ha.palette.ground;
    ui_ctx.res.view.resources = ha.palette.resources;
    // Project the init-resolved reduced-motion policy onto this frame's view (INPUT-10).
    // Probed once at init; here we only copy the bit so optional transitions can gate on it.
    ui_ctx.res.view.reduced_motion = ui_ctx.res.motion.reduced_motion;
    // VIEW-01: compute this frame's view metrics from the window's logical (coordinate) size
    // and its pixel density against the 900×820 reference, and set the one logical→device
    // scale from the DPI factor. The layout is solved in logical px; `scale` only makes text
    // and hairlines crisp on high-DPI. A query failure degrades to the reference metrics.
    {
        const win = ui_ctx.res.platform.window;
        const lw, const lh = win.getSize() catch .{ @as(usize, @intFromFloat(uic.view.ref_w)), @as(usize, @intFromFloat(uic.view.ref_h)) };
        const density = win.getPixelDensity() catch 1;
        const m = uic.view.compute(@floatFromInt(lw), @floatFromInt(lh), density);
        ui_ctx.res.view.metrics = m;
        ui_ctx.res.view.scale = m.dpi_scale;
    }
    var trees: std.ArrayList(*uic.Node) = .empty;
    // const mock = try mock_page(ui_ctx, world);

    // Review phase: the **template audit harness is the default screen** — the game systems and
    // composition are not what we are looking at right now. Set `HA_DEBUG_PAGE=0` (or `false`) to
    // route to the game instead. The game routing is preserved below, just short-circuited here.
    if (!gameRequested(ui_ctx.arena)) {
        const dbg = try p_debug(ui_ctx, world);
        try uic.collect(&trees, ui_ctx.arena, dbg.root);
        if (dbg.overlay) |ov| try uic.collect(&trees, ui_ctx.arena, ov);
        return trees.items;
    }

    // Route on the actor: despawned (vigor hit 0) → game over; housed → the Act I
    // curtain, since owning a `Shelter` is the win condition; otherwise the HUD.
    const player = ecs.MaybeSingle(.{ comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    const settled = ecs.MaybeSingle(.{ comp.Shelter, ecs.With(tag.Player) }){ .world = world };
    if (player.get() == null) {
        try uic.collect(&trees, ui_ctx.arena, try p_gameover(ui_ctx, world));
    } else if (settled.get() != null) {
        try uic.collect(&trees, ui_ctx.arena, try p_act_one_end(ui_ctx, world));
    } else {
        // ACT1-17: the HUD returns its shell root plus an optional trade-dialog overlay root —
        // collected after the shell so the modal draws on top (later trees paint last).
        const play = try p_playgame(ui_ctx, world);
        try uic.collect(&trees, ui_ctx.arena, play.root);
        if (play.overlay) |ov| try uic.collect(&trees, ui_ctx.arena, ov);
    }

    return trees.items;
}

/// Whether to route to the **game** instead of the default template-audit harness. During the
/// review phase the debug page is the default; setting `HA_DEBUG_PAGE=0` (or `false`) opts back
/// into the game. Read into the frame arena and not retained.
fn gameRequested(arena: std.mem.Allocator) bool {
    const raw = std.process.getEnvVarOwned(arena, "HA_DEBUG_PAGE") catch return false;
    if (std.mem.eql(u8, raw, "0")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return true;
    return false;
}
