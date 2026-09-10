//! Shared paint geometry for the feature `draw` fns: a node's box in engine `ui.Rect`
//! (f32) plus the conversions SDL wants (`FRect` for fills/blits, `IRect` for clip).
//! Leaf module — imports only the engine, `sdl`, and the concrete `Node`; never a
//! feature module, so every feature can import it without a cycle.

const ui = @import("../../ui/root.zig");
const sdl = @import("sdl3");
const cb = @import("../ctx_binding.zig");

const Node = cb.Node;

/// A node's full resolved box (global pos + solved size), or null if it hasn't been
/// laid out yet. Where `fill`/`outline` paint, and the box a `.clip` node crops to.
pub fn full(node: *Node) ?ui.Rect {
    return .{
        .x = node.layout._global_x orelse return null,
        .y = node.layout._global_y orelse return null,
        .w = node.size.width,
        .h = node.size.height,
    };
}

/// A node's content box: global pos inset by padding, sized to the host-measured
/// `data_*` dims — where `text`/`img`/`svg` blit their payload. Null if not laid out.
pub fn content(node: *Node) ?ui.Rect {
    const s = node.size;
    return .{
        .x = (node.layout._global_x orelse return null) + s.padding.left,
        .y = (node.layout._global_y orelse return null) + s.padding.up,
        .w = s.data_width,
        .h = s.data_height,
    };
}

/// `ui.Rect` (f32) → SDL `FRect`, the shape the renderer's fill/blit primitives take.
pub fn frect(r: ui.Rect) sdl.rect.FRect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// `?ui.Rect` (f32) → `?IRect` (i32), the shape `setClipRect` takes (`null` disables).
pub fn irect(r: ?ui.Rect) ?sdl.rect.IRect {
    const v = r orelse return null;
    return .{
        .x = @intFromFloat(v.x),
        .y = @intFromFloat(v.y),
        .w = @intFromFloat(v.w),
        .h = @intFromFloat(v.h),
    };
}

// --- Hairline snapping (RENDER-06) -------------------------------------------------------
//
// A one-logical-pixel border/outline/rail/focus ring must stay a **crisp whole-device-pixel**
// line at any DPI scale. Layout geometry is device-space f32; a hairline landing on a
// fractional device coordinate (or a fractional width, e.g. 1 logical px × 1.5 scale = 1.5px)
// is anti-aliased into a blurry 1–2px smear, and adjacent columns/rails at fractional
// positions **shimmer** as their coverage shifts sub-pixel. The fix is to snap the hairline's
// *position* to a whole device pixel and its *width* to a whole number of device px (≥ 1), so
// every hairline is exactly N crisp pixels at a pixel boundary. Today `View.scale` is 1 so
// this is identity for integer-authored widths; it becomes load-bearing when VIEW-01 feeds a
// real DPI factor. These are pure, testable, and shared by every feature that strokes a line.

/// Snap a device-space coordinate to the nearest whole pixel — a hairline edge sits *on* a
/// pixel boundary rather than straddling two. Used for outline/rail positions.
pub fn snap(device_coord: f32) f32 {
    return @round(device_coord);
}

/// A hairline's device-px width for a `logical_w`-logical-pixel line at `scale`: rounded to a
/// whole number of device pixels and floored at 1, so a 1px logical border is always at least
/// one crisp device pixel and never a fractional smear. `@round` (not `@ceil`) keeps a
/// sub-pixel authored width from doubling; the `@max(1, …)` guarantees visibility.
pub fn hairline(logical_w: f32, scale: f32) f32 {
    const s = if (scale > 0) scale else 1;
    return @max(1, @round(logical_w * s));
}

// --- Per-node visual opacity (RENDER-07) -------------------------------------------------
//
// The render walk carries an inherited opacity (0..1) down the tree and multiplies it into
// every feature's paint alpha, so a whole subtree can be dimmed (a board tile filtered out, a
// disabled control) **without recomputing each child's color**. `applyOpacity` is the one fold
// point: it scales a color's alpha by the effective opacity. Opacity is purely visual — it is
// applied here at draw and never consulted by hit-testing (`mark`/interaction), so a dimmed
// node's clickability is decided by state logic alone, as the roadmap requires.

/// A `Color` with its alpha scaled by `opacity` (0..1). `opacity == 1` returns the color
/// unchanged (the common path). Clamped so a stray value can't overflow the byte.
pub fn applyOpacity(c: cb.Color, opacity: f32) cb.Color {
    if (opacity >= 1) return c;
    const a: f32 = @as(f32, @floatFromInt(c.a)) * @max(0, opacity);
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = @intFromFloat(@min(255, @max(0, @round(a)))) };
}

// ============================ Tests (deterministic, SDL-free) =========================

const std = @import("std");

test "snap: rounds a device coordinate to a whole pixel boundary" {
    try std.testing.expectEqual(@as(f32, 12), snap(12.0));
    try std.testing.expectEqual(@as(f32, 12), snap(11.6));
    try std.testing.expectEqual(@as(f32, 13), snap(12.5)); // round-half-up (ties to even/away — either lands on a pixel)
    try std.testing.expectEqual(@as(f32, 12), snap(12.4));
}

test "hairline: a 1px logical line is >=1 crisp device px at any scale" {
    // At scale 1 (today) it is identity: 1 logical px → 1 device px.
    try std.testing.expectEqual(@as(f32, 1), hairline(1, 1));
    // A fractional DPI scale rounds to a whole device px (no 1.5px smear), never below 1.
    try std.testing.expectEqual(@as(f32, 2), hairline(1, 1.5)); // 1.5 → 2
    try std.testing.expectEqual(@as(f32, 2), hairline(1, 2)); // 2.0 → 2
    try std.testing.expectEqual(@as(f32, 3), hairline(1, 3)); // 3.0 → 3
    // A thin authored width never disappears (floored at 1) even at a downscale.
    try std.testing.expectEqual(@as(f32, 1), hairline(1, 0.4)); // 0.4 → round 0 → floored 1
    // A thicker authored line scales and rounds too.
    try std.testing.expectEqual(@as(f32, 3), hairline(2, 1.5)); // 3.0 → 3
    // A non-positive scale is treated as 1 (never a 0/negative width).
    try std.testing.expectEqual(@as(f32, 1), hairline(1, 0));
    try std.testing.expectEqual(@as(f32, 1), hairline(1, -2));
}

test "applyOpacity: scales alpha only, leaves rgb; opacity>=1 is identity" {
    const c: cb.Color = .{ .r = 10, .g = 20, .b = 30, .a = 200 };
    // Identity fast path.
    try std.testing.expectEqual(c, applyOpacity(c, 1));
    try std.testing.expectEqual(c, applyOpacity(c, 2)); // clamped ≥1 → identity
    // Half opacity halves alpha, rgb untouched.
    const half = applyOpacity(c, 0.5);
    try std.testing.expectEqual(@as(u8, 10), half.r);
    try std.testing.expectEqual(@as(u8, 20), half.g);
    try std.testing.expectEqual(@as(u8, 30), half.b);
    try std.testing.expectEqual(@as(u8, 100), half.a);
    // Zero opacity → fully transparent (but rgb preserved).
    try std.testing.expectEqual(@as(u8, 0), applyOpacity(c, 0).a);
    // Negative opacity clamps to 0 alpha.
    try std.testing.expectEqual(@as(u8, 0), applyOpacity(c, -1).a);
}
