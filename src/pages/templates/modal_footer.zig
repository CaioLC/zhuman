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

pub fn modal_footer(parent: El, width: f32, note: []const u8, primary_label: []const u8, primary_enabled: bool) !Result {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const inner_width = width - 30; // match the body's 15px horizontal padding and right edge
    try modal_mod.rule(parent, "footer_rule", width);
    const footer = try parent.div("footer");
    _ = footer.with_size(.{ .fixed = inner_width }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
        .with_style(.{style.pad_sym(15, 9)});
    _ = (try footer.text_fit("note", note, .{ .wrap = 420 }))
        .with_style(.{Style{ .font = 9, .text = th.dim }});
    const actions = try footer.div("actions");
    _ = actions.with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    const leave = try (@import("./button.zig")).button(actions, "leave", "LEAVE", true);
    const primary = try (@import("./button.zig")).button(actions, "primary", primary_label, primary_enabled);
    return .{
        .leave = leave.consume(.clicked),
        .confirm = primary.query().clicked and primary_enabled,
    };
}
