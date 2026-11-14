//! `curtain` — the full-screen beat between runs: a centered column of an optional figure,
//! one headline and one button. Game over uses it; the words, the figure and what the button
//! does are the caller's. An act ends on a scene instead (the `scene` template).

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const El = el.El;

const figure_mod = @import("./figure.zig");
const copy_mod = @import("./copy.zig");
const button_mod = @import("./button.zig");

pub const Options = struct {
    /// The ASCII figure above the line, and its tint.
    figure: ?figure_mod.Figure = null,
    figure_color: ?uic.Color = null,
    line: []const u8,
    button: []const u8,
};

/// Build the beat centered in `parent` (a definite region such as the shell body). Returns
/// the column and whether its button was activated this frame.
pub const Curtain = struct { el: El, clicked: bool };

pub fn curtain(parent: El, id: []const u8, opts: Options) !Curtain {
    const th = parent.ctx.res.view.theme;
    const col = try parent.box(id, .{ .flow = .{ .dir = .column, .cross = .center }, .gap = 10 }, .{});
    col.set(.{ .anchor = .center }, .{});

    if (opts.figure) |fig| try figure_mod.figure(col, "figure", fig, opts.figure_color orelse th.danger);
    _ = try copy_mod.headline(col, "line", opts.line);
    const go = try button_mod.button(col, "go", opts.button, true);
    return .{ .el = col, .clicked = go.query().clicked };
}
