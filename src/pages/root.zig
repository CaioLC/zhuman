//! The game's screen builders (`ui_*`) and `build_ui` live in this module.
//! This is how we display game *content* into UI components.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const tag = ha.sim.tag;
const uic = ha.ui_client;
const ecs = ha.sim.ecs;
const actions = ha.sim.rules.actions;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

// Pages
const p_act_one = @import("./play_game.zig").ui_playgame;
const p_act_two = @import("./act_two/page.zig").ui_act_two;
const p_gameover = @import("./gameover.zig").ui_gameover;
const p_act_one_end = @import("./act_one_end.zig").ui_act_one_end;
const p_debug = @import("./debug_page.zig").debug_page;
const title_page = @import("./title.zig");
const p_title = title_page.ui_title;
const fixture = @import("./fixture.zig");
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
    if (debugRequested(ui_ctx.res)) {
        ui_ctx.res.route = .game;
        // The harness samples the live player, so it begins a run if none has begun.
        const states = &ui_ctx.res.game.states;
        if (states.in(.title) and states.next == null) _ = ui_ctx.res.game.events.writer(ha.sim.events.NewRun).push(.{});
        return try withMenu(ui_ctx, try p_debug(ui_ctx, world));
    }

    // The deterministic fixture harness: `HA_FIXTURE=<name>` seeds one named screen state and
    // renders it through the production page. A developer opt-in like the debug page; off unless
    // the variable is set and non-empty. See `fixture.zig`.
    if (fixtureRequested(ui_ctx.res)) |name| return try withMenu(ui_ctx, try fixture.build_fixture(ui_ctx, world, name));

    // The curtain is the UI's response to `ActEnded`, heard with its own cursor. The world has
    // already crossed into the next act; the curtain holds it still while the player reads.
    var ended = ui_ctx.res.game.events.readerAt(ha.sim.events.ActEnded, &ui_ctx.res.curtain.heard);
    while (ended.next()) |fact| if (fact.act == .act_one) ui_ctx.res.curtain.show(&ui_ctx.res.playback);

    // Route on the state: the title before a run (or when Quit to menu left one behind it),
    // the curtain while it is open, the game-over screen once no player remains (the state
    // follows a tick after `despawn_dead`), then the act's page.
    const states = &ui_ctx.res.game.states;
    if (ui_ctx.res.route == .title or states.in(.title)) return try p_title(ui_ctx, world);
    if (ui_ctx.res.curtain.open) {
        const trees = try withMenu(ui_ctx, try p_act_one_end(ui_ctx));
        // Still open (Continue closes it): a Resume from the menu does not run the world behind it.
        if (ui_ctx.res.curtain.open) ui_ctx.res.playback.paused = true;
        return trees;
    }
    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    if (states.in(.game_over) or player.get() == null) return try withMenu(ui_ctx, try p_gameover(ui_ctx, world));
    return try withMenu(ui_ctx, switch (states.current) {
        .act_one => try p_act_one(ui_ctx, world, .{}),
        .act_two, .act_three => try p_act_two(ui_ctx, world, .{}),
        .title, .game_over => unreachable, // routed above
    });
}

/// What the session menu says about the run behind it: the act (from the state), the day, and
/// how many people.
fn session(ctx: *uic.UiCtx) t.MenuSession {
    const act: u8 = switch (ctx.res.game.states.current) {
        .act_two => 2,
        .act_three => 3,
        .title, .act_one, .game_over => 1,
    };
    return .{
        .act = act,
        .day = 1 + @as(u64, @intFromFloat(ctx.res.game.sim.elapsed / ctx.res.game.config.secs_per_day)),
        // Population has no model yet (ACT2-01): Act II reads the stand-in.
        .people = if (act >= 2) @intFromFloat(ctx.res.game.sim.population) else 1,
    };
}

/// Append the session menu as the final/topmost root over whichever production or development
/// page was built. A header click or Escape on the page (no dialog open, no visible focus) opens
/// it in this same frame; its modal shell owns focus, Escape, and opener restoration.
fn withMenu(ctx: *uic.UiCtx, roots: uic.Trees) !uic.Trees {
    if (!ctx.res.menu.open and roots.len > 0 and t.pageEscape(ctx, roots[0])) ctx.res.menu.show(&ctx.res.playback);
    if (!ctx.res.menu.open) return roots;

    const menu = try t.menu_dialog(ctx, "session_menu", session(ctx));
    if (menu.changed.window) title_page.applyWindow(ctx);
    if (menu.quit) {
        // Quit to menu: the run behind it is left, and the title screen comes up next frame.
        ctx.res.menu.open = false;
        ctx.res.route = .title;
        ctx.res.title = .{};
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
    _ = @import("./hex_pixel.zig");
    _ = @import("./eating.zig");
    _ = @import("./query.zig");
    _ = @import("./play_game.zig");
    _ = @import("./debug_page.zig");
    _ = @import("./gameover.zig");
    _ = @import("./act_one_end.zig");
    _ = @import("./fixture.zig");
    _ = @import("./act_two/page.zig");
    _ = @import("./act_one/holdings.zig");
    _ = @import("./title.zig");
}
