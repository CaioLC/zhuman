//! `scene` template — an ASCII scene and what is said under it (`prototypes/scene.css`): the
//! screen is the scene's grid of cells centred in the stage, a hairline, and a footer with
//! the two caption lines on the left and two text links on the right, `REPLAY` and the one
//! that moves on. The arrival before Act I, the shelter at the act's end and the demo's
//! thank-you use it; the cells, the words and what the links do are the caller's.
//!
//! The caller composes the cells in inks (`Ink`), which name how far or how lit a thing is;
//! the colors are the theme's, chosen here. The caption types itself out from the moment the
//! caller says it began, and each line holds its row from the first frame, so nothing moves
//! when the words arrive. A click on the scene itself asks to skip to its end.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

const terminal_mod = @import("./terminal.zig");

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

/// The screen's height, logical px: the prototype's `min(700px, 100vh)`.
const screen_h: f32 = 700;
/// The cell a scene is authored at: 14px glyphs on a 1.25 line, and the smallest it shrinks to.
const cell_px: f32 = 14;
const min_cell_px: f32 = 7;
const line_em: f32 = 1.25;
/// A cell's advance as a fraction of its size, for fitting the grid to the terminal's width.
const advance_em: f32 = 0.6;
/// The stage's side margin, logical px, either side of the grid.
const stage_margin: f32 = 17;

/// The footer: `padding: 11px 15px 12px`, a caption line 1.35em of 14px tall, 2px between
/// the two, 16px between the links.
const foot_pad_top: f32 = 11;
const foot_pad_side: f32 = 15;
const foot_pad_bottom: f32 = 12;
const caption_line_h: f32 = 19;
const caption_gap: f32 = 2;
const link_gap: f32 = 16;

/// The caption's typing: characters a second, and how long after the first line the second
/// begins.
const typing_cps: f32 = 18;
const second_line_s: f32 = 1.4;

const link_look: Style = .{ .font = 11, .tracking = 0.06, .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} };

pub const Options = struct {
    cells: *const Cells,
    caption: [2][]const u8,
    /// Seconds since the caption began to type; negative before it has.
    caption_s: f32,
    /// The link that moves on (`BEGIN →`).
    go: []const u8,
};

/// The built screen and what was asked of it this frame.
pub const Scene = struct {
    root: *uic.Node,
    /// `REPLAY` was activated.
    replay: bool,
    /// The link that moves on was activated.
    go: bool,
    /// The scene itself was clicked: skip to its end.
    skip: bool,
};

pub fn scene(ctx: *UiCtx, id: []const u8, opts: Options) !Scene {
    const th = ctx.res.view.theme;
    const sh = try terminal_mod.terminal_with(ctx, id, .{ .max_h = screen_h, .scroll = false, .outline = th.line });
    sh.content.set(.{ .flow = .{ .dir = .column } }, .{});

    // The stage takes the height the footer leaves and centres the grid in it.
    const stage = try sh.content.box("stage", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .grow, .flow = .{ .dir = .column, .cross = .center }, .overflow = .clip,
    }, .{});
    const skip = stage.query().clicked;
    const centre = try stage.box("centre", .{ .w = .fit_children, .h = .fit_children }, .{});
    centre.set(.{ .anchor = .center }, .{});
    // Indexed by `Ink`.
    const palette = [_]uic.Color{ th.bg, th.line, th.line2, th.dim, th.fg, th.acc, th.warn, th.danger };
    const px = fitPx(ctx.res.view.metrics.terminal.w, opts.cells.cols);
    _ = try centre.glyph_grid("grid", opts.cells, &palette, px, line_em);

    try sh.content.leaf("rule", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 1 } }, .{Style{ .fill_ink = .line }});

    // The footer: the caption on the left, the links on the right, on one bottom edge.
    const foot = try sh.content.box("foot", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .end },
    }, .{style.pad_each(foot_pad_top, foot_pad_side, foot_pad_bottom, foot_pad_side)});

    const words = try foot.box("caption", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column }, .gap = caption_gap }, .{});
    inline for (.{ "line_1", "line_2" }, .{ style.muted, style.ink(.fg) }, 0..) |lid, ink, n| {
        const row = try words.box(lid, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = caption_line_h }, .flow = .{ .dir = .row, .cross = .center } }, .{});
        const since = opts.caption_s - @as(f32, @floatFromInt(n)) * second_line_s;
        try row.label("text", typed(opts.caption[n], since), .{ style.body, ink });
    }

    const links = try foot.box("links", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .end }, .gap = link_gap }, .{});
    const replay = try link(links, "replay", "REPLAY");
    const go = try link(links, "go", opts.go);

    return .{ .root = sh.root.get(), .replay = replay, .go = go, .skip = skip };
}

/// A text link: a small tracked label that lifts to the accent while hot. Whether it was
/// activated this frame.
fn link(parent: El, id: []const u8, text: []const u8) !bool {
    const b = try parent.box(id, .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const q = b.control(.{ .name = text, .role = .button, .ring = false });
    try b.label("text", text, .{link_look});
    return q.clicked;
}

/// As much of `line` as has been typed `since` seconds after it began: whole codepoints, none
/// before it began.
fn typed(line: []const u8, since: f32) []const u8 {
    if (since <= 0) return line[0..0];
    var left: usize = @intFromFloat(@floor(@min(since * typing_cps, 4096)));
    var i: usize = 0;
    while (i < line.len and left > 0) : (left -= 1) {
        i += std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
    }
    return line[0..@min(i, line.len)];
}

/// The cell size at which `grid_cols` cells fit a terminal `terminal_w` logical px wide with
/// the stage's margins: the authored size, or a whole pixel size below it in a narrow window.
fn fitPx(terminal_w: f32, grid_cols: u16) f32 {
    const room = terminal_w - 2 * stage_margin;
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

test "scene: the caption types whole codepoints at its pace and nothing before it begins" {
    const line = "Act I \u{00b7} Day 1.";
    try std.testing.expectEqualStrings("", typed(line, -1));
    try std.testing.expectEqualStrings("", typed(line, 0));
    try std.testing.expectEqualStrings("Act I ", typed(line, 6.0 / typing_cps + 0.001));
    // The middle dot is two bytes and one character.
    try std.testing.expectEqualStrings("Act I \u{00b7}", typed(line, 7.0 / typing_cps + 0.001));
    try std.testing.expectEqualStrings(line, typed(line, 60));
}
