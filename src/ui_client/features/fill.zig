//! `fill` feature: a solid rect over the node's full box. Render-only — no `State`, no
//! `attach` (callers set `node.render_data.fill = color` directly). The simplest kind
//! of feature: just a `name`, a `Payload`, and a `draw`.

const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "fill";
pub const Payload = ?cb.Color;

/// Solid rect in `c` spanning the node's full resolved box.
pub fn draw(u: *UiCtx, node: *Node, c: cb.Color) void {
    const r = paint.full(node) orelse return;
    u.res.platform.renderer.setDrawColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    u.res.platform.renderer.renderFillRect(paint.frect(r)) catch return;
}
