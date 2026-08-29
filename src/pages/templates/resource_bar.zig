//! `resource_bar` template — the header's always-on stock summary: compact chips
//! (`V: 3/10 | F: 2 | M: 1.2k`) that expand to their full word while hovered
//! (`Vigor: 3/10`). Each chip reads its interaction slot before building its text (the
//! standard last-frame-rect hover pattern), so the swap is just a string choice at
//! build time. Vigor renders as `v/max` — the death-proximity signal — and tints
//! warn/danger as it thins, doing the old ALIVE badge's job in one character of color.
//! Energy is deliberately absent: it's the price of actions (paid from vigor), not a
//! stock — it earns a chip only when harnessed energy becomes storable, later.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const Color = ha.theme.Color;

const fmt_num = @import("../fmt.zig").fmt_num;

/// One chip: a queryable box around a text leaf; hovering swaps short → long. The box
/// (not the text) owns the slot, mirroring `button`'s outer-owns-interaction shape.
fn chip(ctx: *UiCtx, parent: El, id: []const u8, short: []const u8, long: []const u8, color: Color) !void {
    const box = try el.div(ctx, parent, id);
    const txt = if (box.query().hovering) long else short;
    const lbl = (try el.text(ctx, box, "t", txt)).with_style(.{ style.h3, Style{ .text = color } });
    // A plain box has no baseline, so a baseline row bottom-aligns it — the label would
    // ride above the shared line (and above the `|` separators, which straddle it by
    // their descent). Adopt the label's measured baseline so the wrapper aligns like
    // the text it wraps.
    box.get().size.baseline = lbl.get().size.baseline;
}

/// A dim divider between chips.
fn sep(ctx: *UiCtx, parent: El, id: []const u8) !void {
    _ = (try el.text(ctx, parent, id, "|"))
        .with_style(.{ style.h3, Style{ .text = ctx.res.view.theme.dim } });
}

/// The V/F/M row. Returns the bar `El` (shelf convention) — the caller places it.
pub fn resource_bar(
    ctx: *UiCtx,
    parent: El,
    id: []const u8,
    vigor: *const comp.Vigor,
    food: *const comp.InventoryFood,
    materials: *const comp.InventoryMaterial,
) !El {
    const th = ctx.res.view.theme;

    const bar = try el.div(ctx, parent, id);
    _ = bar.with_flow(.{ .dir = .row }).with_gap(10);

    // Two scratch buffers per chip — both variants are formatted before the hover pick;
    // `el.text` copies at build, so the buffers are free again for the next chip.
    var sbuf: [32]u8 = undefined;
    var lbuf: [40]u8 = undefined;

    const frac = vigor.v / vigor.max;
    const vcol = if (frac <= 0.12) th.danger else if (frac < 0.35) th.warn else th.fg;
    try chip(
        ctx,
        bar,
        "vigor",
        std.fmt.bufPrint(&sbuf, "V: {d:.0}/{d:.0}", .{ vigor.v, vigor.max }) catch "?",
        std.fmt.bufPrint(&lbuf, "Vigor: {d:.0}/{d:.0}", .{ vigor.v, vigor.max }) catch "?",
        vcol,
    );

    try sep(ctx, bar, "s1");
    try chip(
        ctx,
        bar,
        "food",
        std.fmt.bufPrint(&sbuf, "F: {d:.0}", .{food.v}) catch "?",
        std.fmt.bufPrint(&lbuf, "Food: {d:.0}", .{food.v}) catch "?",
        th.fg,
    );

    try sep(ctx, bar, "s2");
    var nbuf: [16]u8 = undefined;
    const mnum = fmt_num(&nbuf, materials.v);
    try chip(
        ctx,
        bar,
        "materials",
        std.fmt.bufPrint(&sbuf, "M: {s}", .{mnum}) catch "?",
        std.fmt.bufPrint(&lbuf, "Materials: {s}", .{mnum}) catch "?",
        th.fg,
    );

    return bar;
}
