//! `log_view` template — the event feed: a `scroll_view` over `Resources.log`, one
//! body-sized text line per entry, newest first (the ring buffer's own order), each
//! recolored by its `Tone`. Sized in **lines**, not px: the viewport height is `lines`
//! rows at the body font plus the content gaps between them, measured live so it tracks
//! the font. The given `width` is the *total* footprint — the viewport reserves the
//! scrollbar gutter, so the box never widens when the track appears. Line keys are
//! arena-formatted per index — stable across frames as long as the feed only grows at
//! the head, which is exactly what a newest-first ring does.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const Theme = ha.theme.Theme;
const Color = ha.theme.Color;
const Log = ha.log.Log;
const Tone = ha.log.Tone;

const sv = @import("./scroll_view.zig");

/// Map a log entry's tone to the current theme's matching color role (host policy).
fn log_tone_color(t: Theme, tone: Tone) Color {
    return switch (tone) {
        .dim => t.dim,
        .normal => t.fg,
        .good => t.acc,
        .warn => t.warn,
        .danger => t.danger,
    };
}

/// One row's height at the body font, measured live (falls back to the px itself if the
/// font backend errors — roughly right, and only cosmetic).
fn line_height(ctx: *UiCtx) f32 {
    const px = style.body.font.?;
    _, const h = ctx.res.font.measure("Ag", px) catch return px;
    return @floatFromInt(h);
}

pub fn log_view(ctx: *UiCtx, parent: El, id: []const u8, feed: *const Log, width: f32, lines: usize) !void {
    const th = ctx.res.theme;

    const flines: f32 = @floatFromInt(lines);
    const height = flines * line_height(ctx) + (flines - 1) * sv.content_gap;
    const view = try sv.scroll_view(ctx, parent, id, width - sv.scrollbar_w, height);

    var i: usize = 0;
    while (i < feed.count) : (i += 1) {
        const entry = feed.get(i);
        const key = try std.fmt.allocPrint(ctx.arena, "log{d}", .{i});
        const line = try el.text(ctx, view.content, key, entry.text());
        _ = line.with_style(.{ style.body, Style{ .text = log_tone_color(th, entry.tone) } });
    }
}
