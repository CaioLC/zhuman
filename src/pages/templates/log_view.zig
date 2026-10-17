//! `log_view` — the normalized EventLog footer: the whole `Log` (up to its 64-entry ring) in a
//! **scroll region** sized to four rows, newest first and **emphasized**, each recolored by its
//! `Tone` (including the `good` role). Each line carries the game day and time it was pushed
//! (`D19 11:45`, from `Entry.at`). At rest the region shows the four newest lines; the wheel or the
//! scrollbar thumb reaches older ones. Pushing a line publishes a **polite live announcement**
//! so a screen reader hears the newest event, and the feed publishes a stable **semantic
//! region** at the screen level so the bridge treats it as one live log.
//!
//! `log_view` works in **logical** px: the El/style seams scale the whole thing to
//! device px, so the reserved height tracks the font.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const Theme = uic.Theme;
const Color = uic.Color;
const Log = ha.log.Log;
const Tone = ha.log.Tone;

const sv = @import("./scroll_view.zig");

const footer_row_pad_x: f32 = 5;
const footer_content_gap: f32 = 0;

/// Map a log entry's tone to the current theme's matching color role (host policy).
/// `good` maps to the dedicated `good` role, not the accent, so a gain reads as a gain.
fn log_tone_color(t: Theme, tone: Tone) Color {
    return switch (tone) {
        .dim => t.dim,
        .normal => t.fg,
        .good => t.good,
        .warn => t.warn,
        .danger => t.danger,
    };
}

/// The game-time stamp for an entry pushed at `at` game-seconds: `D{day} {hh}:{mm}`, with the
/// day counted from 1 as the header does and the time of day from the day's fraction of 24h.
/// Truncated, so a line never reads later than it happened. Written into `buf`.
fn timeStamp(buf: []u8, at: f32, secs_per_day: f32) []const u8 {
    if (!(secs_per_day > 0) or !std.math.isFinite(at)) return "";
    const total_min: u64 = @intFromFloat(@floor(@max(0, at) / secs_per_day * 24 * 60 + 1e-3));
    const day = total_min / (24 * 60) + 1;
    const min_of_day = total_min % (24 * 60);
    return std.fmt.bufPrint(buf, "D{d} {d:0>2}:{d:0>2}", .{ day, min_of_day / 60, min_of_day % 60 }) catch "";
}

/// The stamp column width in logical px: a widest-case stamp measured in the stamp font, so
/// message text lines up down the feed (falls back to a fixed width on a backend error).
fn stamp_width(ctx: *UiCtx) f32 {
    const px = style.small.font.?;
    const w, _ = ctx.res.platform.font.measure("D000 00:00", px) catch return 72;
    return @floatFromInt(w); // logical, as `line_height` reads its measure
}

/// One log row's height in **logical** px — the body font's line height, measured live (falls
/// back to the font px on a backend error). Used to give the footer a *definite* height so the
/// bottom-anchored footer region resolves (an anchored `fit_children` box would collapse).
fn line_height(ctx: *UiCtx) f32 {
    const px = style.small.font.?;
    _, const h = ctx.res.platform.font.measure("Ag", px) catch return 17;
    return @max(17, @as(f32, @floatFromInt(h)));
}

/// The footer EventLog: the whole `feed` in a scroll region, newest first and emphasized,
/// tone-colored, each with its game-time stamp. The viewport is `lines` rows high (typically 4),
/// so at rest it shows the newest `lines` entries; the wheel or the thumb reaches older ones.
/// `width` is the logical px total footprint, scrollbar gutter included.
pub fn log_view(parent: El, id: []const u8, feed: *const Log, width: f32, lines: usize) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;

    const flines: f32 = @floatFromInt(lines);
    // Rows are exactly one line high, so `lines` rows fill the viewport with no partial row.
    const row_h = line_height(ctx);
    const band = flines * row_h + (flines - 1) * footer_content_gap; // definite height
    // The gutter is always reserved, so rows keep their width when the scrollbar appears.
    const col_w = @max(0, width - sv.scrollbar_w);
    const view = try sv.scroll_view(parent, id, .{
        .width = col_w,
        .height = band,
        .framed = false, // the shell's footer row already frames the log
        .gap = footer_content_gap,
    }, null);

    // Publish a polite announcement of the newest line so a reader hears the latest event once
    // (live region).
    if (feed.count > 0) {
        _ = ctx.res.announcements.announce(feed.get(0).text());
    }

    var i: usize = 0;
    const stamp_w = stamp_width(ctx);
    while (i < feed.count) : (i += 1) {
        const entry = feed.get(i);
        const newest = i == 0;
        const row = try view.content.item("log", i);
        _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(8)
            .with_size(.{ .fixed = @max(0, col_w - footer_row_pad_x * 2) }, .{ .fixed = row_h })
            .with_style(.{style.pad_each(0, footer_row_pad_x, 0, footer_row_pad_x)});
        // The game-time stamp — a fixed cell so message text lines up down the feed.
        var sbuf: [24]u8 = undefined;
        const stamp = timeStamp(&sbuf, entry.at, ctx.res.config.secs_per_day);
        _ = (try row.text_fit("at", stamp, .{ .cell = .{ .mode = .clip, .width = stamp_w } }))
            .with_style(.{ style.small, Style{ .text = th.dim } });
        // The message — tone-colored; the newest line is emphasized, older lines dim a step
        // toward `dim` unless their tone already carries meaning.
        const tone_color = log_tone_color(th, entry.tone);
        const ink = if (newest) tone_color else if (entry.tone == .normal) th.dim else tone_color;
        _ = (try row.text("m", entry.text()))
            .with_style(.{ style.small, Style{ .text = ink } });
    }
}

// ============================ Tests (pure helper) =======================================

test "timeStamp: day from 1, time of day from the day's fraction" {
    var buf: [24]u8 = undefined;
    const x = std.testing.expectEqualStrings;
    try x("D1 00:00", timeStamp(&buf, 0, 20));
    try x("D1 12:00", timeStamp(&buf, 10, 20));
    try x("D2 06:00", timeStamp(&buf, 25, 20));
    try x("D19 23:59", timeStamp(&buf, 18 * 20 + 19.99, 20)); // truncates, never rounds up
    try x("D1 18:00", timeStamp(&buf, 14.999999, 20)); // float drift absorbed
    try x("", timeStamp(&buf, 5, 0));
}
