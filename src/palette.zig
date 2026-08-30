//! The game's palettes — art direction, values only. The `Theme` *shape* they fill in
//! belongs to the UI foundation (`ui_client/theme.zig`), which paints from its own plain
//! defaults when no palette is installed; this module is what makes the HUD look like
//! this game rather than like a default toolkit.
//!
//! `cold` and `warm` are the two poles of the terminal identity's "temperature", and
//! `lerp` blends every role together by one shared warmth fraction, so the whole HUD
//! shifts as a single mood rather than each color drifting on its own. A screen installs
//! the result by assigning it onto `res.view.theme`.

const std = @import("std");
const uitheme = @import("./ui_client/theme.zig");

const rgb = uitheme.rgb;
const mix = uitheme.mix;

const Theme = uitheme.Theme;

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

/// Blend `cold` → `warm` by `t` (0..1, clamped by `mix`) — every role moves together, so
/// nothing reads "half-cold" while something else reads "half-warm".
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

test "lerp(0) is cold, lerp(1) is warm" {
    try std.testing.expectEqual(cold, lerp(0));
    try std.testing.expectEqual(warm, lerp(1));
}

test "a palette overrides every default role" {
    const base: Theme = .{};
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        try std.testing.expect(!std.meta.eql(@field(base, f.name), @field(cold, f.name)));
    }
}
