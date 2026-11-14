//! `fade` template — the dark the screen passes through between a scene and what comes next:
//! one root over everything, in the window's ground color, as opaque as the fade is deep. It
//! takes no pointer and holds no control, so the screen under it still answers; the page
//! decides what a click means while a fade is running.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const Style = uic.style.Style;

/// The root to draw last, or null when the screen is clear. `level` is the fade's depth, 0
/// clear to 1 dark; it is eased here, so the dark arrives and leaves gently.
pub fn fade(ctx: *uic.UiCtx, level: f32) !?*uic.Node {
    if (level <= 0) return null;
    const root = try el.root(ctx, "fade");
    root.set(.{ .anchor = .top_left }, .{Style{ .fill = ctx.res.view.ground }});
    _ = root.with_opacity(ease(level));
    return root.get();
}

/// Smoothstep: no sudden start, no sudden stop.
fn ease(level: f32) f32 {
    const x = std.math.clamp(level, 0, 1);
    return x * x * (3 - 2 * x);
}

test "fade: the dark eases in and out and is whole at the ends" {
    try std.testing.expectEqual(@as(f32, 0), ease(0));
    try std.testing.expectEqual(@as(f32, 1), ease(1));
    try std.testing.expectEqual(@as(f32, 0.5), ease(0.5));
    try std.testing.expect(ease(0.1) < 0.1 and ease(0.9) > 0.9);
    try std.testing.expectEqual(@as(f32, 1), ease(4));
}
