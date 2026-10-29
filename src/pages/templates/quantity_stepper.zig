//! `quantity_stepper` — the deal slip's `− n +` (`.stepper`), shared by the trade dialog and
//! the neighbours view: two 20px buttons around the count, each disabled at its end of the
//! range, accent on hover or focus. The caller owns the value; the stepper returns it moved.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

const button_w: f32 = 20;
const button_h: f32 = 20;
/// `.stepper strong`: 3ch at 12px.
const count_w: f32 = 3 * 7.2;

pub const Names = struct { less: []const u8, more: []const u8 };

fn stepButton(parent: El, id: []const u8, glyph: []const u8, name: []const u8, enabled: bool) !bool {
    const th = parent.ctx.res.view.theme;
    const b = try parent.div(id);
    _ = b.with_size(.{ .fixed = button_w }, .{ .fixed = button_h })
        .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
    const q = b.control(.{ .enabled = enabled, .name = name, .role = .button });
    const lit = enabled and (q.hovering or q.focused or q.held);
    const line = if (!enabled) th.line else if (lit) th.acc else th.line2;
    const text = if (!enabled) th.line2 else if (lit) th.acc else th.fg;
    _ = b.with_style(.{Style{ .outline_color = line }});
    _ = (try b.text("g", glyph)).with_style(.{Style{ .font = 12, .text = text }});
    return q.clicked;
}

/// Build the stepper and return `value` after this frame's clicks, clamped to `[min, max]`.
pub fn quantity_stepper(parent: El, id: []const u8, value: u32, min: u32, max: u32, names: Names) !u32 {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_size(.fit_children, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(2)
        // The two rules on `.stepper` cascade: the group keeps its `line-2` box.
        .with_style(.{ Style{ .outline_color = th.line2 }, style.pad(2) });
    var v = std.math.clamp(value, min, @max(min, max));
    if (try stepButton(row, "less", "\u{2212}", names.less, v > min)) v -= 1;
    // The count is display text (a `{d}` alone reads as a formatted id to the boundary check).
    const count = try row.div("count");
    _ = count.with_size(.{ .fixed = count_w }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
    _ = (try count.text("n", try ctx.arena.print("{}", .{v})))
        .with_style(.{ Style{ .font = 12, .text = th.fg }, style.pad_sym(0, 2) });
    if (try stepButton(row, "more", "+", names.more, v < max)) v += 1;
    return v;
}
