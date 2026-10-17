//! `board_primitives` — small, **generic** building blocks for board-like surfaces. Today that
//! is `empty_state`, used by the Act II surface (STRUCTURE until the research board is drawn,
//! and a settlement with no one in it). Domain-free: every string is the caller's. The
//! STRUCTURE board's own vocabulary (tags, legend, zoom) is built with the board (BOARD-11).

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;

/// An **empty state** — a centered `message` with an optional dim `hint` beneath it, for a
/// board/list with nothing to show. Generic copy from the caller.
pub fn empty_state(parent: El, id: []const u8, message: []const u8, hint: []const u8) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const box = try parent.div(id);
    _ = box.with_layout(.center).with_flow(.{ .dir = .column, .cross = .center }).with_gap(ha.tokens.gap.tight);
    _ = (try box.text("m", message)).with_style(.{ style.body, Style{ .text = th.dim } });
    if (hint.len > 0)
        _ = (try box.text("h", hint)).with_style(.{ style.small, Style{ .text = th.line2 } });
    return box;
}
