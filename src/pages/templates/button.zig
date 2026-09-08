//! `button` template — a clickable, outlined box hugging a text label, in the game's
//! chrome. The exemplar for the shelf: a *template* is a game-specific (theme-aware)
//! composition built entirely from the `ui_client` foundation — a content leaf
//! (`el.text`) plus style/placement composed via the fluent `El` handle. It owns none of
//! that machinery; it just arranges it and picks the colors from `res.view.theme` + interaction.
//!
//! The caller's `enabled` value remains authoritative and is published as `.disabled`;
//! chrome is dim when disabled, accent on hover/held, otherwise fg. Returns the outer
//! `El`; callers still enforce their domain gate when acting on `.query().clicked`.

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

    // Chrome reads the published state, whose authority remains the caller's `enabled`.
    uic.publishControlState(ctx, outer.get().key, .{ .disabled = !enabled });
    const q = outer.query();
    if (q.hovering) ctx.res.cursor.request(if (enabled) .pointer else .not_allowed);
    const c = if (q.disabled) th.dim else if (q.held or q.hovering) th.acc else th.fg;
    _ = lbl.with_style(.{Style{ .text = c }});
    _ = outer.with_style(.{Style{ .outline_color = c }});

    return outer;
}
