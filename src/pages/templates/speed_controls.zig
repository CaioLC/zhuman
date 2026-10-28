//! Compact right-side playback controls for the HUD: the `<< {speed} >>` stepper and the menu.
//!
//! State lives on `res.Playback`, not UI state, so it survives view changes. Speed persists across
//! fresh runs; pause (the stepper's lowest position) freezes the complete simulation stage while
//! host input, roster watching, rendering and UI motion continue on real frame time.

const ha = @import("ha");

const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;
const Playback = ha.res.Playback;


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

const level_labels = [_][]const u8{ "PAUSE", "1×", "2×", "3×" };
const level_names = [_][]const u8{ "Paused", "1× speed", "2× speed", "3× speed" };
/// The stepper's value cell width, logical px: fits `PAUSE` at 10px, so stepping never moves
/// the chevrons.
const level_cell_w: f32 = 36;

/// The header's `<< {speed} >>` stepper over pause, 1×, 2×, 3×. One focus stop, published as a
/// slider: arrows step, Home pauses, End jumps to 3×. The chevrons are pointer targets only
/// (not extra Tab stops) and dim out at their bound.
pub fn speed_stepper(parent: El, id: []const u8) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const pb = &ctx.res.playback;
    const box = try parent.div(id);
    _ = box.with_flow(.{ .dir = .row, .cross = .center }).with_gap(2)
        .with_size(.fit_children, .fit_children);
    ctx.res.commands.registerRange(box.get().key);

    // Keyboard commands land on the focused range owner; apply them before publishing.
    const pre = box.query();
    if (pre.decrement or pre.page_decrement) pb.step(-1);
    if (pre.increment or pre.page_increment) pb.step(1);
    if (pre.minimum) pb.setLevel(0);
    if (pre.maximum) pb.setLevel(Playback.max_level);

    // Chevrons first: their clicks change the level the value cell and semantics then report.
    // Built in tree order, so lay out the slower chevron, value cell, then faster chevron.
    const slower = try box.div("slower");
    const value_cell = try box.div("value");
    const faster = try box.div("faster");
    if (try chevron(slower, "<<", "Slower", pb.level() > 0)) pb.step(-1);
    if (try chevron(faster, ">>", "Faster", pb.level() < Playback.max_level)) pb.step(1);

    const lvl = pb.level();
    const q = box.control(.{
        .name = "Simulation speed",
        .role = .slider,
        .value = level_names[lvl],
        .cursor = .default,
    });
    const color = if (lvl == 0) th.warn else th.fg;
    _ = value_cell.with_size(.{ .fixed = level_cell_w }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
    _ = (try value_cell.text("label", level_labels[lvl]))
        .with_style(.{ Style{ .font = 10, .tracking = 0.04, .text = color }, style.pad_sym(2, 2) });
    if (q.focused) _ = box.with_style(.{Style{ .outline_color = th.acc }});
    return box;
}

/// One `<<`/`>>` pointer target. Returns whether it was clicked this frame. Kept out of Tab
/// order: the stepper itself is the keyboard owner.
fn chevron(box: El, glyph: []const u8, name: []const u8, enabled: bool) !bool {
    const th = box.ctx.res.view.theme;
    const q = box.control(.{ .name = name, .role = .button, .enabled = enabled, .focusable = false });
    const color = if (!enabled) th.line2 else if (q.hovering or q.held) th.acc else th.dim;
    _ = box.with_size(.fit_children, .fit_children);
    _ = (try box.text("glyph", glyph))
        .with_style(.{ Style{ .font = 10, .text = color }, style.pad_sym(3, 2) });
    return q.clicked;
}
