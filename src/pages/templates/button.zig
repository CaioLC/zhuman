//! `button` template — a clickable, outlined box hugging a text label, in the game's
//! chrome. The exemplar for the shelf: a *template* is a game-specific (theme-aware)
//! composition built entirely from the `ui_client` foundation — a content leaf
//! (`el.text`) plus style/placement composed via the fluent `El` handle. It owns none of
//! that machinery; it just arranges it and picks the colors from `res.view.theme` + interaction.
//!
//! The chrome (dim if disabled, accent on hover, else fg) is computed inline off the outer
//! box's own interaction slot. Returns the outer `El` (shelf convention — a template hands
//! back the same handle an element would); the caller reads `.query().clicked` and still
//! guards the click (`enabled` is only the look).

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

pub fn button(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8, enabled: bool) !El {
    const th = ctx.res.view.theme;

    // Outer clickable box: flows, lays its label out horizontally, and hugs it (fit).
    // No content of its own — just the outline chrome.
    const outer = try el.div(ctx, parent, id);
    _ = outer.with_flow(.{ .dir = .row }).with_size(.fit_children, .fit_children);

    // Label content leaf (flows by default); padding lives on it so glyphs clear the border.
    const lbl = try el.text(ctx, outer, "lbl", label);
    _ = lbl.with_style(.{ style.body, style.pad_sym(8, 4) });

    // Chrome: dim disabled, accent on hover (read off the box's slot), else soft fg.
    const c = if (!enabled) th.dim else if (outer.query().hovering) th.acc else th.fg;
    _ = lbl.with_style(.{Style{ .text = c }});
    _ = outer.with_style(.{Style{ .outline_color = c }});

    return outer;
}
