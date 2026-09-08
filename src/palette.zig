//! The game's palette — art direction, values only. The `Theme` *shape* it fills in
//! belongs to the UI foundation (`ui_client/theme.zig`), which paints from its own plain
//! defaults when no palette is installed; this module is what makes the HUD look like
//! this game rather than like a default toolkit.
//!
//! One palette, and `build_ui` installs it by assigning `theme` onto `res.view.theme`:
//! a dim amber terminal — near-black grounds, warm greys for ink, an ochre accent, and
//! `warn`/`danger` kept off that ramp so a severity still reads as a severity.

const std = @import("std");
const uitheme = @import("./ui_client/theme.zig");

const rgb = uitheme.rgb;

const Theme = uitheme.Theme;

pub const theme = Theme{
    .bg = rgb(14, 12, 9),
    .panel = rgb(21, 18, 15),
    .line = rgb(35, 34, 30),
    .line2 = rgb(60, 58, 51),
    .dim = rgb(119, 116, 106),
    .fg = rgb(181, 176, 161),
    .acc = rgb(166, 150, 113),
    .warn = rgb(215, 170, 76),
    .danger = rgb(210, 86, 66),
};

test "the palette overrides every default role" {
    const base: Theme = .{};
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        try std.testing.expect(!std.meta.eql(@field(base, f.name), @field(theme, f.name)));
    }
}
