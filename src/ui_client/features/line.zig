//! `line` feature — a polyline through points the caller computes, at any angle.
//!
//! The first feature whose payload is not enough to draw it. `fill` and `svg` carry a
//! tint and read everything else off the node; a polyline needs *coordinates*, and there
//! are a variable number of them. So this is the shape the interface had not yet been
//! exercised on: **variable-length data in a pooled `State`**, with the payload reduced
//! to the stroke.
//!
//! Points are **node-local** and expressed in the unit square — (0,0) is the node's
//! top-left corner, (1,1) its bottom-right — so they survive a resize and a zoom without
//! the caller recomputing them. `draw` maps them through `paint.full`, which is the box
//! the node was actually laid out at.
//!
//! Rect fills already draw any axis-aligned line at any thickness; what they cannot do
//! is a diagonal or a curve. That is the whole gap this closes, and it has two consumers
//! waiting: the edges of a production board, and a distribution curve drawn from a
//! `Dist`'s own parameters rather than picked from five hand-drawn SVGs.

const std = @import("std");
const sdl = @import("sdl3");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "line";
pub const Payload = ?cb.Stroke;
pub const State = cb.UiState.LineState;

/// Give `node` a polyline through `pts` (node-local, 0..1 on both axes), stroked in
/// `stroke`. Points past the state's capacity are dropped rather than allocating — a
/// pooled state stays POD, and a curve that needs more than this wants its own node.
/// Sizing stays the caller's: the points mean nothing until the node has a box.
pub fn attach(ctx: *UiCtx, node: *Node, pts: []const cb.Point, stroke: cb.Stroke) void {
    const st = node.state(ctx, State);
    st.set(pts);
    node.render_data.line = stroke;
}

/// Stroke the stored polyline across the node's full box.
pub fn draw(u: *UiCtx, node: *Node, stroke: cb.Stroke) void {
    const st = node.state(u, State);
    const pts = st.points();
    if (pts.len < 2) return;
    const r = paint.full(node) orelse return;

    var buf: [State.cap]sdl.rect.FPoint = undefined;
    for (pts, 0..) |p, i| buf[i] = .{ .x = r.x + p.x * r.w, .y = r.y + p.y * r.h };
    const mapped = buf[0..pts.len];

    const c = stroke.color;
    u.res.platform.renderer.setDrawColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;

    // A hairline is one call. Thickness is faked by re-stroking along the normal of the
    // *first* segment, which is honest for the straight runs both consumers draw and
    // visibly wrong on a tight corner — a real thick stroke wants `renderGeometry` with
    // mitred quads, which is the same call the board's filled tiles will need.
    const w = @max(1.0, stroke.width);
    if (w <= 1.0) {
        u.res.platform.renderer.renderLines(mapped) catch return;
        return;
    }
    const dx = mapped[1].x - mapped[0].x;
    const dy = mapped[1].y - mapped[0].y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return;
    const nx = -dy / len;
    const ny = dx / len;

    var pass: f32 = -(w - 1) / 2;
    while (pass <= (w - 1) / 2 + 0.001) : (pass += 1) {
        var off: [State.cap]sdl.rect.FPoint = undefined;
        for (mapped, 0..) |p, i| off[i] = .{ .x = p.x + nx * pass, .y = p.y + ny * pass };
        u.res.platform.renderer.renderLines(off[0..mapped.len]) catch return;
    }
}
