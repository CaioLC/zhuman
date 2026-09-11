//! `slider` — the **range slider** (KIT-10). A horizontal track with a diamond thumb the
//! player drags (or nudges with the keyboard) to pick a value in `[min, max]` snapped to
//! `step`. **The control owns no domain math** ("no eating math"): it produces a value only;
//! the caller maps it to a rate/threshold. The value is the caller's — `slider` takes the
//! current value and returns the new one, so updates are live and the caller stays the source
//! of truth (only the transient pointer-capture lives in a pooled `SliderState`).
//!
//! Anatomy (KIT-10 checklist): a **split track** (a filled `acc` portion up to the thumb over
//! the inactive `line` remainder, via the RENDER-04 gradient feature), a **diamond thumb**, a
//! **focus ring** (the KIT-02 `focus_ring`, only on `focus_visible`), and **accessible value
//! text**. Interaction: **pointer capture** (press captures, drag maps the pointer x to the
//! track fraction → value, release frees capture — the `updateScrollThumb` pattern); and the
//! keyboard **arrows / PageUp/PageDown / Home/End** resolve through `SliderModel.nudge` (a host
//! routes key events into it; the same model the pointer path snaps through, so drag and keys
//! land on one grid).

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const UiCtx = uic.UiCtx;
const SliderModel = uic.UiState.SliderModel;
const SliderState = uic.UiState.SliderState;

/// Track height and thumb size in logical px (the prototype's slim slider). Small fixed chrome
/// constants local to the control's anatomy.
const track_h: f32 = 4;
const thumb_d: f32 = 14;

/// Build a range slider into `parent`. `value` is the caller's current value; the returned
/// value is the (possibly changed) new one — assign it back to your state for a live update.
/// `label` leads the control; `min`/`max`/`step` define the grid; `enabled` gates interaction.
pub fn slider(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8, value: f32, min: f32, max: f32, step: f32, enabled: bool) !f32 {
    const th = ctx.res.view.theme;
    const model = SliderModel{ .min = min, .max = max, .step = step };
    var v = model.snap(value);

    const box = try el.div(ctx, parent, id);
    _ = box.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = ha.tokens.control.h_compact });
    ctx.registerFocus(box.get().key, enabled);

    _ = (try el.text(ctx, box, "lbl", label)).with_style(.{ style.small, Style{ .text = th.dim } });

    // The track: a fixed-height bar that grows to fill the row. The thumb and the pointer math
    // work against its stamped (prior-frame) device-px rect.
    const track = try el.div(ctx, box, "track");
    _ = track.with_size(.grow, .{ .fixed = track_h });
    const tq = track.query();
    const state = box.get().state(ctx, SliderState);

    // Pointer: press anywhere on the track captures and jumps to that fraction; drag keeps
    // updating; release frees capture. Value is derived from the track's device-px rect.
    if (track.get().rect(ctx)) |r| {
        const pointer = &ctx.res.input.pointer;
        if (enabled and tq.pressed and ctx.capturePointer(track.get().key)) {
            state.dragging = true;
            state.pointer_kind = pointer.kind;
            state.pointer_id = pointer.id;
        }
        if (state.dragging) {
            if (!ctx.hasPointerCapture(track.get().key) or ctx.res.input.cancelled) {
                _ = ctx.releasePointerCapture(track.get().key);
                state.dragging = false;
            } else if (pointer.kind == state.pointer_kind and pointer.id == state.pointer_id) {
                const frac = if (r.w > 0) (pointer.position.x - r.x) / r.w else 0;
                v = model.fromFraction(frac);
                if (!pointer.buttons.primary.held) {
                    _ = ctx.releasePointerCapture(track.get().key);
                    state.dragging = false;
                }
            }
        }
        if (tq.hovering or state.dragging) ctx.res.cursor.request(if (enabled) .pointer else .not_allowed);
    }

    const focused = ctx.isFocused(box.get().key);
    uic.publishControlState(ctx, box.get().key, .{ .disabled = !enabled, .focused = focused, .focus_visible = focused });

    const frac = model.toFraction(v);

    // Split track: a horizontal gradient with a hard split at `frac` — `acc` up to the value,
    // `line` after it (RENDER-04 gradient feature). A hard split is two coincident stops.
    _ = try el.gradient(ctx, track, "fill", .horizontal, &.{
        .{ .pos = 0, .color = th.acc },
        .{ .pos = frac, .color = th.acc },
        .{ .pos = frac, .color = th.line },
        .{ .pos = 1, .color = th.line },
    }, 1.0);

    // Diamond thumb: a small square rotated 45° in feel — we approximate with a bordered box
    // centered on the value fraction, anchored over the track. Placed via prior-frame rect.
    if (track.get().rect(ctx)) |r| {
        const scale = ctx.res.view.scale;
        const thumb = try el.div(ctx, track, "thumb");
        const tx = r.w * frac - uic.view.dp(thumb_d, scale) / 2;
        _ = thumb.with_layout(.top_left)
            .with_offset_px(tx, -(uic.view.dp(thumb_d, scale) - uic.view.dp(track_h, scale)) / 2)
            .with_size_px(.{ .fixed = uic.view.dp(thumb_d, scale) }, .{ .fixed = uic.view.dp(thumb_d, scale) })
            .with_style(.{Style{ .fill = if (enabled) th.acc else th.dim, .outline_color = th.bg }});
        // Focus ring on the thumb, only when focus-visible (KIT-02).
        _ = thumb.with_style(.{style.focus_ring});
    }

    // Accessible value text: the current value, so the readout is present for a screen reader
    // and visible to the player. The caller may render its own richer readout; this is the
    // control's honest minimum.
    var buf: [24]u8 = undefined;
    const vtxt = std.fmt.bufPrint(&buf, "{d:.0}", .{v}) catch "?";
    _ = (try el.text(ctx, box, "val", vtxt)).with_style(.{ style.small, Style{ .text = if (enabled) th.fg else th.dim } });

    return v;
}
