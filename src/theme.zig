//! COLD↔WARM color theme — the terminal identity's "temperature" (roadmap M5). `cold`
//! and `warm` are the two poles, lifted 1:1 from `design/`'s prototype palette; `lerp`
//! blends every field together by one shared "warmth" fraction (see `main.zig`'s
//! `compute_warmth`), so the whole HUD shifts as one mood rather than each color
//! drifting independently. Host-owned (the hex values are this game's art direction),
//! not engine — `src/ui/` stays palette-agnostic.

const ui = @import("./ui/root.zig");
const Color = ui.Color;

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
    .bg = .{ .r = 7, .g = 11, .b = 13 },
    .panel = .{ .r = 11, .g = 18, .b = 21 },
    .line = .{ .r = 22, .g = 36, .b = 42 },
    .line2 = .{ .r = 38, .g = 64, .b = 74 },
    .dim = .{ .r = 91, .g = 112, .b = 121 },
    .fg = .{ .r = 147, .g = 168, .b = 177 },
    .acc = .{ .r = 79, .g = 158, .b = 196 },
    .warn = .{ .r = 201, .g = 162, .b = 79 },
    .danger = .{ .r = 201, .g = 80, .b = 63 },
};

pub const warm = Theme{
    .bg = .{ .r = 19, .g = 12, .b = 7 },
    .panel = .{ .r = 27, .g = 18, .b = 11 },
    .line = .{ .r = 44, .g = 32, .b = 22 },
    .line2 = .{ .r = 74, .g = 54, .b = 36 },
    .dim = .{ .r = 138, .g = 118, .b = 96 },
    .fg = .{ .r = 203, .g = 181, .b = 151 },
    .acc = .{ .r = 224, .g = 145, .b = 58 },
    .warn = .{ .r = 224, .g = 176, .b = 74 },
    .danger = .{ .r = 216, .g = 90, .b = 68 },
};

/// Blend `cold` → `warm` by `t` (0..1, clamped by `Color.lerp`) — every field moves
/// together, so nothing reads "half-cold" while something else reads "half-warm".
pub fn lerp(t: f32) Theme {
    return .{
        .bg = Color.lerp(cold.bg, warm.bg, t),
        .panel = Color.lerp(cold.panel, warm.panel, t),
        .line = Color.lerp(cold.line, warm.line, t),
        .line2 = Color.lerp(cold.line2, warm.line2, t),
        .dim = Color.lerp(cold.dim, warm.dim, t),
        .fg = Color.lerp(cold.fg, warm.fg, t),
        .acc = Color.lerp(cold.acc, warm.acc, t),
        .warn = Color.lerp(cold.warn, warm.warn, t),
        .danger = Color.lerp(cold.danger, warm.danger, t),
    };
}

const std = @import("std");

test "lerp(0) is cold, lerp(1) is warm" {
    try std.testing.expectEqual(cold, lerp(0));
    try std.testing.expectEqual(warm, lerp(1));
}
