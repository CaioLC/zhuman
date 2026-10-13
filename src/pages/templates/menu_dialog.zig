//! Session menu overlay on the shared modal/focus-trap foundation.
//!
//! The menu exposes only reviewed host settings: simulation speed, reduced motion, resume, and
//! quit. Opening pauses the simulation through `MenuState`; Escape/outside/close restores the
//! prior pause state, while RESUME explicitly unpauses. No tuning `Config` field is exposed.

const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

const modal_mod = @import("./modal.zig");
const button_mod = @import("./button.zig");
const playback_mod = @import("./speed_controls.zig");

const width: f32 = 420;

pub const Result = struct {
    root: *uic.Node,
    dismissed: bool,
    resumed: bool,
    quit: bool,
};

pub fn menu_dialog(ctx: *uic.UiCtx, id: []const u8) !Result {
    const th = ctx.res.view.theme;
    const m = try modal_mod.modal(ctx, id, "Menu", width);

    const header = try m.box.div("header");
    _ = header.with_size(.{ .fixed = width - 30 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
        .with_style(.{style.pad_sym(15, 12)});
    const heading = try header.div("heading");
    _ = heading.with_flow(.{ .dir = .column, .cross = .start }).with_gap(2);
    _ = (try heading.text("kicker", "SESSION")).with_style(.{ style.small, Style{ .text = th.warn } });
    _ = (try heading.text("title", "MENU")).with_style(.{ style.heading, Style{ .text = th.fg } });

    const close = try header.div("close");
    _ = close.with_size(.{ .fixed = 28 }, .{ .fixed = 28 })
        .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
    const close_q = close.control(.{ .name = "Close menu", .role = .icon_button });
    _ = (try close.text("glyph", "×"))
        .with_style(.{Style{ .font = 18, .text = if (close_q.hovering or close_q.held or close_q.focused) th.acc else th.dim }});
    const close_clicked = close.consume(.clicked);
    try modal_mod.rule(m.box, "header_rule", width);

    const body = try m.box.div("body");
    _ = body.with_size(.{ .fixed = width - 30 }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(14)
        .with_style(.{style.pad_sym(15, 14)});
    _ = (try body.text("status", "Simulation paused while this menu is open."))
        .with_style(.{ style.body, Style{ .text = th.dim } });

    const speed_row = try body.div("speed_row");
    _ = speed_row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center });
    _ = (try speed_row.text("label", "SPEED")).with_style(.{ style.small, Style{ .text = th.dim } });
    _ = try playback_mod.speed_controls(speed_row, "speed");

    const motion = try body.div("motion");
    if (motion.query().clicked) ctx.res.motion.reduced_motion = !ctx.res.motion.reduced_motion;
    const reduced = ctx.res.motion.reduced_motion;
    const motion_q = motion.control(.{
        .name = "Reduced motion",
        .role = .checkbox,
        .checked = reduced,
    });
    _ = motion.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
        .with_style(.{style.pad_sym(8, 5)});
    _ = (try motion.text("label", "REDUCED MOTION"))
        .with_style(.{ style.body, Style{ .text = if (motion_q.hovering or motion_q.focused) th.acc else th.fg } });
    _ = (try motion.text("value", if (reduced) "● ON" else "○ OFF"))
        .with_style(.{ style.small, Style{ .text = if (reduced) th.good else th.dim } });

    try modal_mod.rule(m.box, "footer_rule", width);
    const footer = try m.box.div("footer");
    _ = footer.with_size(.{ .fixed = width - 30 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
        .with_style(.{style.pad_sym(15, 10)});
    const quit = try button_mod.button(footer, "quit", "QUIT", true);
    const resume_button = try button_mod.button(footer, "resume_button", "RESUME", true);
    const quit_clicked = quit.consume(.clicked);
    const resume_button_clicked = resume_button.consume(.clicked);

    return .{
        .root = m.root,
        .dismissed = modal_mod.dismissed(ctx, m, close_clicked or resume_button_clicked or quit_clicked, resume_button.get().key),
        .resumed = resume_button_clicked,
        .quit = quit_clicked,
    };
}
