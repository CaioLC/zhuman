//! `panel` template — a titled, bordered, padded vertical section that groups content.
//! Themed chrome (border `line`, title `dim`); the caller appends content nodes after the
//! title and they flow vertically under it. Returns the outer node.

const ha = @import("ha");

const ui = ha.ui;
const uic = ha.ui_client;
const style = uic.style;
const elements = uic.elements;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const Node = uic.Node;

pub fn panel(ctx: *UiCtx, parent: *Node, id: []const u8, title: []const u8) !*Node {
    const th = ctx.res.theme;

    const outer = try Node.pcreate(ctx.arena, id, parent);
    style.apply_placement(outer, .{ style.flow, style.col, style.gap(8) });
    style.apply(ctx, outer, .{Style{ .outline = th.line, .padding = ui.Padding.init(12) }});

    const ttl = try elements.text(ctx, outer, "title", title);
    style.apply_placement(ttl, .{style.flow});
    style.apply(ctx, ttl, .{Style{ .text = th.dim }});

    return outer;
}
