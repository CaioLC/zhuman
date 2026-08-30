//! `figure` template — the 3-line ASCII vitals figure (flavor), plus the glyph sets and
//! the warmth→figure mapping. Each line is a content leaf (`el.text`) tinted by the color.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const Color = uic.Color;
const UiCtx = uic.UiCtx;
const El = el.El;

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
pub fn figure(ctx: *UiCtx, parent: El, fig: Figure, color: Color) !void {
    const col = try el.div(ctx, parent, "fig");
    _ = col.with_flow(.{ .dir = .column });

    inline for (.{ "l1", "l2", "l3" }, .{ fig.l1, fig.l2, fig.l3 }) |lid, line| {
        const n = try el.text(ctx, col, lid, line);
        _ = n.with_style(.{Style{ .text = color }});
    }
}
