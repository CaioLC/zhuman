//! `stock_token` and `stockline` (KIT-12) — the header's stock summary as reusable tokens
//! whose **footprint never changes** as their label swaps.
//!
//! A **StockToken** shows a two-letter **abbreviation** with its value (`VI: 3/10`) and swaps to
//! the **full label** while hovered or focused (`VIGOR: 3/10`). Each token sizes to its own
//! content, so the stockline stays **compact** by default — every token is only as wide as its
//! `abbrev + value`. On hover/focus the label expands to the full form, so **only the hovered
//! token grows**; its neighbors stay tight (Act I's direct abbrev/full swap; Act II's compact
//! token expansion rides the same fit). The label is **dim** and the value is the brighter `fg`,
//! with `warn` and `danger` tones available for condition/scarcity states, so the number reads
//! louder than its label and severity reads in the color.
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

/// One stock token's authored data — the act descriptor's row. `abbrev` is the two-letter
/// short form, `full` the hover/focus label, `value` the already-formatted readout, and `tone`
/// its semantic value color. The caller formats `value` and owns domain thresholds.
pub const Stock = struct {
    abbrev: []const u8,
    full: []const u8,
    value: []const u8,
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
    try stock_token_in(try parent.div(id), s);
}

/// Fill `box` as a stock token. `stockline` hands it an `item`, so a loop needs no ids.
fn stock_token_in(box: El, s: Stock) !void {
    const th = box.ctx.res.view.theme;
    // A focusable readout, not a control: the full label is its accessible name and the
    // formatted value its spoken value; hovering it is not an affordance, so no pointer cursor.
    const q = box.control(.{ .name = s.full, .role = .text, .value = s.value, .cursor = .default });
    const reveal = q.hovering or q.focused;

    // The token sizes to its own content, so the stockline is **compact** by default: each
    // token is only as wide as `abbrev + value`. On hover/focus the label swaps to the full
    // form, so **only that token grows** and its neighbors stay tight. Two tinted leaves: a
    // **dim** label (`VIGOR:`) beside the semantic value (`14/15`).
    _ = box.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.fit_children, .fit_children);

    var buf: [64]u8 = undefined;
    const label = if (reveal) s.full else s.abbrev;
    const label_txt = std.fmt.bufPrint(&buf, "{s}:", .{label}) catch label;
    const lbl = (try box.text("l", label_txt))
        .with_style(.{ style.heading, Style{ .text = th.dim } });
    const val = (try box.text("v", s.value))
        .with_style(.{ style.heading, Style{ .text = valueColor(th, s.tone) } });
    box.get().size.baseline = val.get().size.baseline; // baseline-align the wrapper like resource_bar
    _ = lbl;
}

/// The `i`-th dim `|` divider between tokens (heading size, matching the token baseline).
fn sep(parent: El, i: usize) !void {
    const slot = try parent.item("sep", i);
    _ = (try slot.text("t", "|"))
        .with_style(.{ style.heading, Style{ .text = parent.ctx.res.view.theme.dim } });
}

/// The stockline: a row of tokens in the act descriptor's order, `|`-separated. Returns the
/// row `El` (shelf convention). Membership/order is entirely the caller's `stocks` slice.
pub fn stockline(parent: El, id: []const u8, stocks: []const Stock) !El {
    const bar = try parent.div(id);
    _ = bar.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.stack);
    for (stocks, 0..) |s, i| {
        if (i > 0) try sep(bar, i);
        try stock_token_in(try bar.item("tok", i), s);
    }
    return bar;
}

test "stock value tones use foreground, warning, and danger roles" {
    const th = uic.Theme{};
    try std.testing.expectEqual(th.fg, valueColor(th, .normal));
    try std.testing.expectEqual(th.warn, valueColor(th, .warn));
    try std.testing.expectEqual(th.danger, valueColor(th, .danger));
}
