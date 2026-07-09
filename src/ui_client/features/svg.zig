//! `svg` feature — the proof that the interface holds for a *resource-owning,
//! invalidating* state, the shape `text` and `img` never exercised.
//!
//! An SVG is expensive to rasterize, so — unlike `text` (re-rasterized every frame) —
//! its `State` (`SvgState`) **caches** the produced texture, and `attach` re-rasterizes
//! only when the source or size changes (a hash compare, cheap to do every frame). That
//! cached texture is a GPU resource, so `SvgState.deinit` frees it and the pool's
//! eviction hook (`cache.zig`) calls it when the node disappears — without which every
//! scrolled-away / closed SVG would leak a texture. Rasterization is SDL_image
//! (`build.zig` enables `ext_image` + SVG); `sdl.image.loadTexture` reads an `.svg`
//! path into a texture.

const std = @import("std");
const ui = @import("../../ui/root.zig");
const sdl = @import("sdl3");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "svg";
pub const Payload = ?cb.Color; // tint
pub const State = cb.UiState.SvgState;

/// Give `node` a cached SVG raster from `path`, drawn at `px`×`px`, tinted `theme.fg`
/// by default (the caller may recolor `node.render_data.svg`). Re-rasterizes only when
/// `path`/`px` change, so the expensive load happens once and then never until the
/// source does — the invalidation `text` doesn't need and `img` can't express.
pub fn attach(ctx: *UiCtx, node: *Node, path: [:0]const u8, px: f32) !void {
    const st = node.state(ctx, State);
    const k = key_of(path, px);
    if (st.src_key != k) {
        st.deinit(); // free the previous rasterization (if any) before replacing it
        st.tex = sdl.image.loadTexture(ctx.res.renderer.*, path) catch null;
        st.src_key = k;
    }
    node.size = ui.features.Size.initContent(px, px, null);
    node.render_data.svg = ctx.res.theme.fg;
}

/// Blit the cached raster over the node's content box, tinted `c`.
pub fn draw(u: *UiCtx, node: *Node, c: cb.Color) void {
    const tex = node.state(u, State).tex orelse return;
    const r = paint.content(node) orelse return;
    tex.setColorMod(c.r, c.g, c.b) catch {};
    tex.setAlphaMod(c.a) catch {};
    u.res.renderer.renderTexture(tex, null, paint.frect(r)) catch return;
}

/// Invalidation key: the source path folded with the target size. A change in either
/// misses the cache and triggers a re-rasterization in `attach`.
fn key_of(path: []const u8, px: f32) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(path);
    h.update(std.mem.asBytes(&px));
    return h.final();
}
