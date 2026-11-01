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
    const b = try parent.box(id, .{
        .w = .{ .fixed = 22 }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .center, .cross = .center },
    }, .{});
    const q = b.control(.{ .enabled = enabled, .name = name, .role = .button, .ring = false });
    const lit = enabled and (q.hot());
    b.set(.{}, .{Style{ .outline_ink = if (!enabled) .line else if (lit) .acc else .line2 }});
    try b.label("g", glyph, .{ Style{ .font = 11, .ink = if (!enabled) .line2 else if (lit) .acc else .fg }, style.pad_sym(0, 2) });
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
    const n = pages(total, per);
    var p = @min(page, n - 1);
    const row = try parent.box(id, .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 7 }, .{});
    const start = p * per;
    const shown = @min(per, total -| start);
    const range = if (total == 0) "0 of 0" else try ctx.arena.print("{d}\u{2013}{d} of {d}", .{ start + 1, start + shown, total });
    try row.label("range", range, .{Style{ .font = 10, .tracking = 0.06, .ink = .dim }});
    if (try pageButton(row, "prev", "\u{2039}", "Previous page", p > 0)) p -= 1;
    try row.label_fit("now", try ctx.arena.print("{d} / {d}", .{ p + 1, n }), .{ .cell = .{ .mode = .clip, .width = now_w } }, .{Style{ .font = 11, .ink = .fg }});
    if (try pageButton(row, "next", "\u{203a}", "Next page", p + 1 < n)) p += 1;
    return p;
}

test "pages rounds up and never reports zero" {
    try std.testing.expectEqual(@as(usize, 1), pages(0, 7));
    try std.testing.expectEqual(@as(usize, 2), pages(9, 7));
    try std.testing.expectEqual(@as(usize, 1), pages(7, 7));
}
