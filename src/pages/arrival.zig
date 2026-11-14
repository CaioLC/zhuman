//! The arrival (`prototypes/arrival.html`): the scene between New game and Act I. Under a sky
//! of twinkling stars a lone figure walks in from the left across an empty valley, stops once
//! to catch breath, and sits down; then the two lines type themselves out. `BEGIN →` starts
//! the run at any moment, `REPLAY` starts the scene over, and a click on the scene skips to
//! its end.
//!
//! The scene is a pure function of how long it has been showing (`SceneState.seconds`), so a
//! pinned time reproduces the frame. It is composed every frame onto the template's grid: the
//! valley (`valley.zig`), the footprints, then the trees and the figure from the farthest
//! ground row to the nearest.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const t = @import("./templates/root.zig");
const valley = @import("./valley.zig");

const Cells = t.SceneCells;
const Ink = t.SceneInk;

/// The row the figure's feet are on.
const actor_row: i32 = 27;
/// Where the figure stops to catch breath, and where it gives up walking.
const rest_x: i32 = 24;
const end_x: i32 = 56;

/// The figure's timeline, seconds: off stage, a step a `pace`, one rest, a stand, then down.
const enter_s: f32 = 1.5;
const pace_s: f32 = 0.21;
const rest_s: f32 = 1.8;
const stand_s: f32 = 1.6;
const rest_at_s: f32 = enter_s + pace_s * @as(f32, @floatFromInt(rest_x + 2));
const resume_s: f32 = rest_at_s + rest_s;
const stop_s: f32 = resume_s + pace_s * @as(f32, @floatFromInt(end_x - rest_x));
const sit_s: f32 = stop_s + stand_s;
/// How long a footprint lasts before the wind has filled it in.
const print_s: f32 = 22;

const caption = [2][]const u8{ "Day 1.", "Alone, cold and starving." };
/// The caption begins this long after the figure is down, and the scene has played out
/// this long after that.
const caption_after_s: f32 = 1.0;
const played_after_s: f32 = 5.0;
const caption_s: f32 = sit_s + caption_after_s;
const played_s: f32 = sit_s + played_after_s;

const legs = [4][]const u8{ "/ \\", " |\\", " | ", "/| " };

const Phase = enum { away, walk, rest, stand, sit };

/// Where the figure is `seconds` in: its column, what it is doing, and how long it has sat.
const Walker = struct { x: i32, phase: Phase, sat_s: f32 = 0 };

fn walker(seconds: f32) Walker {
    if (seconds < enter_s) return .{ .x = -2, .phase = .away };
    if (seconds < rest_at_s) return .{ .x = @min(rest_x - 1, -2 + steps(seconds - enter_s)), .phase = .walk };
    if (seconds < resume_s) return .{ .x = rest_x, .phase = .rest };
    if (seconds < stop_s) return .{ .x = @min(end_x - 1, rest_x + steps(seconds - resume_s)), .phase = .walk };
    if (seconds < sit_s) return .{ .x = end_x, .phase = .stand };
    return .{ .x = end_x, .phase = .sit, .sat_s = seconds - sit_s };
}

fn steps(walking_s: f32) i32 {
    return @intFromFloat(@floor(walking_s / pace_s));
}

/// When the figure stepped off column `x`.
fn leftAt(x: i32) f32 {
    return if (x < rest_x)
        enter_s + pace_s * @as(f32, @floatFromInt(x + 3))
    else
        resume_s + pace_s * @as(f32, @floatFromInt(x - rest_x + 1));
}

/// The scene `seconds` in.
fn compose(seconds: f32) Cells {
    var g = valley.ground(seconds);

    // The footprints behind the figure, fading as the wind fills them in.
    const who = walker(seconds);
    var px: i32 = 0;
    while (px < who.x - 1) : (px += 2) {
        const age = seconds - leftAt(px);
        if (age >= print_s) continue;
        g.put(px, actor_row, '.', (if (age < 7) Ink.near else if (age < 14) Ink.far else Ink.faint).id());
    }

    // The trees and the figure, the farthest ground row first.
    valley.trees(&g, 0, actor_row);
    figure(&g, who);
    valley.trees(&g, actor_row, valley.h);
    return g;
}

fn figure(g: *Cells, who: Walker) void {
    const pose: []const []const u8 = switch (who.phase) {
        .away => return,
        .walk => &.{ " o ", "(|\\", legs[@intCast(@mod(who.x, 4))] },
        .rest => &.{ " o ", "(|\\", " | " },
        .stand => &.{ " o ", "/|\\", "/ \\" },
        .sit => &.{ " o ", "(|_" },
    };
    g.stamp(pose, who.x - 1, actor_row, Ink.bright.id(), null);
}

pub fn ui_arrival(ctx: *uic.UiCtx) !uic.Trees {
    const clock = &ctx.res.scene.seconds;
    clock.* += ctx.res.game.time.real_dt;

    const cells = compose(clock.*);
    const s = try t.scene(ctx, "arrival", .{
        .cells = &cells,
        .caption = caption,
        .caption_s = clock.* - caption_s,
        .go = "BEGIN \u{2192}",
    });
    if (s.skip) clock.* = @max(clock.*, played_s);
    if (s.replay) clock.* = 0;
    if (s.go) ctx.res.fade.to(.run);
    return try uic.oneRoot(ctx.arena, s.root);
}

const testing = std.testing;

fn glyphAt(g: *const Cells, x: i32, y: i32) ?u21 {
    return if (g.at(x, y)) |c| c.cp else null;
}

test "arrival: the figure is off stage, then walks, rests once, stands and sits" {
    try testing.expectEqual(Phase.away, walker(0).phase);
    try testing.expectEqual(Phase.walk, walker(enter_s + 0.01).phase);
    try testing.expectEqual(@as(i32, -2), walker(enter_s + 0.01).x);
    try testing.expectEqual(Phase.rest, walker(rest_at_s + 0.5).phase);
    try testing.expectEqual(rest_x, walker(rest_at_s + 0.5).x);
    try testing.expectEqual(Phase.walk, walker(resume_s + 1).phase);
    try testing.expectEqual(Phase.stand, walker(stop_s + 0.1).phase);
    try testing.expectEqual(Phase.sit, walker(sit_s + 3).phase);
    try testing.expectEqual(end_x, walker(sit_s + 3).x);
}

test "arrival: the figure never steps backward, skips a column, or passes where it sits" {
    var prev: i32 = -2;
    var s: f32 = 0;
    while (s < sit_s + 5) : (s += 0.05) {
        const x = walker(s).x;
        try testing.expect(x >= prev and x - prev <= 1 and x <= end_x);
        prev = x;
    }
}

test "arrival: the valley is empty until the figure enters, and the figure ends seated" {
    const before = compose(0.5);
    var bright: usize = 0;
    for (before.ink[0..before.count()]) |k| bright += @intFromBool(k == Ink.bright.id());
    try testing.expectEqual(@as(usize, 0), bright);

    const after = compose(sit_s + 10);
    // Seated: the head one row above the feet row, the body on it.
    try testing.expectEqual(@as(?u21, 'o'), glyphAt(&after, end_x, actor_row - 1));
    try testing.expectEqual(@as(?u21, '|'), glyphAt(&after, end_x, actor_row));
    try testing.expectEqual(Ink.bright.id(), after.at(end_x, actor_row).?.ink);
}

test "arrival: the footprints trail the figure and fade once the wind has had them" {
    const mid = compose(rest_at_s + 0.5);
    try testing.expectEqual(@as(?u21, '.'), glyphAt(&mid, 20, actor_row));
    try testing.expectEqual(Ink.near.id(), mid.at(20, actor_row).?.ink);
    // Long after, the first print is filled in: the cell holds whatever the ground has.
    const late = compose(leftAt(0) + print_s + 1);
    if (late.at(0, actor_row)) |c| try testing.expect(c.ink != Ink.near.id());
}

test "arrival: the caption begins after the figure is down and before the scene has played out" {
    try testing.expect(caption_s > sit_s and caption_s < played_s);
    try testing.expectEqual(Phase.sit, walker(played_s).phase);
}

test "arrival: the scene shows fewer distinct glyphs than a grid can cache" {
    const g = compose(sit_s + 10);
    var seen = std.AutoHashMap(u16, void).init(testing.allocator);
    defer seen.deinit();
    for (g.ink[0..g.count()], g.glyph[0..g.count()]) |k, cp| if (k != 0) try seen.put(cp, {});
    try testing.expect(seen.count() < 64);
}
