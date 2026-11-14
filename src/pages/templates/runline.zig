//! `runline` — the header's right-side run context: the **act label** and the **day**. A
//! compact readout, not a control. The caller supplies both values; the act label is dim
//! context and the day stays `fg` as the functional counter (`compact` drops the optional act
//! label).

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

/// What the runline renders. `act_label` is the optional context word ("Act I"); `day` the
/// functional day counter; `compact` drops the optional act label (≤560).
pub const Run = struct {
    act_label: []const u8,
    day: u64,
    compact: bool = false,
};

/// The runline's face: 17px (14px stacked, ≤760) at the body tracking (`.runline`).
fn runType(ctx: *UiCtx) Style {
    return .{ .font = if (@import("./terminal.zig").stacked(ctx)) 14 else 17, .tracking = -0.025 };
}

/// Build the runline into `parent`, right-anchored by the caller. Returns the row `El`.
pub fn runline(parent: El, id: []const u8, run: Run) !El {
    const ctx = parent.ctx;
    var buf: [48]u8 = undefined;

    const row = try parent.box(id, .{ .flow = .{ .dir = .row, .cross = .center }, .gap = 8 }, .{});

    // Act label — optional context, dropped when compact; the middot follows it.
    if (!run.compact) {
        const atxt = std.mem.print(&buf, "{s} \u{00B7}", .{run.act_label}) catch run.act_label;
        try row.label("act", atxt, .{ runType(ctx), style.muted });
    }

    // Day — the functional counter, always shown, in fg.
    const dtxt = std.mem.print(&buf, "Day {d}", .{run.day}) catch "?";
    try row.label("day", dtxt, .{ runType(ctx), style.ink(.fg) });

    return row;
}
