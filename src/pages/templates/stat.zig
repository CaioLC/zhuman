//! `stat` template — one labeled readout line ("Vigor  82/100"): a dim label beside a
//! fg value, sharing a text baseline on a `row`. The Resources panel's workhorse. The
//! value is a pre-formatted string (the caller owns the bufPrint — `el.text` copies it
//! into the node's cache, so a shared frame buffer is fine). Returns the row `El`.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

pub fn stat(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8, value: []const u8) !El {
    const th = ctx.res.view.theme;

    const line = try el.div(ctx, parent, id);
    _ = line.with_flow(.{ .dir = .row }).with_gap(8);

    const lbl = try el.text(ctx, line, "lbl", label);
    _ = lbl.with_style(.{Style{ .text = th.dim }});
    const val = try el.text(ctx, line, "val", value);
    _ = val.with_style(.{Style{ .text = th.fg }});

    return line;
}
