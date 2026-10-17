//! `figure` template — the 3-line ASCII figure (flavor) and its one glyph set, the dead body
//! the game-over screen shows. Each line is a content leaf (`el.text`) tinted by the color.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const Color = uic.Color;
const UiCtx = uic.UiCtx;
const El = el.El;

pub const Figure = struct { l1: []const u8, l2: []const u8, l3: []const u8 };
pub const fig_dead = Figure{ .l1 = "   x", .l2 = "  -|-", .l3 = "  / \\" };

/// Build the figure's 3 lines as a stacked column of tinted text leaves under `parent`.
pub fn figure(parent: El, id: []const u8, fig: Figure, color: Color) !void {
    const col = try parent.div(id);
    _ = col.with_flow(.{ .dir = .column });

    inline for (.{ "l1", "l2", "l3" }, .{ fig.l1, fig.l2, fig.l3 }) |lid, line| {
        const n = try col.text(lid, line);
        // h3 keeps the 3-line figure legible; at body size the ASCII reads as noise.
        _ = n.with_style(.{ style.h3, Style{ .text = color } });
    }
}
