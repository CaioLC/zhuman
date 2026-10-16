//! `table` — the pieces of a **fixed-lane table**: a header cell (a 9px tracked label in the
//! theme's `line2`), a body cell (body-size text fitted with an ellipsis into a box of exactly
//! the lane's width, left- or right-aligned), and the header and body rows that lay the lanes
//! out with one gap and one horizontal padding, so every row's fields line up down the list.
//! `capital_row` (Act I BUILD) and the Act II recipe browser compose these.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const Color = uic.Color;

/// One lane: its node id, header label and width in logical px.
pub const Lane = struct { id: []const u8, label: []const u8, w: f32 };

/// The lanes plus the gaps between them, logical px — a row's content width.
pub fn lanes_width(lanes: []const Lane, gap: f32) f32 {
    var width: f32 = 0;
    for (lanes) |l| width += l.w;
    if (lanes.len > 1) width += @as(f32, @floatFromInt(lanes.len - 1)) * gap;
    return width;
}

/// A column label over its lane.
pub fn header_cell(parent: El, id: []const u8, width: f32, label: []const u8) !void {
    const th = parent.ctx.res.view.theme;
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    _ = (try box.text("t", label)).with_style(.{Style{ .font = 9, .tracking = 0.07, .text = th.line2 }});
}

/// A body cell: `text` in `color`, elided to the lane so a long value never knocks the
/// downstream lanes out of line. `right` aligns the readout to the lane's right edge.
pub fn cell(parent: El, id: []const u8, width: f32, text: []const u8, color: Color, right: bool) !void {
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    const inner = try box.div("i");
    _ = inner.with_layout(if (right) .center_right else .center_left);
    _ = (try inner.text_fit("t", text, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
        .with_style(.{ style.body, Style{ .text = color } });
}

/// A row of lanes: flowed left to right, centered on the cross axis, `gap` apart, padded
/// `pad_x` at the sides and `pad_y` above and below. The caller appends cells and may make
/// it a control.
pub fn table_row(parent: El, id: []const u8, gap: f32, pad_x: f32, pad_y: f32) !El {
    const row = try parent.div(id);
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(gap)
        .with_style(.{style.pad_sym(pad_x, pad_y)});
    return row;
}

/// The header row: one header cell per lane, 4px of vertical padding.
pub fn table_header(parent: El, id: []const u8, lanes: []const Lane, gap: f32, pad_x: f32) !El {
    const header = try table_row(parent, id, gap, pad_x, 4);
    for (lanes) |l| try header_cell(header, l.id, l.w, l.label);
    return header;
}

test "a table's content width is its lanes and the gaps between them" {
    const lanes = [_]Lane{
        .{ .id = "a", .label = "A", .w = 100 },
        .{ .id = "b", .label = "B", .w = 50 },
        .{ .id = "c", .label = "C", .w = 25 },
    };
    try std.testing.expectEqual(@as(f32, 191), lanes_width(&lanes, 8));
    try std.testing.expectEqual(@as(f32, 100), lanes_width(lanes[0..1], 8));
}
