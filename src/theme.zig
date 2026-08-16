//! COLD↔WARM color theme — the terminal identity's "temperature" (roadmap M5). `cold`
//! and `warm` are the two poles, lifted 1:1 from `design/`'s prototype palette; `lerp`
//! blends every field together by one shared "warmth" fraction (see `main.zig`'s
//! `compute_warmth`), so the whole HUD shifts as one mood rather than each color
//! drifting independently. Host-owned (the hex values are this game's art direction),
//! not engine — `src/ui/` stays palette-agnostic.
//!
//! This module is also the **color leaf**: it aliases the host's `Color` (SDL's
//! `pixels.Color`, so we don't reinvent RGBA) and owns the color math (`mix`) the theme
//! blend needs. It imports only `sdl3`, so it can be a dependency of `res.zig` /
//! `ui_client` without a cycle.

const std = @import("std");
const sdl3 = @import("sdl3");

/// The host color type — SDL's `SDL_Color` (`{ r, g, b, a: u8 }`). One alias so the
/// backing type can be swapped in a single place; carried opaquely on `RenderData`.
pub const Color = sdl3.pixels.Color;

/// Opaque RGB shorthand (alpha = 255). SDL's `Color` has no field defaults (it's a
/// translated C struct), so the palette entries below use this instead of spelling
/// `.a = 255` on every line.
fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

pub const Theme = struct {
    bg: Color,
    panel: Color,
    line: Color,
    line2: Color,
    dim: Color,
    fg: Color,
    acc: Color,
    warn: Color,
    danger: Color,
};

pub const cold = Theme{
    .bg = rgb(7, 11, 13),
    .panel = rgb(11, 18, 21),
    .line = rgb(22, 36, 42),
    .line2 = rgb(38, 64, 74),
    .dim = rgb(91, 112, 121),
    .fg = rgb(147, 168, 177),
    .acc = rgb(79, 158, 196),
    .warn = rgb(201, 162, 79),
    .danger = rgb(201, 80, 63),
};

pub const warm = Theme{
    .bg = rgb(19, 12, 7),
    .panel = rgb(27, 18, 11),
    .line = rgb(44, 32, 22),
    .line2 = rgb(74, 54, 36),
    .dim = rgb(138, 118, 96),
    .fg = rgb(203, 181, 151),
    .acc = rgb(224, 145, 58),
    .warn = rgb(224, 176, 74),
    .danger = rgb(216, 90, 68),
};

/// Blend `cold` → `warm` by `t` (0..1, clamped by `mix`) — every field moves together,
/// so nothing reads "half-cold" while something else reads "half-warm".
pub fn lerp(t: f32) Theme {
    return .{
        .bg = mix(cold.bg, warm.bg, t),
        .panel = mix(cold.panel, warm.panel, t),
        .line = mix(cold.line, warm.line, t),
        .line2 = mix(cold.line2, warm.line2, t),
        .dim = mix(cold.dim, warm.dim, t),
        .fg = mix(cold.fg, warm.fg, t),
        .acc = mix(cold.acc, warm.acc, t),
        .warn = mix(cold.warn, warm.warn, t),
        .danger = mix(cold.danger, warm.danger, t),
    };
}

/// Per-channel linear blend from `a` toward `b` by `t` (0..1, clamped), alpha included.
/// The building block for the whole-theme `lerp`, and reused directly by pulsing color
/// readouts (e.g. the heartbeat). Free function because SDL's `Color` can't carry methods.
pub fn mix(a: Color, b: Color, t: f32) Color {
    const c = std.math.clamp(t, 0, 1);
    return .{ .r = chan(a.r, b.r, c), .g = chan(a.g, b.g, c), .b = chan(a.b, b.b, c), .a = chan(a.a, b.a, c) };
}

fn chan(x: u8, y: u8, t: f32) u8 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return @intFromFloat(@round(fx + (fy - fx) * t));
}

test "lerp(0) is cold, lerp(1) is warm" {
    try std.testing.expectEqual(cold, lerp(0));
    try std.testing.expectEqual(warm, lerp(1));
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
