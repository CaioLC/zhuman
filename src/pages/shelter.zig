//! The shelter scene (`prototypes/shelter.html`), composed for the Act I curtain: inside, at
//! the fire. One face is there from the start; the others walk up out of the snow in the
//! doorway and their faces come into the firelight one by one: an elder, a woman and a child,
//! a man in a hat. Everyone blinks; the one who was alone looks up at each newcomer and
//! smiles once the first is lit.
//!
//! The scene is a pure function of how long it has been showing, so a pinned time reproduces
//! the frame. The room (the roof, the posts, what hangs from the beam, the doorway, the
//! floor) comes from the prototype's seeded generator, cell for cell.

const std = @import("std");
const t = @import("./templates/root.zig");
const valley = @import("./valley.zig");

pub const Cells = t.SceneCells;
const Ink = t.SceneInk;
const Clip = t.SceneClip;
const Rng = valley.Rng;

const w: i32 = t.scene_cols;
const h: i32 = t.scene_rows;
/// The opening, inside its frame.
const door: Clip = .{ .x0 = 81, .y0 = 5, .x1 = 93, .y1 = 16 };
/// Seconds from the horizon to the threshold.
const approach_s: f32 = 3.2;
const fire_x: i32 = 44;
const fire_foot: i32 = 28;
/// How long a face takes to come fully into the light, and how long the one at the fire
/// looks at a newcomer.
const lit_s: f32 = 1.6;
const glance_s: f32 = 1.6;
const blink_s: f32 = 0.16;

pub const caption = [2][]const u8{ "The shelter stands.", "You are no longer alone." };
/// When the caption begins, and when the scene has played out.
pub const caption_s: f32 = 19.5;
pub const played_s: f32 = caption_s + 5;

const eye: u21 = 0x2022;

// Fifteen cells by ten, the eyes five and nine cells in; the child is eleven by eight.
const you = [_][]const u8{
    "    ,~~-~~-~.",
    " ,'~ ' ~~ ' '.",
    " |  --   --  |",
    "(|   \u{2022}   \u{2022}   |)",
    " |     ,     |",
    " |    ---    |",
    "  \\ .     . /",
    "   '-.___.-'",
    "  ___|   |___",
    " /   '. .'   \\",
};
const you_smile = " |    \\_/    |";
const you_mouth_row: usize = 5;

const elder = [_][]const u8{
    "    .-----.",
    "  ,'       '.",
    " |  ~~   ~~  |",
    "(|   \u{2022}   \u{2022}   |)",
    " |    (_)    |",
    " | ,~~\\_/~~. |",
    " \\~~~~~~~~~~~/",
    "  \\~~~~~~~~~/",
    "   '~~~~~~~'",
    " ,--'~~~~~'--.",
};

const woman = [_][]const u8{
    "    ,-~~~-.",
    "  ,~'     '~.",
    " (~ --   -- ~)",
    " (~  \u{2022}   \u{2022}  ~)",
    " (~    .    ~)",
    " (~\\  \\_/  /~)",
    " (~ '-._.-' ~)",
    " (~~  | |  ~~)",
    "  (~.-' '-.~)",
    " ,'   \\_/   '.",
};

const child = [_][]const u8{
    "    ,v.",
    "  .-~~~-.",
    " /       \\",
    "(  \u{2022}   \u{2022}  )",
    "(    .    )",
    " \\  \\_/  /",
    "  '-._.-'",
    " ,-'   '-.",
};

const hat = [_][]const u8{
    "    _______",
    "   |_______|",
    " .-'-------'-.",
    "  | --   -- |",
    " (|  \u{2022}   \u{2022}  |)",
    "  |    L    |",
    "  | '~~v~~' |",
    "   \\  \\_/  /",
    "    '-----'",
    "  .--'   '--.",
};

/// Where a face sits around the fire, the row of its art the eyes are on, and when its
/// owner first shows on the horizon; the first is there from the start.
const Person = struct {
    art: []const []const u8,
    x: i32,
    top: i32,
    eyes: usize,
    arrive: ?f32 = null,
    small: bool = false,

    /// When the face begins to come into the light.
    fn appear(self: Person) f32 {
        return if (self.arrive) |a| a + approach_s else -10;
    }
};
const people = [_]Person{
    .{ .art = &you, .x = 22, .top = 10, .eyes = 3 },
    .{ .art = &elder, .x = 42, .top = 7, .eyes = 3, .arrive = 2.5 },
    .{ .art = &woman, .x = 62, .top = 10, .eyes = 3, .arrive = 8 },
    .{ .art = &child, .x = 82, .top = 19, .eyes = 3, .arrive = 8.8, .small = true },
    .{ .art = &hat, .x = 4, .top = 15, .eyes = 4, .arrive = 14.5 },
};

/// A figure in the doorway, far to near: its art, the row its feet are on, its ink.
const Step = struct { art: []const []const u8, foot: i32, ink: Ink };
const walker = [4]Step{
    .{ .art = &.{"."}, .foot = 13, .ink = .far },
    .{ .art = &.{"i"}, .foot = 14, .ink = .near },
    .{ .art = &.{ "o", "A" }, .foot = 15, .ink = .near },
    .{ .art = &.{ " o ", "/|\\", "/ \\" }, .foot = 16, .ink = .bright },
};
const small_walker = [4]Step{
    .{ .art = &.{"."}, .foot = 13, .ink = .far },
    .{ .art = &.{"."}, .foot = 14, .ink = .far },
    .{ .art = &.{"i"}, .foot = 15, .ink = .near },
    .{ .art = &.{ "o", "A" }, .foot = 16, .ink = .bright },
};

const flames = [3][4][]const u8{
    .{ "     )     ", "    ( )    ", "   ) ( (   ", "  ( ) ) )  " },
    .{ "    (      ", "   ) ) (   ", "  ( ( ) )  ", "  ) ) ( (  " },
    .{ "      (    ", "    ) )    ", "   ( ( ) ) ", "  ( ) ( )  " },
};
const logs = " ==#===#== ";

fn line(g: *Cells, y: i32, x0: i32, x1: i32, cp: u21, ink: Ink) void {
    var x = x0;
    while (x <= x1) : (x += 1) g.put(x, y, cp, ink.id());
}

/// The room: everything that does not move.
fn room() Cells {
    var g = Cells.init(t.scene_cols, t.scene_rows);
    var rng = Rng{ .seed = 1949 };

    // The roof and the frame it rests on.
    const straw = [_]u21{ '/', '\\', '|', '/', '\\' };
    var x: i32 = 0;
    while (x < w) : (x += 1) {
        const cp = straw[@intCast(rng.below(5))];
        g.put(x, 0, cp, (if (rng.next() < 0.5) Ink.faint else Ink.far).id());
    }
    line(&g, 1, 0, w - 1, '=', .far);
    var y: i32 = 2;
    while (y < h) : (y += 1) {
        for ([_]i32{ 1, 2, 97, 98 }) |px| g.put(px, y, '|', Ink.far.id());
    }

    // What hangs from the beam: a rope bag, a bundle of herbs.
    g.stamp(&.{ " | ", "(#)", "(#)", " v " }, 12, 5, Ink.far.id(), null);
    g.stamp(&.{ " | ", "\\|/", "/|\\" }, 67, 4, Ink.far.id(), null);

    // The doorway, and the valley outside it.
    line(&g, door.y0 - 1, door.x0, door.x1, '_', .near);
    y = door.y0;
    while (y <= door.y1) : (y += 1) {
        g.put(door.x0 - 1, y, '|', Ink.near.id());
        g.put(door.x1 + 1, y, '|', Ink.near.id());
    }
    line(&g, 13, door.x0, door.x1, '_', .far);
    g.put(83, 13, '/', Ink.far.id());
    g.put(86, 13, '\\', Ink.far.id());
    g.put(84, 13, ' ', 0);
    g.put(85, 13, ' ', 0);
    g.put(84, 12, '/', Ink.far.id());
    g.put(85, 12, '\\', Ink.far.id());
    line(&g, door.y1, door.x0, door.x1, '_', .near);

    // The floor.
    const specks = [_]u21{ '.', ',', '\'' };
    y = 29;
    while (y < h) : (y += 1) {
        x = 4;
        while (x < 96) : (x += 1) {
            if (rng.next() < 0.04) g.put(x, y, specks[@intCast(rng.below(3))], Ink.far.id());
        }
    }
    return g;
}

/// Whether person `n` has their eyes shut at `seconds`: one blink somewhere in each stretch
/// of a few seconds, the stretch and the moment the person's own.
fn blinking(n: usize, seconds: f32) bool {
    const stretch: f32 = 3.1 + 0.7 * @as(f32, @floatFromInt(n));
    const k: u32 = @intFromFloat(@floor(@max(0, seconds) / stretch));
    const at = @as(f32, @floatCast(Rng.of(@as(u32, @intCast(n)) * 1009 + k * 31 + 7))) * (stretch - blink_s);
    const into = seconds - @as(f32, @floatFromInt(k)) * stretch - at;
    return into >= 0 and into < blink_s;
}

/// Which way the one at the fire is looking at `seconds`: toward the newest face still
/// coming into the light, or 0 for straight ahead.
fn glance(seconds: f32) i32 {
    var dir: i32 = 0;
    for (people[1..]) |p| {
        const since = seconds - p.appear();
        if (since >= 0 and since < glance_s) dir = std.math.sign(p.x - people[0].x);
    }
    return dir;
}

/// Write one row of a face, with its eyes shut, moved a cell to a side, or as drawn.
fn faceRow(g: *Cells, row: []const u8, x: i32, y: i32, ink: Ink, shut: bool, look: i32) void {
    var cps: [32]u21 = undefined;
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(row) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n == cps.len) break;
        cps[n] = cp;
        n += 1;
    }
    const first = std.mem.indexOfScalar(u21, cps[0..n], eye);
    const last = std.mem.lastIndexOfScalar(u21, cps[0..n], eye);
    if (first != null and last != null) {
        if (shut) {
            for (cps[0..n]) |*cp| {
                if (cp.* == eye) cp.* = '-';
            }
        } else if (look < 0 and first.? > 0) {
            // The pair of eyes, with whatever is between them, one cell left.
            std.mem.copyForwards(u21, cps[first.? - 1 .. last.?], cps[first.? .. last.? + 1]);
            cps[last.?] = ' ';
        } else if (look > 0 and last.? + 1 < n) {
            std.mem.copyBackwards(u21, cps[first.? + 1 .. last.? + 2], cps[first.? .. last.? + 1]);
            cps[first.?] = ' ';
        }
    }
    for (cps[0..n], 0..) |cp, c| {
        if (cp != ' ') g.put(x + @as(i32, @intCast(c)), y, cp, ink.id());
    }
}

/// The scene `seconds` in.
pub fn compose(seconds: f32) Cells {
    var g = room();

    // Outside, through the doorway: the snow, and whoever is on the way in.
    var snow = Rng{ .seed = 11 };
    for (0..12) |_| {
        const x0 = snow.next() * 13;
        const y0 = snow.next() * 11;
        const fall = 2.5 + snow.next() * 2;
        const fx = @mod(x0 - 3 * @as(f64, seconds), 13);
        const fy = @mod(y0 + fall * @as(f64, seconds), 11);
        g.put(door.x0 + @as(i32, @intFromFloat(@floor(fx))), door.y0 + @as(i32, @intFromFloat(@floor(fy))), '.', Ink.far.id());
    }
    for (people) |p| {
        const age = seconds - (p.arrive orelse continue);
        if (age < 0 or age >= approach_s) continue;
        const stage: usize = @intFromFloat(@floor(age / (approach_s / 4)));
        const pose = (if (p.small) small_walker else walker)[@min(stage, 3)];
        const centre: i32 = (if (p.small) @as(i32, 91) else 88) - @as(i32, @intCast(stage));
        const left = centre - @as(i32, @intCast(pose.art[0].len / 2));
        if (pose.art.len == 3 and @mod(@as(i32, @intFromFloat(@floor(age * 5))), 2) == 1) {
            // Mid-stride: the legs together.
            g.stamp(&.{ pose.art[0], pose.art[1], " | " }, left, pose.foot, pose.ink.id(), door);
        } else {
            g.stamp(pose.art, left, pose.foot, pose.ink.id(), door);
        }
    }

    // The fire: a new flame shape several times a second, and sparks that rise and die.
    const tick: u32 = @intFromFloat(@floor(@max(0, seconds) * 7));
    const flame = flames[@intCast(@as(i32, @intFromFloat(@floor(Rng.of(tick) * 3))))];
    g.stamp(flame[0..3], fire_x, fire_foot - 1, Ink.flame.id(), null);
    g.stamp(flame[3..4], fire_x, fire_foot, Ink.ember.id(), null);
    for (logs, 0..) |c, i| g.put(fire_x + @as(i32, @intCast(i)), fire_foot + 1, c, (if (c == '#') Ink.ember else Ink.near).id());

    const newest: i32 = @intFromFloat(@floor(@max(0, seconds) / 0.22));
    var k = newest;
    while (k > newest - 10 and k >= 0) : (k -= 1) {
        var r = Rng{ .seed = @intCast(k * 7919 + 101) };
        const from = @as(f64, @floatFromInt(fire_x)) + 3 + r.next() * 5;
        const rise = 2.5 + r.next() * 2.5;
        const sway = (r.next() - 0.5) * 1.6;
        const life = 0.8 + r.next() * 1.2;
        const age = @as(f64, seconds) - @as(f64, @floatFromInt(k)) * 0.22;
        const sy = @as(f64, @floatFromInt(fire_foot)) - 3.5 - rise * age;
        if (age >= life or sy < 17.5) continue;
        const spent = age / life;
        const ink: Ink = if (spent < 0.4) .flame else if (spent < 0.75) .warm else .near;
        g.put(@intFromFloat(@floor(from + sway * age)), @intFromFloat(@floor(sy)), if (spent < 0.5) '\'' else '.', ink.id());
    }

    // The faces: each comes out of the dark into the firelight.
    const smiling = seconds >= people[1].appear() + lit_s;
    const look = glance(seconds);
    for (people, 0..) |p, n| {
        const shown = seconds - p.appear();
        if (shown < 0) continue;
        const ink: Ink = if (shown < 0.5) .faint else if (shown < 1.0) .far else if (shown < lit_s) .near else .warm;
        for (p.art, 0..) |row, r| {
            const text = if (n == 0 and smiling and r == you_mouth_row) you_smile else row;
            const on_eyes = r == p.eyes;
            faceRow(&g, text, p.x, p.top + @as(i32, @intCast(r)), ink, on_eyes and blinking(n, seconds), if (on_eyes and n == 0) look else 0);
        }
    }
    return g;
}

const testing = std.testing;

fn count(g: *const Cells, cp: u21, x0: i32, y0: i32, x1: i32, y1: i32) usize {
    var n: usize = 0;
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            if (g.at(x, y)) |c| n += @intFromBool(c.cp == cp);
        }
    }
    return n;
}

/// A moment at or after `from` when person `n` is not blinking.
fn eyesOpen(n: usize, from: f32) f32 {
    var s = from;
    while (blinking(n, s)) s += 0.05;
    return s;
}

test "shelter: the scene is the same for the same time" {
    const a = compose(12.4);
    const b = compose(12.4);
    try testing.expectEqualSlices(u8, a.ink[0..a.count()], b.ink[0..b.count()]);
    for (a.ink[0..a.count()], 0..) |k, i| if (k != 0) try testing.expectEqual(a.glyph[i], b.glyph[i]);
}

test "shelter: the room has its beam, its posts and its doorway" {
    const g = room();
    try testing.expectEqual(@as(usize, 100), count(&g, '=', 0, 1, 99, 1));
    try testing.expectEqual(@as(u21, '|'), g.at(1, 20).?.cp);
    try testing.expectEqual(@as(u21, '|'), g.at(98, 20).?.cp);
    try testing.expectEqual(@as(u21, '|'), g.at(door.x0 - 1, door.y0).?.cp);
    try testing.expectEqual(@as(u21, '|'), g.at(door.x1 + 1, door.y1).?.cp);
    // The peak outside.
    try testing.expectEqual(@as(u21, '/'), g.at(84, 12).?.cp);
    try testing.expectEqual(@as(u21, '\\'), g.at(85, 12).?.cp);
}

test "shelter: one face at the start, five at the end, each in the firelight" {
    const start = eyesOpen(0, 0.5);
    const alone = compose(start);
    try testing.expectEqual(@as(usize, 2), count(&alone, eye, 0, 0, 79, 31));

    var end = played_s;
    while (blinking(0, end) or blinking(1, end) or blinking(2, end) or blinking(3, end) or blinking(4, end)) end += 0.05;
    const full = compose(end);
    try testing.expectEqual(@as(usize, 10), count(&full, eye, 0, 0, 99, 31));
    // The one who was there from the start is lit warm.
    try testing.expectEqual(Ink.warm.id(), full.at(22 + 1, 10 + 2).?.ink);
}

test "shelter: a face comes out of the dark as its owner reaches the threshold" {
    const e = people[1];
    try testing.expect(compose(e.appear() - 0.1).at(e.x + 1, e.top + 2) == null);
    try testing.expectEqual(Ink.faint.id(), compose(e.appear() + 0.1).at(e.x + 1, e.top + 2).?.ink);
    try testing.expectEqual(Ink.far.id(), compose(e.appear() + 0.7).at(e.x + 1, e.top + 2).?.ink);
    try testing.expectEqual(Ink.near.id(), compose(e.appear() + 1.3).at(e.x + 1, e.top + 2).?.ink);
    try testing.expectEqual(Ink.warm.id(), compose(e.appear() + 2.0).at(e.x + 1, e.top + 2).?.ink);
}

test "shelter: a newcomer walks up in the doorway, and nothing of them shows outside it" {
    const e = people[1];
    // Far: a dot on the horizon.
    const far = compose(e.arrive.? + 0.1);
    try testing.expectEqual(@as(u21, '.'), far.at(88, 13).?.cp);
    // Near: a whole figure at the threshold, in the foreground ink.
    const near = compose(e.arrive.? + approach_s - 0.3);
    try testing.expectEqual(@as(usize, 1), count(&near, 'o', door.x0, door.y0, door.x1, door.y1));
    try testing.expectEqual(Ink.bright.id(), near.at(85, 14).?.ink);
    // Gone once inside.
    const inside = compose(e.arrive.? + approach_s + 0.1);
    try testing.expectEqual(@as(usize, 0), count(&inside, 'o', door.x0, door.y0, door.x1, door.y1));
}

test "shelter: the one at the fire looks at each newcomer, then straight ahead" {
    try testing.expectEqual(@as(i32, 0), glance(1));
    // The elder sits to the right, the man in the hat to the left.
    try testing.expectEqual(@as(i32, 1), glance(people[1].appear() + 0.5));
    try testing.expectEqual(@as(i32, -1), glance(people[4].appear() + 0.5));
    try testing.expectEqual(@as(i32, 0), glance(people[4].appear() + glance_s + 0.1));

    // Looking right moves the eyes a cell right: from five and nine cells in to six and ten.
    const at = eyesOpen(0, people[1].appear() + 0.3);
    const g = compose(at);
    try testing.expect(g.at(22 + 5, 13) == null);
    try testing.expectEqual(eye, g.at(22 + 6, 13).?.cp);
    try testing.expectEqual(eye, g.at(22 + 10, 13).?.cp);
}

test "shelter: the one at the fire smiles once the first newcomer is lit" {
    const before = compose(people[1].appear() + lit_s - 0.2);
    try testing.expectEqual(@as(u21, '-'), before.at(22 + 7, 10 + 5).?.cp);
    const after = compose(people[1].appear() + lit_s + 0.2);
    try testing.expectEqual(@as(u21, '_'), after.at(22 + 7, 10 + 5).?.cp);
}

test "shelter: everyone blinks, briefly" {
    for (0..people.len) |n| {
        var shut: usize = 0;
        var total: usize = 0;
        var s: f32 = 0;
        while (s < 30) : (s += 0.02) {
            shut += @intFromBool(blinking(n, s));
            total += 1;
        }
        try testing.expect(shut > 0);
        try testing.expect(shut * 10 < total);
    }
    // A blink shuts both eyes.
    var s: f32 = 0;
    while (!blinking(0, s)) s += 0.02;
    const g = compose(s);
    try testing.expectEqual(@as(usize, 0), count(&g, eye, 22, 13, 36, 13));
    try testing.expectEqual(@as(u21, '-'), g.at(22 + 5, 13).?.cp);
}

test "shelter: the scene shows fewer distinct glyphs than a grid can cache" {
    const g = compose(played_s);
    var seen = std.AutoHashMap(u16, void).init(testing.allocator);
    defer seen.deinit();
    for (g.ink[0..g.count()], g.glyph[0..g.count()]) |k, cp| if (k != 0) try seen.put(cp, {});
    try testing.expect(seen.count() < 100);
}
