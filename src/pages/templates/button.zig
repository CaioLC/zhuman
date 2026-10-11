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

pub fn button(parent: El, id: []const u8, label: []const u8, enabled: bool) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;

    // Outer clickable box: flows, lays its label out horizontally, and hugs it (fit).
    // No content of its own — just the outline chrome.
    const outer = try parent.div(id);
    _ = outer.with_flow(.{ .dir = .row }).with_size(.fit_children, .fit_children);

    // The whole box is the control; its authority remains the caller's `enabled`. The lifecycle
    // (focus, activation, disabled consumption, state and semantics, cursor) is one call.
    const q = outer.control(.{ .enabled = enabled, .name = label, .role = .button });

    // Chrome from the published state: dim disabled, accent on held/hover/focus, else fg.
    const c = if (!enabled) th.dim else if (q.held or q.hovering or q.focused) th.acc else th.fg;
    // Label content leaf (flows by default); padding lives on it so glyphs clear the border.
    _ = (try outer.text("lbl", label)).with_style(.{ style.body, style.pad_sym(8, 4), Style{ .text = c } });
    _ = outer.with_style(.{Style{ .outline_color = c }});

    return outer;
}
