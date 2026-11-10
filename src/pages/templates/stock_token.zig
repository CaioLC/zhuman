//! `stock_token` and `stockline` — the header's stock summary as reusable tokens whose
//! **footprint never changes**.
//!
//! A **StockToken** rests as a two-letter **abbreviation** with its truncated value (`FO: 3`,
//! `VI: 14/15`): a **dim** label beside the value in its tone or verdict colour, so the number
//! reads louder than its label and severity reads in the colour. That resting form is the
//! token's only footprint in the flow, hovered or not, so its neighbours, the `|` separators and
//! the line wraps never move.
//!
//! While hovered or focused the token is **read**: its **read form** — the full label in capitals, in `fg`
//! and the value with one truncated decimal, shown only when fractional (`FOOD: 3.6`,
//! `VIGOR: 14.2/15`) — is drawn as an **overlay** out of the flow, at the read size (`readType`:
//! 17px, 15px stacked, 13px on a compact line at ≤560). Its box is opaque `bg`, its text's width
//! plus 4px on each side, and runs from the token's top to its bottom, reaching 4px higher over
//! a compact line so it backs the taller read glyphs without touching a wrapped line above. Its
//! text sits on the token's resting baseline and starts at the token's left edge; when that
//! would carry the box past the stockline's right edge, the overlay ends at the token's right
//! edge instead (`readLeft`). The overlay is painted after every token of its line and takes no
//! pointer, so the resting tokens are the only hit targets: sweeping along the line hands the
//! read from token to token, a covered token included.
//!
//! Every other token or separator of the line whose box the overlay's box overlaps, or comes
//! within 4px of horizontally, sharing more than half a pixel vertically (`covered`), is not
//! painted while the overlay is open, keeping its footprint; the rest paint exactly as at rest.
//! The header hides the run context's items the same way (`Line.cover`), which happens only
//! where a stacked line is narrower than a read form. The overlay opens and closes over
//! `tokens.dur_stock_token_s` (120ms) eased out: its alpha and a left-to-right reveal of its
//! width, with the covered parts fading out over the same time; reduced motion snaps it.
//!
//! A **compact** stockline — Act II's nine stocks — rests every token at 10px with 4px gaps, so
//! the long line fits beside the runline (the prototype's `.stockline.compact`). A full line — Act I's three — rests at the line size, so its overlay
//! differs from rest only by the longer label and the detailed value.
//!
//! The **stockline** is a row of tokens separated by dim `|` dividers; its **order and
//! membership come from the act descriptor** the caller passes (`&.[_]Stock{...}`), so Act I
//! (Vigor/Food/Materials) and Act II (its sectors) list their own tokens without the template
//! hard-coding either.
//!
//! Placing the overlay and finding what it covers reads the line's prior-frame geometry (the
//! line, its tokens and its separators are stamped): a token's resting box is the same every
//! frame, so last frame's rects are this frame's.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const Rect = uic.Rect;

/// Semantic tone for the numeric value. The resting label is dim in every state. `accent` is
/// the medium of exchange (`.stock-value.accent` on Coin).
pub const Tone = enum { normal, warn, danger, accent };

/// A compact line's resting type size and token gap, logical px.
const compact_font: f32 = 10;
const compact_gap: f32 = 4;
/// The full line's gap (`.stockline { gap: 9px }`).
const line_gap: f32 = 9;
/// The read overlay's fill reaches this far past its text on each side, logical px; a token or
/// separator closer than this to the fill is covered.
const read_pad: f32 = 4;
/// The most tokens a line places overlays for; tokens past it rest and are never read.
const max_tokens = 16;

/// The stockline's face: 17px (15px stacked, ≤760) at the body tracking — `.stockline`.
pub fn lineType(ctx: *UiCtx) Style {
    return .{ .font = if (@import("./terminal.zig").stacked(ctx)) 15 else 17, .tracking = -0.025 };
}

/// The size a token is read at: the line's, and 13px on a compact line at ≤560, where the 15px
/// read form of its longest label is wider than the stacked line.
fn readType(ctx: *UiCtx, compact: bool) Style {
    if (compact and ctx.res.view.metrics.width_class.atMost(.w560)) return .{ .font = 13, .tracking = -0.025 };
    return lineType(ctx);
}

/// One stock token's domain data. `abbrev` is the two-letter short form, `full` the read
/// label, `value` the raw amount, and `max` an optional ceiling shown as `/max` (Vigor). The
/// template owns compact truncation and one-decimal read formatting; callers own domain
/// meaning and thresholds.
pub const Stock = struct {
    abbrev: []const u8,
    full: []const u8,
    value: f32,
    max: ?f32 = null,
    tone: Tone = .normal,
    /// What the value means (`low` for a stock at zero); when set it paints the value instead
    /// of `tone`.
    verdict: ?style.Verdict = null,
};

/// Build one stock token into `parent`: a stockline of one, so it rests and reads as a token
/// of a line does. The token is a focusable readout rather than a control.
pub fn stock_token(parent: El, id: []const u8, s: Stock) !void {
    _ = try stockline(parent, id, &.{s}, false);
}

/// Absorbs float drift before truncating (an accumulated `3.5999998` reads `3.6`, not `3.5`).
const drift_eps: f32 = 1e-3;
/// Truncation ceiling: keeps `@intFromFloat` defined for absurd values.
const max_magnitude: f32 = 1e15;

/// Format one amount, truncated toward zero (floor for the non-negative stocks we show).
/// `detailed` gives one decimal only when fractional (`3.6`, `126`); otherwise a compact
/// whole number with `k`/`M` suffixes (`11`, `1.9k`, `12k`, `1.2M`). Digits are integer math
/// so a suffix never rounds up past the true value (`9999` is `9.9k`, never `10.0k`).
fn formatAmount(buf: []u8, v: f32, detailed: bool) []const u8 {
    if (!std.math.isFinite(v)) return "?";
    const mag = @min(@abs(v), max_magnitude);
    var w = std.Io.Writer.fixed(buf);

    if (detailed) {
        const tenths: u64 = @intFromFloat(@floor(mag * 10 + drift_eps));
        if (tenths == 0) return "0";
        if (v < 0) w.writeAll("-") catch return "?";
        w.print("{d}", .{tenths / 10}) catch return "?";
        if (tenths % 10 != 0) w.print(".{d}", .{tenths % 10}) catch return "?";
        return w.buffered();
    }

    const n: u64 = @intFromFloat(@floor(mag + drift_eps));
    if (n == 0) return "0";
    if (v < 0) w.writeAll("-") catch return "?";
    // Integer digits, so a suffix never rounds up past the true value.
    if (n >= 1_000_000) {
        w.print("{d}.{d}M", .{ n / 1_000_000, n / 100_000 % 10 }) catch return "?";
    } else if (n >= 10_000) {
        w.print("{d}k", .{n / 1000}) catch return "?";
    } else if (n >= 1_000) {
        w.print("{d}.{d}k", .{ n / 1000, n / 100 % 10 }) catch return "?";
    } else {
        w.print("{d}", .{n}) catch return "?";
    }
    return w.buffered();
}

/// A stock's readout: its amount, plus `/max` when it has a ceiling (`14/15`, `14.2/15`).
fn formatStock(buf: []u8, s: Stock, detailed: bool) []const u8 {
    const m = s.max orelse return formatAmount(buf, s.value, detailed);
    var vbuf: [32]u8 = undefined;
    var mbuf: [32]u8 = undefined;
    return std.mem.print(buf, "{s}/{s}", .{
        formatAmount(&vbuf, s.value, detailed),
        formatAmount(&mbuf, m, detailed),
    }) catch "?";
}

// -- The overlay's geometry: pure functions over device-px rects -------------------------

/// The read overlay's box left edge: `pad` before the token, so its text starts at the
/// token's left edge, unless a box `width` wide would then pass `line_right`; then the box
/// ends `pad` past the token's right edge, so its text ends there.
pub fn readLeft(token: Rect, width: f32, pad: f32, line_left: f32, line_right: f32) f32 {
    const left = token.x - pad;
    if (left + width <= line_right) return left;
    const flipped = token.x + token.w + pad - width;
    // A line narrower than the read form: flipped it would pass the line's left edge too, so
    // it stays at the token and runs on past the line's right edge.
    if (flipped < line_left - pad) return left;
    return flipped;
}

/// The read overlay's text top: its baseline (`read_descent` above the bottom of its `read_h`
/// text) on the token's resting baseline (`rest_descent` above the token's bottom).
pub fn readTop(token: Rect, rest_descent: f32, read_h: f32, read_descent: f32) f32 {
    return token.y + token.h - rest_descent - (read_h - read_descent);
}

/// Whether the overlay's box hides `other`: horizontally `other` overlaps it or comes within
/// `margin` of it, and vertically they share more than half a pixel, so a line above or below
/// that the box only touches is not covered.
pub fn covered(overlay: Rect, other: Rect, margin: f32) bool {
    return other.x < overlay.x + overlay.w + margin and other.x + other.w > overlay.x - margin and
        other.y < overlay.y + overlay.h - 0.5 and other.y + other.h > overlay.y + 0.5;
}

/// Cubic ease-out over `t` in 0..1: fast at the start, settling at the end.
pub fn easeOut(t: f32) f32 {
    const u = 1 - std.math.clamp(t, 0, 1);
    return 1 - u * u * u;
}

/// How open the token's read overlay stands this frame, 0..1, easing toward `reveal`. The tween
/// runs a linear clock 0→1 over the duration; the open amount eases out from where the overlay
/// stood when the state last changed, so a reversal mid-way glides back from there.
fn readProgress(box: El, reveal: bool) f32 {
    const reg = &box.ctx.res.tween;
    const key = box.get().key;
    const mem = box.state(uic.UiState.RevealState);
    if (mem.shown != reveal) {
        const was: f32 = if (mem.shown) 1 else 0;
        mem.from = mem.from + (was - mem.from) * easeOut(reg.value(key, 1));
        mem.shown = reveal;
        reg.from(key, 0, 1, ha.tokens.dur_stock_token_s);
    }
    const clock = reg.value(key, 1);
    if (clock >= 1) reg.release(key);
    const target: f32 = if (reveal) 1 else 0;
    return mem.from + (target - mem.from) * easeOut(clock);
}

// -- The line --------------------------------------------------------------------------

/// The read form's measured content, device px: its width (label, gap, value), its height,
/// and its baseline's height above its bottom.
pub const ReadExtent = struct { w: f32, h: f32, descent: f32 };

/// A built stockline: its row, and its open overlays' boxes (device px, from this frame's
/// placement over last frame's rects) with how open each stands, so parts beside the line can
/// be hidden under them too.
pub const Line = struct {
    bar: El,
    n: usize = 0,
    reads: [max_tokens]?Rect = @splat(null),
    open: [max_tokens]f32 = @splat(0),
    pads: [max_tokens]f32 = @splat(0),

    /// The opacity of a part at `rect` under the line's overlays, `skip` being the token's own:
    /// 1 less the most open overlay that covers it.
    fn shown(self: *const Line, rect: ?Rect, skip: ?usize) f32 {
        const part = rect orelse return 1;
        var a: f32 = 1;
        for (0..self.n) |i| {
            if (skip != null and skip.? == i) continue;
            const o = self.reads[i] orelse continue;
            if (covered(o, part, self.pads[i])) a = @min(a, 1 - self.open[i]);
        }
        return a;
    }

    /// Hide each of `parts`, controls whose rects are already stamped, where an open overlay
    /// covers it.
    pub fn cover(self: *const Line, parts: []const El) void {
        for (parts) |p| _ = p.with_opacity(p.get().render_data.opacity * self.shown(priorRect(p), null));
    }

    /// Hide each direct child of `group` where an open overlay covers it, stamping the children
    /// as geometry probes for the next frame.
    pub fn coverChildren(self: *const Line, group: El) void {
        for (group.get().children.items) |c| {
            const part = El{ .ctx = group.ctx, .node = c };
            part.probe();
            _ = part.with_opacity(c.render_data.opacity * self.shown(priorRect(part), null));
        }
    }
};

/// What a line's `fill` builds into the parts the line places. `control(tok, i)` publishes the
/// token as a readout and returns whether it is read; `resting(tok, i)` fills its resting form
/// and sets its baseline; `separator(slot, i)` fills the divider before token `i`; `read(row,
/// i)` fills the read form into the overlay's text row and returns its extent.
fn line(parent: El, id: []const u8, count: usize, compact: bool, fill: anytype) !Line {
    const n = @min(count, max_tokens);
    const bar = try parent.box(id, .{ .flow = .{ .dir = .row, .cross = .center }, .gap = if (compact) compact_gap else line_gap }, .{});
    bar.probe();

    var toks: [max_tokens]El = undefined;
    var seps: [max_tokens]?El = @splat(null);
    var reveal: [max_tokens]bool = undefined;
    for (0..count) |i| {
        if (i > 0) {
            const slot = try bar.item("sep", i);
            slot.probe();
            try fill.separator(slot, i);
            if (i < n) seps[i] = slot;
        }
        const tok = try bar.item("tok", i);
        const read = fill.control(tok, i);
        try fill.resting(tok, i);
        if (i < n) {
            toks[i] = tok;
            reveal[i] = read;
        }
    }

    var out = Line{ .bar = bar, .n = n };
    for (0..n) |i| out.open[i] = readProgress(toks[i], reveal[i]);
    // The overlays, after every token so they paint above the line: the closing ones first,
    // so the one opening paints over a neighbour's that is still fading. Each is an opaque box
    // `pad` wider than its text on each side, as tall as the token (and `pad` taller above a
    // compact line, over the taller read glyphs), with its text on the token's baseline.
    const line_geo = bar.prior_geometry();
    const pad = uic.view.dp(read_pad, bar.ctx.res.view.scale);
    const bleed: f32 = if (compact) pad else 0;
    for ([2]bool{ false, true }) |opening| {
        for (0..n) |i| {
            const open = out.open[i];
            if (reveal[i] != opening or open <= 0) continue;
            const lg = line_geo orelse continue;
            const tg = toks[i].prior_geometry() orelse continue;
            const anchor = (try bar.item("read", i)).with_layout(.top_left).with_size_px(.{ .fixed = 0 }, .{ .fixed = 0 });
            const clip = try anchor.box("clip", .{ .anchor = .top_left, .overflow = .clip, .opacity = open }, .{});
            const back = try clip.box("back", .{ .anchor = .top_left }, .{Style{ .fill_ink = .bg }});
            const row = try clip.box("text", .{
                .anchor = .top_left, .flow = .{ .dir = .row, .cross = .center }, .gap = ha.tokens.gap.inline_, .w = .fit_children, .h = .fit_children,
            }, .{});
            const ext = try fill.read(row, i);
            const width = pad + ext.w + pad;
            const box = Rect{
                .x = readLeft(tg.rect, width, pad, lg.rect.x, lg.rect.x + lg.rect.w),
                .y = tg.rect.y - bleed,
                .w = width,
                .h = tg.rect.h + bleed,
            };
            const text_y = readTop(tg.rect, toks[i].get().size.baseline, ext.h, ext.descent);
            // The clip spans the box and the text, whichever reaches further.
            const top = @min(box.y, text_y);
            const bottom = @max(box.y + box.h, text_y + ext.h);
            _ = anchor.with_offset_px(box.x - lg.rect.x, top - lg.rect.y);
            // The reveal: the overlay's width opens left to right with its alpha.
            _ = clip.with_size_px(.{ .fixed = width * open }, .{ .fixed = bottom - top });
            _ = back.with_offset_px(0, box.y - top).with_size_px(.{ .fixed = width }, .{ .fixed = box.h });
            _ = row.with_offset_px(pad, text_y - top);
            out.reads[i] = box;
            out.pads[i] = pad;
        }
    }

    // A token or separator under another token's open overlay fades out as it opens; the rest
    // are untouched. The read token itself lies under its own opaque box.
    for (0..n) |j| {
        _ = toks[j].with_opacity(out.shown(priorRect(toks[j]), j));
        if (seps[j]) |slot| _ = slot.with_opacity(out.shown(priorRect(slot), null));
    }
    return out;
}

/// A part's box as last frame stamped it.
fn priorRect(part: El) ?Rect {
    return if (part.prior_geometry()) |g| g.rect else null;
}

/// A stockline's parts as text: the resting abbreviation and compact value, the dim `|`, and
/// the read form.
const Texts = struct {
    stocks: []const Stock,
    compact: bool,

    fn control(self: Texts, box: El, i: usize) bool {
        const s = self.stocks[i];
        var buf: [64]u8 = undefined;
        // A focusable readout, not a control: the full label is its accessible name and the
        // detailed value its spoken value; reading it is not an affordance, so no pointer cursor.
        return box.control(.{ .name = s.full, .role = .text, .value = formatStock(&buf, s, true), .cursor = .default, .ring = false }).hover_focus();
    }

    fn restingSize(self: Texts) Style {
        return if (self.compact) .{ .font = compact_font } else .{};
    }

    fn resting(self: Texts, box: El, i: usize) !void {
        const s = self.stocks[i];
        box.set(.{ .flow = .{ .dir = .row, .cross = .center }, .gap = ha.tokens.gap.inline_, .w = .fit_children, .h = .fit_children }, .{});
        var lbuf: [64]u8 = undefined;
        const label = std.mem.print(&lbuf, "{s}:", .{s.abbrev}) catch s.abbrev;
        var vbuf: [64]u8 = undefined;
        try box.label("l", label, .{ lineType(box.ctx), self.restingSize(), style.muted });
        const val = (try box.text("v", formatStock(&vbuf, s, false)))
            .with_style(.{ lineType(box.ctx), self.restingSize(), style.tone(s.tone), Style{ .verdict = s.verdict } });
        box.get().size.baseline = val.get().size.baseline; // baseline-align the wrapper like its label
    }

    fn separator(self: Texts, slot: El, _: usize) !void {
        try slot.label("t", "|", .{ lineType(slot.ctx), self.restingSize(), style.faint });
    }

    fn read(self: Texts, row: El, i: usize) !ReadExtent {
        const s = self.stocks[i];
        // The read label is the full name in capitals (`VIGOR:`), as the abbreviation is.
        var ubuf: [48]u8 = undefined;
        const full = std.ascii.upperString(&ubuf, s.full[0..@min(s.full.len, ubuf.len)]);
        var lbuf: [64]u8 = undefined;
        const label = std.mem.print(&lbuf, "{s}:", .{full}) catch full;
        var vbuf: [64]u8 = undefined;
        const face = readType(row.ctx, self.compact);
        const lbl = (try row.text("l", label)).with_style(.{ face, Style{ .ink = .fg } });
        const val = (try row.text("v", formatStock(&vbuf, s, true)))
            .with_style(.{ face, style.tone(s.tone), Style{ .verdict = s.verdict } });
        const ls = lbl.get().size;
        const vs = val.get().size;
        return .{ .w = ls.data_width + row.get().layout.gap + vs.data_width, .h = @max(ls.data_height, vs.data_height), .descent = vs.baseline };
    }
};

/// The stockline: a row of tokens in the act descriptor's order, `|`-separated. Returns the
/// row `El` (shelf convention). Membership/order is entirely the caller's `stocks` slice;
/// `compact` is the long-line form (see the module doc).
pub fn stockline(parent: El, id: []const u8, stocks: []const Stock, compact: bool) !El {
    return (try stocklineCovering(parent, id, stocks, compact)).bar;
}

/// `stockline`, returning its open overlays too, so a caller with parts beside the line (the
/// header's run context) can hide what they cover (`Line.cover`, `Line.coverChildren`).
pub fn stocklineCovering(parent: El, id: []const u8, stocks: []const Stock, compact: bool) !Line {
    return line(parent, id, stocks.len, compact, Texts{ .stocks = stocks, .compact = compact });
}

test "stock value tones use foreground, warning, danger and accent roles" {
    try std.testing.expectEqual(style.ThemeRole.fg, style.toneRole(Tone.normal));
    try std.testing.expectEqual(style.ThemeRole.warn, style.toneRole(Tone.warn));
    try std.testing.expectEqual(style.ThemeRole.danger, style.toneRole(Tone.danger));
    try std.testing.expectEqual(style.ThemeRole.acc, style.toneRole(Tone.accent));
}

test "stock amounts truncate compactly and at one decimal" {
    var buf: [32]u8 = undefined;
    const x = std.testing.expectEqualStrings;
    try x("11", formatAmount(&buf, 11.66, false));
    try x("11.6", formatAmount(&buf, 11.66, true));
    try x("126", formatAmount(&buf, 126, true)); // no `.0` on whole amounts
    try x("0", formatAmount(&buf, 0, true));
}

test "stock amount suffixes truncate instead of rounding up" {
    var buf: [32]u8 = undefined;
    const x = std.testing.expectEqualStrings;
    try x("999", formatAmount(&buf, 999.9, false));
    try x("1.0k", formatAmount(&buf, 1000, false));
    try x("1.9k", formatAmount(&buf, 1999, false));
    try x("9.9k", formatAmount(&buf, 9999, false));
    try x("10k", formatAmount(&buf, 10_000, false));
    try x("999k", formatAmount(&buf, 999_999, false));
    try x("1.2M", formatAmount(&buf, 1_299_999, false));
}

test "stock amounts absorb float drift" {
    var buf: [32]u8 = undefined;
    const x = std.testing.expectEqualStrings;
    try x("3.6", formatAmount(&buf, 3.5999998, true));
    try x("3", formatAmount(&buf, 2.9999998, false));
}

test "stock amounts handle negatives and non-finite values" {
    var buf: [32]u8 = undefined;
    const x = std.testing.expectEqualStrings;
    try x("-1.9k", formatAmount(&buf, -1999, false));
    try x("-2.5", formatAmount(&buf, -2.5, true));
    try x("0", formatAmount(&buf, -0.3, false));
    try x("?", formatAmount(&buf, std.math.inf(f32), false));
}

test "stock readout appends max when set" {
    var buf: [64]u8 = undefined;
    const x = std.testing.expectEqualStrings;
    const vigor = Stock{ .abbrev = "VI", .full = "Vigor", .value = 14.25, .max = 15 };
    try x("14/15", formatStock(&buf, vigor, false));
    try x("14.2/15", formatStock(&buf, vigor, true));
    const food = Stock{ .abbrev = ha.sim.data.roster.Resource.food.abbrevIn(1), .full = ha.sim.data.roster.Resource.food.labelIn(1), .value = 4 };
    try x("4", formatStock(&buf, food, false));
}

test "the read overlay starts at the token and flips to end at it past the line's edge" {
    const eq = std.testing.expectEqual;
    const tok = Rect{ .x = 100, .y = 0, .w = 40, .h = 12 };
    // Fits: the box starts the pad before the token.
    try eq(@as(f32, 96), readLeft(tok, 108, 4, 0, 300));
    // Exactly reaching the line's edge still fits.
    try eq(@as(f32, 96), readLeft(tok, 204, 4, 0, 300));
    // One px past: the box ends the pad past the token's right edge.
    try eq(@as(f32, 140 + 4 - 205), readLeft(tok, 205, 4, -100, 300));
    try eq(@as(f32, 144 - 108), readLeft(tok, 108, 4, 0, 150));
    // A box no wider than the token plus its pads lands on the same box either way.
    try eq(@as(f32, 96), readLeft(tok, 48, 4, 0, 120));
    // Flipped, it may reach the pad before the line's left edge, as an unflipped first token's
    // does; past that, a line narrower than the read form keeps it at the token.
    try eq(@as(f32, 36 - 40), readLeft(tok, 148, 4, 0, 150));
    try eq(@as(f32, 96), readLeft(tok, 149, 4, 0, 150));
}

test "the read overlay's baseline sits on the token's resting baseline" {
    const tok = Rect{ .x = 0, .y = 50, .w = 40, .h = 12 };
    // Resting baseline at 62 - 3 = 59; a 21px read text with a 5px descent puts its top at
    // 59 - 16 = 43, so it rises above the 10px line.
    const top = readTop(tok, 3, 21, 5);
    try std.testing.expectEqual(@as(f32, 43), top);
    try std.testing.expectEqual(@as(f32, 59), top + 21 - 5);
    // The same size at rest and read: the overlay sits on the token's own box.
    try std.testing.expectEqual(@as(f32, 50), readTop(tok, 3, 12, 3));
}

test "covered: overlap or a horizontal approach within the margin hides; a gap past it does not" {
    const o = Rect{ .x = 100, .y = 10, .w = 50, .h = 20 }; // right edge 150, bottom 30
    const c = std.testing.expect;
    const n = struct {
        fn f(b: bool) !void {
            try std.testing.expect(!b);
        }
    }.f;
    // Inside, straddling either edge, and enclosing.
    try c(covered(o, .{ .x = 110, .y = 15, .w = 10, .h = 10 }, 4));
    try c(covered(o, .{ .x = 145, .y = 15, .w = 20, .h = 10 }, 4));
    try c(covered(o, .{ .x = 90, .y = 15, .w = 15, .h = 10 }, 4));
    try c(covered(o, .{ .x = 50, .y = 0, .w = 200, .h = 50 }, 4));
    // Right of the fill: within the margin hides, the margin's edge and beyond do not.
    try c(covered(o, .{ .x = 150, .y = 15, .w = 10, .h = 10 }, 4));
    try c(covered(o, .{ .x = 153.9, .y = 15, .w = 10, .h = 10 }, 4));
    try n(covered(o, .{ .x = 154, .y = 15, .w = 10, .h = 10 }, 4));
    try n(covered(o, .{ .x = 200, .y = 15, .w = 10, .h = 10 }, 4));
    // Left of the fill, the same way.
    try c(covered(o, .{ .x = 87, .y = 15, .w = 10, .h = 10 }, 4));
    try n(covered(o, .{ .x = 86, .y = 15, .w = 10, .h = 10 }, 4));
    // Vertically a shared range past half a pixel: a line above or below that the box reaches
    // into is covered, one that only touches it, within half a pixel, or sits clear is not.
    try c(covered(o, .{ .x = 110, .y = 0, .w = 10, .h = 11 }, 4));
    try c(covered(o, .{ .x = 110, .y = 29, .w = 10, .h = 10 }, 4));
    try n(covered(o, .{ .x = 110, .y = 0, .w = 10, .h = 10.5 }, 4));
    try n(covered(o, .{ .x = 110, .y = 29.5, .w = 10, .h = 10 }, 4));
    try n(covered(o, .{ .x = 110, .y = 0, .w = 10, .h = 10 }, 4));
    try n(covered(o, .{ .x = 110, .y = 30, .w = 10, .h = 10 }, 4));
    try n(covered(o, .{ .x = 110, .y = 34, .w = 10, .h = 10 }, 4));
    // Diagonal: within the margin horizontally but on another line clear of the box.
    try n(covered(o, .{ .x = 152, .y = 40, .w = 10, .h = 10 }, 4));
}

test "the overlay eases out over its duration and lands on its ends" {
    const eq = std.testing.expectApproxEqAbs;
    try eq(@as(f32, 0), easeOut(0), 1e-6);
    try eq(@as(f32, 1), easeOut(1), 1e-6);
    try eq(@as(f32, 0.875), easeOut(0.5), 1e-6);
    try eq(@as(f32, 1), easeOut(2), 1e-6); // clamped
    try eq(@as(f32, 0), easeOut(-1), 1e-6);
    var prev: f32 = 0;
    for (1..11) |k| {
        const v = easeOut(@as(f32, @floatFromInt(k)) / 10);
        try std.testing.expect(v > prev);
        prev = v;
    }
}

// -- Headless: the line's overlay over fixed boxes --------------------------------------
// The replay rig has no font, so these lines are built of fixed boxes through the same `line`
// that builds the text stockline: each token 40x12 resting, its read form 100x20.

const replay_test = struct {
    const Rig = struct {
        res: ha.res.Resources,
        arena: std.heap.ArenaAllocator,
        ui: UiCtx,
        driver: uic.FrameDriver,

        fn setUp(self: *Rig) void {
            self.res = uic.replay.headlessResources();
            self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            self.ui = UiCtx.init(&self.res, std.testing.allocator, self.arena.allocator());
            self.driver = uic.FrameDriver.init(&self.ui, &self.arena, std.testing.io, .none);
        }

        fn tearDown(self: *Rig) void {
            self.ui.deinit();
            self.arena.deinit();
        }
    };

    const Boxes = struct {
        fn control(_: Boxes, box: El, _: usize) bool {
            return box.control(.{ .name = "stock", .role = .text, .cursor = .default, .ring = false }).hover_focus();
        }
        fn resting(_: Boxes, box: El, _: usize) !void {
            box.set(.{ .w = .{ .fixed = 40 }, .h = .{ .fixed = 12 } }, .{});
            box.get().size.baseline = 3;
        }
        fn separator(_: Boxes, slot: El, _: usize) !void {
            slot.set(.{ .w = .{ .fixed = 4 }, .h = .{ .fixed = 12 } }, .{});
        }
        fn read(_: Boxes, row: El, _: usize) !ReadExtent {
            try row.leaf("r", .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 20 } }, .{});
            return .{ .w = 100, .h = 20, .descent = 4 };
        }
    };

    /// A `width`-wide header holding a three-token line that grows and wraps as the header's
    /// does. Records each token's and separator's key and opacity, and each overlay's.
    const Fixture = struct {
        width: f32,
        tok_keys: [3]u64 = @splat(0),
        sep_keys: [3]u64 = @splat(0),
        tok_alpha: [3]f32 = @splat(1),
        sep_alpha: [3]f32 = @splat(1),
        read_alpha: [3]?f32 = @splat(null),

        pub fn build(self: *Fixture, ctx: *UiCtx) anyerror!uic.Trees {
            const root = try el.root(ctx, "root");
            const head = try root.box("head", .{ .anchor = .top_left, .offset = .{ .y = 40 }, .w = .{ .fixed = self.width }, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
            const bar = (try line(head, "stocks", 3, false, Boxes{})).bar;
            bar.get().layout.flow.wrap = true;
            bar.set(.{ .w = .grow, .h = .fit_children }, .{});
            self.read_alpha = @splat(null);
            for (bar.get().children.items) |c| {
                const i = c.index orelse continue;
                if (std.mem.eql(u8, c.id, "tok")) {
                    self.tok_keys[i] = c.key;
                    self.tok_alpha[i] = c.render_data.opacity;
                } else if (std.mem.eql(u8, c.id, "sep")) {
                    self.sep_keys[i] = c.key;
                    self.sep_alpha[i] = c.render_data.opacity;
                } else if (std.mem.eql(u8, c.id, "read")) {
                    self.read_alpha[i] = c.children.items[0].render_data.opacity;
                }
            }
            const out = try ctx.arena.alloc(*uic.Node, 1);
            out[0] = root.get();
            return out;
        }

        fn rects(self: *const Fixture, ui: *UiCtx) ![3]Rect {
            var out: [3]Rect = undefined;
            for (self.tok_keys, 0..) |k, i| out[i] = ui.rectOf(k) orelse return error.Unstamped;
            return out;
        }
    };

    fn hover(r: *uic.Replay, x: f32, y: f32) !void {
        try r.frame(&.{.{ .pointer_move = .{ .x = x, .y = y } }});
    }
};

test "stockline: reading a token moves no token; its overlay hides what it covers" {
    const T = replay_test;
    var rig: T.Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    var fx = T.Fixture{ .width = 300 };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(T.Fixture, &fx));
    try r.idle(3);
    const rest = try fx.rects(&rig.ui);
    // 0..40 | 49..53 | 62..102 | 111..115 | 124..164, one line.
    try std.testing.expectEqual(@as(f32, 62), rest[1].x);

    // Hover token 0: the overlay starts closed and opens over the tween's duration.
    try T.hover(&r, rest[0].x + 10, rest[0].y + 6);
    for (0..3) |i| try std.testing.expectEqual(@as(f32, 1), fx.tok_alpha[i]);
    rig.res.tween.advance(ha.tokens.dur_stock_token_s / 2);
    try r.frame(&.{});
    const half = fx.read_alpha[0] orelse return error.NoOverlay;
    try std.testing.expect(half > 0.5 and half < 1); // eased out: past halfway at half time
    try std.testing.expectApproxEqAbs(1 - half, fx.tok_alpha[1], 1e-6); // the covered fade with it
    rig.res.tween.advance(1);
    try r.idle(1);
    try std.testing.expectEqual(@as(?f32, 1), fx.read_alpha[0]);

    // Its box runs -4..104: it hides the first separator and token 1, and lies over its own
    // token; the second separator (111, 7px clear) and token 2 paint as at rest.
    try std.testing.expectEqual(@as(f32, 1), fx.tok_alpha[0]);
    try std.testing.expectEqual(@as(f32, 0), fx.sep_alpha[1]);
    try std.testing.expectEqual(@as(f32, 0), fx.tok_alpha[1]);
    try std.testing.expectEqual(@as(f32, 1), fx.sep_alpha[2]);
    try std.testing.expectEqual(@as(f32, 1), fx.tok_alpha[2]);
    // Nothing moved.
    const open = try fx.rects(&rig.ui);
    for (0..3) |i| try std.testing.expectEqual(rest[i], open[i]);

    // The covered token is still hit at its resting box: the read passes to it.
    try T.hover(&r, rest[1].x + 10, rest[1].y + 6);
    rig.res.tween.advance(1);
    try r.idle(1);
    try std.testing.expectEqual(@as(?f32, null), fx.read_alpha[0]);
    try std.testing.expectEqual(@as(?f32, 1), fx.read_alpha[1]);
    try std.testing.expectEqual(@as(f32, 1), fx.tok_alpha[0]);
    try std.testing.expectEqual(@as(f32, 0), fx.tok_alpha[2]);
    const moved = try fx.rects(&rig.ui);
    for (0..3) |i| try std.testing.expectEqual(rest[i], moved[i]);

    // Off the line: every overlay closes and every part paints as at rest.
    try T.hover(&r, 5, 5);
    rig.res.tween.advance(1);
    try r.idle(1);
    for (0..3) |i| {
        try std.testing.expectEqual(@as(?f32, null), fx.read_alpha[i]);
        try std.testing.expectEqual(@as(f32, 1), fx.tok_alpha[i]);
        try std.testing.expectEqual(@as(f32, 1), fx.sep_alpha[i]);
    }
}

test "stockline: a token near the line's end reads leftward, and wrapping moves nothing" {
    const T = replay_test;
    var rig: T.Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    // 170 wide: the line ends at 170, so token 2's 108px fill from 120 would pass it.
    var fx = T.Fixture{ .width = 170 };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(T.Fixture, &fx));
    try r.idle(3);
    const rest = try fx.rects(&rig.ui);
    try T.hover(&r, rest[2].x + 10, rest[2].y + 6);
    rig.res.tween.advance(1);
    try r.idle(1);
    // Flipped: the fill runs 60..168, hiding token 1 and the second separator, not the first
    // separator (49..53, 7px clear) nor token 0.
    try std.testing.expectEqual(@as(?f32, 1), fx.read_alpha[2]);
    try std.testing.expectEqual(@as(f32, 0), fx.tok_alpha[1]);
    try std.testing.expectEqual(@as(f32, 0), fx.sep_alpha[2]);
    try std.testing.expectEqual(@as(f32, 1), fx.sep_alpha[1]);
    try std.testing.expectEqual(@as(f32, 1), fx.tok_alpha[0]);
    const open = try fx.rects(&rig.ui);
    for (0..3) |i| try std.testing.expectEqual(rest[i], open[i]);

    // 110 wide, the line wraps after token 1 and token 2 sits alone below: reading it covers
    // nothing on the line above and moves nothing.
    var narrow = T.Fixture{ .width = 110 };
    var rig2: T.Rig = undefined;
    rig2.setUp();
    defer rig2.tearDown();
    var r2 = uic.Replay.init(&rig2.driver, uic.replay.hostOf(T.Fixture, &narrow));
    try r2.idle(3);
    const wrapped = try narrow.rects(&rig2.ui);
    try std.testing.expect(wrapped[2].y > wrapped[0].y);
    try T.hover(&r2, wrapped[2].x + 10, wrapped[2].y + 6);
    rig2.res.tween.advance(1);
    try r2.idle(1);
    try std.testing.expectEqual(@as(?f32, 1), narrow.read_alpha[2]);
    try std.testing.expectEqual(@as(f32, 1), narrow.tok_alpha[0]);
    try std.testing.expectEqual(@as(f32, 1), narrow.tok_alpha[1]);
    const after = try narrow.rects(&rig2.ui);
    for (0..3) |i| try std.testing.expectEqual(wrapped[i], after[i]);
}

test "stockline: reduced motion opens and closes the overlay at once" {
    const T = replay_test;
    var rig: T.Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    rig.res.tween.setPolicy(.{ .reduced_motion = true });
    var fx = T.Fixture{ .width = 300 };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(T.Fixture, &fx));
    try r.idle(3);
    const rest = try fx.rects(&rig.ui);
    try T.hover(&r, rest[0].x + 10, rest[0].y + 6);
    try std.testing.expectEqual(@as(?f32, 1), fx.read_alpha[0]);
    try std.testing.expectEqual(@as(f32, 0), fx.tok_alpha[1]);
    try T.hover(&r, 5, 5);
    try std.testing.expectEqual(@as(?f32, null), fx.read_alpha[0]);
    try std.testing.expectEqual(@as(f32, 1), fx.tok_alpha[1]);
}
