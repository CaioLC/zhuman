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
};

pub fn modal(ctx: *UiCtx, id: []const u8, title: []const u8, width: f32) !Modal {
    const th = ctx.res.view.theme;
    const shell = try uic.modal(ctx, id, title);
    const box = El{ .node = shell.box, .ctx = ctx };
    _ = box.with_size(.{ .fixed = width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_style(.{Style{ .fill = th.bg, .outline_color = th.warn }});
    return .{ .root = shell.root, .box = box, .width = width };
}

pub fn rule(ctx: *UiCtx, parent: El, id: []const u8, width: f32) !void {
    _ = (try el.div(ctx, parent, id)).with_size(.{ .fixed = width }, .{ .fixed = 1 })
        .with_style(.{Style{ .fill = ctx.res.view.theme.line }});
}

/// Consume all activation inside the dialog, then inspect the fullscreen root. `owned` combines
/// explicit controls such as × and LEAVE with outside-click and Escape into one caller result.
pub fn dismissed(ctx: *UiCtx, m: Modal, owned: bool) bool {
    _ = ctx.consumeFlag(m.box.get().key, .clicked);
    const root_q = (El{ .node = m.root, .ctx = ctx }).query();
    return owned or root_q.clicked or root_q.dismissed;
}
