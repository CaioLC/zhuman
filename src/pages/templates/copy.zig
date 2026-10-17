//! `copy` — the shelf's **prose leaves**: the one-line readouts and curtain lines a page
//! shows between its templates. Each names a role and takes its colors from the theme, so a
//! page says *what* a line is and never how it looks (`tools/boundary_check.sh` rejects a
//! styled or text node in a page).

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;

/// A catalog's count line under its controls — `20 of 20 actions shown` — small and dim.
pub fn summary_line(parent: El, id: []const u8, text: []const u8) !El {
    const th = parent.ctx.res.view.theme;
    return (try parent.text(id, text)).with_style(.{ style.small, Style{ .text = th.dim } });
}

/// What a list says when nothing matches: body size in the quiet `line2`.
pub fn empty_line(parent: El, id: []const u8, text: []const u8) !El {
    const th = parent.ctx.res.view.theme;
    return (try parent.text(id, text)).with_style(.{ style.body, Style{ .text = th.line2 } });
}

/// A curtain's one spoken line: h2 in the foreground.
pub fn headline(parent: El, id: []const u8, text: []const u8) !El {
    const th = parent.ctx.res.view.theme;
    return (try parent.text(id, text)).with_style(.{ style.h2, Style{ .text = th.fg } });
}

/// The prose measure of a curtain dialog, logical px: the width a `lede` wraps at so a note
/// reads as a paragraph instead of stretching a `fit_children` panel to one long line.
pub const prose_measure: f32 = 320;

/// The dim paragraph under a headline. With a `measure`, the prose wraps on word boundaries
/// at that logical width instead of stretching its panel to one long line.
pub fn lede(parent: El, id: []const u8, text: []const u8, measure: ?f32) !El {
    const th = parent.ctx.res.view.theme;
    const node = if (measure) |w| try parent.text_fit(id, text, .{ .wrap = w }) else try parent.text(id, text);
    return node.with_style(.{ style.body, Style{ .text = th.dim } });
}
