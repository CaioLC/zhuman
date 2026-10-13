//! Compact right-side playback controls for the HUD: chevron speed, menu, then pause.
//!
//! State lives on `res.Playback`, not UI state, so it survives view changes. Speed persists across
//! fresh runs; pause freezes the complete simulation stage while host input, roster watching,
//! rendering and UI motion continue on real frame time.

const ha = @import("ha");

const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

const speeds = [_]u8{ 1, 2, 3 };
const labels = [_][]const u8{ ">", ">>", ">>>" };
const accessible_names = [_][]const u8{ "1× speed", "2× speed", "3× speed" };

/// The > / >> / >>> single-selection group placed with the right-side controls.
pub fn speed_controls(parent: El, id: []const u8) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const group = try parent.div(id);
    _ = group.with_flow(.{ .dir = .row, .cross = .center }).with_gap(3);
    const group_key = group.get().key;

    var member_keys: [speeds.len]u64 = undefined;
    for (speeds, labels, accessible_names, 0..) |speed, label, accessible_name, i| {
        const chip = try group.item("speed", i);
        if (chip.query().clicked) ctx.res.playback.setSpeed(speed);
        const selected = ctx.res.playback.speed == speed;
        const q = chip.control(.{
            .name = accessible_name,
            .role = .radio,
            .selected = selected,
            .roving_group = group_key,
        });
        member_keys[i] = chip.get().key;
        const color = if (q.hovering or q.held or q.focused) th.acc else if (selected) th.fg else th.dim;
        _ = chip.with_size(.fit_children, .fit_children);
        _ = (try chip.text("label", label))
            .with_style(.{ Style{ .font = 10, .text = color }, style.pad_sym(4, 2) });
        if (selected) _ = chip.with_style(.{Style{ .outline_color = color }});
    }

    ctx.res.semantics.publish(uic.semantic.describeGroup(group_key, "simulation speed", &member_keys));
    return group;
}

/// Open the session menu. The menu owns the temporary pause it introduces.
pub fn menu_control(parent: El, id: []const u8) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const menu = try parent.div(id);
    if (menu.query().clicked) ctx.res.menu.show(&ctx.res.playback);
    const q = menu.control(.{ .name = "Open menu", .role = .button });
    const color = if (q.hovering or q.held or q.focused) th.acc else th.dim;
    _ = menu.with_size(.fit_children, .fit_children);
    _ = (try menu.text("label", "MENU"))
        .with_style(.{ Style{ .font = 9, .tracking = 0.04, .text = color }, style.pad_sym(4, 2) });
    return menu;
}

/// The independent PAUSE/RESUME toggle placed after the run context at the far right.
pub fn pause_control(parent: El, id: []const u8) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const pause = try parent.div(id);
    if (pause.query().clicked) ctx.res.playback.togglePaused();
    const paused = ctx.res.playback.paused;
    const q = pause.control(.{
        .name = if (paused) "Resume simulation" else "Pause simulation",
        .role = .checkbox,
        .checked = paused,
    });
    const color = if (q.hovering or q.held or q.focused) th.acc else if (paused) th.warn else th.dim;
    _ = pause.with_size(.fit_children, .fit_children);
    _ = (try pause.text("label", if (paused) "RESUME" else "PAUSE"))
        .with_style(.{ Style{ .font = 9, .tracking = 0.04, .text = color }, style.pad_sym(4, 2) });
    if (paused) _ = pause.with_style(.{Style{ .outline_color = color }});
    return pause;
}
