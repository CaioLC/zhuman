//! Session menu overlay on the shared `dialog_frame`.
//!
//! The menu exposes only reviewed host settings: reduced motion, resume, and quit. Speed is
//! the header stepper's alone. Opening pauses the simulation through `MenuState`; Escape/close
//! restores the prior pause state, while RESUME explicitly unpauses. No tuning `Config` field is
//! exposed. (PORT-03 rebuilds this on `menu.html`.)

const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;

const modal_mod = @import("./modal.zig");
const frame_mod = @import("./dialog_frame.zig");
const button_mod = @import("./button.zig");

const width: f32 = 420;

pub const Result = struct {
    root: *uic.Node,
    dismissed: bool,
    resumed: bool,
    quit: bool,
};

pub fn menu_dialog(ctx: *uic.UiCtx, id: []const u8) !Result {
    const th = ctx.res.view.theme;
    const frame = try frame_mod.dialog_frame(ctx, .{
        .id = id,
        .width = width,
        .kicker = "SESSION",
        .title = "MENU",
        .close_name = "Close menu",
    });

    const body = try frame.body.div("content");
    _ = body.with_size(.{ .fixed = frame.inner_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(14)
        .with_style(.{style.pad_sym(frame_mod.pad_x, 14)});
    _ = (try body.text("status", "Simulation paused while this menu is open."))
        .with_style(.{ style.body, Style{ .text = th.dim } });

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

    const quit = try button_mod.button(frame.footer, "quit", "QUIT", true);
    const resume_button = try button_mod.button(frame.footer, "resume_button", "RESUME", true);
    const quit_clicked = quit.consume(.clicked);
    const resume_button_clicked = resume_button.consume(.clicked);

    return .{
        .root = frame.modal.root,
        .dismissed = modal_mod.dismissed(ctx, frame.modal, frame.close_clicked or resume_button_clicked or quit_clicked, resume_button.get().key),
        .resumed = resume_button_clicked,
        .quit = quit_clicked,
    };
}
