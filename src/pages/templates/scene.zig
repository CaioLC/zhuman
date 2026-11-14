//! `scene` template — an ASCII scene and what is said under it: a grid of cells, two lines
//! of caption that fade in, and one button. The arrival before Act I uses it; the cells, the
//! words and what the button does are the caller's.
//!
//! The caller composes the cells in inks (`Ink`), which name how far or how lit a thing is;
//! the colors are the theme's, chosen here. Both caption lines hold their place from the
//! first frame, so the scene does not move when they appear.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const El = el.El;

const button_mod = @import("./button.zig");

pub const Cells = el.GlyphCells;
pub const Clip = el.GlyphClip;

/// A cell's ink, faintest first, then the firelight. `none` is the empty cell.
pub const Ink = enum(u8) {
    none,
    /// Barely there: a faint star, a drift.
    faint,
    /// The far ground: mountains, the small trees, the dimmer stars.
    far,
    /// The near ground: the hills, the big trees.
    near,
    /// The one the scene is about.
    bright,
    /// Lit by a fire.
    warm,
    flame,
    ember,

    pub fn id(self: Ink) u8 {
        return @intFromEnum(self);
    }
};

/// The grid every scene is composed on.
pub const cols: u16 = 100;
pub const rows: u16 = 32;

/// The cell size a scene is authored at, logical px, and the smallest it shrinks to.
const cell_px: f32 = 14;
const min_cell_px: f32 = 7;
/// A cell's advance as a fraction of its size, for fitting the grid to the terminal's width.
const advance_em: f32 = 0.6;

pub const Options = struct {
    cells: *const Cells,
    /// The two caption lines and how far each has faded in, 0 to 1.
    caption: [2][]const u8,
    shown: [2]f32 = .{ 1, 1 },
    button: []const u8,
};

/// Build the scene centered in `parent` (a definite region such as the shell body). Returns
/// the column and whether its button was activated this frame.
pub const Scene = struct { el: El, clicked: bool };

pub fn scene(parent: El, id: []const u8, opts: Options) !Scene {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const col = try parent.box(id, .{ .flow = .{ .dir = .column, .cross = .center }, .gap = 6 }, .{});
    col.set(.{ .anchor = .center }, .{});

    // Indexed by `Ink`.
    const palette = [_]uic.Color{ th.bg, th.line, th.line2, th.dim, th.fg, th.acc, th.warn, th.danger };
    _ = try col.glyph_grid("grid", opts.cells, &palette, fitPx(ctx.res.view.metrics.terminal.w, opts.cells.cols));

    const first = (try col.text("caption_1", opts.caption[0])).with_style(.{ style.body, style.muted });
    _ = first.with_opacity(std.math.clamp(opts.shown[0], 0, 1));
    const second = (try col.text("caption_2", opts.caption[1])).with_style(.{ style.body, style.ink(.fg) });
    _ = second.with_opacity(std.math.clamp(opts.shown[1], 0, 1));

    _ = try col.spacer("gap", 1, 6);
    const go = try button_mod.button(col, "go", opts.button, true);
    return .{ .el = col, .clicked = go.query().clicked };
}

/// The cell size at which `grid_cols` cells fit a terminal `terminal_w` logical px wide with
/// the page's margins: the authored size, or a whole pixel size below it in a narrow window.
fn fitPx(terminal_w: f32, grid_cols: u16) f32 {
    const room = terminal_w - 2 * ha.tokens.pad_page;
    const fit = @floor(room / (@as(f32, @floatFromInt(@max(1, grid_cols))) * advance_em));
    return std.math.clamp(fit, min_cell_px, cell_px);
}

test "scene: the grid is authored at 14px and shrinks to fit a narrow terminal" {
    try std.testing.expectEqual(@as(f32, 14), fitPx(900, cols));
    try std.testing.expectEqual(@as(f32, 14), fitPx(2000, cols));
    try std.testing.expectEqual(@as(f32, 10), fitPx(640, cols));
    try std.testing.expectEqual(min_cell_px, fitPx(200, cols));
}

test "scene: the inks index the palette in order, none first" {
    try std.testing.expectEqual(@as(u8, 0), Ink.none.id());
    try std.testing.expectEqual(@as(u8, 7), Ink.ember.id());
}
