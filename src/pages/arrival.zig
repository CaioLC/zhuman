//! The arrival (`prototypes/arrival.html`): the scene between New game and Act I. Under a sky
//! of twinkling stars a lone figure walks in from the left across an empty valley, stops once
//! to catch breath, and sits down; then the two lines, and Begin starts the run.
//!
//! The scene is a pure function of how long it has been showing (`SceneState.seconds`), so a
//! pinned time reproduces the frame. It is composed every frame onto the template's grid: the
//! backdrop (the far range, the near hills, the ground), the stars, the footprints, then the
//! trees and the figure from the farthest ground row to the nearest. Every random choice
//! comes from one seeded generator, so the valley is the same every time.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const t = @import("./templates/root.zig");
const title_page = @import("./title.zig");

const Cells = t.SceneCells;
const Ink = t.SceneInk;

const w: i32 = t.scene_cols;
const h: i32 = t.scene_rows;
/// The row the ground line sits on; the ground is every row below.
const horizon: i32 = 21;
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
/// When each caption line starts to fade in after the figure is down, and how long it takes.
const caption_at_s = [2]f32{ 1.0, 2.4 };
const caption_fade_s: f32 = 0.9;

const bare_tree = [_][]const u8{
    " \\   |   /",
    "  \\ \\|  / _/",
    " __\\ | /_/",
    "    \\|/",
    "     |/",
    "     |",
    "     |",
    "    /|\\",
};
const fir = [_][]const u8{ "   ^", "  /|\\", " /_|_\\", "  /|\\", " / | \\", "/__|__\\", "   |" };
const far_fir = [_][]const u8{ " ^", "/|\\", "/|\\", " |" };

/// A thing standing on a ground row. A lower row is nearer and is drawn over a higher one;
/// the list is in that order, and the figure goes in at its own row.
const Prop = struct { art: []const []const u8, x: i32, foot: i32, ink: Ink };
const props = [_]Prop{
    .{ .art = &far_fir, .x = 36, .foot = 22, .ink = .far },
    .{ .art = &far_fir, .x = 92, .foot = 22, .ink = .far },
    .{ .art = &far_fir, .x = 6, .foot = 23, .ink = .far },
    .{ .art = &far_fir, .x = 40, .foot = 23, .ink = .far },
    .{ .art = &fir, .x = 12, .foot = 25, .ink = .near },
    .{ .art = &bare_tree, .x = 76, .foot = 29, .ink = .near },
};

/// The far range: straight-sided peaks, each an apex column and a height.
const peaks = [_][2]i32{ .{ 9, 5 }, .{ 21, 9 }, .{ 31, 6 }, .{ 45, 4 }, .{ 62, 11 }, .{ 73, 6 }, .{ 87, 8 }, .{ 98, 4 } };

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

/// How far each caption line has faded in, 0 to 1.
fn captionShown(seconds: f32) [2]f32 {
    const sat = walker(seconds).sat_s;
    var shown: [2]f32 = undefined;
    for (&shown, caption_at_s) |*s, at| s.* = std.math.clamp((sat - at) / caption_fade_s, 0, 1);
    return shown;
}

/// The generator `prototypes/scene.js` seeds its scenes with, so the valley here is the
/// prototype's cell for cell.
const Rng = struct {
    seed: u32,

    fn next(self: *Rng) f64 {
        self.seed +%= 0x6D2B79F5;
        var x: u32 = (self.seed ^ (self.seed >> 15)) *% (1 | self.seed);
        x = (x +% ((x ^ (x >> 7)) *% (61 | x))) ^ x;
        return @as(f64, @floatFromInt(x ^ (x >> 14))) / 4294967296.0;
    }

    fn below(self: *Rng, n: f64) i32 {
        return @intFromFloat(@floor(self.next() * n));
    }
};

/// A ridge is a height at every cell edge, each within one of its neighbour. A cell climbs,
/// falls or runs flat between its two edges, and hides whatever stood behind it.
fn ridge(g: *Cells, edge: *const [w + 1]i32, ink: Ink) void {
    for (0..@intCast(w)) |i| {
        const x: i32 = @intCast(i);
        const a = edge[i];
        const b = edge[i + 1];
        const row = horizon - @min(a, b);
        var y = row;
        while (y <= horizon) : (y += 1) g.put(x, y, ' ', 0);
        g.put(x, row, if (b > a) '/' else if (b < a) '\\' else '_', ink.id());
    }
}

/// The scene `seconds` in.
fn compose(seconds: f32) Cells {
    var g = Cells.init(t.scene_cols, t.scene_rows);
    var rng = Rng{ .seed = 1848 };

    var far: [w + 1]i32 = undefined;
    var near: [w + 1]i32 = undefined;
    for (0..far.len) |i| {
        const j: i32 = @intCast(i);
        var top: i32 = 0;
        for (peaks) |p| top = @max(top, p[1] - @as(i32, @intCast(@abs(j - p[0]))));
        far[i] = top;

        // The near hills: low and rolling, a step at a time.
        const x: f64 = @floatFromInt(j);
        const want: i32 = @intFromFloat(@max(0, @round(1.1 + 1.4 * @sin(x * 0.045 + 2.1) + 0.8 * @sin(x * 0.11 + 5))));
        const prev = if (i == 0) want else near[i - 1];
        near[i] = @max(prev - 1, @min(prev + 1, want));
    }
    ridge(&g, &far, .far);
    ridge(&g, &near, .near);

    // The ground: drifts, and what little grows on it.
    for (0..9) |_| {
        const y = horizon + 2 + rng.below(@floatFromInt(h - horizon - 3));
        const x = rng.below(@floatFromInt(w));
        const len = 4 + rng.below(9);
        var i: i32 = 0;
        while (i < len) : (i += 1) if (rng.next() < 0.7) g.put(x + i, y, '_', Ink.faint.id());
    }
    const tufts = [_]u21{ '.', '.', '.', ',', '\'', '"' };
    var y: i32 = horizon + 1;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            if (rng.next() < 0.035) g.put(x, y, tufts[@intCast(rng.below(tufts.len))], Ink.far.id());
        }
    }

    // The stars: thicker toward the top, none below the skyline or behind a tree. Most are
    // faint, a few are bright, and each twinkles to its own period.
    for (0..@intCast(w)) |i| {
        const x: i32 = @intCast(i);
        const skyline = horizon - @max(@max(far[i], far[i + 1]), @max(near[i], near[i + 1]));
        var sy: i32 = 0;
        while (sy < skyline) : (sy += 1) {
            const thin = 1 - 0.6 * @as(f64, @floatFromInt(sy)) / @as(f64, @floatFromInt(horizon));
            if (rng.next() >= 0.04 * thin) continue;
            const pick = rng.next();
            const period = 1.5 + rng.next() * 3.5;
            const phase = rng.next() * std.math.pi * 2;
            if (behindProp(x, sy)) continue;
            const glow = @sin(@as(f64, seconds) * 2 * std.math.pi / period + phase);
            if (pick < 0.7) {
                g.put(x, sy, '.', (if (glow > 0.2) Ink.far else Ink.faint).id());
            } else if (pick < 0.94) {
                g.put(x, sy, 0xB7, (if (glow > 0.2) Ink.near else Ink.far).id());
            } else {
                const cp: u21 = if (glow > 0.5) '*' else if (glow > -0.3) '+' else 0xB7;
                g.put(x, sy, cp, (if (glow > -0.3) Ink.near else Ink.far).id());
            }
        }
    }

    // The footprints behind the figure, fading as the wind fills them in.
    const who = walker(seconds);
    var px: i32 = 0;
    while (px < who.x - 1) : (px += 2) {
        const age = seconds - leftAt(px);
        if (age >= print_s) continue;
        g.put(px, actor_row, '.', (if (age < 7) Ink.near else if (age < 14) Ink.far else Ink.faint).id());
    }

    // The trees and the figure, the farthest ground row first.
    var placed = who.phase == .away;
    for (props) |p| {
        if (!placed and p.foot > actor_row) {
            figure(&g, who);
            placed = true;
        }
        g.stamp(p.art, p.x, p.foot, p.ink.id(), null);
    }
    if (!placed) figure(&g, who);
    return g;
}

/// Whether a sky cell is inside a tree's box, where a star would show through its branches.
fn behindProp(x: i32, y: i32) bool {
    for (props) |p| {
        const width: i32 = @intCast(p.art[0].len + 4);
        const height: i32 = @intCast(p.art.len);
        if (x >= p.x and x < p.x + width and y > p.foot - height and y <= p.foot) return true;
    }
    return false;
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
    ctx.res.scene.seconds += ctx.res.game.time.real_dt;
    const seconds = ctx.res.scene.seconds;

    const regions = try t.shell(ctx, .{
        .id = "arrival",
        .act = .act_one,
        .page_pad = ha.tokens.pad_page,
        .section_gap = ha.tokens.gap.section,
        // A scene centred in the window; it never scrolls.
        .scroll = false,
    });
    const cells = compose(seconds);
    const s = try t.scene(regions.body, "scene", .{
        .cells = &cells,
        .caption = caption,
        .shown = captionShown(seconds),
        .button = "Begin",
    });
    if (s.clicked) title_page.beginRun(ctx);
    return try uic.oneRoot(ctx.arena, regions.root.get());
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

test "arrival: the scene is the same for the same time" {
    const a = compose(9.3);
    const b = compose(9.3);
    try testing.expectEqualSlices(u8, a.ink[0..a.count()], b.ink[0..b.count()]);
    for (a.ink[0..a.count()], 0..) |k, i| if (k != 0) try testing.expectEqual(a.glyph[i], b.glyph[i]);
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

test "arrival: the stars stay above the skyline" {
    const g = compose(3);
    // The tallest peak's apex is the two cells on row `horizon - 10`; two rows down, inside
    // the mountain, there is nothing.
    try testing.expectEqual(@as(?u21, '/'), glyphAt(&g, 61, horizon - 10));
    try testing.expectEqual(@as(?u21, '\\'), glyphAt(&g, 62, horizon - 10));
    try testing.expect(g.at(61, horizon - 8) == null and g.at(62, horizon - 8) == null);
}

test "arrival: the caption fades in after the figure is down, the first line first" {
    try testing.expectEqual([2]f32{ 0, 0 }, captionShown(sit_s));
    const mid = captionShown(sit_s + caption_at_s[0] + caption_fade_s + 0.01);
    try testing.expectEqual(@as(f32, 1), mid[0]);
    try testing.expect(mid[1] < 1);
    try testing.expectEqual([2]f32{ 1, 1 }, captionShown(sit_s + 10));
}

test "arrival: the scene shows fewer distinct glyphs than a grid can cache" {
    const g = compose(sit_s + 10);
    var seen = std.AutoHashMap(u16, void).init(testing.allocator);
    defer seen.deinit();
    for (g.ink[0..g.count()], g.glyph[0..g.count()]) |k, cp| if (k != 0) try seen.put(cp, {});
    try testing.expect(seen.count() < 64);
}
