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

const tile_w: f32 = 300;
const tile_h: f32 = 82;
const pad_x: f32 = 10;
const pad_top: f32 = 9;
const pad_bottom: f32 = 8;

/// Build the Act I policy tile at the same 300px grid-cell width as the action cards. The
/// returned policy value is live; callers map it to their persisted metabolism rate.
pub fn eating_policy(ctx: *UiCtx, parent: El, id: []const u8, value: f32, enabled: bool) !f32 {
    const th = ctx.res.view.theme;

    const panel = try el.div(ctx, parent, id);
    _ = panel.with_size(.{ .fixed = tile_w - pad_x * 2 }, .{ .fixed = tile_h - pad_top - pad_bottom })
        .with_flow(.{ .dir = .column }).with_gap(5)
        .with_style(.{
        Style{ .outline_color = th.line2, .outline_style = .dashed },
        style.pad_each(pad_top, pad_x, pad_bottom, pad_x),
    });

    // Create the three prototype rows in visual order first. Their contents can be attached
    // after the slider resolves this frame's live value without changing sibling order.
    const head = try el.div(ctx, panel, "head");
    _ = head.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between }).with_gap(8);

    const range_slot = try el.div(ctx, panel, "range");
    _ = range_slot.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 18 });

    const scale_row = try el.div(ctx, panel, "scale");
    _ = scale_row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between }).with_gap(8);

    const range = try slider_mod.slider(ctx, range_slot, .{
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

    _ = (try el.text(ctx, head, "title", "EATING POLICY")).with_style(.{
        Style{ .font = 10, .tracking = 0.06, .text = th.dim },
    });

    var output_buf: [48]u8 = undefined;
    const output = std.fmt.bufPrint(&output_buf, "{s} \u{00B7} {d:.2}\u{00D7}", .{ word, rate }) catch word;
    _ = (try el.text(ctx, head, "value", output)).with_style(.{
        Style{ .font = 10, .text = if (enabled) th.acc else th.dim },
    });

    _ = (try el.text(ctx, scale_row, "min", "meager")).with_style(.{
        Style{ .font = 9, .text = th.line2 },
    });
    _ = (try el.text(ctx, scale_row, "max", "lavish")).with_style(.{
        Style{ .font = 9, .text = th.line2 },
    });

    // Replace the generic numeric semantic value published by `slider` with the prototype's
    // richer aria-valuetext. Duplicate-key publication updates in place, preserving order.
    var aria_buf: [64]u8 = undefined;
    const aria = std.fmt.bufPrint(&aria_buf, "{s}, {d:.2} times normal", .{ word, rate }) catch word;
    ctx.res.semantics.publish(uic.semantic.describeSlider(
        range.el.get().key,
        "Eating policy",
        aria,
        enabled,
        ctx.isFocused(range.el.get().key),
    ));

    return new_value;
}
