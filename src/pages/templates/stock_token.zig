//! `stock_token` and `stockline` — the header's stock summary as reusable tokens
//! whose **footprint never changes** as their label swaps.
//!
//! A **StockToken** shows a two-letter **abbreviation** with its truncated value (`FO: 3`,
//! `VI: 14/15`) and swaps to the **full label** plus one truncated decimal, shown only when
//! fractional, while hovered or focused (`FOOD: 3.6`, `COIN: 126`). Each token sizes to its own content, so the stockline stays **compact**
//! by default — every token is only as wide as its `abbrev + value`. On hover/focus the label
//! expands to the full form, so **only the hovered token grows**; its neighbors stay tight
//! (Act I's direct abbrev/full swap; Act II's compact token expansion rides the same fit). The
//! label is **dim** and the value is the brighter `fg`, with `warn` and `danger` tones available
//! for condition/scarcity states, so the number reads louder than its label and severity reads
//! in the color.
//!
//! A **compact** stockline — Act II's nine stocks — sets every token at 10px with 4px gaps, and
//! the hovered or focused token returns to the full heading size, so the long line fits beside
//! the runline and the one being read stays legible (the prototype's `.stockline.compact`).
//!
//! The **stockline** is a row of tokens separated by dim `|` dividers; its **order and
//! membership come from the act descriptor** the caller passes (`&.[_]Stock{...}`), so Act I
//! (Vigor/Food/Materials) and Act II (its sectors) list their own tokens without the template
//! hard-coding either.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const Color = uic.Color;

/// Semantic tone for the numeric value. Labels remain dim in every state.
pub const Tone = enum { normal, warn, danger };

/// A compact line's resting type size and token gap, logical px.
const compact_font: f32 = 10;
const compact_gap: f32 = 4;

/// One stock token's domain data. `abbrev` is the two-letter short form, `full` the
/// hover/focus label, `value` the raw amount, and `max` an optional ceiling shown as `/max`
/// (Vigor). The template owns compact truncation and one-decimal hover formatting; callers own
/// domain meaning and thresholds.
pub const Stock = struct {
    abbrev: []const u8,
    full: []const u8,
    value: f32,
    max: ?f32 = null,
    tone: Tone = .normal,
};

fn valueColor(th: uic.Theme, tone: Tone) Color {
    return switch (tone) {
        .normal => th.fg,
        .warn => th.warn,
        .danger => th.danger,
    };
}

/// Build one stock token into `parent`. The token sizes to its content (abbrev + value),
/// swapping to the full label while hovered/focused so only it grows. Its tone applies only to
/// the value, leaving the label dim. The token is a focusable readout rather than a control.
pub fn stock_token(parent: El, id: []const u8, s: Stock) !void {
    try stock_token_in(try parent.div(id), s, false);
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

/// Fill `box` as a stock token. `stockline` hands it an `item`, so a loop needs no ids.
/// `compact` rests the token at the compact size until it is hovered or focused.
fn stock_token_in(box: El, s: Stock, compact: bool) !void {
    const th = box.ctx.res.view.theme;
    var detail_buf: [64]u8 = undefined;
    const detail = formatStock(&detail_buf, s, true);
    // A focusable readout, not a control: the full label is its accessible name and the
    // detailed value its spoken value; hovering it is not an affordance, so no pointer cursor.
    const q = box.control(.{ .name = s.full, .role = .text, .value = detail, .cursor = .default });
    const reveal = q.hovering or q.focused;
    var compact_buf: [64]u8 = undefined;
    const value = if (reveal) detail else formatStock(&compact_buf, s, false);

    // The token sizes to its own content, so the stockline is **compact** by default: each
    // token is only as wide as `abbrev + value`. On hover/focus the label swaps to the full
    // form, so **only that token grows** and its neighbors stay tight. Two tinted leaves: a
    // **dim** label (`VIGOR:`) beside the semantic value (`14.2/15`).
    _ = box.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.fit_children, .fit_children);

    var buf: [64]u8 = undefined;
    const label = if (reveal) s.full else s.abbrev;
    const label_txt = std.mem.print(&buf, "{s}:", .{label}) catch label;
    const size: Style = if (compact and !reveal) .{ .font = compact_font } else .{};
    const lbl = (try box.text("l", label_txt))
        .with_style(.{ style.heading, size, Style{ .text = th.dim } });
    const val = (try box.text("v", value))
        .with_style(.{ style.heading, size, Style{ .text = valueColor(th, s.tone) } });
    box.get().size.baseline = val.get().size.baseline; // baseline-align the wrapper like its label
    _ = lbl;
}

/// The `i`-th dim `|` divider between tokens (the tokens' resting size, matching their baseline).
fn sep(parent: El, i: usize, compact: bool) !void {
    const slot = try parent.item("sep", i);
    const size: Style = if (compact) .{ .font = compact_font } else .{};
    _ = (try slot.text("t", "|"))
        .with_style(.{ style.heading, size, Style{ .text = parent.ctx.res.view.theme.dim } });
}

/// The stockline: a row of tokens in the act descriptor's order, `|`-separated. Returns the
/// row `El` (shelf convention). Membership/order is entirely the caller's `stocks` slice;
/// `compact` is the long-line form (see the module doc).
pub fn stockline(parent: El, id: []const u8, stocks: []const Stock, compact: bool) !El {
    const bar = try parent.div(id);
    _ = bar.with_flow(.{ .dir = .row, .cross = .center })
        .with_gap(if (compact) compact_gap else ha.tokens.gap.stack);
    for (stocks, 0..) |s, i| {
        if (i > 0) try sep(bar, i, compact);
        try stock_token_in(try bar.item("tok", i), s, compact);
    }
    return bar;
}

test "stock value tones use foreground, warning, and danger roles" {
    const th = uic.Theme{};
    try std.testing.expectEqual(th.fg, valueColor(th, .normal));
    try std.testing.expectEqual(th.warn, valueColor(th, .warn));
    try std.testing.expectEqual(th.danger, valueColor(th, .danger));
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
    const food = Stock{ .abbrev = ha.roster.Resource.food.abbrevIn(1), .full = ha.roster.Resource.food.labelIn(1), .value = 4 };
    try x("4", formatStock(&buf, food, false));
}
