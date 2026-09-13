//! `modal_header` — two-line modal heading plus the conventional top-right close control.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const modal_mod = @import("./modal.zig");

pub fn modal_header(ctx: *UiCtx, parent: El, width: f32, kicker_text: []const u8, meta: []const u8, title: []const u8) !bool {
    const th = ctx.res.view.theme;
    const inner_width = width - 46; // 15px authored padding + engine text/control overhang
    const header = try el.div(ctx, parent, "header");
    _ = header.with_size(.{ .fixed = inner_width }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
        .with_style(.{style.pad_each(13, 15, 10, 15)});
    const heading = try el.div(ctx, header, "heading");
    _ = heading.with_flow(.{ .dir = .column, .cross = .start }).with_gap(2);
    const kicker = try std.fmt.allocPrint(ctx.arena, "{s} \u{00b7} {s}", .{ kicker_text, meta });
    _ = (try el.text(ctx, heading, "kicker", kicker)).with_style(.{ style.small, Style{ .font = 10, .tracking = 0.08, .text = th.warn } });
    _ = (try el.text(ctx, heading, "title", title)).with_style(.{ style.heading, Style{ .text = th.fg } });

    const close = try el.div(ctx, header, "close");
    _ = close.with_size(.{ .fixed = 28 }, .{ .fixed = 28 })
        .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
    ctx.registerFocus(close.get().key, true);
    const q = close.query();
    if (q.clicked) _ = ctx.requestFocus(close.get().key);
    const focused = ctx.isFocused(close.get().key);
    uic.publishControlState(ctx, close.get().key, .{ .focused = focused, .focus_visible = focused });
    if (q.hovering) ctx.res.cursor.request(.pointer);
    _ = (try el.text(ctx, close, "glyph", "\u{00d7}"))
        .with_style(.{Style{ .font = 18, .text = if (q.held or q.hovering or focused) th.acc else th.dim }});
    ctx.res.semantics.publish(uic.semantic.describeIconButton(close.get().key, "Close trade dialog", true, focused));
    const clicked = close.consume(.clicked);
    try modal_mod.rule(ctx, parent, "header_rule", width);
    return clicked;
}
