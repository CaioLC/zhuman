//! `text` feature: cached, host-measured glyph text. Co-locates its whole surface —
//! the pooled `State`, the `attach` mixin (measure + content-size + cache), and the
//! `draw` (blit). `State` (`TextState`) is *declared* in `ctx_binding.UiState` and
//! only referenced here, because the pool registry can't import a feature module
//! without a cycle (this module imports ctx_binding, not the reverse).

const ui = @import("../../ui/root.zig");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "text";
pub const Payload = ?ui.Color;
pub const State = cb.UiState.TextState;

/// Give `node` cached text — measured at build (the host has the font on hand),
/// content-sized, and flagged for the render walk. Apply it **after** the node is
/// wired into the tree, so `node.key` is final. Overrides both size axes to `.content`,
/// keeping the node's existing padding.
pub fn attach(ctx: *UiCtx, node: *Node, text: []const u8) !void {
    node.state(ctx, State).update(text);
    const tw, const th = try ctx.res.font.getStringSize(text);
    var size = node.size;
    size.w = .content;
    size.h = .content;
    size.data_width = @floatFromInt(tw);
    size.data_height = @floatFromInt(th);
    node.size = size;
    node.render_data.text = ctx.res.theme.fg; // present ⟹ walk blits it; caller may recolor
}

/// Blit the node's cached text in `c` over its content box. Rasterizes each frame (a
/// short string is cheap — unlike `svg`, which caches its raster in `State`).
pub fn draw(u: *UiCtx, node: *Node, c: ui.Color) void {
    const fmt = node.state(u, State).text() orelse return;
    const r = paint.content(node) orelse return;

    var surface = u.res.font.renderTextSolid(fmt, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    defer surface.deinit();
    const texture = u.res.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();
    u.res.renderer.renderTexture(texture, null, paint.frect(r)) catch return;
}
