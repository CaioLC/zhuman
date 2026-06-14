//! RGBA color — engine-carried render *data*. Like `Rect`, it's a pure POD the
//! engine stores on every node but never interprets; the host's draw primitives
//! read it. It lives in the engine (not as host policy like `RenderFlags`) because
//! RGBA is universal — every host that draws wants the same four channels — so
//! widgets can share one color type across bindings. Defaults to opaque white.

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
