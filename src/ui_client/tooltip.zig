//! `tooltip` — a floating, filled, bordered, padded single-line box built as its **own root**
//! so the page can list it after the screen and it floats above everything. It never
//! intercepts input (KIT-08): it is pass-through, so despite being stamped last it takes no
//! pointer hit and does not occlude the control it describes. Place it in device px with
//! `with_offset_px`, and keep it inside the terminal with `clampToTerminal` using the box's
//! prior-frame geometry for its size.

const std = @import("std");
const cb = @import("./ctx_binding.zig");
const el = @import("./elements.zig");
const style = @import("./style.zig");
const view = @import("./view.zig");

const UiCtx = cb.UiCtx;
const El = el.El;
const Style = style.Style;

/// Build the tooltip root holding one line of `text`. The caller positions it.
pub fn tooltip(ctx: *UiCtx, id: []const u8, text: []const u8) !El {
    const th = ctx.res.view.theme;

    // A parentless, content-sized root: `el.root` is the fullscreen anchor, so this one is
    // built directly. A root must place itself, hence the explicit anchor.
    const node = try cb.Node.create(ctx.arena, id);
    node.layout.anchor = .top_left;
    const box = El{ .ctx = ctx, .node = node };
    _ = box.with_flow(.{ .dir = .column })
        .with_size(.fit_children, .fit_children)
        .with_style(.{ style.pad(6), Style{ .fill = th.panel, .outline_color = th.line2 } });
    _ = box.query(); // keep the slot alive for its geometry read-back
    _ = box.pass_through(); // informational overlay, never a hit target

    _ = (try box.text("lbl", text)).with_style(.{Style{ .text = th.fg }});

    return box;
}

/// Clamp a desired top-left (`x`,`y`) so a `w`×`h` box stays inside the terminal rect. Device
/// px, like the layout. Returns the adjusted origin; if the box is larger than the terminal on
/// an axis it pins to the near edge.
pub fn clampToTerminal(ctx: *UiCtx, x: f32, y: f32, w: f32, h: f32) struct { x: f32, y: f32 } {
    const m = ctx.res.view.metrics;
    const scale = ctx.res.view.scale;
    // The terminal rect is logical; scale to device px to match the overlay's layout space.
    const tx = view.dp(m.terminal.x, scale);
    const ty = view.dp(m.terminal.y, scale);
    const tw = view.dp(m.terminal.w, scale);
    const th = view.dp(m.terminal.h, scale);
    const cx = std.math.clamp(x, tx, @max(tx, tx + tw - w));
    const cy = std.math.clamp(y, ty, @max(ty, ty + th - h));
    return .{ .x = cx, .y = cy };
}
