//! `runline` — the header's right-side run context: the energy **rate**
//! (generated − consumed), the **act label**, and the **day**. A compact readout, not a
//! control. Act I has no stored energy flow (energy is the price of actions, paid from vigor),
//! so it passes `gen = consumed = 0` and only the act/day segments show; Act II passes its real
//! generated/consumed rates and the `⚡ +{gen}/−{consumed}` segment appears. The caller supplies
//! all values (the runline owns no domain math); segments are dim context except the day, which
//! stays `fg` as the functional counter (`compact` drops the optional act label).

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
/// functional day counter; `compact` drops the optional act label (≤560).
pub const Run = struct {
    gen: f32 = 0,
    consumed: f32 = 0,
    act_label: []const u8,
    day: u64,
    compact: bool = false,
};

/// Build the runline into `parent`, right-anchored by the caller. Returns the row `El`.
pub fn runline(parent: El, id: []const u8, run: Run) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    var buf: [48]u8 = undefined;

    const row = try parent.div(id);
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_);

    // Energy rate segment — only when there is a flow (Act II): `⚡ +gen/−consumed`, the
    // prototype's `.energy-rate` — dim bolt and slash, generated in `acc`, consumed in `warn`.
    // It is a rate, not a stockpile, so it never takes the stockline's `LABEL: value` form.
    if (run.gen != 0 or run.consumed != 0) {
        const energy = try row.div("energy");
        _ = energy.with_flow(.{ .dir = .row, .cross = .center }).with_gap(3)
            .with_style(.{style.pad_each(0, 12 - ha.tokens.gap.inline_, 0, 0)}); // 12px before the act label
        _ = (try energy.text("bolt", "\u{26A1}")).with_style(.{ style.heading, Style{ .text = th.dim } });
        var gbuf: [16]u8 = undefined;
        var cbuf: [16]u8 = undefined;
        const gen_txt = std.mem.print(&gbuf, "+{d}", .{@round(run.gen)}) catch "+?";
        const use_txt = std.mem.print(&cbuf, "\u{2212}{d}", .{@round(run.consumed)}) catch "\u{2212}?";
        _ = (try energy.text("gen", gen_txt)).with_style(.{ style.heading, Style{ .text = th.acc } });
        _ = (try energy.text("slash", "/")).with_style(.{ style.heading, Style{ .text = th.dim } });
        _ = (try energy.text("use", use_txt)).with_style(.{ style.heading, Style{ .text = th.warn } });
    }

    // Act label — optional context, dropped when compact; the middot follows it.
    if (!run.compact) {
        const atxt = std.mem.print(&buf, "{s} \u{00B7}", .{run.act_label}) catch run.act_label;
        _ = (try row.text("act", atxt))
            .with_style(.{ style.heading, Style{ .text = th.dim } });
    }

    // Day — the functional counter, always shown, in fg.
    const dtxt = std.mem.print(&buf, "Day {d}", .{run.day}) catch "?";
    _ = (try row.text("day", dtxt))
        .with_style(.{ style.heading, Style{ .text = th.fg } });

    return row;
}
