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
pub fn draw(u: *UiCtx, node: *Node, c: cb.Color, opacity: f32) void {
    const r = paint.full(node) orelse return;
    const col = paint.applyOpacity(c, opacity); // RENDER-07 subtree dimming
    u.res.platform.renderer.setDrawColor(.{ .r = col.r, .g = col.g, .b = col.b, .a = col.a }) catch return;
    u.res.platform.renderer.renderFillRect(paint.frect(r)) catch return;
}
