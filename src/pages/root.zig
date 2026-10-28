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
const act_two_fixtures = @import("./act_two/fixtures.zig");
const t = @import("./templates/root.zig");

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
        const m = uic.view.computeZoomed(@floatFromInt(lw), @floatFromInt(lh), density, ui_ctx.res.settings.ui_scale.factor());
        ui_ctx.res.view.metrics = m;
        ui_ctx.res.view.scale = m.dpi_scale;
    }
    // Every page returns its roots in draw order (a dialog's root after the shell it covers).
    // The game is the normal route. The template audit harness remains available as an explicit
    // developer opt-in via a truthy `HA_DEBUG_PAGE` value.
    if (debugRequested(ui_ctx.res)) return try withMenu(ui_ctx, world, try p_debug(ui_ctx, world));

    // The deterministic fixture harness: `HA_FIXTURE=<name>` seeds one named screen state and
    // renders it through the production page. A developer opt-in like the debug page; off unless
    // the variable is set and non-empty. See `fixture.zig`.
    if (fixtureRequested(ui_ctx.res)) |name| return try withMenu(ui_ctx, world, try fixture.build_fixture(ui_ctx, world, name));

    // Route on the actor: despawned (vigor hit 0) → game over; housed → the Act I curtain,
    // since owning the good that ends the act is the win condition; otherwise the live page.
    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    const a = player.get() orelse return try withMenu(ui_ctx, world, try p_gameover(ui_ctx, world));
    if (ha.capital.ownsMilestone(world, a[0], &ui_ctx.res.catalog, .act_one)) return try withMenu(ui_ctx, world, try p_act_one_end(ui_ctx, world));
    return try withMenu(ui_ctx, world, try p_act_one(ui_ctx, world, .{}));
}

/// What the session menu says about the run behind it: the act, the day, and how many people.
fn session(ctx: *uic.UiCtx, world: *World) t.MenuSession {
    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    const act: u8 = if (player.get()) |a| ha.migration.actOf(world, a[0]) else 1;
    return .{
        .act = act,
        .day = 1 + @as(u64, @intFromFloat(ctx.res.sim.elapsed / ctx.res.config.secs_per_day)),
        // Population has no model yet (ACT2-01): Act II reads its fixture.
        .people = if (act >= 2) @intFromFloat(act_two_fixtures.population) else 1,
    };
}

/// Apply the window setting the menu changed: a windowed size, or fullscreen.
fn applyWindow(ctx: *uic.UiCtx) void {
    const choice = ctx.res.settings.window orelse return;
    const win = ctx.res.platform.window;
    if (choice.size()) |s| {
        win.setFullscreen(false) catch {};
        win.setSize(s.w, s.h) catch {};
    } else {
        win.setFullscreen(true) catch {};
    }
}

/// Append the session menu as the final/topmost root over whichever production or development
/// page was built. A header click can open it in this same frame; its modal shell owns focus,
/// Escape, and opener restoration.
fn withMenu(ctx: *uic.UiCtx, world: *World, roots: uic.Trees) !uic.Trees {
    if (!ctx.res.menu.open) return roots;

    const menu = try t.menu_dialog(ctx, "session_menu", session(ctx, world));
    if (menu.changed.window) applyWindow(ctx);
    if (menu.quit) {
        // Quit to menu lands on the title screen once it exists (PORT-04); until then, exit.
        ctx.res.menu.open = false;
        ctx.res.menu.quit_requested = true;
    } else if (menu.resumed) {
        ctx.res.menu.resumeGame(&ctx.res.playback);
    }
    if (!ctx.res.menu.open) return roots;

    var all = std.ArrayList(*uic.Node).empty;
    try all.appendSlice(ctx.arena, roots);
    try all.append(ctx.arena, menu.root);
    return all.items;
}

/// Whether to route to the template-audit harness instead of the game. Debug mode is off by
/// default; any non-empty value other than `0` or `false` explicitly enables it.
fn debugRequested(res: *const ha.res.Resources) bool {
    const raw = res.env("HA_DEBUG_PAGE") orelse return false;
    if (raw.len == 0) return false;
    if (std.mem.eql(u8, raw, "0")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return true;
}

/// The requested fixture name from `HA_FIXTURE`, or null when the variable is unset or empty.
/// The name is borrowed from the process environment and routed by `fixture.build_fixture`,
/// which falls back to the first catalog entry for an unknown name.
fn fixtureRequested(res: *const ha.res.Resources) ?[]const u8 {
    const raw = res.env("HA_FIXTURE") orelse return null;
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
    _ = @import("./fixture.zig");
    _ = @import("./act_two/page.zig");
    _ = @import("./act_one/holdings.zig");
}
