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
const p_act_one = @import("./play_game.zig").ui_playgame;
const p_gameover = @import("./gameover.zig").ui_gameover;
const p_act_one_end = @import("./act_one_end.zig").ui_act_one_end;
const p_debug = @import("./debug_page.zig").debug_page;
const fixture = @import("./fixture.zig");

/// Returns a flattened list of *Nodes for the render stage
pub fn build_ui(ui_ctx: *uic.UiCtx, world: *World) !uic.Trees {
    ui_ctx.res.view.theme = ha.palette.theme;
    ui_ctx.res.view.ground = ha.palette.ground;
    ui_ctx.res.view.resources = ha.palette.resources;
    // Project the init-resolved reduced-motion policy onto this frame's view.
    // Probed once at init; here we only copy the bit so optional transitions can gate on it.
    ui_ctx.res.view.reduced_motion = ui_ctx.res.motion.reduced_motion;
    // Compute this frame's view metrics from the window's logical (coordinate) size
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
    // Every page returns its roots in draw order (a dialog's root after the shell it covers).
    // The game is the normal route. The template audit harness remains available as an explicit
    // developer opt-in via a truthy `HA_DEBUG_PAGE` value.
    if (debugRequested(ui_ctx.arena)) return try p_debug(ui_ctx, world);

    // The deterministic fixture harness: `HA_FIXTURE=<name>` seeds one named screen state and
    // renders it through the production page. A developer opt-in like the debug page; off unless
    // the variable is set and non-empty. See `fixture.zig`.
    if (fixtureRequested(ui_ctx.arena)) |name| return try fixture.build_fixture(ui_ctx, world, name);

    // Route on the actor: despawned (vigor hit 0) → game over; housed → the Act I
    // curtain, since owning a `Shelter` is the win condition; otherwise the live Act-I page.
    const player = ecs.MaybeSingle(.{ comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    const settled = ecs.MaybeSingle(.{ comp.Shelter, ecs.With(tag.Player) }){ .world = world };
    if (player.get() == null) return try p_gameover(ui_ctx, world);
    if (settled.get() != null) return try p_act_one_end(ui_ctx, world);
    return try p_act_one(ui_ctx, world);
}

/// Whether to route to the template-audit harness instead of the game. Debug mode is off by
/// default; any non-empty value other than `0` or `false` explicitly enables it. The value is
/// read into the frame arena and not retained.
fn debugRequested(arena: std.mem.Allocator) bool {
    const raw = std.process.getEnvVarOwned(arena, "HA_DEBUG_PAGE") catch return false;
    if (raw.len == 0) return false;
    if (std.mem.eql(u8, raw, "0")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return true;
}

/// The requested fixture name from `HA_FIXTURE`, or null when the variable is unset or empty.
/// The name is copied into the frame arena (valid for this build) and routed by
/// `fixture.build_fixture`, which falls back to the first catalog entry for an unknown name.
fn fixtureRequested(arena: std.mem.Allocator) ?[]const u8 {
    const raw = std.process.getEnvVarOwned(arena, "HA_FIXTURE") catch return null;
    if (raw.len == 0) return null;
    return raw;
}

test {
    _ = @import("./templates/root.zig");
    _ = @import("./fmt.zig");
    _ = @import("./play_game.zig");
    _ = @import("./debug_page.zig");
    _ = @import("./gameover.zig");
    _ = @import("./act_one_end.zig");
    _ = @import("./mock.zig");
    _ = @import("./fixture.zig");
    _ = @import("./act_two/page.zig");
}
