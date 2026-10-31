//! `eating_policy` — the prototype's complete policy tile: heading/readout, range input, and
//! endpoint scale. Domain math remains in `ha.eating`; the nested `slider` owns only range
//! interaction/chrome. The caller supplies and receives the `0..100` policy value.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const eating = ha.eating;

const slider_mod = @import("./slider.zig");

const tile_h: f32 = 82;
const pad_x: f32 = 10;
const pad_top: f32 = 9;
const pad_bottom: f32 = 8;

/// Build the policy tile at the full width of its parent (the Household rail's column, under
/// BODY). The returned policy value is live; callers map it to their persisted metabolism rate.
pub fn eating_policy(parent: El, id: []const u8, value: f32, enabled: bool) !f32 {
    const ctx = parent.ctx;

    // The percentage width is a border box, so the horizontal padding comes out of it and the
    // outlined panel remains exactly 100% of its fluid grid column.
    const panel = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = tile_h }, .flow = .{ .dir = .row, .cross = .start },
    }, .{ Style{ .outline_ink = .line2, .outline_style = .dashed }, style.pad_sym(pad_x, 0) });
    const content = try panel.box("content", .{
        .w = .grow, .h = .{ .fixed = tile_h - pad_top - pad_bottom }, .flow = .{ .dir = .column }, .gap = 5,
    }, .{style.pad_each(pad_top, 0, pad_bottom, 0)});

    // Create the three prototype rows in visual order first. Their contents can be attached
    // after the slider resolves this frame's live value without changing sibling order.
    const head = try content.box("head", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .main = .space_between },
        .gap = 8,
    }, .{});

    const range_slot = try content.box("range", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 18 } }, .{});

    const scale_row = try content.box("scale", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .main = .space_between },
        .gap = 8,
    }, .{});

    const range = try slider_mod.slider(range_slot, .{
        .id = "control",
        .label = "Eating policy",
        .value = value,
        .min = 0,
        .max = 100,
        .step = 1,
        .enabled = enabled,
    });
    const new_value = range.value;
    const rate = eating.rate(new_value);
    const word = eating.word(new_value);

    try head.label("title", "EATING POLICY", .{ Style{ .font = 10, .tracking = 0.06, .ink = .dim } });

    var output_buf: [48]u8 = undefined;
    const output = std.mem.print(&output_buf, "{s} \u{00B7} {d:.2}\u{00D7}", .{ word, rate }) catch word;
    try head.label("value", output, .{ Style{ .font = 10, .ink = if (enabled) .acc else .dim } });

    try scale_row.label("min", "meager", .{ Style{ .font = 9, .ink = .line2 } });
    try scale_row.label("max", "lavish", .{ Style{ .font = 9, .ink = .line2 } });

    // Replace the generic numeric semantic value published by `slider` with the prototype's
    // richer aria-valuetext. Duplicate-key publication updates in place, preserving order.
    var aria_buf: [64]u8 = undefined;
    const aria = std.mem.print(&aria_buf, "{s}, {d:.2} times normal", .{ word, rate }) catch word;
    ctx.res.semantics.publish(uic.semantic.describeSlider(
        range.el.get().key,
        "Eating policy",
        aria,
        enabled,
        ctx.isFocused(range.el.get().key),
    ));

    return new_value;
}
