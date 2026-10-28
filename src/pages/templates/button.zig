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
    return button_variant(parent, id, label, enabled, .primary);
}

/// The prototype's three action buttons: `.primary-action` (fg outline), `.secondary-action`
/// (line2 outline, dim label) and `.danger-action` (danger outline and label); `.back` is
/// `.panel-back`, a small tracked label on a line2 outline. All turn accent on hover/focus.
pub const Variant = enum { primary, secondary, danger, back };

pub fn button_variant(parent: El, id: []const u8, label: []const u8, enabled: bool, variant: Variant) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;

    // Outer clickable box: flows, lays its label out horizontally, and hugs it (fit).
    // No content of its own — just the outline chrome.
    const outer = try parent.div(id);
    _ = outer.with_flow(.{ .dir = .row }).with_size(.fit_children, .fit_children);

    // The whole box is the control; its authority remains the caller's `enabled`. The lifecycle
    // (focus, activation, disabled consumption, state and semantics, cursor) is one call.
    const q = outer.control(.{ .enabled = enabled, .name = label, .role = .button });
    const lit = q.held or q.hovering or q.focused;

    // Chrome from the published state: dim disabled, accent on held/hover/focus, else the
    // variant's rest colors.
    const rest_line: uic.Color, const rest_text: uic.Color = switch (variant) {
        .primary => .{ th.fg, th.fg },
        .secondary, .back => .{ th.line2, th.dim },
        .danger => .{ th.danger, th.danger },
    };
    const line = if (!enabled) th.dim else if (lit) (if (variant == .danger) th.danger else th.acc) else rest_line;
    const text = if (!enabled) th.dim else if (lit) (if (variant == .danger) th.fg else th.acc) else rest_text;
    // Label content leaf (flows by default); padding lives on it so glyphs clear the border.
    const label_style: Style = switch (variant) {
        .back => Style{ .font = 10, .tracking = 0.07 },
        else => style.body,
    };
    const pad = if (variant == .back) style.pad_sym(8, 3) else style.pad_sym(8, 4);
    _ = (try outer.text("lbl", label)).with_style(.{ label_style, pad, Style{ .text = text } });
    _ = outer.with_style(.{Style{ .outline_color = line }});

    return outer;
}
