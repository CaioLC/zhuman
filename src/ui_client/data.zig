//! Feature mixins: give a node persistent or measured data (cached text, a texture, a
//! sprite-sheet cell) and size it to match. Called right after a node is wired into the
//! tree (so `node.key` is final) by `widgets.zig`'s builder functions.

const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("../font.zig");
const cb = @import("./ctx_binding.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;
const TextData = zfont.TextData;

/// Feature mixin: give `node` cached text — measured at build, content-sized, and
/// flagged for the render walk. Apply it **after** the node is wired into the tree,
/// so `node.key` is final (see `Node.rekey`). Overrides both size axes to `.content`,
/// keeping the node's existing padding.
pub fn data_text(ctx: *UiCtx, node: *Node, text: []const u8) !void {
    const idx = ctx.cache(node.key, TextData);
    ctx.pool(TextData).get(idx).update(text);
    node.data = idx;

    // Measure the content here, at build — the host has the font on hand. The
    // engine never measures; it just reads these dims (`content` rule + renderer).
    const tw, const th = try ctx.res.font.getStringSize(text);
    var size = node.size;
    size.w = .content;
    size.h = .content;
    size.data_width = @floatFromInt(tw);
    size.data_height = @floatFromInt(th);
    node.size = size;
    node.render_data.text = ctx.res.theme.fg; // present ⟹ render walk blits it; caller may recolor
}

/// Feature mixin: give `node` a cached texture (owned by `Resources`, not pooled per-node
/// like `TextData`). Sizes the node to the whole texture and flags the `img` aspect.
pub fn data_img(_: *UiCtx, node: *Node, texture: sdl.render.Texture) !void {
    const w, const h = try texture.getSize();
    node.size = ui.features.Size.initContent(w, h, null);
    node.render_data.img = .{ .texture = texture };
}

/// Feature mixin: draw one `src` cell of a sprite sheet at a fixed `px`×`px` on screen.
/// Unlike `data_img`, the display size is the caller's choice (sheet cells are large),
/// so the source rect and on-screen box are decoupled.
pub fn data_sprite(_: *UiCtx, node: *Node, sprite: Sprite, px: f32) !void {
    node.size = ui.features.Size.initContent(px, px, null);
    node.render_data.img = sprite;
}
