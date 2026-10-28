//! `modal_footer` — the trade dialog's footer content in the frame's footer band: the venue's
//! note, then the secondary LEAVE and the primary confirmation actions.

const ha = @import("ha");
const El = ha.ui_client.elements.El;
const frame_mod = @import("./dialog_frame.zig");
const button_mod = @import("./button.zig");

/// `primary_key` is the confirmation button's stable key — the dialog's initial focus target.
pub const Result = struct { leave: bool, confirm: bool, primary_key: u64 };

pub fn modal_footer(footer: El, note: []const u8, primary_label: []const u8, primary_enabled: bool) !Result {
    try frame_mod.dialog_note(footer, "note", note, 420);
    const actions = try footer.div("actions");
    _ = actions.with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    const leave = try button_mod.button(actions, "leave", "LEAVE", true);
    const primary = try button_mod.button(actions, "primary", primary_label, primary_enabled);
    return .{
        .leave = leave.consume(.clicked),
        .confirm = primary.query().clicked and primary_enabled,
        .primary_key = primary.get().key,
    };
}
