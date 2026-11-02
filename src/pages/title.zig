//! The title screen (`title.html`): the route before a run. The menu offers Continue (disabled
//! while there is no settlement to resume), New game, Settings, Credits and Quit. Behind it the
//! attract loop shows the game receded: a ticking stockline, the merchant strip, work filling,
//! holdings and an event log. The loop is canned (the prototype's own copy, its tick every
//! 160ms, a log line every 3.4s) and a pure function of how long the title has been showing,
//! so a fixture that pins the time reproduces the frame.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const World = ha.sim.ecs.World;
const t = @import("./templates/root.zig");

const tick_s: f32 = 0.16;
const log_s: f32 = 3.4;

const Stock = struct { key: []const u8, value: f32, max: ?f32 = null, drift: f32 };
const stocks = [_]Stock{
    .{ .key = "VI", .value = 13, .max = 15, .drift = 0.05 },
    .{ .key = "PO", .value = 7, .drift = 0.004 },
    .{ .key = "CO", .value = 42, .drift = 0.07 },
    .{ .key = "FO", .value = 23, .drift = 0.11 },
    .{ .key = "WA", .value = 6, .drift = 0.05 },
    .{ .key = "FU", .value = 4, .drift = 0.04 },
    .{ .key = "ME", .value = 2, .drift = 0.02 },
    .{ .key = "MI", .value = 9, .drift = 0.04 },
    .{ .key = "BI", .value = 30, .drift = 0.13 },
};

const Work = struct { name: []const u8, at: f32, rate: f32 };
const work = [_]Work{
    .{ .name = "Forage", .at = 0.32, .rate = 0.011 },
    .{ .name = "Garden bed", .at = 0.68, .rate = 0.004 },
    .{ .name = "Split wood", .at = 0.11, .rate = 0.008 },
};

/// Lines in the game's own voice; the ground should not read as filler.
const log_lines = [_][]const u8{
    "You return with 4 Biomass.",
    "Mira Halt took 6 Biomass at 4 coin.",
    "The garden bed is ready to collect.",
    "Tomas Dace is short on biomass and has Food to spare.",
    "A merchant is taking orders beside the east path.",
    "Seven people now share the settlement\u{2019}s stores.",
    "You eat. Vigor climbs.",
    "A new recipe is within reach: Fishing net.",
    "Odd Ryne will not take charcoal \u{2014} he has forty spare.",
    "The carpenter bench still lacks Biomass and Metal.",
    "Charcoal clears at 3 coin, down from 4.",
    "Split wood finishes. The hatchet holds.",
};

const rail = [_]t.TitleRailRow{
    .{ .label = "Charcoal \u{00d7}14", .value = "trade stock" },
    .{ .label = "Planks \u{00d7}8", .value = "trade stock" },
    .{ .label = "Baskets \u{00d7}6", .value = "trade stock" },
    .{ .label = "Rope \u{00d7}4", .value = "trade stock" },
    .{ .label = "Sandals \u{00d7}2", .value = "forage costs less" },
    .{ .label = "Root cellar \u{00d7}1", .value = "food keeps 2\u{00d7}" },
    .{ .label = "Leaf bed \u{00d7}1", .value = "vigor ceiling +1" },
    .{ .label = "Garden bed \u{00d7}1", .value = "grows food" },
};

/// The start of the run clock, in minutes of day 43 (19:08).
const clock_start: u32 = 19 * 60 + 8;

/// A stock's value after `n` ticks: a bounded wander around its start, deterministic in `n`.
fn wander(s: Stock, n: u32, i: usize) f32 {
    const x: f32 = @floatFromInt(n);
    const phase: f32 = @floatFromInt(i * 7 + 3);
    const amp = s.drift * 6 * 8;
    var v = s.value + amp * (@sin(x * 0.037 + phase) + 0.5 * @sin(x * 0.113 + phase * 1.7));
    v = @max(0, v);
    if (s.max) |m| v = @min(m, v);
    return v;
}

fn hhmm(arena: std.mem.Allocator, minutes: u32) ![]const u8 {
    const m = minutes % (24 * 60);
    return arena.print("{d:0>2}:{d:0>2}", .{ m / 60, m % 60 });
}

/// The attract frame `seconds` into the title.
fn attract(arena: std.mem.Allocator, seconds: f32) !t.TitleAttract {
    const n: u32 = @intFromFloat(@max(0, seconds) / tick_s);
    const minutes = clock_start + 7 * n;

    var stock_text = try arena.alloc([]const u8, stocks.len);
    for (stocks, 0..) |s, i| {
        const v = wander(s, n, i);
        stock_text[i] = if (s.max) |m|
            try arena.print("{s}: {d:.0}/{d:.0}", .{ s.key, v, m })
        else
            try arena.print("{s}: {d:.0}", .{ s.key, v });
    }

    var bars = try arena.alloc(t.TitleWork, work.len);
    for (work, 0..) |w, i| {
        const at = @mod(w.at + w.rate * @as(f32, @floatFromInt(n)), 1.0);
        bars[i] = .{ .name = w.name, .fraction = at, .pct = try arena.print("{d:.0}%", .{at * 100}) };
    }

    // Three lines, newest first: the title opens with three already pushed, then one more
    // every 3.4s, each stamped with the run clock at its push.
    const pushes: u32 = 3 + @as(u32, @intFromFloat(@max(0, seconds) / log_s));
    const lines = try arena.alloc(t.TitleLogLine, 3);
    for (lines, 0..) |*l, k| {
        const idx = pushes - 1 - @as(u32, @intCast(k));
        const at_tick: u32 = if (idx < 3) 0 else @intFromFloat(@as(f32, @floatFromInt(idx - 2)) * log_s / tick_s);
        const opening = [_]u32{ 0, 23, 54 };
        const stamp = clock_start + 7 * at_tick + (if (idx < 3) opening[idx] else 54);
        l.* = .{ .time = try hhmm(arena, stamp), .text = log_lines[idx % log_lines.len] };
    }

    return .{
        .stocks = stock_text,
        .run = try arena.print("Act II \u{00b7} Day {d}", .{43 + minutes / (24 * 60)}),
        .strip_signal = "MERCHANT",
        .strip_copy = "9 lots \u{00b7} salt, oil, nails, cloth, glass, tools",
        .work = bars,
        .rail_count = "8 KINDS, 41",
        .rail = &rail,
        .log = lines,
    };
}

pub fn ui_title(ctx: *uic.UiCtx, world: *World) !uic.Trees {
    _ = world;
    ctx.res.title.attract_s += ctx.res.game.time.real_dt;
    const r = try t.title_screen(ctx, "title", try attract(ctx.arena, ctx.res.title.attract_s));
    if (r.changed.window) applyWindow(ctx);
    switch (r.action) {
        .none => {},
        .new_game => {
            // The schedule begins the run from the intent; the route, the pause and the
            // curtain are the host's, reset here. The curtain keeps its cursor, so a fact
            // already heard is not heard again.
            _ = ctx.res.game.events.writer(ha.sim.events.NewRun).push(.{});
            ctx.res.route = .game;
            ctx.res.title = .{};
            ctx.res.playback.paused = false;
            ctx.res.curtain = .{ .heard = ctx.res.curtain.heard };
        },
        .quit => ctx.res.menu.quit_requested = true,
    }
    return try uic.oneRoot(ctx.arena, r.root);
}

/// Apply the window setting a settings panel changed: a windowed size, or fullscreen.
pub fn applyWindow(ctx: *uic.UiCtx) void {
    const choice = ctx.res.settings.window orelse return;
    const win = ctx.res.platform.window;
    if (choice.size()) |s| {
        win.setFullscreen(false) catch {};
        win.setSize(s.w, s.h) catch {};
    } else {
        win.setFullscreen(true) catch {};
    }
}

test "the attract frame is deterministic in time and keeps three log lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try attract(arena.allocator(), 5);
    const b = try attract(arena.allocator(), 5);
    try std.testing.expectEqualStrings(a.stocks[0], b.stocks[0]);
    try std.testing.expectEqual(@as(usize, 3), a.log.len);
    try std.testing.expectEqualStrings("Act II \u{00b7} Day 43", (try attract(arena.allocator(), 0)).run);
}
