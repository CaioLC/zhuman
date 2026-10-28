//! `modal` — game-level modal chrome over the ui-client scrim/focus shell: the centered outer
//! frame and the end-of-build close step. `dialog_frame` composes the shared header, body and
//! footer on top of it; callers fill the body and the footer.

const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

/// The trade dialog width — the prototype's `.terminal-dialog` (760px).
pub const default_width: f32 = 760;

pub const Modal = struct {
    root: *uic.Node,
    box: El,
    width: f32,
    /// True on the frame the dialog first builds (see `settle`).
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
        .with_style(.{Style{ .fill = th.bg, .outline_color = th.acc }});
    return .{ .root = shell.root.get(), .box = box, .width = width, .first_open = shell.first_open, .opener = shell.opener };
}

pub fn rule(parent: El, id: []const u8, width: f32) !void {
    const ctx = parent.ctx;
    _ = (try parent.div(id)).with_size(.{ .fixed = width }, .{ .fixed = 1 })
        .with_style(.{Style{ .fill = ctx.res.view.theme.line }});
}

/// What the caller tells the close step.
pub const Close = struct {
    /// An explicit close the dialog's own controls asked for this frame (×, LEAVE, RESUME).
    owned: bool = false,
    /// Where focus goes on the frame the dialog opens; null (or a key that cannot take focus)
    /// falls back to the first control in the trap.
    initial_focus: ?u64 = null,
    /// A sub-screen is showing: Escape steps back to the dialog's first screen instead of
    /// closing it (the session menu's save/load/settings/quit screens).
    escape_steps_back: bool = false,
};

pub const Outcome = struct {
    /// The dialog closed this frame; focus is back on the opener.
    closed: bool,
    /// Escape asked a sub-screen to step back; the dialog stays open.
    back: bool,
};

/// The dialog's end-of-build step. Consumes all activation inside the dialog, then folds the
/// caller's explicit close with Escape into one outcome. A click on the backdrop does nothing,
/// as with the prototypes' `<dialog>`: the scrim only blocks what it covers. Focus policy
/// lives here too: on the frame the dialog opens, focus goes to `initial_focus`, and on the
/// frame it closes, back to the opener. The closing frame also forgets the shell's open edge,
/// so a dialog that reopens next frame is a fresh open (initial focus, a new opener), not a
/// continuation of this one.
pub fn settle(ctx: *UiCtx, m: Modal, c: Close) Outcome {
    _ = ctx.consumeFlag(m.box.get().key, .clicked);
    const root = El{ .node = m.root, .ctx = ctx };
    const root_q = root.query();
    const escape = root_q.dismissed;
    const back = escape and c.escape_steps_back and !c.owned;
    const closing = c.owned or (escape and !c.escape_steps_back);
    if (closing) {
        if (m.opener) |opener| _ = ctx.requestFocus(opener);
        root.state(uic.UiState.ModalState).* = .{};
    } else if (m.first_open) {
        const on_target = if (c.initial_focus) |key| ctx.requestFocus(key) else false;
        if (!on_target) _ = ctx.focusFirstInScope();
    }
    return .{ .closed = closing, .back = back };
}

/// `settle` for a dialog with one screen: closes on its own controls or Escape.
pub fn dismissed(ctx: *UiCtx, m: Modal, owned: bool, initial_focus: ?u64) bool {
    return settle(ctx, m, .{ .owned = owned, .initial_focus = initial_focus }).closed;
}
