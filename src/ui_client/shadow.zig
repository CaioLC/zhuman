//! `shadow` — reusable **shadow / backdrop composition** (RENDER-05). SDL has no blur, so
//! the prototype's soft drop shadows (`box-shadow: 0 16px 80px #000a`, dialog `0 18px 80px
//! #000d`, popup `0 4px 14px #0008`) are approximated by a small **bounded stack of
//! translucent black rectangles** — each a little larger and more offset than the last, with
//! low alpha, so they build up a soft penumbra under a box without a real gaussian. This is
//! the "bounded layers" the roadmap calls for, deliberately **understated**: flat black
//! translucency, no rounded corners, no gloss, no glow.
//!
//! Two pieces:
//!   - `layers(Spec)` — the **pure**, SDL-free layer math (offsets, spreads, alphas). It is
//!     unit-tested without a renderer; the layout/paint is a thin emitter on top.
//!   - `drop` / `backdrop` — `El` emitters. `drop` places the layers as absolutely-anchored
//!     fill rects *inside* a target's parent, sized to the target's box and painted **before**
//!     it (call `drop` before building the box, so the shadow is under it). `backdrop` is the
//!     modal scrim: one fullscreen translucent fill.
//!
//! Colors are the host `Color` (SDL's) — a shadow is flat black at a per-layer alpha, a
//! backdrop is the near-black terminal ground at the prototype's `0xd9` alpha. The RENDER-01
//! `.blend` baseline is what makes every one of these translucent layers composite.

const std = @import("std");
const cb = @import("./ctx_binding.zig");
const el = @import("./elements.zig");
const style = @import("./style.zig");

const UiCtx = cb.UiCtx;
const Color = cb.Color;
const El = el.El;

/// A soft-shadow spec, in the prototype's own terms: how far the shadow drops (`offset_y`),
/// how far the penumbra spreads (`blur`, the CSS blur radius), the darkness at the core
/// (`base_alpha`, 0..255 — the CSS shadow color's alpha byte), and how many bounded layers to
/// stack. Horizontal offset is `offset_x` (0 for the prototype's straight-down shadows).
pub const Spec = struct {
    offset_x: f32 = 0,
    offset_y: f32,
    blur: f32,
    base_alpha: u8,
    /// The number of stacked layers. More layers = smoother penumbra at more draw calls; the
    /// prototype's understated shadows read fine at 4–5. Bounded and small by design.
    count: u8 = 4,
};

/// One shadow layer relative to the target box: how much to grow it on every side (`spread`),
/// where to offset it, and the flat-black alpha to fill it with. Emitted as an
/// absolutely-anchored fill rect behind the target.
pub const Layer = struct {
    spread: f32,
    dx: f32,
    dy: f32,
    alpha: u8,
};

/// The maximum layer count `layers` will emit (bounds the returned buffer).
pub const max_layers = 8;

/// Turn a `Spec` into a bounded, ordered set of shadow `Layer`s (outermost first, so a caller
/// painting them in order lands the tightest/darkest layer last, nearest the box). **Pure** —
/// no SDL, no allocation; writes into `out` and returns the filled slice. Layer `i` (0 =
/// outermost) spreads by `blur · (count−i)/count` — the outer layers are the wide, faint
/// penumbra and the inner ones the tight, darker core — and every layer carries the full
/// `offset`, so the stack reads as a single soft drop shadow. Alpha ramps from faint at the
/// wide outer layer to `base_alpha·(scaled)` at the core, kept low so the layers *sum* to the
/// prototype's understated darkness rather than each being opaque. A `count` of 0 or a
/// non-positive `blur` yields a single flat layer at the offset (a hard shadow).
pub fn layers(spec: Spec, out: *[max_layers]Layer) []const Layer {
    const n: usize = @min(@max(spec.count, 1), max_layers);
    if (spec.blur <= 0) {
        out[0] = .{ .spread = 0, .dx = spec.offset_x, .dy = spec.offset_y, .alpha = spec.base_alpha };
        return out[0..1];
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Outer (i=0) → widest spread, faintest; inner (i=n-1) → tightest, darkest.
        const frac_out: f32 = @as(f32, @floatFromInt(n - i)) / @as(f32, @floatFromInt(n)); // 1..1/n
        const frac_in: f32 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n)); // 1/n..1
        const spread = spec.blur * frac_out;
        // Per-layer alpha: base_alpha spread across the layers so they sum toward the intended
        // darkness. Ramp linearly toward the core; divide by count so N faint layers stack up
        // instead of N opaque ones.
        const a: f32 = @as(f32, @floatFromInt(spec.base_alpha)) * frac_in / @as(f32, @floatFromInt(n));
        out[i] = .{
            .spread = spread,
            .dx = spec.offset_x,
            .dy = spec.offset_y,
            .alpha = @intFromFloat(@min(255, @max(0, @round(a)))),
        };
    }
    return out[0..n];
}

/// Emit a soft drop shadow behind a target box of size `w`×`h` at (`x`,`y`) in `parent`'s
/// local space, as bounded translucent-black fill rects (RENDER-05). Call this **before**
/// building the box so the layers paint under it (siblings paint in child order). `id` keys
/// the layer nodes. Understated flat black; the RENDER-01 `.blend` baseline composites them.
pub fn drop(ctx: *UiCtx, parent: El, id: []const u8, x: f32, y: f32, w: f32, h: f32, spec: Spec) !void {
    var buf: [max_layers]Layer = undefined;
    const ls = layers(spec, &buf);
    for (ls, 0..) |l, i| {
        const key = try std.fmt.allocPrint(ctx.arena, "{s}_sh{d}", .{ id, i });
        const node = try el.div(ctx, parent, key);
        _ = node.with_layout(.top_left)
            .with_offset(x - l.spread + l.dx, y - l.spread + l.dy)
            .with_size(.{ .fixed = w + 2 * l.spread }, .{ .fixed = h + 2 * l.spread })
            .with_style(.{style.Style{ .fill = black(l.alpha) }});
    }
}

/// The modal/dialog **backdrop scrim** (RENDER-05): one translucent fill over the whole
/// window, the near-black terminal ground at the prototype's `0xd9` alpha. Returns the fill
/// color so a caller can set it on a fullscreen root (the modal already builds that root).
pub fn backdropColor(ground: Color) Color {
    return .{ .r = ground.r, .g = ground.g, .b = ground.b, .a = 0xd9 };
}

fn black(a: u8) Color {
    return .{ .r = 0, .g = 0, .b = 0, .a = a };
}

// ============================ Tests (deterministic, SDL-free) =========================

const testing = std.testing;

test "layers: emits `count` ordered layers, outermost widest/faintest, inner tightest/darkest" {
    var buf: [max_layers]Layer = undefined;
    const ls = layers(.{ .offset_y = 16, .blur = 80, .base_alpha = 170, .count = 4 }, &buf);
    try testing.expectEqual(@as(usize, 4), ls.len);
    // Outermost has the widest spread; spread decreases toward the core.
    try testing.expect(ls[0].spread > ls[3].spread);
    try testing.expectApproxEqAbs(@as(f32, 80), ls[0].spread, 1e-4); // blur * 4/4
    try testing.expectApproxEqAbs(@as(f32, 20), ls[3].spread, 1e-4); // blur * 1/4
    // Alpha ramps up toward the core (inner darker than outer).
    try testing.expect(ls[3].alpha > ls[0].alpha);
    // Every layer carries the full drop offset.
    for (ls) |l| try testing.expectApproxEqAbs(@as(f32, 16), l.dy, 1e-4);
}

test "layers: alpha stays bounded and low per layer (no opaque layer)" {
    var buf: [max_layers]Layer = undefined;
    const ls = layers(.{ .offset_y = 18, .blur = 80, .base_alpha = 221, .count = 5 }, &buf);
    for (ls) |l| try testing.expect(l.alpha < 221); // each layer is a fraction of the base
}

test "layers: count is clamped to at least 1 and at most max_layers" {
    var buf: [max_layers]Layer = undefined;
    const one = layers(.{ .offset_y = 4, .blur = 14, .base_alpha = 136, .count = 0 }, &buf);
    try testing.expectEqual(@as(usize, 1), one.len);
    const many = layers(.{ .offset_y = 4, .blur = 14, .base_alpha = 136, .count = 255 }, &buf);
    try testing.expectEqual(@as(usize, max_layers), many.len);
}

test "layers: a non-positive blur is a single hard shadow at the offset" {
    var buf: [max_layers]Layer = undefined;
    const ls = layers(.{ .offset_x = 3, .offset_y = 4, .blur = 0, .base_alpha = 128, .count = 4 }, &buf);
    try testing.expectEqual(@as(usize, 1), ls.len);
    try testing.expectEqual(@as(f32, 0), ls[0].spread);
    try testing.expectEqual(@as(f32, 3), ls[0].dx);
    try testing.expectEqual(@as(f32, 4), ls[0].dy);
    try testing.expectEqual(@as(u8, 128), ls[0].alpha);
}

test "backdropColor: keeps the ground rgb and sets the prototype 0xd9 scrim alpha" {
    const ground: Color = .{ .r = 9, .g = 8, .b = 6, .a = 255 };
    const scrim = backdropColor(ground);
    try testing.expectEqual(@as(u8, 9), scrim.r);
    try testing.expectEqual(@as(u8, 8), scrim.g);
    try testing.expectEqual(@as(u8, 6), scrim.b);
    try testing.expectEqual(@as(u8, 0xd9), scrim.a);
}
