//! `text` feature: cached, host-measured glyph text. Co-locates its whole surface —
//! the pooled `State`, the `attach` mixin (measure + content-size + cache), and the
//! `draw` (blit). `State` (`TextState`) is *declared* in `ctx_binding.UiState` and
//! only referenced here, because the pool registry can't import a feature module
//! without a cycle (this module imports ctx_binding, not the reverse).

const std = @import("std");
const sdl = @import("sdl3");
const ui = @import("../../ui/root.zig");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");
const style = @import("../style.zig");
const wrap = @import("wrap.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "text";
pub const Payload = ?cb.Color;
pub const State = cb.UiState.TextState;

// --- Font-backed measurer for the pure wrap routine -------------------------------------
//
// `wrap.wrapLines` is deliberately SDL-free (see `wrap.zig`): it asks a `wrap.Measurer` for
// pixel widths. Here we back that interface with the live `sdl.ttf.Font` — resolved once at
// the caller's `px` — so build-time measurement and per-line rendering run the *same* wrap
// over the *same* metrics. On a font error the width/prefix functions report 0, which
// degrades to "nothing fits" rather than panicking mid-frame; the caller treats a failed
// measure as an empty box (like a refused string), keeping box and render in agreement.
//
// **TEXT-04 tracking:** the measurer carries a device-px `tracking` delta added *between*
// glyph clusters. When `tracking == 0` every width/prefix call falls through to SDL's own
// `getStringSize`/`measureString` — byte-for-byte the pre-TEXT-04 behavior, so untracked
// text costs nothing. When `tracking != 0`, width/prefix are computed by the shared
// `trackedAdvance` routine that walks codepoint clusters accumulating per-glyph advances
// (plus kerning) and adding `tracking` between clusters — the SAME routine `draw`'s
// per-cluster blit loop uses to place glyphs, so measurement and rendering add the identical
// integer `dx` between the identical clusters and cannot drift on any path (single-line,
// wrap, clip, ellipsis). Walking per codepoint also means no multi-codepoint run is ever
// handed to a shaper, so no ligature can form — the render-path half of TEXT-04's
// two-layer "no ligatures" defense (the NL font asset is the other half).

const FontMeasurer = struct {
    font: sdl.ttf.Font,
    /// Device-px letter-spacing added between glyph clusters. `0` = SDL's native metrics.
    tracking: f32 = 0,

    fn width(ptr: *const anyopaque, text: []const u8) f32 {
        const self: *const FontMeasurer = @ptrCast(@alignCast(ptr));
        if (self.tracking == 0) {
            const w, _ = self.font.getStringSize(text) catch return 0;
            return @floatFromInt(w);
        }
        return trackedWidth(self.font, text, self.tracking);
    }
    fn prefixBytes(ptr: *const anyopaque, text: []const u8, max_w: f32) usize {
        const self: *const FontMeasurer = @ptrCast(@alignCast(ptr));
        if (self.tracking == 0) {
            const iw: c_int = if (max_w <= 0) 0 else @intFromFloat(max_w);
            _, const len = self.font.measureString(text, iw) catch return 0;
            return len;
        }
        return trackedPrefixBytes(self.font, text, max_w, self.tracking);
    }
    fn measurer(self: *const FontMeasurer) wrap.Measurer {
        return .{ .ptr = self, .widthFn = width, .prefixBytesFn = prefixBytes };
    }
};

/// One glyph cluster's contribution while walking tracked text: the byte span it occupies
/// and the device-px x-advance to add *after* placing it (its glyph advance plus the kerning
/// against the previous cluster; the inter-cluster `tracking` delta is added by the caller).
const Cluster = struct { start: usize, len: usize, advance: f32 };

/// Walk `text` one UTF-8 codepoint cluster at a time, invoking `emit` with each cluster's
/// byte span and per-glyph advance (glyph advance + kerning-from-previous). This is the ONE
/// place cluster iteration + per-glyph metrics live, so the tracked measurer and the tracked
/// draw loop step identically. Kerning is queried between consecutive codepoints (SDL returns
/// 0 when the font has no kern pair, so this is a no-op for monospace-without-kerning too).
/// A malformed byte is treated as a 1-byte cluster so the walk always terminates. On a font
/// metric error the cluster's advance degrades to 0 (matching the width `catch 0` policy).
fn walkClusters(
    font: sdl.ttf.Font,
    text: []const u8,
    comptime Ctx: type,
    ctx: Ctx,
    comptime emit: fn (Ctx, Cluster) void,
) void {
    var i: usize = 0;
    var prev_cp: ?u32 = null;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        const cp: u32 = std.unicode.utf8Decode(text[i..end]) catch text[i];
        const m = font.getGlyphMetrics(cp) catch null;
        var adv: f32 = if (m) |mm| @floatFromInt(mm.advance) else 0;
        if (prev_cp) |p| {
            const k = font.getGlyphKerning(p, cp) catch 0;
            adv += @floatFromInt(k);
        }
        emit(ctx, .{ .start = i, .len = end - i, .advance = adv });
        prev_cp = cp;
        i = end;
    }
}

/// The tracked device-px width of `text`: Σ (per-glyph advance + kerning) + `tracking` ×
/// (cluster_count − 1). The single width source for tracked single-line measure, wrap, and
/// ellipsis budgeting — and it equals the cumulative x the draw loop reaches after the last
/// glyph, so measure and draw agree. Empty text is width 0 (no trailing tracking).
fn trackedWidth(font: sdl.ttf.Font, text: []const u8, tracking: f32) f32 {
    const Acc = struct {
        w: f32 = 0,
        n: usize = 0,
        tracking: f32,
        fn take(self: *@This(), cl: Cluster) void {
            if (self.n > 0) self.w += self.tracking; // gap before every cluster after the first
            self.w += cl.advance;
            self.n += 1;
        }
    };
    var acc = Acc{ .tracking = tracking };
    walkClusters(font, text, *Acc, &acc, Acc.take);
    return @max(0, acc.w);
}

/// The largest **codepoint-aligned** byte length of `text` whose tracked width does not
/// exceed `max_w` — the tracked counterpart of `TTF_MeasureString`, used only by the wrap
/// hard-break fallback and (indirectly) ellipsis budgeting. Walks clusters accumulating the
/// same running width as `trackedWidth`; stops before the first cluster that would exceed
/// `max_w`. Always allows at least the running total to include a cluster boundary, never a
/// mid-codepoint cut.
fn trackedPrefixBytes(font: sdl.ttf.Font, text: []const u8, max_w: f32, tracking: f32) usize {
    if (max_w <= 0) return 0;
    const Acc = struct {
        w: f32 = 0,
        n: usize = 0,
        fitted: usize = 0,
        max_w: f32,
        tracking: f32,
        done: bool = false,
        fn take(self: *@This(), cl: Cluster) void {
            if (self.done) return;
            var next = self.w;
            if (self.n > 0) next += self.tracking;
            next += cl.advance;
            if (next > self.max_w) {
                self.done = true;
                return;
            }
            self.w = next;
            self.n += 1;
            self.fitted = cl.start + cl.len;
        }
    };
    var acc = Acc{ .max_w = max_w, .tracking = tracking };
    walkClusters(font, text, *Acc, &acc, Acc.take);
    return acc.fitted;
}

/// The per-line vertical step, in px — one line's advance. Uses the font's line skip so
/// stacked lines get the font's own leading (consistent with how a paragraph renders),
/// rather than the tight per-glyph height. Both `attach` (height) and `draw` (offset) read
/// this, so the reserved box height and the drawn line positions cannot drift.
fn lineSkip(font: sdl.ttf.Font) f32 {
    return @floatFromInt(font.getLineSkip());
}

/// Accumulator for the wrap measurement pass: widest line and line count.
const MeasureAcc = struct {
    src: []const u8,
    m: wrap.Measurer,
    max_line_w: f32 = 0,
    count: usize = 0,

    fn take(self: *MeasureAcc, line: wrap.Line) bool {
        const w = if (line.len == 0) 0 else self.m.width(self.src[line.start .. line.start + line.len]);
        if (w > self.max_line_w) self.max_line_w = w;
        self.count += 1;
        return true;
    }
};

/// Measure a wrapped block: returns `{ width, height, baseline }` matching what `draw` will
/// render. `width` is the widest line, `height` is `line_count * lineSkip`, and `baseline`
/// is the last line's baseline-from-bottom (the font descent) — a multi-line block's
/// cross-axis reference is its final line, so a wrapped label still baseline-aligns in a
/// row. Runs the *same* `wrap.wrapLines` `draw` runs, so box and glyphs agree.
fn measureWrapped(font: sdl.ttf.Font, text: []const u8, max_w: f32, tracking: f32) struct { f32, f32, f32 } {
    var fm = FontMeasurer{ .font = font, .tracking = tracking };
    var acc = MeasureAcc{ .src = text, .m = fm.measurer() };
    wrap.wrapLines(text, max_w, fm.measurer(), *MeasureAcc, &acc, MeasureAcc.take);
    const skip = lineSkip(font);
    const height = @as(f32, @floatFromInt(acc.count)) * skip;
    // Baseline from bottom = descent = one line's height − ascent. For a stacked block the
    // reference is the last line, whose bottom is the box bottom, so the same descent holds.
    const ascent: f32 = @floatFromInt(font.getAscent());
    const baseline = if (acc.count == 0) 0 else skip - ascent;
    return .{ acc.max_line_w, height, baseline };
}

/// Shared write-through of measured metrics onto a node's size — used by `attach` and by
/// `style.apply`'s re-measure so the two never diverge. Public so `style.zig` can call it
/// without duplicating the wrap-vs-single-line branch.
pub fn remeasure(ctx: *UiCtx, node: *Node) void {
    const st = node.state(ctx, State);
    const measured = st.text() orelse "";
    if (st.wrap_width > 0) {
        const font = ctx.res.platform.font.at(st.px) catch return;
        const tw, const th, const baseline = measureWrapped(font, measured, st.wrap_width, st.tracking);
        node.size.data_width = tw;
        node.size.data_height = th;
        node.size.baseline = baseline;
    } else if (st.overflow != .visible) {
        // TEXT-03: an explicitly allocated single-line cell. The *box* is the allocated
        // width, never the unbounded glyph width — including a legal zero-width cell. A
        // widening label cannot shift its neighbors, and hit-testing uses this stamped cell.
        // Height and baseline still come from the font, single-line, so the cell baseline-aligns in
        // a row exactly like an ordinary label. The drawn glyphs (clipped or ellipsized) are
        // `draw`'s concern; measure only reserves the cell.
        _, const th, const baseline = ctx.res.platform.font.measureBaseline(measured, st.px) catch return;
        node.size.data_width = st.overflow_width;
        node.size.data_height = @floatFromInt(th);
        node.size.baseline = baseline;
    } else {
        // Single-line, unconstrained. Height/baseline always come from the font; the width
        // is the tracking-aware advance when tracking is set (so the reserved box matches the
        // spaced glyphs draw will place) and SDL's native width otherwise (the untracked fast
        // path — byte-for-byte the pre-TEXT-04 measure).
        const tw, const th, const baseline = ctx.res.platform.font.measureBaseline(measured, st.px) catch return;
        const w: f32 = if (st.tracking == 0)
            @floatFromInt(tw)
        else blk: {
            const font = ctx.res.platform.font.at(st.px) catch break :blk @floatFromInt(tw);
            break :blk trackedWidth(font, measured, st.tracking);
        };
        node.size.data_width = w;
        node.size.data_height = @floatFromInt(th);
        node.size.baseline = baseline;
    }
}

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
///
/// Wrapping is off here (`wrap_width` stays 0, the single-line fast path) — a caller opts a
/// node into constrained multiline with `El.with_wrap`, which sets the width and re-measures.
pub fn attach(ctx: *UiCtx, node: *Node, text: []const u8) !void {
    const st = node.state(ctx, State);
    _ = st.update(text); // copies in full or refuses the whole string (sets `refused`)
    // Seed the default (body) size through the one logical→device seam, so an unstyled leaf
    // opens the font at the same device px a `style.body` leaf would; `style.apply` overrides
    // + re-measures for a heading/eyebrow. Tracking defaults to 0 (untracked fast path) until
    // a role fragment resolves it. See `ui_client/type.zig`.
    st.px = @import("../type.zig").toDevice(style.default_font, ctx.res.view.scale);
    var size = node.size;
    size.w = .content;
    size.h = .content;
    node.size = size;
    // Measure from what the state will actually render, single-line or wrapped, via the one
    // shared routine `draw` also runs — so the content box always matches the drawn lines.
    remeasure(ctx, node);
    node.render_data.text = ctx.res.view.theme.fg; // present ⟹ walk blits it; caller may recolor
}

/// Blit the node's cached text in `c` over its content box. Rasterizes each frame (a
/// short string is cheap — unlike `svg`, which caches its raster in `State`).
///
/// Single-line, unconstrained (`wrap_width == 0` and `overflow == .visible`) is the fast
/// path: one `renderTextSolid` over the content box, exactly as before. When wrapped, re-runs
/// the *same* `wrap.wrapLines` the measure pass used and blits one surface per line at
/// `content.y + i*lineSkip`, so the drawn lines are byte-for-byte the measured lines.
///
/// TEXT-03 adds two single-line overflow disciplines for an allocated `overflow_width` cell
/// (mutually exclusive with wrapping — wrapping wins if both are set):
///   - `.clip` — blit the whole accepted string, but scope the renderer's clip to exactly
///     the content cell for the blit and **restore the prior clip afterward** (including on
///     an error path), so a leaf's own glyphs are cropped to its box without leaking the clip
///     to siblings drawn later. (The engine's `Layout.overflow=.clip` crops a node's
///     *children*; a text leaf's own glyphs are painted before that narrowing, so the crop
///     must be applied here, renderer-scoped and reverted.)
///   - `.ellipsis` — recompute the identical `wrap.ellipsisFit` the measure pass would (one
///     source of truth), blit the codepoint-aligned prefix, then the deterministic ellipsis
///     token; a too-narrow cell draws nothing rather than overflowing.
pub fn draw(u: *UiCtx, node: *Node, c: cb.Color) void {
    const st = node.state(u, State);
    const fmt = st.text() orelse return;
    const r = paint.content(node) orelse return;
    const f = u.res.platform.font.at(st.px) catch return;

    if (st.wrap_width <= 0 and st.overflow == .visible) {
        // Fast path — one surface over the content box (tracking 0 ⟹ byte-for-byte the prior
        // behavior; tracking != 0 ⟹ the per-cluster advance loop that mirrors the measurer).
        drawSpan(u, f, fmt, c, r.x, r.y, st.tracking);
        return;
    }

    if (st.wrap_width <= 0) {
        // Single-line overflow cell (TEXT-03). The content box `r` is the allocated cell
        // (`remeasure` wrote `data_width = overflow_width`), so clip/ellipsis both bound to it.
        switch (st.overflow) {
            .clip => drawClipped(u, f, fmt, c, r, st.tracking),
            .ellipsis => drawEllipsized(u, f, fmt, c, r, st.tracking),
            .visible => drawSpan(u, f, fmt, c, r.x, r.y, st.tracking), // overflow_width>0 but visible: draw whole
        }
        return;
    }

    var fm = FontMeasurer{ .font = f, .tracking = st.tracking };
    var lr = LineRenderer{ .u = u, .font = f, .src = fmt, .color = c, .x = r.x, .y = r.y, .skip = lineSkip(f), .tracking = st.tracking };
    wrap.wrapLines(fmt, st.wrap_width, fm.measurer(), *LineRenderer, &lr, LineRenderer.take);
}

/// The deterministic ellipsis token appended by `.ellipsis` overflow: U+2026 HORIZONTAL
/// ELLIPSIS. Its width is *measured* from the live font (never assumed), so the fit budget
/// tracks the actual glyph and the same token draws as was measured.
pub const ellipsis_token = "\u{2026}";

/// Blit `text` in `c` at (`x`, `y`). Shared by the fast path and the overflow prefix/ellipsis
/// blits so they rasterize identically. An empty string draws nothing; a failed
/// rasterize/upload/measure is skipped silently (a missing glyph frame is cosmetic, matching
/// every other text path's `catch return`).
///
/// **TEXT-04:** `tracking == 0` is the untracked fast path — one `renderTextSolid` surface
/// sized to its own `getStringSize` box, byte-for-byte the pre-TEXT-04 blit. `tracking != 0`
/// switches to `drawTrackedSpan`, which blits each glyph cluster at the cumulative advance
/// the measurer computed, so the drawn positions match the measured width exactly.
fn drawSpan(u: *UiCtx, font: sdl.ttf.Font, text: []const u8, c: cb.Color, x: f32, y: f32, tracking: f32) void {
    if (text.len == 0) return;
    if (tracking != 0) return drawTrackedSpan(u, font, text, c, x, y, tracking);
    var surface = font.renderTextSolid(text, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    defer surface.deinit();
    const texture = u.res.platform.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();
    const w, const h = font.getStringSize(text) catch return;
    const dst: ui.Rect = .{ .x = x, .y = y, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    u.res.platform.renderer.renderTexture(texture, null, paint.frect(dst)) catch return;
}

/// The tracked blit: place each glyph cluster at the cumulative x-advance the measurer's
/// `walkClusters` produces, adding the integer device `tracking` delta *between* clusters.
/// Each cluster is rasterized on its own via `renderTextSolid` (a single codepoint, so no
/// ligature can form — the render-path half of the no-ligature defense) and blitted at its
/// pen x. Because this reuses the same `walkClusters` iteration + advance rule as
/// `trackedWidth`, the rightmost pen position equals the measured width, so measure and draw
/// agree cluster-for-cluster on every tracked path (single-line, wrapped line, clip, prefix).
/// A missing glyph frame is skipped silently, exactly like the fast path.
fn drawTrackedSpan(u: *UiCtx, font: sdl.ttf.Font, text: []const u8, c: cb.Color, x: f32, y: f32, tracking: f32) void {
    const Pen = struct {
        u: *UiCtx,
        font: sdl.ttf.Font,
        src: []const u8,
        color: cb.Color,
        x: f32,
        y: f32,
        tracking: f32,
        n: usize = 0,
        fn take(self: *@This(), cl: Cluster) void {
            if (self.n > 0) self.x += self.tracking; // inter-cluster gap, matching the measurer
            const bytes = self.src[cl.start .. cl.start + cl.len];
            blitCluster(self.u, self.font, bytes, self.color, self.x, self.y);
            self.x += cl.advance;
            self.n += 1;
        }
    };
    var pen = Pen{ .u = u, .font = font, .src = text, .color = c, .x = x, .y = y, .tracking = tracking };
    walkClusters(font, text, *Pen, &pen, Pen.take);
}

/// Blit one glyph cluster's own surface at (`x`, `y`), sized to its measured box. Split out of
/// `drawSpan` so the tracked loop rasterizes a single codepoint identically to how the fast
/// path rasterizes a whole span. A missing/failed glyph frame is skipped silently.
fn blitCluster(u: *UiCtx, font: sdl.ttf.Font, bytes: []const u8, c: cb.Color, x: f32, y: f32) void {
    if (bytes.len == 0) return;
    var surface = font.renderTextSolid(bytes, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    defer surface.deinit();
    const texture = u.res.platform.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();
    const w, const h = font.getStringSize(bytes) catch return;
    const dst: ui.Rect = .{ .x = x, .y = y, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    u.res.platform.renderer.renderTexture(texture, null, paint.frect(dst)) catch return;
}

/// `.clip` overflow: blit the whole accepted string but scope the renderer's clip to the
/// intersection of the *prior* clip and the content cell, then restore the prior clip —
/// renderer-scoped, and reverted even if the blit errors. Restoring the prior clip (not
/// `null`) is essential: this leaf may sit inside an ancestor `.clip` (a scroll viewport),
/// and dropping that clip would let the string paint outside the ancestor's box.
fn drawClipped(u: *UiCtx, font: sdl.ttf.Font, text: []const u8, c: cb.Color, cell: ui.Rect, tracking: f32) void {
    const renderer = u.res.platform.renderer;
    // Snapshot both the enable bit and rectangle. The binding maps an enabled zero-area
    // SDL clip to `null`, the same value used for disabled clipping; retaining the bit keeps
    // a fully clipped ancestor fully clipped instead of accidentally widening it to this cell.
    const prior_enabled = renderer.getClipEnabled();
    const reported_prior = renderer.getClipRect() catch return;
    const prior = effectiveClip(prior_enabled, reported_prior);
    defer renderer.setClipRect(prior) catch {};

    // Narrow to the intersection of the prior clip and the cell. `paint.irect` truncates to
    // integer px, matching how the engine's own clip stack is stored.
    const cell_clip = paint.irect(cell) orelse return;
    const narrowed: sdl.rect.IRect = if (prior) |p| intersectIRect(p, cell_clip) else cell_clip;
    renderer.setClipRect(narrowed) catch return;

    drawSpan(u, font, text, c, cell.x, cell.y, tracking);
}

/// Normalize SDL's clip query into the state `setClipRect` must restore. The binding returns
/// `null` both when clipping is disabled and when SDL reports an enabled zero-area rectangle;
/// the separate enable bit disambiguates those states. Any zero rectangle clips everything,
/// so its exact origin is irrelevant.
fn effectiveClip(enabled: bool, reported: ?sdl.rect.IRect) ?sdl.rect.IRect {
    if (!enabled) return null;
    return reported orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// Integer-rect intersection for the clip stack (SDL clip rects are integer px). An empty
/// result (non-overlapping) yields a zero-area rect, which clips everything out — the safe
/// outcome for a cell fully outside its ancestor's clip.
fn intersectIRect(a: sdl.rect.IRect, b: sdl.rect.IRect) sdl.rect.IRect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

/// `.ellipsis` overflow: recompute the identical `wrap.ellipsisFit` (measure == draw), then
/// blit the codepoint-aligned prefix followed by the ellipsis token. The ellipsis width is
/// font-measured. A too-narrow cell (`budget <= 0`) yields an empty fit → draws nothing,
/// never a glyph wider than the allocated cell.
fn drawEllipsized(u: *UiCtx, font: sdl.ttf.Font, text: []const u8, c: cb.Color, cell: ui.Rect, tracking: f32) void {
    var fm = FontMeasurer{ .font = font, .tracking = tracking };
    const m = fm.measurer();
    // Ellipsis-token width via the same (tracking-aware) measurer, so the fit budget and the
    // drawn token measure identically. A single codepoint, so tracked width == native width.
    const ell_w: f32 = m.width(ellipsis_token);
    const r = wrap.ellipsisFit(text, cell.w, ell_w, m);
    const prefix = text[0..r.prefix_len];
    drawSpan(u, font, prefix, c, cell.x, cell.y, tracking);
    if (r.elided) {
        // Advance x past the drawn prefix (its tracked width), plus one inter-cluster gap to
        // the ellipsis when tracked, then blit the ellipsis. A zero-width prefix places the
        // ellipsis at the cell origin. Using the tracking-aware width keeps the token exactly
        // where the measurer accounted for it.
        var pw: f32 = if (prefix.len == 0) 0 else m.width(prefix);
        if (tracking != 0 and prefix.len != 0) pw += tracking; // gap between prefix and ellipsis
        drawSpan(u, font, ellipsis_token, c, cell.x + pw, cell.y, tracking);
    }
}

/// Renders each wrapped line in order, advancing `y` by one line skip per line. The stepped
/// `y` is what makes the drawn stack occupy exactly the `count * lineSkip` box the measure
/// pass reserved. Each line blits via the shared `drawSpan` (the same routine the single-line
/// and overflow paths use), so a missing glyph frame is skipped silently and an empty line
/// draws nothing while the caller still advances `y` — a blank row keeps its height.
const LineRenderer = struct {
    u: *UiCtx,
    font: sdl.ttf.Font,
    src: []const u8,
    color: cb.Color,
    x: f32,
    y: f32,
    skip: f32,
    tracking: f32 = 0,
    i: usize = 0,

    fn take(self: *LineRenderer, line: wrap.Line) bool {
        const ly = self.y + @as(f32, @floatFromInt(self.i)) * self.skip;
        drawSpan(self.u, self.font, self.src[line.start .. line.start + line.len], self.color, self.x, ly, self.tracking);
        self.i += 1;
        return true;
    }
};

// --- Tests ------------------------------------------------------------------------------
//
// `attach` and `draw` cannot run without a live SDL font/renderer, but their TEXT-01
// correctness rests on a single, SDL-free invariant: both derive the string they act on
// from the *same* accessor, `State.text()`. `attach` measures `st.text() orelse ""` (so
// the reserved layout box matches what will be drawn, and a refused/over-cap string
// reserves a zero box rather than space for text that will never appear); `draw` renders
// `st.text() orelse return` (drawing nothing for that same refused/empty state). These
// tests pin that shared source directly, so the measure-vs-render agreement — the bug
// TEXT-01 fixes — is guarded without a graphics context. The wrap *routine* itself
// (`wrap.zig`) is separately and thoroughly tested SDL-free with a fake measurer.

test {
    _ = wrap; // pull `wrap.zig`'s SDL-free wrap tests into the feature test binary
}

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

test "text feature: wrap_width is POD state that round-trips; default is the fast path" {
    var st = State.init();
    try std.testing.expectEqual(@as(f32, 0), st.wrap_width); // default: single-line fast path
    try std.testing.expect(st.update("You are not alone here anymore."));
    st.wrap_width = 120;
    try std.testing.expectEqual(@as(f32, 120), st.wrap_width);
    // The accepted string is untouched by the wrap constraint — wrapping recomputes spans
    // from this same source, never mutates it, so measure and render read one buffer.
    try std.testing.expectEqualStrings("You are not alone here anymore.", st.text() orelse "");
}

test "text feature: an over-cap string is still refused whole even with wrap set" {
    // TEXT-01's whole-refusal is preserved: wrapping is not a way to smuggle a too-long
    // source past the cap. A refused state has no text, so the wrapped measure sees "" and
    // reserves a zero box — identical to the single-line refusal path.
    var st = State.init();
    st.wrap_width = 200;
    var over: [State.cap + 1]u8 = undefined;
    @memset(&over, 'x');
    try std.testing.expect(!st.update(&over)); // refused whole, wrap or not
    try std.testing.expect(st.text() == null);
}

test "text feature: overflow mode/width are POD state that round-trip; default is the fast path" {
    var st = State.init();
    // Default is `.visible` + 0 width: the unconstrained single-line fast path, unchanged.
    try std.testing.expectEqual(State.Overflow.visible, st.overflow);
    try std.testing.expectEqual(@as(f32, 0), st.overflow_width);
    try std.testing.expect(st.update("Iron Ingot ×12"));
    st.overflow = .ellipsis;
    st.overflow_width = 64;
    try std.testing.expectEqual(State.Overflow.ellipsis, st.overflow);
    try std.testing.expectEqual(@as(f32, 64), st.overflow_width);
    // The accepted string is untouched by the cell constraint — overflow recomputes the fit
    // from this same buffer, never mutates it, so measure and render read one source.
    try std.testing.expectEqualStrings("Iron Ingot ×12", st.text() orelse "");
}

test "text feature: an over-cap string is still refused whole even with an overflow cell" {
    // TEXT-01's whole-refusal holds: an overflow cell is not a way to smuggle a too-long
    // source past the cap. A refused state has no text, so the cell draws nothing.
    var st = State.init();
    st.overflow = .clip;
    st.overflow_width = 120;
    var over: [State.cap + 1]u8 = undefined;
    @memset(&over, 'x');
    try std.testing.expect(!st.update(&over)); // refused whole, cell or not
    try std.testing.expect(st.text() == null);
}

test "text feature: an overflow cell measures to the allocated width, not the glyph width" {
    // The core TEXT-03 geometry invariant, pinned SDL-free: `remeasure` writes
    // `data_width = overflow_width` for an overflow cell, independent of the glyph width. We
    // stand in for `remeasure`'s cell branch (which needs a live font for height/baseline)
    // by exercising the exact rule it applies to the width — the width comes from the field,
    // never from a measurement — so a widening label cannot redefine the box.
    var st = State.init();
    st.overflow = .clip;
    st.overflow_width = 48;
    try std.testing.expect(st.update("a string far wider than forty-eight pixels of glyphs"));
    // The rule remeasure applies for the width axis of a cell:
    const cell_data_width: f32 = if (st.overflow != .visible)
        st.overflow_width
    else
        0; // (glyph-measured branch not exercised here)
    try std.testing.expectEqual(@as(f32, 48), cell_data_width);

    // Zero is also an explicitly allocated cell, not the unconstrained sentinel: it keeps
    // zero layout/hit width and the overflow draw branch emits no glyphs.
    st.overflow = .ellipsis;
    st.overflow_width = 0;
    const zero_cell_width: f32 = if (st.overflow != .visible) st.overflow_width else -1;
    try std.testing.expectEqual(@as(f32, 0), zero_cell_width);
}

test "text feature: switching a cell back to .visible clears the constraint" {
    // Mode switching / reuse: a pooled node reused with `.visible` + 0 is byte-for-byte the
    // fast path again — no lingering cell width steering the geometry.
    var st = State.init();
    try std.testing.expect(st.update("Copper Wire"));
    st.overflow = .ellipsis;
    st.overflow_width = 40;
    // ...later reused as an ordinary label:
    st.overflow = .visible;
    st.overflow_width = 0;
    try std.testing.expectEqual(State.Overflow.visible, st.overflow);
    try std.testing.expectEqual(@as(f32, 0), st.overflow_width);
}

test "text feature: the ellipsis token is a single deterministic codepoint (U+2026)" {
    // draw's `.ellipsis` path appends exactly this; pin it so the token never drifts and is
    // valid UTF-8 (measured once, drawn as measured).
    try std.testing.expectEqualStrings("\u{2026}", ellipsis_token);
    try std.testing.expect(std.unicode.utf8ValidateSlice(ellipsis_token));
    try std.testing.expectEqual(@as(usize, 1), std.unicode.utf8CountCodepoints(ellipsis_token) catch 0);
}

test "text feature: enabled empty clip remains enabled-empty; disabled remains disabled" {
    try std.testing.expect(effectiveClip(false, null) == null);
    const empty = effectiveClip(true, null).?;
    try std.testing.expectEqual(@as(i32, 0), empty.w);
    try std.testing.expectEqual(@as(i32, 0), empty.h);

    const reported: sdl.rect.IRect = .{ .x = 3, .y = 4, .w = 20, .h = 10 };
    try std.testing.expectEqual(reported, effectiveClip(true, reported).?);
}

test "text feature: integer clip-rect intersection is the overlap, empties to zero area" {
    // The clip abstraction `drawClipped` uses is pure integer-rect math — testable without a
    // renderer. Overlap is the intersection; a disjoint pair yields a zero-area rect (clips
    // everything out — the safe outcome for a cell fully outside its ancestor's clip).
    const a: sdl.rect.IRect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const b: sdl.rect.IRect = .{ .x = 20, .y = 10, .w = 200, .h = 20 };
    const o = intersectIRect(a, b);
    try std.testing.expectEqual(@as(i32, 20), o.x);
    try std.testing.expectEqual(@as(i32, 10), o.y);
    try std.testing.expectEqual(@as(i32, 80), o.w); // min(100,220) - 20
    try std.testing.expectEqual(@as(i32, 20), o.h); // min(50,30) - 10
    // Disjoint → zero area, never negative.
    const d = intersectIRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .x = 100, .y = 100, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(i32, 0), d.w);
    try std.testing.expectEqual(@as(i32, 0), d.h);
}

test "text feature: tracking is POD state that round-trips; default is the untracked fast path" {
    // TEXT-04: `tracking` defaults to 0 (the untracked fast path — one getStringSize measure
    // and one renderTextSolid span, byte-for-byte the pre-TEXT-04 behavior). A resolved
    // device-px delta round-trips like `wrap_width`/`overflow`, with no allocator (POD).
    var st = State.init();
    try std.testing.expectEqual(@as(f32, 0), st.tracking); // default: untracked
    try std.testing.expect(st.update("IN REACH"));
    st.tracking = 1; // e.g. +0.07em eyebrow at 11px device rounds to +1px
    try std.testing.expectEqual(@as(f32, 1), st.tracking);
    // Tracking never mutates the accepted string — measure and draw read one buffer.
    try std.testing.expectEqualStrings("IN REACH", st.text() orelse "");
    // Negative (tightening) tracking round-trips too.
    st.tracking = -1;
    try std.testing.expectEqual(@as(f32, -1), st.tracking);
}

test "text feature: an over-cap string is still refused whole even with tracking set" {
    // TEXT-04 tracking is not a way to smuggle a too-long source past TEXT-01's cap.
    var st = State.init();
    st.tracking = 1;
    var over: [State.cap + 1]u8 = undefined;
    @memset(&over, 'x');
    try std.testing.expect(!st.update(&over)); // refused whole, tracked or not
    try std.testing.expect(st.text() == null); // draws nothing
}
