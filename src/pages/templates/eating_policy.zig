//! `eating_policy` (KIT-19) — the BODY panel's eating control: a `0..100` range slider (the
//! KIT-10 control) whose value maps through the shared `eating` math to a rate word, a
//! multiplier, and the BODY projections (coverage / recovery). The control owns **no** eating
//! math — it reads it all from `ha.eating`, so the display and the authoritative simulation
//! compute the same numbers. The caller owns the `value` (its stored policy); this returns the
//! new value for a live update.
//!
//! Renders `{word} · {rate:.2}×` as the headline, an aria/value narration `{word}, {rate:.2}
//! times normal`, and the two projections `coverage`/`recovery` (one decimal day). The per-act
//! `eating.Config` (Act I `5.2/0.224`, Act II `10.3/0.448`) is the caller's, so the same
//! template serves both acts.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const eating = ha.eating;

const slider_mod = @import("./slider.zig");

/// Build the eating-policy panel into `parent`. `value` is the caller's current `0..100`
/// policy; `cfg` the per-act base coverage/recovery. Returns the new value (assign it back for
/// a live update). `enabled` gates the slider.
pub fn eating_policy(ctx: *UiCtx, parent: El, id: []const u8, value: f32, cfg: eating.Config, enabled: bool) !f32 {
    const th = ctx.res.view.theme;

    const panel = try el.div(ctx, parent, id);
    _ = panel.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    _ = (try el.text(ctx, panel, "eyebrow", "BODY")).with_style(.{ style.eyebrow, Style{ .text = th.dim } });

    // The slider (KIT-10), 0..100 step 1. It owns no eating math — the caller maps its value.
    const new_value = try slider_mod.slider(ctx, panel, "rate", "Eat", value, 0, 100, 1, enabled);
    const r = eating.rate(new_value);
    const w = eating.word(new_value);

    // Headline: `{word} · {rate:.2}×`. The aria/value narration is the same facts spelled out.
    var hbuf: [48]u8 = undefined;
    const headline = std.fmt.bufPrint(&hbuf, "{s} \u{00B7} {d:.2}\u{00D7}", .{ w, r }) catch w;
    _ = (try el.text(ctx, panel, "headline", headline)).with_style(.{ style.body, Style{ .text = th.fg } });
    // Narration published as an announcement so a screen reader hears "hearty, 1.32 times normal".
    var abuf: [64]u8 = undefined;
    const aria = std.fmt.bufPrint(&abuf, "{s}, {d:.2} times normal", .{ w, r }) catch w;
    _ = ctx.res.announcements.announce(aria);

    // BODY projections: coverage and recovery, one decimal day each.
    const cov = eating.coverage(cfg, r);
    const rec = eating.recovery(cfg, r);
    var pbuf: [64]u8 = undefined;
    const proj = std.fmt.bufPrint(&pbuf, "coverage {d:.1}d \u{00B7} recovery {d:.1}d", .{ cov, rec }) catch "";
    _ = (try el.text(ctx, panel, "proj", proj)).with_style(.{ style.small, Style{ .text = th.dim } });

    return new_value;
}
