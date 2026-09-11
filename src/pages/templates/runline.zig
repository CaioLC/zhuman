//! `runline` (KIT-12) — the header's right-side run context: the energy **rate**
//! (generated − consumed), the **act label**, and the **day**. A compact readout, not a
//! control. Act I has no stored energy flow (energy is the price of actions, paid from vigor),
//! so it passes `gen = consumed = 0` and only the act/day segments show; Act II passes its real
//! generated/consumed rates and the `+{gen}/−{consumed}` segment appears. The caller supplies
//! all values (the runline owns no domain math); segments are dim context except the day, which
//! stays `fg` as the functional counter (VIEW-04 drops the optional act label when compact).

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

/// What the runline renders. `gen`/`consumed` are per-unit energy rates (0 in Act I → the
/// energy segment is omitted); `act_label` is the optional context word ("Act I"); `day` the
/// functional day counter; `compact` drops the optional act label (VIEW-04 ≤560).
pub const Run = struct {
    gen: f32 = 0,
    consumed: f32 = 0,
    act_label: []const u8,
    day: u64,
    compact: bool = false,
};

/// Build the runline into `parent`, right-anchored by the caller. Returns the row `El`.
pub fn runline(ctx: *UiCtx, parent: El, id: []const u8, run: Run) !El {
    const th = ctx.res.view.theme;
    var buf: [48]u8 = undefined;

    const row = try el.div(ctx, parent, id);
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_);

    // Energy rate segment — only when there is a flow (Act II). `+gen −consumed` in dim.
    if (run.gen != 0 or run.consumed != 0) {
        const etxt = std.fmt.bufPrint(&buf, "+{d:.1} \u{2212}{d:.1} energy", .{ run.gen, run.consumed }) catch "";
        _ = (try el.text(ctx, row, "energy", etxt))
            .with_style(.{ style.heading, Style{ .text = th.dim } });
        _ = (try el.text(ctx, row, "e_sep", "\u{00B7}"))
            .with_style(.{ style.heading, Style{ .text = th.dim } });
    }

    // Act label — optional context, dropped when compact (VIEW-04); the middot follows it.
    if (!run.compact) {
        const atxt = std.fmt.bufPrint(&buf, "{s} \u{00B7}", .{run.act_label}) catch run.act_label;
        _ = (try el.text(ctx, row, "act", atxt))
            .with_style(.{ style.heading, Style{ .text = th.dim } });
    }

    // Day — the functional counter, always shown, in fg.
    const dtxt = std.fmt.bufPrint(&buf, "Day {d}", .{run.day}) catch "?";
    _ = (try el.text(ctx, row, "day", dtxt))
        .with_style(.{ style.heading, Style{ .text = th.fg } });

    return row;
}
