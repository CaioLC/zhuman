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

pub fn panel(ctx: *UiCtx, parent: El, id: []const u8, title: []const u8) !El {
    const th = ctx.res.view.theme;

    const outer = try el.div(ctx, parent, id);
    _ = outer.with_flow(.{ .dir = .column }).with_size(.fit_children, .fit_children)
        .with_style(.{ Style{ .outline_color = th.line }, style.pad(12), style.gap(8) });

    const ttl = try el.text(ctx, outer, "title", title);
    _ = ttl.with_style(.{Style{ .text = th.dim }});

    return outer;
}
