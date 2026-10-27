//! `table` — the pieces of a **fixed-lane table**: a header cell (a 9px tracked label in the
//! theme's `line2`), a body cell (body-size text fitted with an ellipsis into a box of exactly
//! the lane's width, left- or right-aligned), and the header and body rows that lay the lanes
//! out with one gap and one horizontal padding, so every row's fields line up down the list.
//! `capital_row` (the BUILD pane, every act) composes these.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const Color = uic.Color;

/// A column label over its lane.
pub fn header_cell(parent: El, id: []const u8, width: f32, label: []const u8) !void {
    const th = parent.ctx.res.view.theme;
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    _ = (try box.text("t", label)).with_style(.{Style{ .font = 9, .tracking = 0.07, .text = th.line2 }});
}

/// The direction a sortable column is shown in: `none` for a column that is not the active
/// sort, otherwise the arrow it wears.
pub const SortShown = enum { none, ascending, descending };

/// A **sortable** column label: the same tracked label as `header_cell`, but a control. The
/// active sort column reads in `fg` with its arrow (`COST ↑` ascending, `COST ↓` descending);
/// others stay `line2` and lift to accent on hover/focus. Members register under `group` (the
/// header row's key), so the whole header is one Tab stop and the arrows rove across it.
/// Returns the cell's stable key (for the group's member list) and whether it was clicked
/// (pointer or Enter/Space) this frame; the caller owns what a click does to the sort.
pub const SortCell = struct { key: u64, clicked: bool };

pub fn sort_header_cell(parent: El, id: []const u8, width: f32, label: []const u8, shown: SortShown, group: u64) !SortCell {
    const th = parent.ctx.res.view.theme;
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    const q = box.control(.{
        .name = label,
        .role = .button,
        .value = switch (shown) {
            .none => "not sorted",
            .ascending => "sorted ascending",
            .descending => "sorted descending",
        },
        .roving_group = group,
    });
    var buf: [48]u8 = undefined;
    const text = switch (shown) {
        .none => label,
        .ascending => std.mem.print(&buf, "{s} \u{2191}", .{label}) catch label,
        .descending => std.mem.print(&buf, "{s} \u{2193}", .{label}) catch label,
    };
    const color = if (q.hovering or q.held or q.focused) th.acc else if (shown != .none) th.fg else th.line2;
    _ = (try box.text("t", text)).with_style(.{Style{ .font = 9, .tracking = 0.07, .text = color }});
    return .{ .key = box.get().key, .clicked = q.clicked };
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
