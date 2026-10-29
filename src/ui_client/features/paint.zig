//! Shared paint geometry for the feature `draw` fns: a node's box in engine `ui.Rect`
//! (f32) plus the conversions SDL wants (`FRect` for fills/blits, `IRect` for clip).
//! Leaf module — imports only the engine, `sdl`, and the concrete `Node`; never a
//! feature module, so every feature can import it without a cycle.

const ui = @import("ui");
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

// --- Hairline snapping -------------------------------------------------------
//
// A one-logical-pixel border/outline/rail/focus ring must stay a **crisp whole-device-pixel**
// line at any DPI scale. Layout geometry is device-space f32; a hairline landing on a
// fractional device coordinate (or a fractional width, e.g. 1 logical px × 1.5 scale = 1.5px)
// is anti-aliased into a blurry 1–2px smear, and adjacent columns/rails at fractional
// positions **shimmer** as their coverage shifts sub-pixel. The fix is to snap the hairline's
// *position* to a whole device pixel and its *width* to a whole number of device px (≥ 1), so
// every hairline is exactly N crisp pixels at a pixel boundary. At DPI 1 this is identity for
// integer-authored widths; a fractional `View.scale` is what makes it load-bearing.
// These are pure, testable, and shared by every feature that strokes a line.

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

// --- Per-node visual opacity -------------------------------------------------
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

// --- The focus ring ------------------------------------------------------------
//
// `outline: 1px solid var(--warn); outline-offset: 3px`: a hairline `offset` logical px clear
// of the box, outside it. A ring the ancestors' clip would cut (a row flush to a scroll
// viewport's edge, a tile at the board's rim) is drawn inside the visible part of the box
// instead, `inset` logical px in, so the focused control always shows it whole.

pub const ring_offset: f32 = 3;
pub const ring_inset: f32 = 2;

/// The rect the ring's outer edge strokes, in device px: `box` grown by the offset and the
/// hairline when `clip` holds that, else the visible part of `box` shrunk by the inset. Null
/// when nothing of the box is visible.
pub fn focusRing(box: ui.Rect, clip: ?ui.Rect, scale: f32) ?ui.Rect {
    const s = if (scale > 0) scale else 1;
    const w = hairline(1, s);
    const out = grow(box, @round(ring_offset * s) + w);
    const c = clip orelse return out;
    if (contains(c, out)) return out;
    const seen = c.intersect(box);
    if (seen.w <= 0 or seen.h <= 0) return null;
    const in = grow(seen, -@round(ring_inset * s));
    if (in.w < 2 * w or in.h < 2 * w) return seen;
    return in;
}

fn grow(r: ui.Rect, by: f32) ui.Rect {
    return .{ .x = r.x - by, .y = r.y - by, .w = r.w + 2 * by, .h = r.h + 2 * by };
}

fn contains(outer: ui.Rect, inner: ui.Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and
        inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h;
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

test "focusRing: 3px clear of the box outside it, inset when the clip would cut it" {
    const box: ui.Rect = .{ .x = 100, .y = 50, .w = 40, .h = 20 };
    // Unclipped at scale 1: grown by 3 + the 1px hairline.
    try std.testing.expectEqual(ui.Rect{ .x = 96, .y = 46, .w = 48, .h = 28 }, focusRing(box, null, 1).?);
    // At scale 2 the offset and the hairline both double.
    try std.testing.expectEqual(ui.Rect{ .x = 92, .y = 42, .w = 56, .h = 36 }, focusRing(box, null, 2).?);
    // A clip that holds the ring leaves it outside.
    try std.testing.expectEqual(ui.Rect{ .x = 96, .y = 46, .w = 48, .h = 28 }, focusRing(box, .{ .x = 0, .y = 0, .w = 400, .h = 400 }, 1).?);
    // A clip flush to the box's left edge draws inside the box, 2px in.
    try std.testing.expectEqual(ui.Rect{ .x = 102, .y = 52, .w = 36, .h = 16 }, focusRing(box, .{ .x = 100, .y = 0, .w = 400, .h = 400 }, 1).?);
    // A clip that shows only part of the box insets the visible part.
    try std.testing.expectEqual(ui.Rect{ .x = 102, .y = 52, .w = 36, .h = 6 }, focusRing(box, .{ .x = 0, .y = 0, .w = 400, .h = 60 }, 1).?);
    // A box scrolled wholly out of its clip draws nothing.
    try std.testing.expectEqual(@as(?ui.Rect, null), focusRing(box, .{ .x = 0, .y = 0, .w = 50, .h = 50 }, 1));
}
