//! `panel` template — a titled, bordered, padded vertical section that groups content.
//! Themed chrome (border `line`, title `dim`); the caller appends content nodes after the
//! title and they flow vertically under it. Returns the outer `El`, so the caller places
//! it (`with_layout`) and appends into it like any element.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

pub fn panel(parent: El, id: []const u8, title: []const u8) !El {

    const outer = try parent.box(id, .{
        .flow = .{ .dir = .column }, .w = .fit_children, .h = .fit_children,
    }, .{ Style{ .outline_ink = .line }, style.pad(12), style.gap(8) });

    const ttl = try outer.text("title", title);
    // A panel title is the prototype's **eyebrow / section-heading** — 11px,
    // UPPERCASE, positive (loosened) tracking — not a body heading. The `eyebrow` role
    // carries the size + uppercase transform + in-band tracking; the theme `dim` color is
    // the panel's chrome. The caller passes a normal-case title (e.g. "Actions"); the role's
    // transform uppercases it at apply time, so call sites stay readable.
    ttl.set(.{}, .{ style.eyebrow, style.muted });

    return outer;
}
