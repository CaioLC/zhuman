//! The valley the outdoor scenes share (`prototypes/valley.js`): the far range, the near
//! hills, the ground, the trees, and the stars over them. The arrival and the thank-you are
//! both set in it, seen from the same place.
//!
//! Every random choice comes from one seeded generator, the prototype's own, so the valley is
//! the prototype's cell for cell and the same in every scene. Only the stars change with
//! time.

const std = @import("std");
const t = @import("./templates/root.zig");

pub const Cells = t.SceneCells;
pub const Ink = t.SceneInk;

pub const w: i32 = t.scene_cols;
pub const h: i32 = t.scene_rows;
/// The row the ground line sits on; the ground is every row below.
pub const horizon: i32 = 21;

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

/// A tree standing on a ground row. A lower row is nearer and is drawn over a higher one;
/// the list is in that order.
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

/// The generator `prototypes/scene.js` seeds its scenes with.
pub const Rng = struct {
    seed: u32,

    pub fn next(self: *Rng) f64 {
        self.seed +%= 0x6D2B79F5;
        var x: u32 = (self.seed ^ (self.seed >> 15)) *% (1 | self.seed);
        x = (x +% ((x ^ (x >> 7)) *% (61 | x))) ^ x;
        return @as(f64, @floatFromInt(x ^ (x >> 14))) / 4294967296.0;
    }

    /// A whole number in `0..n`.
    pub fn below(self: *Rng, n: f64) i32 {
        return @intFromFloat(@floor(self.next() * n));
    }

    /// The first draw of a generator seeded `seed`: a value in `0..1` fixed by the seed.
    pub fn of(seed: u32) f64 {
        var r = Rng{ .seed = seed };
        return r.next();
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

/// The valley without its trees, `seconds` in: the range, the hills, the ground and the sky.
pub fn ground(seconds: f32) Cells {
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
            if (behindTree(x, sy)) continue;
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
    return g;
}

/// Whether a sky cell is inside a tree's box, where a star would show through its branches.
fn behindTree(x: i32, y: i32) bool {
    for (props) |p| {
        const width: i32 = @intCast(p.art[0].len + 4);
        const height: i32 = @intCast(p.art.len);
        if (x >= p.x and x < p.x + width and y > p.foot - height and y <= p.foot) return true;
    }
    return false;
}

/// Draw the trees standing on ground rows after `after` up to and including `upto`. A scene
/// draws its own things between two calls, so each stands in front of the trees behind it.
pub fn trees(g: *Cells, after: i32, upto: i32) void {
    for (props) |p| {
        if (p.foot > after and p.foot <= upto) g.stamp(p.art, p.x, p.foot, p.ink.id(), null);
    }
}

const testing = std.testing;

test "valley: the ground is the same for the same time" {
    const a = ground(9.3);
    const b = ground(9.3);
    try testing.expectEqualSlices(u8, a.ink[0..a.count()], b.ink[0..b.count()]);
    for (a.ink[0..a.count()], 0..) |k, i| if (k != 0) try testing.expectEqual(a.glyph[i], b.glyph[i]);
}

test "valley: the stars stay above the skyline" {
    const g = ground(3);
    // The tallest peak's apex is the two cells on row `horizon - 10`; two rows down, inside
    // the mountain, there is nothing.
    try testing.expectEqual(@as(u21, '/'), g.at(61, horizon - 10).?.cp);
    try testing.expectEqual(@as(u21, '\\'), g.at(62, horizon - 10).?.cp);
    try testing.expect(g.at(61, horizon - 8) == null and g.at(62, horizon - 8) == null);
}

test "valley: the trees are drawn by ground row, each once" {
    var all = Cells.init(t.scene_cols, t.scene_rows);
    trees(&all, 0, h);
    var split = Cells.init(t.scene_cols, t.scene_rows);
    trees(&split, 0, 25);
    trees(&split, 25, h);
    try testing.expectEqualSlices(u8, all.ink[0..all.count()], split.ink[0..split.count()]);
    // The bare tree's trunk foot, on the nearest row any tree stands on.
    try testing.expectEqual(@as(u21, '|'), all.at(81, 29).?.cp);
}

test "valley: the generator is the prototype's" {
    // `seeded(1848)()` in scene.js.
    var r = Rng{ .seed = 1848 };
    const first = r.next();
    try testing.expect(first >= 0 and first < 1);
    try testing.expectEqual(first, Rng.of(1848));
}
