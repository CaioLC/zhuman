//! `stock_token` and `stockline` (KIT-12) — the header's stock summary as reusable tokens
//! whose **footprint never changes** as their label swaps.
//!
//! A **StockToken** shows a two-letter **abbreviation** with its value (`VI: 3/10`) and swaps to
//! the **full label** while hovered or focused (`VIGOR: 3/10`). Each token sizes to its own
//! content, so the stockline stays **compact** by default — every token is only as wide as its
//! `abbrev + value`. On hover/focus the label expands to the full form, so **only the hovered
//! token grows**; its neighbors stay tight (Act I's direct abbrev/full swap; Act II's compact
//! token expansion rides the same fit). The label is **dim** and the value is the brighter `fg`
//! (a **low/zero** value tints `danger` instead), so the number reads louder than its label and
//! scarcity reads in the color.
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

/// One stock token's authored data — the act descriptor's row. `abbrev` is the two-letter
/// short form, `full` the hover/focus label, `value` the already-formatted readout, and
/// `danger` whether the value is low/zero (tints the whole token). The caller formats `value`
/// (the token owns no domain math) and decides `danger` from its own thresholds.
pub const Stock = struct {
    abbrev: []const u8,
    full: []const u8,
    value: []const u8,
    danger: bool = false,
};

/// Build one stock token into `parent`. The token sizes to its content (abbrev + value),
/// swapping to the full label while hovered/focused so only it grows; a `danger` value
/// tints it. Returns nothing — it is a readout, not a control (though it is queryable for the
/// hover swap and registers focus so keyboard focus also reveals the full label).
pub fn stock_token(ctx: *UiCtx, parent: El, id: []const u8, s: Stock) !void {
    const th = ctx.res.view.theme;
    const box = try el.div(ctx, parent, id);
    ctx.registerFocus(box.get().key, true);
    const q = box.query();
    const focused = ctx.isFocused(box.get().key);
    const reveal = q.hovering or focused;

    // The token sizes to its own content, so the stockline is **compact** by default: each
    // token is only as wide as `abbrev + value`. On hover/focus the label swaps to the full
    // form, so **only that token grows** and its neighbors stay tight. Two tinted leaves: a
    // **dim** label (`VIGOR:`) beside the **fg** value (`14/15`), matching the prototype where
    // the number reads brighter than its label.
    _ = box.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.fit_children, .fit_children);

    var buf: [64]u8 = undefined;
    const label = if (reveal) s.full else s.abbrev;
    const label_txt = std.fmt.bufPrint(&buf, "{s}:", .{label}) catch label;
    const lbl = (try el.text(ctx, box, "l", label_txt))
        .with_style(.{ style.heading, Style{ .text = th.dim } });
    const value_color = if (s.danger) th.danger else th.fg;
    const val = (try el.text(ctx, box, "v", s.value))
        .with_style(.{ style.heading, Style{ .text = value_color } }); // the number you glance at
    box.get().size.baseline = val.get().size.baseline; // baseline-align the wrapper like resource_bar
    _ = lbl;
}

/// A dim `|` divider between tokens (heading size, matching the token baseline).
fn sep(ctx: *UiCtx, parent: El, id: []const u8) !void {
    _ = (try el.text(ctx, parent, id, "|"))
        .with_style(.{ style.heading, Style{ .text = ctx.res.view.theme.dim } });
}

/// The stockline: a row of tokens in the act descriptor's order, `|`-separated. Returns the
/// row `El` (shelf convention). Membership/order is entirely the caller's `stocks` slice.
pub fn stockline(ctx: *UiCtx, parent: El, id: []const u8, stocks: []const Stock) !El {
    const bar = try el.div(ctx, parent, id);
    _ = bar.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.stack);
    for (stocks, 0..) |s, i| {
        if (i > 0) {
            const skey = try std.fmt.allocPrint(ctx.arena, "sep{d}", .{i});
            try sep(ctx, bar, skey);
        }
        const tkey = try std.fmt.allocPrint(ctx.arena, "tok{d}", .{i});
        try stock_token(ctx, bar, tkey, s);
    }
    return bar;
}
