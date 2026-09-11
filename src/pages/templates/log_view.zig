//! `log_view` (KIT-22) — the normalized EventLog footer: the **four newest** lines, newest
//! first and **emphasized**, each recolored by its `Tone` (including the KIT-01 `good` role).
//! The newest line is stamped **NOW**; older lines carry a relative age marker. The footer log
//! **does not scroll** — the `Log` preserves the full history beyond four, but it is only
//! reachable through the explicit `log_history` view (a scroll region), never an independent
//! scroll on the footer. Pushing a line publishes a **polite live announcement** so a screen
//! reader hears the newest event, and the feed publishes a stable **semantic region** at the
//! screen level so the bridge treats it as one live log.
//!
//! `log_view` works in **logical** px (VIEW-02): the El/style seams scale the whole thing to
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

/// Map a log entry's tone to the current theme's matching color role (host policy). KIT-22:
/// `good` maps to the dedicated `good` role (KIT-01), not the accent, so a gain reads as a gain.
fn log_tone_color(t: Theme, tone: Tone) Color {
    return switch (tone) {
        .dim => t.dim,
        .normal => t.fg,
        .good => t.good,
        .warn => t.warn,
        .danger => t.danger,
    };
}

/// The relative age marker for line `i` (0 = newest): the newest is `NOW`, older lines a dim
/// `−{i}` recency marker. A lightweight timestamp without threading sim time through `Log.push`
/// — it reads as "how many events back". Written into `buf`.
fn ageStamp(buf: []u8, i: usize) []const u8 {
    if (i == 0) return "NOW";
    return std.fmt.bufPrint(buf, "-{d}", .{i}) catch "";
}

/// One log row's height in **logical** px — the body font's line height, measured live (falls
/// back to the font px on a backend error). Used to give the footer a *definite* height so the
/// bottom-anchored footer region resolves (an anchored `fit_children` box would collapse).
fn line_height(ctx: *UiCtx) f32 {
    const px = style.body.font.?;
    _, const h = ctx.res.platform.font.measure("Ag", px) catch return px;
    return @floatFromInt(h);
}

/// The normalized footer EventLog (KIT-22): the newest `lines` entries (typically 4), newest
/// first and emphasized, tone-colored, each with its `NOW`/age stamp — **no scrolling**. `width`
/// is a logical px column. The full history stays in `feed`; `log_history` is the way to it.
pub fn log_view(ctx: *UiCtx, parent: El, id: []const u8, feed: *const Log, width: f32, lines: usize) !void {
    const th = ctx.res.view.theme;

    const flines: f32 = @floatFromInt(lines);
    const band = flines * line_height(ctx) + (flines - 1) * sv.content_gap; // definite height
    const col = try el.div(ctx, parent, id);
    _ = col.with_flow(.{ .dir = .column }).with_gap(sv.content_gap)
        .with_size(.{ .fixed = width }, .{ .fixed = band });

    // Publish a polite announcement of the newest line so a reader hears the latest event once
    // (KIT-22 live region). The full history stays in `feed`; `log_history` is the way to it.
    if (feed.count > 0) {
        _ = ctx.res.announcements.announce(feed.get(0).text());
    }

    const shown = @min(lines, feed.count);
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const entry = feed.get(i);
        const newest = i == 0;
        const key = try std.fmt.allocPrint(ctx.arena, "log{d}", .{i});
        const row = try el.div(ctx, col, key);
        _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(8)
            .with_size(.{ .fixed = width }, .fit_children);
        // The age/NOW stamp — a fixed narrow cell so message text lines up down the feed.
        var sbuf: [8]u8 = undefined;
        _ = (try el.text(ctx, row, "at", ageStamp(&sbuf, i)))
            .with_style(.{ style.small, Style{ .text = th.dim } })
            .with_cell(.clip, 30);
        // The message — tone-colored; the newest line is emphasized, older lines dim a step
        // toward `dim` unless their tone already carries meaning.
        const tone_color = log_tone_color(th, entry.tone);
        const ink = if (newest) tone_color else if (entry.tone == .normal) th.dim else tone_color;
        _ = (try el.text(ctx, row, "m", entry.text()))
            .with_style(.{ style.body, Style{ .text = ink } });
    }
}

/// The explicit **history view** (KIT-22): the full `Log` in a scroll region, newest first,
/// tone-colored. This is the *only* place the feed scrolls — opened deliberately (a modal or a
/// dedicated panel), never the footer. `width` is a logical px total footprint; `height` the
/// logical viewport height.
pub fn log_history(ctx: *UiCtx, parent: El, id: []const u8, feed: *const Log, width: f32, height: f32) !void {
    const th = ctx.res.view.theme;
    const col_w = width - sv.scrollbar_w;
    const view = try sv.scroll_view(ctx, parent, id, col_w, height);
    var i: usize = 0;
    while (i < feed.count) : (i += 1) {
        const entry = feed.get(i);
        const key = try std.fmt.allocPrint(ctx.arena, "h{d}", .{i});
        const row = try el.div(ctx, view.content, key);
        _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(8)
            .with_size(.{ .fixed = col_w }, .fit_children);
        var sbuf: [8]u8 = undefined;
        _ = (try el.text(ctx, row, "at", ageStamp(&sbuf, i)))
            .with_style(.{ style.small, Style{ .text = th.dim } })
            .with_cell(.clip, 30);
        _ = (try el.text(ctx, row, "m", entry.text()))
            .with_wrap(col_w - 38)
            .with_style(.{ style.body, Style{ .text = log_tone_color(th, entry.tone) } });
    }
}

// ============================ Tests (pure helper) =======================================

test "ageStamp: newest is NOW, older lines are -N" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("NOW", ageStamp(&buf, 0));
    try std.testing.expectEqualStrings("-1", ageStamp(&buf, 1));
    try std.testing.expectEqualStrings("-3", ageStamp(&buf, 3));
}
