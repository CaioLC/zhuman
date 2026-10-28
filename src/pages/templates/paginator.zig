//! `paginator` — `{a}–{b} of {n}  ‹  p / P  ›` (`.paginator`), shared by the trade dialog's
//! busy ledger and the neighbours view. The caller owns the page; this returns it moved.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

/// `.page-now`: 6ch at 11px.
const now_w: f32 = 6 * 6.6;

fn pageButton(parent: El, id: []const u8, glyph: []const u8, name: []const u8, enabled: bool) !bool {
    const th = parent.ctx.res.view.theme;
    const b = try parent.div(id);
    _ = b.with_size(.{ .fixed = 22 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
    const q = b.control(.{ .enabled = enabled, .name = name, .role = .button });
    const lit = enabled and (q.hovering or q.focused or q.held);
    _ = b.with_style(.{Style{ .outline_color = if (!enabled) th.line else if (lit) th.acc else th.line2 }});
    _ = (try b.text("g", glyph)).with_style(.{ Style{ .font = 11, .text = if (!enabled) th.line2 else if (lit) th.acc else th.fg }, style.pad_sym(0, 2) });
    return q.clicked;
}

/// The page count for `total` rows at `per` a page (at least one page).
pub fn pages(total: usize, per: usize) usize {
    return @max(1, (total + per - 1) / per);
}

/// Build the paginator over `total` rows at `per` a page and return the page after this frame's
/// clicks, clamped to the pages there are.
pub fn paginator(parent: El, id: []const u8, page: usize, total: usize, per: usize) !usize {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const n = pages(total, per);
    var p = @min(page, n - 1);
    const row = try parent.div(id);
    _ = row.with_size(.fit_children, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(7);
    const start = p * per;
    const shown = @min(per, total -| start);
    const range = if (total == 0) "0 of 0" else try ctx.arena.print("{d}\u{2013}{d} of {d}", .{ start + 1, start + shown, total });
    _ = (try row.text("range", range)).with_style(.{Style{ .font = 10, .tracking = 0.06, .text = th.dim }});
    if (try pageButton(row, "prev", "\u{2039}", "Previous page", p > 0)) p -= 1;
    _ = (try row.text_fit("now", try ctx.arena.print("{d} / {d}", .{ p + 1, n }), .{ .cell = .{ .mode = .clip, .width = now_w } }))
        .with_style(.{Style{ .font = 11, .text = th.fg }});
    if (try pageButton(row, "next", "\u{203a}", "Next page", p + 1 < n)) p += 1;
    return p;
}

test "pages rounds up and never reports zero" {
    try std.testing.expectEqual(@as(usize, 1), pages(0, 7));
    try std.testing.expectEqual(@as(usize, 2), pages(9, 7));
    try std.testing.expectEqual(@as(usize, 1), pages(7, 7));
}
