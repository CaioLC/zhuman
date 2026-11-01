//! `table` — the pieces of a **track table**: a header cell (a 9px tracked label in the
//! theme's `line2`), a body cell (body-size text elided at its track's width, left- or
//! right-aligned), and the header and body rows that lay their cells out by one shared set of
//! grid tracks (`uic.tracks`, declared on a common ancestor with `El.with_tracks`) with one
//! horizontal padding, so every row's fields line up down the list. A cell's width is its
//! track's; the caller places it (`El.at_track`) when it does not take the next track.
//! `capital_row` (the BUILD pane, every act) composes these.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;

/// A column label over its lane. Returns the cell.
pub fn header_cell(parent: El, id: []const u8, label: []const u8) !El {
    const box = try parent.box(id, .{ .w = .fit_children, .h = .fit_children }, .{});
    try box.label("t", label, .{Style{ .font = 9, .tracking = 0.07, .ink = .line2 }});
    return box;
}

/// The direction a sortable column is shown in: `none` for a column that is not the active
/// sort, otherwise the arrow it wears.
pub const SortShown = enum { none, ascending, descending };

/// A **sortable** column label: the same tracked label as `header_cell`, but a control. The
/// active sort column reads in `fg` with its arrow (`COST ↑` ascending, `COST ↓` descending)
/// and is published as `selected`; others stay `line2`. Every column lifts to accent on
/// hover/focus. Members register under `group` (the header row's key), so the whole header is
/// one Tab stop and the arrows rove across it.
/// Returns the cell, its stable key (for the group's member list) and whether it was clicked
/// (pointer or Enter/Space) this frame; the caller owns what a click does to the sort.
pub const SortCell = struct { el: El, key: u64, clicked: bool };

pub fn sort_header_cell(parent: El, id: []const u8, label: []const u8, shown: SortShown, group: u64) !SortCell {
    const box = try parent.box(id, .{ .w = .fit_children, .h = .fit_children }, .{});
    const q = box.control(.{
        .name = label,
        .role = .button,
        .value = switch (shown) {
            .none => "not sorted",
            .ascending => "sorted ascending",
            .descending => "sorted descending",
        },
        // The active sort column is the header's one selected member.
        .selected = shown != .none,
        .roving_group = group,
        .ring = false, // the label lifts to accent
    });
    var buf: [48]u8 = undefined;
    const text = switch (shown) {
        .none => label,
        .ascending => std.mem.print(&buf, "{s} \u{2191}", .{label}) catch label,
        .descending => std.mem.print(&buf, "{s} \u{2193}", .{label}) catch label,
    };
    try box.label("t", text, .{ Style{ .font = 9, .tracking = 0.07 }, sort_label });
    return .{ .el = box, .key = box.get().key, .clicked = q.clicked };
}

/// A sortable column's label: line2, fg while it is the active sort (published as
/// `selected`), accent while hot on every column, the active one included.
pub const sort_label = Style{ .ink = .line2, .on = &.{ .{ .when = .selected, .ink = .fg }, .{ .when = .hot, .ink = .acc } } };

/// A body cell: `text` in `ink` (a look: a role, and any state rules on the row), elided at its
/// track's width so a long value never knocks the downstream lanes out of line. `right` anchors
/// the readout to the lane's right edge. Returns the cell.
pub fn cell(parent: El, id: []const u8, text: []const u8, ink: Style, right: bool) !El {
    const box = try parent.box(id, .{ .w = .fit_children, .h = .fit_children }, .{});
    // The anchored inner spans the cell, so the text elides at the track.
    const inner = try box.box("i", .{
        .anchor = if (right) .center_right else .center_left, .w = .{ .pct_of_parent = 1.0 },
        .h = .fit_children,
    }, .{});
    try inner.label_fit("t", text, .{ .cell_fill = .ellipsis }, .{ Style{ .font = 11 }, ink }); // `.build-row { font-size: 11px }`
    return box;
}

/// A row of lanes: a participant of `set` (its in-flow children are cells on the set's tracks,
/// the set's gap apart), centered on the cross axis, padded `pad_x` at the sides and `pad_y`
/// above and below. The caller appends cells and may make it a control.
pub fn table_row(parent: El, id: []const u8, set: *uic.TrackSet, pad_x: f32, pad_y: f32) !El {
    const row = try parent.box(id, .{ .flow = .{ .dir = .row, .cross = .center }, .in_tracks = set }, .{style.pad_sym(pad_x, pad_y)});
    return row;
}
