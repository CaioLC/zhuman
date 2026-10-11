//! `modal` — game-level modal chrome over the ui-client scrim/focus shell. It owns only the
//! centered outer frame and dismissal boundary; header/body/footer content is composed by callers.

const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

pub const default_width: f32 = 684;

pub const Modal = struct {
    root: *uic.Node,
    box: El,
    width: f32,
    /// True on the frame the dialog first builds (see `dismissed`).
    first_open: bool,
    /// The key focused when the dialog opened, restored on close.
    opener: ?u64,
};

pub fn modal(ctx: *UiCtx, id: []const u8, title: []const u8, width: f32) !Modal {
    const th = ctx.res.view.theme;
    const shell = try uic.modal(ctx, id, title);
    const box = shell.box;
    _ = box.with_size(.{ .fixed = width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_style(.{Style{ .fill = th.bg, .outline_color = th.warn }});
    return .{ .root = shell.root.get(), .box = box, .width = width, .first_open = shell.first_open, .opener = shell.opener };
}

pub fn rule(parent: El, id: []const u8, width: f32) !void {
    const ctx = parent.ctx;
    _ = (try parent.div(id)).with_size(.{ .fixed = width }, .{ .fixed = 1 })
        .with_style(.{Style{ .fill = ctx.res.view.theme.line }});
}

/// The dialog's end-of-build step. Consumes all activation inside the dialog, then inspects
/// the fullscreen root: `owned` combines explicit controls such as × and LEAVE with the
/// outside click and Escape into one caller result. Focus policy lives here too: on the frame
/// the dialog opens, focus goes to `primary` (the confirmation control; the first control in
/// the trap when it is disabled or absent), and on the frame it closes, back to the opener.
pub fn dismissed(ctx: *UiCtx, m: Modal, owned: bool, primary: ?u64) bool {
    _ = ctx.consumeFlag(m.box.get().key, .clicked);
    const root_q = (El{ .node = m.root, .ctx = ctx }).query();
    const closing = owned or root_q.clicked or root_q.dismissed;
    if (closing) {
        if (m.opener) |opener| _ = ctx.requestFocus(opener);
    } else if (m.first_open) {
        const on_primary = if (primary) |key| ctx.requestFocus(key) else false;
        if (!on_primary) _ = ctx.focusFirstInScope();
    }
    return closing;
}
