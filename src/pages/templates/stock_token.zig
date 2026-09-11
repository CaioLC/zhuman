//! `stock_token` and `stockline` (KIT-12) — the header's stock summary as reusable tokens
//! whose **footprint never changes** as their label swaps.
//!
//! A **StockToken** shows a two-letter **abbreviation** with its value (`Vi 3/10`) and swaps to
//! the **full label** while hovered or focused (`Vigor 3/10`). The crux is *stable alignment*:
//! the whole token renders inside a fixed-width **cell** (`El.with_cell(.clip, w)`, TEXT-03), so
//! whether it shows the short or the long form its layout/hit box stays exactly `cell_w` — a
//! widening label never shoves the neighboring tokens outside the stockline (Act I's direct
//! abbrev/full swap; Act II's compact-token font expansion rides the same cell). A **low/zero**
//! value tints `danger`, so scarcity reads in the color, not just the number.
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

/// The cell width (logical px) each token reserves so its footprint is stable across the
/// abbrev↔full swap. Sized to comfortably hold the longest full label + value at the heading
/// size; the `.clip` cell keeps a longer string from widening the box (it clips), and a shorter
/// one still reserves the full width for column-stable alignment.
pub const cell_w: f32 = 128;

/// Build one stock token into `parent`. The whole token is a fixed-width cell that shows the
/// abbreviation + value, swapping to the full label while hovered/focused; a `danger` value
/// tints it. Returns nothing — it is a readout, not a control (though it is queryable for the
/// hover swap and registers focus so keyboard focus also reveals the full label).
pub fn stock_token(ctx: *UiCtx, parent: El, id: []const u8, s: Stock) !void {
    const th = ctx.res.view.theme;
    const box = try el.div(ctx, parent, id);
    ctx.registerFocus(box.get().key, true);
    const q = box.query();
    const focused = ctx.isFocused(box.get().key);
    const reveal = q.hovering or focused;

    var buf: [64]u8 = undefined;
    const label = if (reveal) s.full else s.abbrev;
    const txt = std.fmt.bufPrint(&buf, "{s} {s}", .{ label, s.value }) catch s.value;
    const color = if (s.danger) th.danger else th.fg;
    const lbl = (try el.text(ctx, box, "t", txt))
        .with_style(.{ style.heading, Style{ .text = color } })
        .with_cell(.clip, cell_w); // stable footprint: the box is always cell_w, never the glyph width
    box.get().size.baseline = lbl.get().size.baseline; // baseline-align the wrapper like resource_bar
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
