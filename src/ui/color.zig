//! RGBA color — a pure POD utility, like `Rect`. The engine never stores or reads
//! it; it's provided here (not left to host policy) because RGBA is universal —
//! every host that draws wants the same four channels — so widgets can share one
//! color type across bindings. The host embeds it in its `RenderData` (each draw
//! aspect carries the color to paint in). Defaults to opaque white.

const std = @import("std");

pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,

    pub const white: Color = .{};
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };

    /// Scale the rgb channels by `f` (clamped 0..255), keeping alpha — for dimming
    /// a disabled widget or brightening on hover without naming a second color.
    pub fn scaled(self: Color, f: f32) Color {
        return .{ .r = chan(self.r, f), .g = chan(self.g, f), .b = chan(self.b, f), .a = self.a };
    }

    fn chan(v: u8, f: f32) u8 {
        const x = @as(f32, @floatFromInt(v)) * f;
        return @intFromFloat(@min(255, @max(0, x)));
    }

    /// Per-channel linear blend from `a` toward `b` by `t` (0..1, clamped), alpha
    /// included — the building block for a whole-theme lerp (a host slides a *set* of
    /// paired colors together by one shared `t`, e.g. a COLD↔WARM identity).
    pub fn lerp(a: Color, b: Color, t: f32) Color {
        const c = std.math.clamp(t, 0, 1);
        return .{ .r = mix(a.r, b.r, c), .g = mix(a.g, b.g, c), .b = mix(a.b, b.b, c), .a = mix(a.a, b.a, c) };
    }

    fn mix(x: u8, y: u8, t: f32) u8 {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        return @intFromFloat(@round(fx + (fy - fx) * t));
    }
};

test "Color.lerp: t=0 is a, t=1 is b, midpoint averages, out-of-range clamps" {
    const a = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const b = Color{ .r = 100, .g = 200, .b = 50, .a = 255 };
    try std.testing.expectEqual(a, Color.lerp(a, b, 0));
    try std.testing.expectEqual(b, Color.lerp(a, b, 1));
    try std.testing.expectEqual(Color{ .r = 50, .g = 100, .b = 25, .a = 128 }, Color.lerp(a, b, 0.5));
    try std.testing.expectEqual(a, Color.lerp(a, b, -1)); // clamps below 0
    try std.testing.expectEqual(b, Color.lerp(a, b, 2)); // clamps above 1
}
