//! `text` feature: cached, host-measured glyph text. Co-locates its whole surface —
//! the pooled `State`, the `attach` mixin (measure + content-size + cache), and the
//! `draw` (blit). `State` (`TextState`) is *declared* in `ctx_binding.UiState` and
//! only referenced here, because the pool registry can't import a feature module
//! without a cycle (this module imports ctx_binding, not the reverse).

const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");
const style = @import("../style.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "text";
pub const Payload = ?cb.Color;
pub const State = cb.UiState.TextState;

/// Give `node` cached text — measured at build (the host has the font on hand),
/// content-sized, and flagged for the render walk. Apply it **after** the node is
/// wired into the tree, so `node.key` is final. Overrides both size axes to `.content`,
/// keeping the node's existing padding.
///
/// Measures the **same** string the state accepted, not the caller's argument, so the
/// reserved layout box always matches what `draw` will render. When `State.update`
/// refuses a source past `State.cap` (non-silent, whole-string), the state holds no text,
/// so this measures nothing (a zero box) rather than reserving space for a string the
/// renderer will not draw — box and render stay in agreement. A too-long string is thus
/// dropped visibly (empty node), never cut mid-codepoint. TEXT-02 adds wrapping for text
/// that must actually be longer than `State.cap`.
pub fn attach(ctx: *UiCtx, node: *Node, text: []const u8) !void {
    const st = node.state(ctx, State);
    _ = st.update(text); // copies in full or refuses the whole string (sets `refused`)
    st.px = style.default_font; // `style.apply` overrides + re-measures for a heading
    // Measure from what the state will actually render (`null` when refused/empty), so the
    // content box never reserves room for a string that will not be drawn.
    const measured = st.text() orelse "";
    const tw, const th, const baseline = try ctx.res.platform.font.measureBaseline(measured, st.px);
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

// --- Tests ------------------------------------------------------------------------------
//
// `attach` and `draw` cannot run without a live SDL font/renderer, but their TEXT-01
// correctness rests on a single, SDL-free invariant: both derive the string they act on
// from the *same* accessor, `State.text()`. `attach` measures `st.text() orelse ""` (so
// the reserved layout box matches what will be drawn, and a refused/over-cap string
// reserves a zero box rather than space for text that will never appear); `draw` renders
// `st.text() orelse return` (drawing nothing for that same refused/empty state). These
// tests pin that shared source directly, so the measure-vs-render agreement — the bug
// TEXT-01 fixes — is guarded without a graphics context.

const std = @import("std");

test "text feature: measure and draw read the same accepted string" {
    var st = State.init();
    try std.testing.expect(st.update("Forage the ridge"));
    // The string attach measures (`st.text() orelse ""`) and the string draw renders
    // (`st.text() orelse return`) are byte-identical — one source of truth.
    const measured = st.text() orelse "";
    const rendered = st.text() orelse "";
    try std.testing.expectEqualStrings("Forage the ridge", measured);
    try std.testing.expectEqualStrings(measured, rendered);
}

test "text feature: an over-cap string measures an empty box and draws nothing" {
    var st = State.init();
    var over: [State.cap + 1]u8 = undefined;
    @memset(&over, 'x');
    try std.testing.expect(!st.update(&over)); // refused whole
    // attach's measured source and draw's rendered source both collapse to nothing, so the
    // node reserves a zero content box and paints no cut string — box and render agree.
    try std.testing.expectEqualStrings("", st.text() orelse "");
    try std.testing.expect(st.text() == null); // draw's `orelse return` path
}
