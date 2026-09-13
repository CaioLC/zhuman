//! `modal_footer` — modal note plus secondary LEAVE and primary confirmation actions.

const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const modal_mod = @import("./modal.zig");

pub const Result = struct { leave: bool, confirm: bool };

pub fn modal_footer(ctx: *UiCtx, parent: El, width: f32, note: []const u8, primary_label: []const u8, primary_enabled: bool) !Result {
    const th = ctx.res.view.theme;
    const inner_width = width - 46; // 15px authored padding + engine button overhang
    try modal_mod.rule(ctx, parent, "footer_rule", width);
    const footer = try el.div(ctx, parent, "footer");
    _ = footer.with_size(.{ .fixed = inner_width }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
        .with_style(.{style.pad_sym(15, 9)});
    _ = (try el.text(ctx, footer, "note", note)).with_wrap(420)
        .with_style(.{Style{ .font = 9, .text = th.dim }});
    const actions = try el.div(ctx, footer, "actions");
    _ = actions.with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    const leave = try (@import("./button.zig")).button(ctx, actions, "leave", "LEAVE", true);
    const primary = try (@import("./button.zig")).button(ctx, actions, "primary", primary_label, primary_enabled);
    return .{
        .leave = leave.consume(.clicked),
        .confirm = primary.query().clicked and primary_enabled,
    };
}
