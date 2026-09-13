//! `slider` — the prototype-faithful horizontal range control (KIT-10).
//!
//! The template owns only range-control behavior and chrome: an 18px interaction lane, a 3px
//! split rail, and a true 12px outlined diamond thumb. Labels, policy wording, and endpoint
//! captions belong to the caller's composition (`eating_policy`), matching the HTML anatomy.
//! The caller remains the value source of truth; pooled state stores pointer capture only.
//!
//! Pointer interaction clicks/jumps anywhere in the lane, captures through drag, and releases
//! on button-up/cancellation. Keyboard interaction is routed to a registered range owner:
//! arrows move one step, Page Up/Down move a coarse step, and Home/End jump to the bounds.
//! Pointer and keyboard both resolve through `SliderModel`, so every path lands on one grid.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const El = el.El;
const UiCtx = uic.UiCtx;
const SliderModel = uic.UiState.SliderModel;
const SliderState = uic.UiState.SliderState;

/// Prototype dimensions in logical px (`.eating-slider` and its pseudo-elements).
const control_h: f32 = 18;
const track_h: f32 = 3;
const thumb_d: f32 = 12;
const thumb_half_stroke: f32 = 0.045; // ≈ 1px full stroke on a 12px diamond

const diamond = [_]uic.Point{
    .{ .x = 0.5, .y = 0.0 },
    .{ .x = 1.0, .y = 0.5 },
    .{ .x = 0.5, .y = 1.0 },
    .{ .x = 0.0, .y = 0.5 },
};

pub const Options = struct {
    id: []const u8,
    label: []const u8,
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    enabled: bool = true,
};

pub const Slider = struct {
    value: f32,
    el: El,
};

/// Build one range input. The returned value may change this frame from pointer or keyboard
/// input; assign it back to caller state. The visible control deliberately contains no text.
pub fn slider(ctx: *UiCtx, parent: El, opts: Options) !Slider {
    const th = ctx.res.view.theme;
    const model = SliderModel{ .min = opts.min, .max = opts.max, .step = opts.step };
    var value = model.snap(opts.value);

    const control = try el.div(ctx, parent, opts.id);
    _ = control.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = control_h });
    const key = control.get().key;
    ctx.registerFocus(key, opts.enabled);
    ctx.res.commands.registerRange(key);

    const q = control.query();
    const state = control.get().state(ctx, SliderState);

    // Host-routed keyboard commands. These flags are transient and targeted only when this
    // stable key was the focused range owner in the prior frame.
    if (opts.enabled) {
        if (q.decrement) value = model.nudge(value, .left);
        if (q.increment) value = model.nudge(value, .right);
        if (q.page_decrement) value = model.nudge(value, .page_down);
        if (q.page_increment) value = model.nudge(value, .page_up);
        if (q.minimum) value = model.nudge(value, .home);
        if (q.maximum) value = model.nudge(value, .end);
    }

    // The entire 18px lane is the hit target, as the native prototype input is; the rail is
    // intentionally only 3px. Press requests focus, jumps immediately, and owns capture.
    if (control.get().rect(ctx)) |r| {
        const pointer = &ctx.res.input.pointer;
        if (opts.enabled and q.pressed) {
            _ = ctx.requestFocus(key);
            if (ctx.capturePointer(key)) {
                state.dragging = true;
                state.pointer_kind = pointer.kind;
                state.pointer_id = pointer.id;
            }
        }

        if (state.dragging) {
            if (!ctx.hasPointerCapture(key) or ctx.res.input.cancelled) {
                _ = ctx.releasePointerCapture(key);
                state.dragging = false;
            } else if (pointer.kind == state.pointer_kind and pointer.id == state.pointer_id) {
                const fraction = if (r.w > 0) (pointer.position.x - r.x) / r.w else 0;
                value = model.fromFraction(fraction);
                if (!pointer.buttons.primary.held) {
                    _ = ctx.releasePointerCapture(key);
                    state.dragging = false;
                }
            }
        }
    }

    if (q.hovering or state.dragging) {
        ctx.res.cursor.request(if (opts.enabled) .horizontal_resize else .not_allowed);
    }

    const focused = ctx.isFocused(key);
    uic.publishControlState(ctx, key, .{
        .disabled = !opts.enabled,
        .focused = focused,
        .focus_visible = focused,
    });

    var value_buf: [32]u8 = undefined;
    const value_text = std.fmt.bufPrint(&value_buf, "{d:.2}", .{value}) catch "?";
    ctx.res.semantics.publish(uic.semantic.describeSlider(key, opts.label, value_text, opts.enabled, focused));

    const fraction = model.toFraction(value);
    const scale = ctx.res.view.scale;
    const track_y = @round(uic.view.dp((control_h - track_h) / 2, scale));

    // Hard split at the current fraction: accent progress, line-2 remainder. The geometry is
    // presentation-only/pass-through so the full control lane remains the sole hit target.
    const rail = try el.gradient(ctx, control, "rail", .horizontal, &.{
        .{ .pos = 0, .color = if (opts.enabled) th.acc else th.dim },
        .{ .pos = fraction, .color = if (opts.enabled) th.acc else th.dim },
        .{ .pos = fraction, .color = th.line2 },
        .{ .pos = 1, .color = th.line2 },
    }, 1.0);
    _ = rail.with_layout(.top_left)
        .with_offset_px(0, track_y)
        .with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = track_h })
        .pass_through();

    // Use the prior stamped lane width for the value-relative thumb position. The thumb is a
    // genuine diamond mesh (background fill + closed foreground stroke), not a square proxy.
    if (control.get().rect(ctx)) |r| {
        const thumb_px = uic.view.dp(thumb_d, scale);
        const lane_h_px = uic.view.dp(control_h, scale);
        const x = @round(r.w * fraction - thumb_px / 2);
        const y = @round((lane_h_px - thumb_px) / 2);
        const thumb = try el.div(ctx, control, "thumb");
        _ = thumb.with_layout(.top_left)
            .with_offset_px(x, y)
            .with_size_px(.{ .fixed = thumb_px }, .{ .fixed = thumb_px })
            .pass_through();

        const fill = try el.polygon(ctx, thumb, "fill", &diamond, th.bg, 1.0);
        _ = fill.with_layout(.top_left)
            .with_size(.{ .pct_of_parent = 1.0 }, .{ .pct_of_parent = 1.0 })
            .pass_through();

        const edge_color = if (!opts.enabled) th.dim else if (focused or q.hovering or state.dragging) th.acc else th.fg;
        const edge = try el.polyline(ctx, thumb, "edge", &diamond, thumb_half_stroke, true, .butt, edge_color, 1.0);
        _ = edge.with_layout(.top_left)
            .with_size(.{ .pct_of_parent = 1.0 }, .{ .pct_of_parent = 1.0 })
            .pass_through();
    }

    return .{ .value = value, .el = control };
}
