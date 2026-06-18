//! RGBA color — a pure POD utility, like `Rect`. The engine never stores or reads
//! it; it's provided here (not left to host policy) because RGBA is universal —
//! every host that draws wants the same four channels — so widgets can share one
//! color type across bindings. The host embeds it in its `RenderData` (each draw
//! aspect carries the color to paint in). Defaults to opaque white.

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
};
