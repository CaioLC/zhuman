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
    .good = rgb(143, 155, 115), // #8f9b73 — a desaturated olive that reads positive on the amber ramp
};

/// The terminal **ground** — the near-black `#090806` the framed terminal floats on, one
/// notch darker than the terminal's own `bg` (`#0e0c09`). Art direction, so it lives in the
/// game palette rather than the generic `Theme` (it is not a widget role — no foundation
/// widget paints from it); the terminal shell (`pages/templates/terminal.zig`) reads it from
/// here via `View`. KIT-01 folded it out of that template's file-scope literal to here.
pub const ground = rgb(9, 8, 6);

/// The six resource/sector colors — Food, Water, Fuel, Metal, Minerals, Biomass. These are
/// **game content**, not foundation `Theme` roles: the engine has no notion of a "resource",
/// and Act II adds sectors keyed by these hues, so they are authored here as a fixed record
/// and carried on `View` for the HUD/legend to sample. Kept off `Theme` on purpose (KIT-01's
/// sub-bullet: "keep six resource/sector colors in game `View`/palette, not generic `Theme`").
pub const ResourceColors = struct {
    food: uitheme.Color = rgb(217, 121, 102), // #d97966
    water: uitheme.Color = rgb(91, 159, 196), // #5b9fc4
    fuel: uitheme.Color = rgb(213, 166, 78), // #d5a64e
    metal: uitheme.Color = rgb(132, 151, 163), // #8497a3
    minerals: uitheme.Color = rgb(154, 124, 180), // #9a7cb4
    biomass: uitheme.Color = rgb(120, 162, 118), // #78a276
};

/// The one resource-color record installed on `View` each frame alongside `theme`.
pub const resources = ResourceColors{};

test "the palette overrides every default role" {
    const base: Theme = .{};
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        try std.testing.expect(!std.meta.eql(@field(base, f.name), @field(theme, f.name)));
    }
}
