//! `outline` feature: a 1px box border around the node's full box. Render-only, like
//! `fill` (no `State`/`attach`). Listed *last* in the feature `list` so a hover/
//! affordance ring draws over opaque fills and image tiles.

const ui = @import("../../ui/root.zig");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "outline";
pub const Payload = ?ui.Color;

/// Box border in `c` around the node's full resolved box.
pub fn draw(u: *UiCtx, node: *Node, c: ui.Color) void {
    const r = paint.full(node) orelse return;
    u.res.renderer.setDrawColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    u.res.renderer.renderRect(paint.frect(r)) catch return;
}
