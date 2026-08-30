//! The foundation's color vocabulary: the `Color` type, the blend math, and `Theme` —
//! nine named roles every widget paints from.
//!
//! **The roles are foundation; the values are art direction.** A UI layer needs a
//! default ink or an unstyled text leaf would be invisible, so `Theme` carries a plain
//! neutral palette and the content leaves paint from it. A game overrides those values
//! (see `src/palette.zig`) by assigning a whole `Theme` onto `res.view.theme`; nothing
//! here knows those palettes exist.
//!
//! A **leaf module** on purpose — it imports only `sdl3`, never the engine or
//! `ctx_binding`. That is what lets `res.zig` hold a `Theme` on `View` without an import
//! cycle (`res.zig` → this → `sdl3`, and nothing points back).

const std = @import("std");
const sdl3 = @import("sdl3");

/// The host color type — exactly SDL's `SDL_Color` (`{ r, g, b, a: u8 }`), not a wrapper.
/// Carried opaquely on `RenderData`; the engine never reads it.
///
/// The alias is a **dependency fence, not an abstraction seam**. It buys no portability:
/// this layer is SDL all the way down (renderer, textures, fonts, `FRect`), and every
/// call into SDL destructures a colour into an anonymous literal anyway, so nothing here
/// leans on the type's identity. What it buys is that `src/pages/` — templates and
/// screens — can name a colour without importing `sdl3`. No file under `pages/` imports
/// the graphics backend today; this is part of why.
pub const Color = sdl3.pixels.Color;

/// Opaque RGB shorthand (alpha = 255). SDL's `Color` has no field defaults (it is a
/// translated C struct), so palette entries use this instead of spelling `.a = 255` on
/// every line.
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

/// The nine roles a widget paints from. Defaults are a deliberately plain greyscale plus
/// three conventional semantic hues — enough to render the whole foundation legibly with
/// no game attached, and obviously *not* anyone's visual identity, so a screen that
/// forgets to install a palette looks unfinished rather than subtly wrong.
pub const Theme = struct {
    /// Window ground.
    bg: Color = rgb(16, 16, 16),
    /// A raised surface (a panel, a card).
    panel: Color = rgb(28, 28, 28),
    /// Hairline separators and inactive tracks.
    line: Color = rgb(48, 48, 48),
    /// A stronger border — a panel edge, a hovered frame.
    line2: Color = rgb(72, 72, 72),
    /// De-emphasised text (captions, placeholders, spent affordances).
    dim: Color = rgb(128, 128, 128),
    /// Default ink. What a content leaf paints with when nothing styles it.
    fg: Color = rgb(220, 220, 220),
    /// Accent — focus rings, the active tab, an interactive highlight.
    acc: Color = rgb(90, 150, 210),
    /// Caution.
    warn: Color = rgb(210, 170, 80),
    /// Failure or loss.
    danger: Color = rgb(210, 85, 70),
};

/// Per-channel linear blend from `a` toward `b` by `t` (0..1, clamped), alpha included.
/// The building block for a whole-theme blend, and reused directly by pulsing color
/// readouts (a heartbeat). A free function because SDL's `Color` cannot carry methods.
pub fn mix(a: Color, b: Color, t: f32) Color {
    const c = std.math.clamp(t, 0, 1);
    return .{ .r = chan(a.r, b.r, c), .g = chan(a.g, b.g, c), .b = chan(a.b, b.b, c), .a = chan(a.a, b.a, c) };
}

fn chan(x: u8, y: u8, t: f32) u8 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return @intFromFloat(@round(fx + (fy - fx) * t));
}

test "mix: t=0 is a, t=1 is b, midpoint averages, out-of-range clamps" {
    const a = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const b = Color{ .r = 100, .g = 200, .b = 50, .a = 255 };
    try std.testing.expectEqual(a, mix(a, b, 0));
    try std.testing.expectEqual(b, mix(a, b, 1));
    try std.testing.expectEqual(Color{ .r = 50, .g = 100, .b = 25, .a = 128 }, mix(a, b, 0.5));
    try std.testing.expectEqual(a, mix(a, b, -1)); // clamps below 0
    try std.testing.expectEqual(b, mix(a, b, 2)); // clamps above 1
}

test "Theme is fully defaulted — the foundation renders with no palette installed" {
    const t: Theme = .{};
    try std.testing.expectEqual(rgb(220, 220, 220), t.fg);
}
