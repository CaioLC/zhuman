//! `outline` feature: a stroked border around the node's box. Render-only, like `fill`
//! (no `State`/`attach`). Listed *last* in the feature `list` so a hover/affordance ring
//! draws over opaque fills and image tiles.
//!
//! The border is drawn **inward** — every bar sits within the node's resolved box, so
//! thickening it never grows the box (layout doesn't account for the outline anyway; this
//! just keeps the pixels from spilling onto a neighbor). Three `style`s:
//!   - `.solid`  — four filled border bars (top/bottom/left/right), thickness = `width`.
//!   - `.dashed` — each edge stroked as dash segments (`dash_len` on, `dash_gap` off).
//!   - `.dotted` — the dash walker with dot = gap = `width` (square dots).

const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");
const sdl = @import("sdl3");
const ui = @import("../../ui/root.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Rect = ui.Rect;
const Renderer = *const sdl.render.Renderer;
const FRect = sdl.rect.FRect;

pub const name = "outline";
pub const Payload = ?cb.Outline;

// Dash metrics (px) for `.dashed`. `.dotted` derives its own from `width` instead.
const dash_len: f32 = 6;
const dash_gap: f32 = 4;

/// Stroke the node's box per `o` (color + width + style), inward.
pub fn draw(u: *UiCtx, node: *Node, o: cb.Outline) void {
    const r = paint.full(node) orelse return;
    const rnd = u.res.renderer;
    rnd.setDrawColor(.{ .r = o.color.r, .g = o.color.g, .b = o.color.b, .a = o.color.a }) catch return;

    const w = @max(o.width, 1);
    switch (o.style) {
        .solid => {
            fillBar(rnd, .{ .x = r.x, .y = r.y, .w = r.w, .h = w }); // top
            fillBar(rnd, .{ .x = r.x, .y = r.y + r.h - w, .w = r.w, .h = w }); // bottom
            fillBar(rnd, .{ .x = r.x, .y = r.y, .w = w, .h = r.h }); // left
            fillBar(rnd, .{ .x = r.x + r.w - w, .y = r.y, .w = w, .h = r.h }); // right
        },
        .dashed => strokeDashed(rnd, r, w, dash_len, dash_gap),
        .dotted => strokeDashed(rnd, r, w, w, w),
    }
}

/// One filled border bar (ignoring render errors — a dropped border is cosmetic).
fn fillBar(rnd: Renderer, rect: FRect) void {
    rnd.renderFillRect(rect) catch {};
}

/// Stroke all four edges of `r` as dash segments of `dash`px on / `gap`px off, each bar
/// `w`px thick and inward. Corners may double-paint by up to `w`px — harmless (opaque).
fn strokeDashed(rnd: Renderer, r: Rect, w: f32, dash: f32, gap: f32) void {
    dashRun(rnd, r.x, r.y, r.w, w, true, dash, gap); // top
    dashRun(rnd, r.x, r.y + r.h - w, r.w, w, true, dash, gap); // bottom
    dashRun(rnd, r.x, r.y, r.h, w, false, dash, gap); // left
    dashRun(rnd, r.x + r.w - w, r.y, r.h, w, false, dash, gap); // right
}

/// Emit dash segments along one edge. `horizontal` runs along +x (bars `thick` tall);
/// otherwise along +y (bars `thick` wide). The final dash is clipped to the edge length.
fn dashRun(rnd: Renderer, x: f32, y: f32, len: f32, thick: f32, horizontal: bool, dash: f32, gap: f32) void {
    var off: f32 = 0;
    while (off < len) : (off += dash + gap) {
        const seg = @min(dash, len - off);
        const rect: FRect = if (horizontal)
            .{ .x = x + off, .y = y, .w = seg, .h = thick }
        else
            .{ .x = x, .y = y + off, .w = thick, .h = seg };
        rnd.renderFillRect(rect) catch {};
    }
}
