//! `figure` template — the 3-line ASCII vitals figure (flavor), plus the glyph sets and
//! the warmth→figure mapping. Migrated from the old `pages/templates.zig` onto the new
//! foundation: each line is a content leaf (`elements.text`) tinted by `style.apply`.

const ha = @import("ha");

const uic = ha.ui_client;
const style = uic.style;
const elements = uic.elements;
const Style = style.Style;
const Color = ha.theme.Color;
const UiCtx = uic.UiCtx;
const Node = uic.Node;

pub const Figure = struct { l1: []const u8, l2: []const u8, l3: []const u8 };
pub const fig_robust = Figure{ .l1 = "  \\o/", .l2 = "   |", .l3 = "  / \\" };
pub const fig_ok = Figure{ .l1 = "   O", .l2 = "  /|\\", .l3 = "  / \\" };
pub const fig_weary = Figure{ .l1 = "   o", .l2 = "  /|", .l3 = "  /" };
pub const fig_dead = Figure{ .l1 = "   x", .l2 = "  -|-", .l3 = "  / \\" };

pub fn figure_glyphs(warmth: f32) Figure {
    if (warmth < 0.25) return fig_weary;
    if (warmth > 0.6) return fig_robust;
    return fig_ok;
}

/// Build the figure's 3 lines as a stacked column of tinted text leaves under `parent`.
pub fn figure(ctx: *UiCtx, parent: *Node, fig: Figure, color: Color) !void {
    const col = try Node.pcreate(ctx.arena, "fig", parent);
    style.apply_placement(col, .{ style.flow, style.col });

    inline for (.{ "l1", "l2", "l3" }, .{ fig.l1, fig.l2, fig.l3 }) |id, line| {
        const n = try elements.text(ctx, col, id, line);
        style.apply_placement(n, .{style.flow});
        style.apply(ctx, n, .{Style{ .text = color }});
    }
}
