//! `img` feature: a textured draw — a whole texture, or one cell of a sprite sheet.
//! Stateless (the texture lives on `Resources`, not pooled per-node), so no `State`.
//! Two `attach` flavors differ only in how the node is sized: `attach_texture` fits
//! the whole texture; `attach_sprite` draws a sheet cell at a caller-chosen `px`.

const ui = @import("../../ui/root.zig");
const sdl = @import("sdl3");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;

pub const name = "img";
pub const Payload = ?Sprite;

/// Whole-texture image: size the node to the texture, flag the `img` aspect.
pub fn attach_texture(_: *UiCtx, node: *Node, texture: sdl.render.Texture) !void {
    const w, const h = try texture.getSize();
    node.size = ui.features.Size.initContent(w, h);
    node.render_data.img = .{ .texture = texture };
}

/// One `src` cell of a sprite sheet, drawn at `px`×`px` (display size decoupled from
/// the source cell, which is large).
pub fn attach_sprite(_: *UiCtx, node: *Node, sprite: Sprite, px: f32) !void {
    node.size = ui.features.Size.initContent(px, px);
    node.render_data.img = sprite;
}

/// Blit `sprite` (whole texture, or its `src` cell) into the node's content box.
pub fn draw(u: *UiCtx, node: *Node, sprite: Sprite) void {
    const r = paint.content(node) orelse return;
    u.res.renderer.renderTexture(sprite.texture, sprite.src, paint.frect(r)) catch return;
}
