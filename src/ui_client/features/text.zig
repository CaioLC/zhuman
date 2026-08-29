//! `text` feature: cached, host-measured glyph text. Co-locates its whole surface —
//! the pooled `State`, the `attach` mixin (measure + content-size + cache), and the
//! `draw` (blit). `State` (`TextState`) is *declared* in `ctx_binding.UiState` and
//! only referenced here, because the pool registry can't import a feature module
//! without a cycle (this module imports ctx_binding, not the reverse).

const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");
const font = @import("../../font.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "text";
pub const Payload = ?cb.Color;
pub const State = cb.UiState.TextState;

/// Give `node` cached text — measured at build (the host has the font on hand),
/// content-sized, and flagged for the render walk. Apply it **after** the node is
/// wired into the tree, so `node.key` is final. Overrides both size axes to `.content`,
/// keeping the node's existing padding.
pub fn attach(ctx: *UiCtx, node: *Node, text: []const u8) !void {
    const st = node.state(ctx, State);
    st.update(text);
    st.px = font.default_px; // default; `style.apply` overrides + re-measures for a heading
    const tw, const th, const baseline = try ctx.res.platform.font.measureBaseline(text, st.px);
    var size = node.size;
    size.w = .content;
    size.h = .content;
    size.data_width = @floatFromInt(tw);
    size.data_height = @floatFromInt(th);
    size.baseline = baseline; // text baseline (from bottom) → cross-axis reference for rows
    node.size = size;
    node.render_data.text = ctx.res.view.theme.fg; // present ⟹ walk blits it; caller may recolor
}

/// Blit the node's cached text in `c` over its content box. Rasterizes each frame (a
/// short string is cheap — unlike `svg`, which caches its raster in `State`).
pub fn draw(u: *UiCtx, node: *Node, c: cb.Color) void {
    const st = node.state(u, State);
    const fmt = st.text() orelse return;
    const r = paint.content(node) orelse return;

    // Render at the size stored on the state (default, or a heading size from `apply`), so
    // glyphs fill the content box that was measured at the same size.
    const f = u.res.platform.font.at(st.px) catch return;
    var surface = f.renderTextSolid(fmt, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    defer surface.deinit();
    const texture = u.res.platform.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();
    u.res.platform.renderer.renderTexture(texture, null, paint.frect(r)) catch return;
}
