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

/// Build the Act I policy tile at the full width of its action-grid column. The returned
/// policy value is live; callers map it to their persisted metabolism rate.
pub fn eating_policy(parent: El, id: []const u8, value: f32, enabled: bool) !f32 {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;

    // Keep the percentage width border-box safe: horizontal padding is represented by two
    // in-flow lanes, so the outlined panel remains exactly 100% of its fluid grid column.
    const panel = try parent.div(id);
    _ = panel.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = tile_h })
        .with_flow(.{ .dir = .row, .cross = .start })
        .with_style(.{Style{ .outline_color = th.line2, .outline_style = .dashed }});
    const lead = try panel.div("lead");
    _ = lead.with_size(.{ .fixed = pad_x }, .{ .fixed = 1 }).pass_through();
    const content = try panel.div("content");
    _ = content.with_size(.grow, .{ .fixed = tile_h - pad_top - pad_bottom })
        .with_flow(.{ .dir = .column }).with_gap(5)
        .with_style(.{style.pad_each(pad_top, 0, pad_bottom, 0)});
    const tail = try panel.div("tail");
    _ = tail.with_size(.{ .fixed = pad_x }, .{ .fixed = 1 }).pass_through();

    // Create the three prototype rows in visual order first. Their contents can be attached
    // after the slider resolves this frame's live value without changing sibling order.
    const head = try content.div("head");
    _ = head.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between }).with_gap(8);

    const range_slot = try content.div("range");
    _ = range_slot.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 18 });

    const scale_row = try content.div("scale");
    _ = scale_row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between }).with_gap(8);

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

    _ = (try head.text("title", "EATING POLICY")).with_style(.{
        Style{ .font = 10, .tracking = 0.06, .text = th.dim },
    });

    var output_buf: [48]u8 = undefined;
    const output = std.fmt.bufPrint(&output_buf, "{s} \u{00B7} {d:.2}\u{00D7}", .{ word, rate }) catch word;
    _ = (try head.text("value", output)).with_style(.{
        Style{ .font = 10, .text = if (enabled) th.acc else th.dim },
    });

    _ = (try scale_row.text("min", "meager")).with_style(.{
        Style{ .font = 9, .text = th.line2 },
    });
    _ = (try scale_row.text("max", "lavish")).with_style(.{
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
