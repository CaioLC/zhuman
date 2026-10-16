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
    const th = parent.ctx.res.view.theme;
    const panel = try parent.div(id);
    _ = panel.with_size(.{ .fixed = content_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_style(.{
        Style{ .outline_color = th.line },
        style.solid,
        style.pad_each(pad.up, pad.right, pad.down, pad.left),
    });
    return panel;
}

/// An eyebrow section label: 11px, loosened tracking, the theme's dim.
pub fn section_label(parent: El, id: []const u8, text: []const u8) !El {
    const th = parent.ctx.res.view.theme;
    return (try parent.text(id, text)).with_style(.{Style{ .font = 11, .tracking = 0.07, .text = th.dim }});
}

/// A panel's heading row: the section label on the left and an optional count on the right,
/// on one baseline.
pub fn readout_heading(parent: El, id: []const u8, title: []const u8, count: ?[]const u8) !El {
    const heading = try parent.div(id);
    _ = heading.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline });
    _ = try section_label(heading, "title", title);
    if (count) |c| _ = try section_label(heading, "count", c);
    return heading;
}

/// A readout line filled into `row`, a node the caller keyed: body-size primary copy on the
/// left and an 11px readout in `right_color` on the right, on one baseline.
pub fn kv_line_in(row: El, left: []const u8, right: []const u8, right_color: Color) !void {
    const th = row.ctx.res.view.theme;
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .baseline });
    _ = (try row.text("label", left)).with_style(.{ style.body, Style{ .text = th.fg } });
    const tail = try row.div("tail");
    _ = tail.with_layout(.center_right);
    _ = (try tail.text("value", right)).with_style(.{Style{ .font = 11, .text = right_color }});
}

/// A readout line under its own id.
pub fn kv_line(parent: El, id: []const u8, left: []const u8, right: []const u8, right_color: Color) !void {
    try kv_line_in(try parent.div(id), left, right, right_color);
}

/// One sentence of dim 11px prose around a live value in `value_color`.
pub fn sentence(parent: El, id: []const u8, prefix: []const u8, value: []const u8, suffix: []const u8, value_color: Color) !void {
    const th = parent.ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_flow(.{ .dir = .row, .cross = .baseline });
    _ = (try row.text("prefix", prefix)).with_style(.{Style{ .font = 11, .text = th.dim }});
    _ = (try row.text("value", value)).with_style(.{Style{ .font = 11, .text = value_color }});
    _ = (try row.text("suffix", suffix)).with_style(.{Style{ .font = 11, .text = th.dim }});
}

/// A 1px hairline across the panel, `above` px under the block before it and `below` px over
/// the next.
pub fn divider(parent: El, id: []const u8, above: f32, below: f32) !void {
    const th = parent.ctx.res.view.theme;
    const wrap = try parent.div(id);
    _ = wrap.with_size(.{ .pct_of_parent = 1.0 }, .fit_children).with_flow(.{ .dir = .column });
    _ = try wrap.spacer("above", 1, above);
    const line = try wrap.div("line");
    _ = line.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 1 }).with_style(.{Style{ .fill = th.line }});
    _ = try wrap.spacer("below", 1, below);
}
