//! `curtain` — the full-screen beat between runs and acts: a centered column of an optional
//! figure, one headline, an optional note at prose measure, and one button. Game over and the
//! Act I curtain both use it; the words, the figure and what the button does are the caller's.
//! An optional `title` frames the column as a titled panel (the act curtain's `ACT I`).

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const El = el.El;

const panel_mod = @import("./panel.zig");
const figure_mod = @import("./figure.zig");
const copy_mod = @import("./copy.zig");
const button_mod = @import("./button.zig");

pub const Options = struct {
    /// A panel title framing the beat; null leaves it unframed.
    title: ?[]const u8 = null,
    /// The ASCII figure above the line, and its tint.
    figure: ?figure_mod.Figure = null,
    figure_color: ?uic.Color = null,
    line: []const u8,
    note: ?[]const u8 = null,
    button: []const u8,
};

/// Build the beat centered in `parent` (a definite region such as the shell body). Returns
/// the column and whether its button was activated this frame.
pub const Curtain = struct { el: El, clicked: bool };

pub fn curtain(parent: El, id: []const u8, opts: Options) !Curtain {
    const th = parent.ctx.res.view.theme;
    const col = if (opts.title) |title| try panel_mod.panel(parent, id, title) else blk: {
        const c = try parent.div(id);
        _ = c.with_flow(.{ .dir = .column, .cross = .center }).with_gap(10);
        break :blk c;
    };
    _ = col.with_layout(.center);

    if (opts.figure) |fig| try figure_mod.figure(col, "figure", fig, opts.figure_color orelse th.danger);
    // Stable ids across beats: the leaves persist and re-source their text.
    _ = try copy_mod.headline(col, "line", opts.line);
    if (opts.note) |note| _ = try copy_mod.lede(col, "note", note, copy_mod.prose_measure);
    const go = try button_mod.button(col, "go", opts.button, true);
    return .{ .el = col, .clicked = go.query().clicked };
}
