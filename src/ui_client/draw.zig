//! Render primitives: paint one already-laid-out node in a given color. Each fn is the
//! host's answer to one `RenderData` aspect (`text`/`img`/`fill`/`outline`) — `tree.zig`'s
//! `draw_tree` is the only caller, switching on which aspects a node carries.

const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const cb = @import("./ctx_binding.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;
const TextData = cb.UiState.TextData;

/// Draw a text node: resolve its cached `TextData` via `node.data` and blit it in `c`.
/// One render primitive per `RenderData` aspect; the host's render loop (`tree.draw_tree`)
/// unwraps each optional aspect and passes its color in. `data` should be non-null
/// whenever `text` is present — the guard is belt-and-suspenders.
pub fn draw_text(u: *UiCtx, node: *Node, c: ui.Color) void {
    const idx = node.data orelse return;
    const td = u.pool(TextData).get(idx);
    const s = node.size;
    const l = node.layout;
    const fmt = td.text() orelse return;

    var surface = u.res.font.renderTextSolid(fmt, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    defer surface.deinit();
    const texture = u.res.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();

    const dst = sdl.rect.FRect{
        .x = (l._global_x orelse return) + s.padding.left,
        .y = (l._global_y orelse return) + s.padding.up,
        .w = s.data_width,
        .h = s.data_height,
    };
    u.res.renderer.renderTexture(texture, null, dst) catch return;
}

/// Draw a textured node: blit `sprite` (whole texture, or its `src` cell) into the
/// node's resolved box. Same dst geometry as `draw_text` — global pos inset by padding,
/// sized by the node's measured `data_*` dims.
pub fn draw_texture(u: *UiCtx, node: *Node, sprite: Sprite) void {
    const s = node.size;
    const l = node.layout;
    const dst = sdl.rect.FRect{
        .x = (l._global_x orelse return) + s.padding.left,
        .y = (l._global_y orelse return) + s.padding.up,
        .w = s.data_width,
        .h = s.data_height,
    };
    u.res.renderer.renderTexture(sprite.texture, sprite.src, dst) catch return;
}

/// The node's resolved on-screen box (global pos from layout + solved size), or null
/// if it hasn't been laid out yet. The shape SDL's rect primitives draw into.
fn node_box(node: *Node) ?sdl.rect.FRect {
    return .{
        .x = node.layout._global_x orelse return null,
        .y = node.layout._global_y orelse return null,
        .w = node.size.width,
        .h = node.size.height,
    };
}

/// Draw a fill node: a solid rect in color `c` over its resolved box.
pub fn draw_fill(u: *UiCtx, node: *Node, c: ui.Color) void {
    const box = node_box(node) orelse return;
    u.res.renderer.setDrawColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    u.res.renderer.renderFillRect(box) catch return;
}

/// Draw an outline node: a box border in color `c` around its resolved box.
pub fn draw_outline(u: *UiCtx, node: *Node, c: ui.Color) void {
    const box = node_box(node) orelse return;
    u.res.renderer.setDrawColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    u.res.renderer.renderRect(box) catch return;
}
