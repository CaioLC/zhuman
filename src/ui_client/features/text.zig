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
const text_cache = @import("text_cache.zig");

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

const Metrics = struct { width: f32, height: f32, baseline: f32 };

/// Apply the final axis-aligned text orientation to upright metrics. A 90° rotation swaps
/// width/height exactly; its baseline is zero because a vertical control label does not
/// participate in horizontal row-baseline alignment. This pure rule is also the hit/focus
/// contract: the engine stamps the resulting node box, so its rectangle matches the pixels.
fn orientMetrics(orientation: State.Orientation, upright: Metrics) Metrics {
    return switch (orientation) {
        .horizontal => upright,
        .counter_clockwise_90 => .{ .width = upright.height, .height = upright.width, .baseline = 0 },
    };
}

/// Shared write-through of measured metrics onto a node's size — used by `attach` and by
/// `style.apply`'s re-measure so the two never diverge. Public so `style.zig` can call it
/// without duplicating the wrap-vs-single-line branch.
pub fn remeasure(ctx: *UiCtx, node: *Node) void {
    const st = node.state(ctx, State);
    const measured = st.text() orelse "";
    const upright: Metrics = if (st.wrap_width > 0) blk: {
        const font = ctx.res.platform.font.at(st.px) catch return;
        const tw, const th, const baseline = measureWrapped(font, measured, st.wrap_width, st.tracking);
        break :blk .{ .width = tw, .height = th, .baseline = baseline };
    } else if (st.overflow != .visible) blk: {
        // TEXT-03: an explicitly allocated single-line cell. The *box* is the allocated
        // width, never the unbounded glyph width — including a legal zero-width cell. A
        // widening label cannot shift its neighbors, and hit-testing uses this stamped cell.
        // Height and baseline still come from the font, single-line, so the cell baseline-aligns
        // like an ordinary label. The drawn glyphs are `draw`'s concern.
        _, const th, const baseline = ctx.res.platform.font.measureBaseline(measured, st.px) catch return;
        break :blk .{ .width = st.overflow_width, .height = @floatFromInt(th), .baseline = baseline };
    } else blk: {
        // Single-line, unconstrained. Height/baseline always come from the font; the width
        // is the tracking-aware advance when tracking is set and SDL's native width otherwise.
        const tw, const th, const baseline = ctx.res.platform.font.measureBaseline(measured, st.px) catch return;
        const w: f32 = if (st.tracking == 0)
            @floatFromInt(tw)
        else tracked: {
            const font = ctx.res.platform.font.at(st.px) catch break :tracked @floatFromInt(tw);
            break :tracked trackedWidth(font, measured, st.tracking);
        };
        break :blk .{ .width = w, .height = @floatFromInt(th), .baseline = baseline };
    };

    const oriented = orientMetrics(st.orientation, upright);
    node.size.data_width = oriented.width;
    node.size.data_height = oriented.height;
    node.size.baseline = oriented.baseline;
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

/// Blit the node's cached text in `c` over its content box. **Every** variant is cached as
/// one composite white texture in `State.tex` (TEXT-05): a cache miss generates the composite
/// once (see `renderComposite`), a hit blits it tinted — no variant re-rasterizes per frame,
/// unlike a naive `renderTextSolid`-every-frame path.
///
/// The variant a node draws is decided by its state and reproduced *inside* the composite by
/// `planVariant` (the one place each variant's glyph placement lives), so the cached pixels
/// match the measure pass glyph-for-glyph:
///   - single-line, unconstrained (`wrap_width == 0`, `overflow == .visible`) — the whole
///     string (tracked: per-cluster at the measured advances; untracked: one span).
///   - wrapped (`wrap_width > 0`) — the *same* `wrap.wrapLines` the measure pass ran, one
///     stamped line per break at `i*lineSkip` (a blank line keeps its height), tracked or not.
///   - `.clip` — the whole string is cached (its pixels depend only on keyed inputs); the
///     clip **rect** is the one per-frame render-time op, scoped to the prior clip ∩ the cell
///     around the blit and **restored afterward** (including on error) so a leaf's glyphs are
///     cropped to its box without leaking the clip to siblings.
///   - `.ellipsis` — the identical `wrap.ellipsisFit` (one source of truth): the
///     codepoint-aligned prefix plus the deterministic ellipsis token, baked into the
///     composite; a too-narrow cell composites nothing rather than overflowing.
pub fn draw(u: *UiCtx, node: *Node, c: cb.Color, opacity: f32) void {
    const st = node.state(u, State);
    const fmt = st.text() orelse {
        // TEXT-01 refused/empty: nothing to draw. Release any texture still cached from a
        // prior accepted string (renderer alive here) so an emptied label doesn't leak.
        if (st.tex != null) st.deinit();
        return;
    };
    const tint = paint.applyOpacity(c, opacity); // RENDER-07 subtree dimming (tint-on-blit)
    const r = paint.content(node) orelse return;
    const f = u.res.platform.font.at(st.px) catch return;

    // **TEXT-05 (all variants cached):** every accepted variant — normal, tracked, wrapped,
    // clip, ellipsis, and their tracked combinations — is rasterized into **one composite
    // white texture** on a cache miss and blitted (tinted) thereafter. The only per-frame,
    // render-time-only operation is the `.clip` cell's clip rectangle: the *pixels* of a
    // clipped string are the whole string (they depend only on keyed inputs), so they are
    // cached like any other variant and the clip scope is applied around the cached blit.
    // No variant re-rasterizes a glyph on a cache hit.
    const clip_cell: ?ui.Rect = if (st.wrap_width <= 0 and st.overflow == .clip) r else null;
    drawCached(u, st, f, fmt, tint, r, clip_cell);
}

/// Build the TEXT-05 cache inputs from the current state + the live renderer generation.
/// The one place `State` fields are projected onto the SDL-free key seam, so the enumerated
/// key dimensions stay in sync with `text_cache.Key`. Color is deliberately absent (tint-on-
/// blit). `content` is the accepted/transformed bytes (`fmt`), already folded by `attach`.
fn cacheInputs(u: *UiCtx, st: *const State, fmt: []const u8) text_cache.Inputs {
    return .{
        .content = fmt,
        .px = st.px,
        .font_id = text_cache.default_font_id,
        .tracking = st.tracking,
        .overflow = @intFromEnum(st.overflow),
        .overflow_width = st.overflow_width,
        .wrap_width = st.wrap_width,
        .generation = u.res.platform.generation,
    };
}

/// The deterministic ellipsis token appended by `.ellipsis` overflow: U+2026 HORIZONTAL
/// ELLIPSIS. Its width is *measured* from the live font (never assumed), so the fit budget
/// tracks the actual glyph and the same token draws as was measured.
pub const ellipsis_token = "\u{2026}";

// ============================ Unified composite cache (TEXT-05) ========================
//
// **Every** accepted variant — normal, tracked, wrapped, clip, ellipsis, and the tracked
// combinations of wrap/clip/ellipsis — rasterizes into **one composite white texture** on a
// cache miss and blits (tinted) thereafter. There is no per-frame `renderTextSolid` on a
// hit for any variant. The composite is generated **atomically**: on a miss the renderer's
// target/clip/draw-color/blend state is snapshotted, a fresh `.target` texture is made and
// cleared transparent, the variant's white sub-spans are drawn into it at the exact relative
// offsets the pre-cache per-frame paths used, and the prior render state is **always**
// restored (including on any error path). If any step fails, the partial texture is freed
// and **no** key is latched, so the next frame retries — a failure is never cached.
//
// Why white + tint-on-blit: the composite carries the glyph *shapes* only; color is applied
// at blit via `setColorMod`/`setAlphaMod` (the `svg.draw` model), so a hover/focus recolor
// reuses the same texture with zero cache churn — color is not a key dimension.

/// One white sub-span to stamp into the composite at a **composite-relative** offset. The
/// bytes are a slice of the accepted buffer (a whole line, a single cluster, the ellipsis
/// token, …). Collected by the per-variant planners and replayed against either a real SDL
/// target (`renderComposite`) or a pure geometry sink (the SDL-free layout tests).
const SubBlit = struct { bytes: []const u8, x: f32, y: f32 };

/// A `Plan.Sink` callback that discards every sub-blit — used for the pure measurement pass
/// (the composite bounds are the accumulated `Plan.w`/`Plan.h`, no SDL touched) and by the
/// SDL-free layout tests as the "measure only" sink.
fn noopEmit(_: *anyopaque, _: SubBlit) void {}

/// A planner walks the variant once and emits each `SubBlit` plus the composite's bounding
/// size, so the *same* placement code drives both measurement (composite size) and the
/// actual white stamps — measure and render cannot drift. `emit` returns the drawn span's
/// device width so a planner can advance a pen without re-measuring.
const Plan = struct {
    font: sdl.ttf.Font,
    tracking: f32,
    /// The running composite bounds (max x reached, max y+lineHeight reached).
    w: f32 = 0,
    h: f32 = 0,
    sink: *Sink,

    /// A sink receives each planned sub-blit. Two implementations: the real compositor
    /// (stamps a white texture into the current target) and a pure collector (tests).
    const Sink = struct {
        ctx: *anyopaque,
        emitFn: *const fn (*anyopaque, SubBlit) void,
        fn emit(self: *Sink, b: SubBlit) void {
            self.emitFn(self.ctx, b);
        }
    };

    /// The font's tracking-aware device width of `bytes`.
    fn widthOf(self: *Plan, bytes: []const u8) f32 {
        if (self.tracking == 0) {
            const w, _ = self.font.getStringSize(bytes) catch return 0;
            return @floatFromInt(w);
        }
        return trackedWidth(self.font, bytes, self.tracking);
    }

    fn lineHeight(self: *Plan) f32 {
        // Minimum transparent line box for blank lines. Non-empty spans additionally grow
        // the target to their actual `getStringSize` raster bounds in `span`, so a font whose
        // surface height or glyph overhang differs from this nominal metric cannot be cropped.
        return @floatFromInt(self.font.getHeight());
    }

    /// Stamp a whole span at composite-relative (`x`, `y`). Untracked: one sub-blit sized to
    /// its actual raster box. Tracked: one sub-blit **per cluster** at the cumulative advance,
    /// matching `trackedWidth`, while the composite bounds include both the logical pen and
    /// each cluster's actual surface bounds. The nominal `line_h` preserves blank-line space;
    /// real glyph dimensions may grow beyond it but can never be cropped by the target.
    fn span(self: *Plan, bytes: []const u8, x: f32, y: f32, line_h: f32) void {
        if (bytes.len == 0) {
            self.grow(x, y, line_h);
            return;
        }
        if (self.tracking == 0) {
            const rw, const rh = self.font.getStringSize(bytes) catch return;
            self.sink.emit(.{ .bytes = bytes, .x = x, .y = y });
            self.grow(x + @as(f32, @floatFromInt(rw)), y, @max(line_h, @as(f32, @floatFromInt(rh))));
            return;
        }
        const Ctx = struct {
            plan: *Plan,
            src: []const u8,
            x: f32,
            y: f32,
            line_h: f32,
            n: usize = 0,
            fn take(s: *@This(), cl: Cluster) void {
                if (s.n > 0) s.x += s.plan.tracking; // inter-cluster gap, matching the measurer
                const b = s.src[cl.start .. cl.start + cl.len];
                const glyph_x = s.x;
                s.plan.sink.emit(.{ .bytes = b, .x = glyph_x, .y = s.y });
                s.x += cl.advance;
                const rw, const rh = s.plan.font.getStringSize(b) catch {
                    s.n += 1;
                    s.plan.grow(s.x, s.y, s.line_h);
                    return;
                };
                const raster_right = glyph_x + @as(f32, @floatFromInt(rw));
                s.plan.grow(@max(s.x, raster_right), s.y, @max(s.line_h, @as(f32, @floatFromInt(rh))));
                s.n += 1;
            }
        };
        var c = Ctx{ .plan = self, .src = bytes, .x = x, .y = y, .line_h = line_h };
        walkClusters(self.font, bytes, *Ctx, &c, Ctx.take);
    }

    fn grow(self: *Plan, right: f32, top: f32, line_h: f32) void {
        if (right > self.w) self.w = right;
        const bottom = top + line_h;
        if (bottom > self.h) self.h = bottom;
    }
};

/// Walk a variant, emitting each white sub-blit to `sink` and returning the composite bounds
/// (`w`, `h`) in device px. This is the ONE place a variant's glyph placement lives for the
/// cache; `renderComposite` replays it against a real target, so the composite pixels match
/// what the pre-cache per-frame paths drew glyph-for-glyph. `overflow_width`/`wrap_width` are
/// read from `st`, matching `remeasure`'s cell/wrap branches.
fn planVariant(st: *const State, font: sdl.ttf.Font, text: []const u8, sink: *Plan.Sink) struct { f32, f32 } {
    var plan = Plan{ .font = font, .tracking = st.tracking, .sink = sink };
    const skip = lineSkip(font);
    const line_h = plan.lineHeight();

    if (st.wrap_width > 0) {
        // Wrapped (tracked or not): each line stamped at (0, i*skip); a blank line still
        // advances `y` so the composite reserves its height, matching the measure pass.
        const Ctx = struct {
            plan: *Plan,
            src: []const u8,
            skip: f32,
            line_h: f32,
            i: usize = 0,
            fn take(s: *@This(), line: wrap.Line) bool {
                const ly = @as(f32, @floatFromInt(s.i)) * s.skip;
                s.plan.span(s.src[line.start .. line.start + line.len], 0, ly, s.line_h);
                s.i += 1;
                return true;
            }
        };
        var fm = FontMeasurer{ .font = font, .tracking = st.tracking };
        var c = Ctx{ .plan = &plan, .src = text, .skip = skip, .line_h = line_h };
        wrap.wrapLines(text, st.wrap_width, fm.measurer(), *Ctx, &c, Ctx.take);
        return .{ plan.w, plan.h };
    }

    if (st.overflow == .ellipsis) {
        // Ellipsis cell: the identical `wrap.ellipsisFit` (measure == draw), then the
        // codepoint-aligned prefix and — if elided — the deterministic token at the prefix's
        // tracked width plus one inter-cluster gap. A too-narrow cell yields an empty fit.
        var fm = FontMeasurer{ .font = font, .tracking = st.tracking };
        const m = fm.measurer();
        const ell_w: f32 = m.width(ellipsis_token);
        const r = wrap.ellipsisFit(text, st.overflow_width, ell_w, m);
        const prefix = text[0..r.prefix_len];
        plan.span(prefix, 0, 0, line_h);
        if (r.elided) {
            var pw: f32 = if (prefix.len == 0) 0 else m.width(prefix);
            if (st.tracking != 0 and prefix.len != 0) pw += st.tracking;
            plan.span(ellipsis_token, pw, 0, line_h);
        }
        return .{ plan.w, plan.h };
    }

    // Single line — normal, tracked, or `.clip` (clip renders the whole string; the clip
    // *rect* is applied at blit, not baked into the pixels). One stamped span at the origin.
    plan.span(text, 0, 0, line_h);
    return .{ plan.w, plan.h };
}

/// The real compositor sink: stamps one white sub-span into whatever target is currently
/// bound on the renderer. Each span's own surface is rasterized white and rendered at its
/// composite-relative offset; a failed glyph frame is skipped silently and marks the plan
/// incomplete so the caller can decide whether the composite is usable (it still is — a
/// missing glyph is cosmetic, matching every text path's `catch return`).
const Compositor = struct {
    u: *UiCtx,
    font: sdl.ttf.Font,
    fn emit(ctx: *anyopaque, b: SubBlit) void {
        const self: *Compositor = @ptrCast(@alignCast(ctx));
        if (b.bytes.len == 0) return;
        var surface = self.font.renderTextSolid(b.bytes, .{ .r = 255, .g = 255, .b = 255, .a = 255 }) catch return;
        defer surface.deinit();
        const texture = self.u.res.platform.renderer.createTextureFromSurface(surface) catch return;
        defer texture.deinit();
        // Composite the glyph's own alpha onto the transparent target (Solid renders a
        // paletted surface; `.blend` keeps its transparent margins transparent so only the
        // glyph pixels carry alpha into the composite).
        texture.setBlendMode(.blend) catch {};
        const w, const h = self.font.getStringSize(b.bytes) catch return;
        const dst: ui.Rect = .{ .x = b.x, .y = b.y, .w = @floatFromInt(w), .h = @floatFromInt(h) };
        self.u.res.platform.renderer.renderTexture(texture, null, paint.frect(dst)) catch return;
    }
    fn sink(self: *Compositor) Plan.Sink {
        return .{ .ctx = self, .emitFn = emit };
    }
};

/// Rasterize a whole variant into **one composite white texture**, uploaded once, sized to
/// the variant's full pixel bounds. Returns the texture, or `null` on any failure — always
/// leaving **no** partial owned state (the target texture is freed on any error) and never
/// mutating persistent renderer state (target/clip/draw-color/blend are snapshotted and
/// restored on every path). The composite is a `.target`-access texture with `.blend` blend
/// mode so its transparent margins don't paint black at blit and its white glyphs tint
/// cleanly. A zero-area variant (empty fit / blank) yields `null` (nothing to cache/draw).
fn renderComposite(u: *UiCtx, st: *const State, font: sdl.ttf.Font, text: []const u8) ?sdl.render.Texture {
    const renderer = u.res.platform.renderer;

    // First pass: measure the composite bounds with a no-op sink (no SDL, no allocation).
    var noop_ctx: u8 = 0;
    var measure_sink = Plan.Sink{ .ctx = &noop_ctx, .emitFn = noopEmit };
    const cw_f, const ch_f = planVariant(st, font, text, &measure_sink);
    const cw: usize = @intFromFloat(@ceil(@max(0, cw_f)));
    const ch: usize = @intFromFloat(@ceil(@max(0, ch_f)));
    if (cw == 0 or ch == 0) return null; // nothing visible (empty fit, blank, refused-ish)

    const target = renderer.createTexture(.packed_rgba_8_8_8_8, .target, cw, ch) catch return null;
    // On any failure past this point the target must be freed (no partial owned state).
    var ok = false;
    defer if (!ok) target.deinit();
    target.setBlendMode(.blend) catch return null;

    // Snapshot every renderer state the composite pass mutates, and restore it on every path
    // (success or error) so no sibling draw inherits our target/clip/color/blend.
    const prior_target = renderer.getTarget();
    const prior_enabled = renderer.getClipEnabled();
    const prior_clip = effectiveClip(prior_enabled, renderer.getClipRect() catch null);
    const prior_color = renderer.getDrawColor() catch null;
    const prior_blend = renderer.getDrawBlendMode() catch null;
    defer {
        renderer.setTarget(prior_target) catch {};
        renderer.setClipRect(prior_clip) catch {};
        if (prior_color) |pc| renderer.setDrawColor(pc) catch {};
        if (prior_blend) |pb| renderer.setDrawBlendMode(pb) catch {};
    }

    renderer.setTarget(target) catch return null;
    // The composite lives in its own coordinate space: no inherited clip, and a transparent
    // clear (blend on) so only the glyph pixels carry alpha.
    renderer.setClipRect(null) catch {};
    renderer.setDrawBlendMode(.blend) catch {};
    renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 }) catch return null;
    renderer.clear() catch return null;

    // Second pass: stamp each white sub-span into the target at its composite-relative offset,
    // via the SAME planner that produced the bounds — so pixels match the measured layout.
    var compositor = Compositor{ .u = u, .font = font };
    var draw_sink = compositor.sink();
    _ = planVariant(st, font, text, &draw_sink);

    ok = true; // keep the target: it is the finished composite
    return target;
}

/// The unified cached draw for **all** variants. Consults `text_cache.decide` against the
/// stored key/texture: a **hit** blits the cached composite (no raster/upload, no free); a
/// **miss** frees-or-abandons the old texture per the free-vs-reset rule, renders a fresh
/// composite atomically, and latches the new key on success — or leaves the slot empty to
/// retry next frame on failure. When `clip_cell` is set (`.clip` overflow) the renderer's
/// clip is scoped to the prior clip ∩ the cell around the blit and restored after (even on
/// error) — the only per-frame render-time op; the cached pixels are the whole string.
fn drawCached(u: *UiCtx, st: *State, font: sdl.ttf.Font, text: []const u8, c: cb.Color, box: ui.Rect, clip_cell: ?ui.Rect) void {
    if (text.len == 0) return;
    const wanted = text_cache.keyOf(cacheInputs(u, st, text));
    switch (text_cache.decide(st.cache_key, st.tex != null, wanted)) {
        .none => {
            if (st.tex != null) st.deinit();
            return;
        },
        .hit => {},
        .miss => |m| {
            if (m.free_old) st.deinit() else st.abandonTexture();
            const tex = renderComposite(u, st, font, text) orelse return; // failure: nothing latched, retry
            st.tex = tex;
            st.cache_key = wanted; // latch only on success
        },
    }

    if (clip_cell) |cell| {
        // `.clip`: scope the renderer clip to the prior clip ∩ the cell for the blit, then
        // restore the prior clip (never `null` — this leaf may sit inside an ancestor clip).
        const renderer = u.res.platform.renderer;
        const prior_enabled = renderer.getClipEnabled();
        const reported_prior = renderer.getClipRect() catch return;
        const prior = effectiveClip(prior_enabled, reported_prior);
        defer renderer.setClipRect(prior) catch {};
        const cell_clip = paint.irect(cell) orelse return;
        const narrowed: sdl.rect.IRect = if (prior) |p| intersectIRect(p, cell_clip) else cell_clip;
        renderer.setClipRect(narrowed) catch return;
        blitCached(u, st.tex.?, c, box, st.orientation);
    } else {
        blitCached(u, st.tex.?, c, box, st.orientation);
    }
}

const BlitPlacement = struct {
    dst: ui.Rect,
    clockwise_degrees: ?f64,
};

/// Place an upright cached texture inside its already-oriented content box. Horizontal text
/// starts at the box origin. For 90° CCW, center the unrotated `w×h` destination on the
/// swapped `h×w` box; rotating that destination 270° clockwise around its own center lands
/// the final pixels exactly on the oriented box. Pure geometry keeps this testable without SDL.
fn blitPlacement(orientation: State.Orientation, box: ui.Rect, texture_w: f32, texture_h: f32) BlitPlacement {
    return switch (orientation) {
        .horizontal => .{
            .dst = .{ .x = box.x, .y = box.y, .w = texture_w, .h = texture_h },
            .clockwise_degrees = null,
        },
        .counter_clockwise_90 => .{
            .dst = .{
                .x = box.x + (box.w - texture_w) / 2,
                .y = box.y + (box.h - texture_h) / 2,
                .w = texture_w,
                .h = texture_h,
            },
            .clockwise_degrees = 270,
        },
    };
}

/// Blit an already-cached upright composite, tinted in `c`. Orientation is deliberately a
/// final-blit transform: horizontal and vertical uses share the same TEXT-05 texture and a
/// mode switch causes no glyph raster/upload churn. The 90° path uses an axis-aligned center
/// rotation, matching `orientMetrics`' swapped layout/focus/hit box.
fn blitCached(u: *UiCtx, tex: sdl.render.Texture, c: cb.Color, box: ui.Rect, orientation: State.Orientation) void {
    const w, const h = tex.getSize() catch return;
    // RENDER-01: honor the tint alpha explicitly (the composite is already generated with
    // `.blend`, but set it here too so a translucent/dimmed label composites consistently).
    tex.setBlendMode(.blend) catch {};
    tex.setColorMod(c.r, c.g, c.b) catch {};
    tex.setAlphaMod(c.a) catch {};
    const placement = blitPlacement(orientation, box, w, h);
    if (placement.clockwise_degrees) |angle| {
        u.res.platform.renderer.renderTextureRotated(tex, null, paint.frect(placement.dst), angle, null, .{}) catch return;
    } else {
        u.res.platform.renderer.renderTexture(tex, null, paint.frect(placement.dst)) catch return;
    }
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
    // The clip abstraction `drawCached` uses for a `.clip` cell is pure integer-rect math —
    // testable without a renderer. Overlap is the intersection; a disjoint pair yields a
    // zero-area rect (clips everything out — the safe outcome for a cell fully outside its ancestor's clip).
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

test "text feature: orientation defaults horizontal and preserves accepted content" {
    var st = State.init();
    try std.testing.expectEqual(State.Orientation.horizontal, st.orientation);
    try std.testing.expect(st.update("HOLDINGS"));
    st.orientation = .counter_clockwise_90;
    try std.testing.expectEqual(State.Orientation.counter_clockwise_90, st.orientation);
    try std.testing.expectEqualStrings("HOLDINGS", st.text() orelse "");
}

test "text feature: counter-clockwise orientation swaps layout axes and clears baseline" {
    const upright = Metrics{ .width = 72, .height = 11, .baseline = 3 };
    try std.testing.expectEqual(upright, orientMetrics(.horizontal, upright));

    const vertical = orientMetrics(.counter_clockwise_90, upright);
    try std.testing.expectEqual(@as(f32, 11), vertical.width);
    try std.testing.expectEqual(@as(f32, 72), vertical.height);
    try std.testing.expectEqual(@as(f32, 0), vertical.baseline);
}

test "text feature: rotated blit is centered on the swapped content box" {
    // Upright texture 72×11 becomes an axis-aligned 11×72 footprint at (20,30).
    const box: ui.Rect = .{ .x = 20, .y = 30, .w = 11, .h = 72 };
    const p = blitPlacement(.counter_clockwise_90, box, 72, 11);
    try std.testing.expectEqual(@as(?f64, 270), p.clockwise_degrees);
    try std.testing.expectEqual(@as(f32, -10.5), p.dst.x);
    try std.testing.expectEqual(@as(f32, 60.5), p.dst.y);
    try std.testing.expectEqual(@as(f32, 72), p.dst.w);
    try std.testing.expectEqual(@as(f32, 11), p.dst.h);

    // Rotating the unrotated destination around its center produces exactly the box bounds.
    const cx = p.dst.x + p.dst.w / 2;
    const cy = p.dst.y + p.dst.h / 2;
    try std.testing.expectEqual(box.x, cx - p.dst.h / 2);
    try std.testing.expectEqual(box.y, cy - p.dst.w / 2);
    try std.testing.expectEqual(box.x + box.w, cx + p.dst.h / 2);
    try std.testing.expectEqual(box.y + box.h, cy + p.dst.w / 2);
}

test "text feature: horizontal blit remains the existing origin-sized path" {
    const box: ui.Rect = .{ .x = 7, .y = 9, .w = 80, .h = 20 };
    const p = blitPlacement(.horizontal, box, 42, 14);
    try std.testing.expectEqual(@as(?f64, null), p.clockwise_degrees);
    try std.testing.expectEqual(ui.Rect{ .x = 7, .y = 9, .w = 42, .h = 14 }, p.dst);
}
