//! `readout` — the primitives of a **readout panel** (`docs/ui_design.md`, HOLDINGS): the
//! bordered, solid-outlined, padded column that HOLDINGS and BODY are made of; its eyebrow
//! section label and the heading row that pairs one with a count; the two-ended
//! `label … value` line; the dim-prose sentence around one live value; and the hairline
//! divider between blocks. Act I's `holdings` template and Act II's rail content compose
//! these, so neither styles a node of its own.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const Color = uic.Color;

/// A panel's padding, clockwise from the top — the argument order of `style.pad_each`.
pub const Pad = struct { up: f32, right: f32, down: f32, left: f32 };

/// The bordered panel: a column that fits its children, `content_width` wide. The engine's
/// fixed sizes are content boxes, so the caller derives the width from its rail minus `pad`.
pub fn readout_panel(parent: El, id: []const u8, content_width: f32, pad: Pad) !El {
    const panel = try parent.box(id, .{
        .w = .{ .fixed = content_width }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
    }, .{ Style{ .outline_ink = .line }, style.solid, style.pad_each(pad.up, pad.right, pad.down, pad.left) });
    return panel;
}

/// An eyebrow section label: 11px, loosened tracking, the theme's dim.
pub fn section_label(parent: El, id: []const u8, text: []const u8) !El {
    return (try parent.text(id, text)).with_style(.{Style{ .font = 11, .tracking = 0.07, .ink = .dim }});
}

/// A panel's heading row: the section label on the left and an optional count on the right,
/// on one baseline.
pub fn readout_heading(parent: El, id: []const u8, title: []const u8, count: ?[]const u8) !El {
    const heading = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .baseline },
    }, .{});
    _ = try section_label(heading, "title", title);
    if (count) |c| _ = try section_label(heading, "count", c);
    return heading;
}

/// A readout line filled into `row`, a node the caller keyed: body-size primary copy on the
/// left and an 11px readout in `right_color` on the right, on one baseline.
pub fn kv_line_in(row: El, left: []const u8, right: []const u8, right_color: Color) !void {
    row.set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .baseline } }, .{});
    try row.label("label", left, .{ style.body, style.ink(.fg) });
    const tail = try row.box("tail", .{ .anchor = .center_right }, .{});
    try tail.label("value", right, .{Style{ .font = 11, .text = right_color }});
}

/// A readout line under its own id.
pub fn kv_line(parent: El, id: []const u8, left: []const u8, right: []const u8, right_color: Color) !void {
    try kv_line_in(try parent.div(id), left, right, right_color);
}

/// One sentence of dim 11px prose around a live value in `value_color`.
pub fn sentence(parent: El, id: []const u8, prefix: []const u8, value: []const u8, suffix: []const u8, value_color: Color) !void {
    const row = try parent.box(id, .{ .flow = .{ .dir = .row, .cross = .baseline } }, .{});
    try row.label("prefix", prefix, .{style.note});
    try row.label("value", value, .{Style{ .font = 11, .text = value_color }});
    try row.label("suffix", suffix, .{style.note});
}

/// A 1px hairline across the panel, `above` px under the block before it and `below` px over
/// the next.
pub fn divider(parent: El, id: []const u8, above: f32, below: f32) !void {
    const wrap = try parent.box(id, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column } }, .{});
    try wrap.leaf("line", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 1 }, .margin = .{ .before = above, .after = below },
    }, .{style.rule_fill});
}
