//! `button` template — a clickable, outlined box hugging a text label, in the game's
//! chrome. The exemplar for the shelf: a *template* is a game-specific (theme-aware)
//! composition built entirely from the `ui_client` foundation — a content leaf
//! (`el.text`) plus style/placement composed via the fluent `El` handle. It owns none of
//! that machinery; it just arranges it and picks the colors from `res.view.theme` + interaction.
//!
//! The caller's `enabled` value remains authoritative and is published as `.disabled`;
//! chrome is dim when disabled, accent on hover/held, otherwise fg. Returns the outer
//! `El`; callers still enforce their domain gate when acting on `.query().clicked`.

const std = @import("std");
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

/// A variant's chrome: the box outline and the label ink, each the variant's rest role with
/// two state rules over it (`hot` lifts, `disabled` dims, and a disabled owner is never hot).
pub const Look = struct { outline: Style, label: Style };

fn variantLook(comptime rest_line: style.ThemeRole, comptime rest_text: style.ThemeRole, comptime hot_line: style.ThemeRole, comptime hot_text: style.ThemeRole) Look {
    return .{
        .outline = .{ .outline_ink = rest_line, .on = &.{ .{ .when = .hot, .outline_ink = hot_line }, .{ .when = .disabled, .outline_ink = .dim } } },
        .label = .{ .ink = rest_text, .on = &.{ .{ .when = .hot, .ink = hot_text }, .{ .when = .disabled, .ink = .dim } } },
    };
}

/// Every variant's chrome. All lift to accent while hot except `danger`, whose outline stays
/// danger and whose label lifts to fg.
pub const looks = std.EnumArray(Variant, Look).init(.{
    .primary = variantLook(.fg, .fg, .acc, .acc),
    .secondary = variantLook(.line2, .dim, .acc, .acc),
    .danger = variantLook(.danger, .danger, .danger, .fg),
    .back = variantLook(.line2, .dim, .acc, .acc),
});

pub fn button_variant(parent: El, id: []const u8, label: []const u8, enabled: bool, variant: Variant) !El {
    // Outer clickable box: flows, lays its label out horizontally, and hugs it (fit).
    // No content of its own — just the outline chrome.
    const outer = try parent.box(id, .{ .flow = .{ .dir = .row }, .w = .fit_children, .h = .fit_children }, .{});

    // The whole box is the control; its authority remains the caller's `enabled`. The lifecycle
    // (focus, activation, disabled consumption, state and semantics, cursor) is one call.
    _ = outer.control(.{ .enabled = enabled, .name = label, .role = .button, .ring = false });

    // Chrome from the published state (`looks`): dim disabled, the lift on held/hover/focus,
    // else the variant's rest colors.
    const look = looks.get(variant);
    // Label content leaf (flows by default); padding lives on it so glyphs clear the border.
    const label_style: Style = switch (variant) {
        .back => Style{ .font = 10, .tracking = 0.07 },
        else => style.body,
    };
    const pad = if (variant == .back) style.pad_sym(8, 3) else style.pad_sym(8, 4);
    try outer.label("lbl", label, .{ label_style, pad, look.label });
    outer.set(.{}, .{look.outline});

    return outer;
}
