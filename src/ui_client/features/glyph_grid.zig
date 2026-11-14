//! `glyph_grid` feature — a grid of monospace cells, one glyph and one ink each, for a
//! surface that is composed cell by cell and changes every frame: an ASCII scene.
//!
//! Text leaves are the wrong tool for that. A text node caches one texture for its whole
//! string and re-rasterizes it when the string changes, so a row that changes every tick
//! is rasterized every tick. Here the thing cached is the **glyph**: each distinct
//! codepoint is rasterized white once, at the grid's size, into a texture the node's
//! pooled state owns, and a frame is one tinted blit a filled cell (tint-on-blit, the
//! `text_cache` and `svg` strategy). Changing a cell never rasterizes anything.
//!
//! The cells themselves are the pure, SDL-free `glyph_cells.Cells`; this module is the
//! part that touches the font and the renderer. A cell is the font's advance wide and
//! `line_em` of its size tall (a CSS `line-height`), with the glyph centred on the line, so
//! the node is `cols` × `rows` of those. The glyphs are rasterized the way text is, one-bit
//! or anti-aliased by the player's TEXT setting.

const std = @import("std");
const sdl = @import("sdl3");
const ui = @import("ui");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");
const cells_mod = @import("glyph_cells.zig");
const text = @import("text.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "glyph_grid";
pub const Payload = ?cb.GlyphGrid;
pub const State = cb.UiState.GlyphGridState;

pub const Cells = cells_mod.Cells;
pub const Clip = cells_mod.Clip;

/// Give `node` the grid `cells`, drawn at `logical_px` on lines `line_em` of that tall, with
/// `palette[ink]` the color of an ink (a cell whose ink is past the palette draws nothing).
/// Copies the cells into the node's pooled state, so the caller's buffer need not outlive
/// the call, and sizes the node to the grid.
pub fn attach(ctx: *UiCtx, node: *Node, cells: *const Cells, palette: []const cb.Color, logical_px: f32, line_em: f32) void {
    const st = node.state(ctx, State);
    st.cells = cells.*;
    st.palette_len = @intCast(@min(palette.len, State.palette_cap));
    @memcpy(st.palette[0..st.palette_len], palette[0..st.palette_len]);
    st.px = @import("../type.zig").toDevice(logical_px, ctx.res.view.scale);

    st.cell_w = advance(ctx, st.px);
    st.cell_h = st.px * line_em;
    node.size = ui.features.Size.initContent(
        st.cell_w * @as(f32, @floatFromInt(cells.cols)),
        st.cell_h * @as(f32, @floatFromInt(cells.rows)),
    );
    node.render_data.glyph_grid = .{};
}

/// The font's advance at `px`, the width of a cell. Zero when the font cannot be had.
fn advance(ctx: *UiCtx, px: f32) f32 {
    const f = ctx.res.platform.font.at(px) catch return 0;
    const w, _ = f.getStringSize("M") catch return 0;
    return @floatFromInt(w);
}

/// Paint every filled cell: its glyph's texture, tinted its ink's color, at its place in
/// the node's content box. A glyph met for the first time is rasterized here.
pub fn draw(u: *UiCtx, node: *Node, _: cb.GlyphGrid, opacity: f32) void {
    const st = node.state(u, State);
    const r = paint.content(node) orelse return;
    if (st.cell_w <= 0 or st.cell_h <= 0) return;

    // The glyph textures belong to one size, one rasterizer and one renderer. A new size or
    // TEXT setting frees them; a renderer reset has already destroyed them, so they are
    // dropped unfreed.
    const generation = u.res.platform.generation;
    const smooth = u.res.view.text_smooth;
    if (st.tex_generation != generation) {
        st.abandonGlyphs();
    } else if (st.tex_px != st.px or st.tex_smooth != smooth) {
        st.deinit();
    }
    st.tex_generation = generation;
    st.tex_px = st.px;
    st.tex_smooth = smooth;

    const f = u.res.platform.font.at(st.px) catch return;
    const x0 = @floor(r.x);
    const y0 = @floor(r.y);
    const cols: usize = st.cells.cols;
    for (st.cells.ink[0..st.cells.count()], 0..) |ink, i| {
        if (ink == 0 or ink >= st.palette_len) continue;
        const g = glyph(u, st, f, st.cells.glyph[i]) orelse continue;
        const tex = g.tex orelse continue;
        const c = paint.applyOpacity(st.palette[ink], opacity);
        tex.setColorMod(c.r, c.g, c.b) catch {};
        tex.setAlphaMod(c.a) catch {};
        // The glyph's box is centred on its line, as a CSS line box centres it, and both
        // land on whole pixels.
        const line_y = st.cell_h * @as(f32, @floatFromInt(i / cols));
        const dst: ui.Rect = .{
            .x = x0 + st.cell_w * @as(f32, @floatFromInt(i % cols)),
            .y = y0 + @round(line_y + (st.cell_h - g.h) / 2),
            .w = g.w,
            .h = g.h,
        };
        u.res.platform.renderer.renderTexture(tex, null, paint.frect(dst)) catch {};
    }
}

/// The cached glyph for `cp`, rasterizing it on first sight. A glyph that will not
/// rasterize keeps its slot with no texture, so it is not retried every frame; a full
/// table refuses a new glyph, and that cell draws nothing.
fn glyph(u: *UiCtx, st: *State, f: sdl.ttf.Font, cp: u16) ?*State.Glyph {
    for (st.glyphs[0..st.glyph_len]) |*g| if (g.cp == cp) return g;
    if (st.glyph_len == State.glyph_cap) return null;
    const g = &st.glyphs[st.glyph_len];
    st.glyph_len += 1;
    g.* = .{ .cp = cp };

    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return g;
    const white: sdl.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    var surface = (if (st.tex_smooth) f.renderTextBlended(buf[0..n], white) else f.renderTextSolid(buf[0..n], white)) catch return g;
    defer surface.deinit();
    if (st.tex_smooth) text.liftCoverage(surface);
    const tex = u.res.platform.renderer.createTextureFromSurface(surface) catch return g;
    tex.setBlendMode(.blend) catch {};
    const w, const h = f.getStringSize(buf[0..n]) catch {
        tex.deinit();
        return g;
    };
    g.tex = tex;
    g.w = @floatFromInt(w);
    g.h = @floatFromInt(h);
    return g;
}

test {
    _ = cells_mod;
}
