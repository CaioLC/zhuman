//! The thank-you (`prototypes/thanks.html`): the scene the Act I demo ends on. It is the
//! valley of the arrival, seen from the same place, with the shelter standing where the
//! figure sat down. Smoke rises from the roof, the windows and the door are lit, and the
//! people are outside at a fire: the one who came alone waves now and then, the elder sits,
//! two stand, and the child runs back and forth in front of the shelter. The thanks and the
//! credits come up in the sky a line at a time, clearing the stars behind them.
//!
//! The scene is a pure function of how long it has been showing (`SceneState.seconds`).
//! `TITLE \u{2192}` goes back to the title screen, `REPLAY` starts the scene over, and a click on
//! the scene skips to its end.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const t = @import("./templates/root.zig");
const valley = @import("./valley.zig");

const Cells = t.SceneCells;
const Ink = t.SceneInk;
const Rng = valley.Rng;

const hut_x: i32 = 48;
const hut_foot: i32 = 27;
const fire_x: i32 = 36;
const fire_foot: i32 = 29;

const caption = [2][]const u8{ "Human Action \u{00b7} the Act I demo ends here.", "Thank you for testing it." };
const caption_s: f32 = 16;
const played_s: f32 = caption_s + 5;

// The shelter in three layers: its outline, the thatch, and what is lit from inside.
const hut = [_][]const u8{
    "       /\\       ",
    "      /  \\      ",
    "    _/    \\_    ",
    "   /        \\   ",
    "  /          \\  ",
    " /            \\ ",
    "/______________\\",
    " |     __     | ",
    " |    |  |    | ",
    " |____|  |____| ",
};
const thatch = [_][]const u8{
    "       ::       ",
    "      ::::      ",
    "    ::::::::    ",
    "   ::::::::::   ",
    "  ::::::::::::  ",
    "",
    "",
    "",
    "",
};
const lit = [_][]const u8{
    "   []  ::  []   ",
    "       ::       ",
};

const flames = [3][2][]const u8{
    .{ " ) ", "(()" },
    .{ " ( ", "())" },
    .{ "  )", ")((" },
};

/// What comes up in the sky, and when. A line is centred text in one ink, or a credit: a
/// role and a name either side of a dot on the middle column.
const SkyLine = struct {
    row: i32,
    at: f32,
    text: []const u8 = "",
    ink: Ink = .near,
    role: []const u8 = "",
    name: []const u8 = "",
};
const sky = [_]SkyLine{
    .{ .row = 2, .at = 2, .text = "T H A N K   Y O U   F O R   P L A Y I N G", .ink = .bright },
    .{ .row = 4, .at = 5, .text = "A game about what people do when they cannot have everything.", .ink = .near },
    .{ .row = 6, .at = 8, .role = "Design and code", .name = "Caio Lacerda de Castro" },
    .{ .row = 7, .at = 9, .role = "Built with", .name = "Zig and SDL3, no engine" },
    .{ .row = 8, .at = 10, .role = "Typeface", .name = "JetBrains Mono" },
    .{ .row = 10, .at = 13, .text = "Named after a long book by Ludwig von Mises. You don't have to read it.", .ink = .far },
};

/// Empty the cells a block of art covers, each row from its first mark to its last, so what
/// stands behind it does not show through.
fn solid(g: *Cells, lines: []const []const u8, x: i32, foot: i32) void {
    const top = foot - @as(i32, @intCast(lines.len)) + 1;
    for (lines, 0..) |line, r| {
        const first = std.mem.indexOfNone(u8, line, " ") orelse continue;
        const last = std.mem.lastIndexOfNone(u8, line, " ") orelse continue;
        var c = first;
        while (c <= last) : (c += 1) g.put(x + @as(i32, @intCast(c)), top + @as(i32, @intCast(r)), ' ', 0);
    }
}

/// A line of the sky, coming up out of the dark: `shown` is how long it has been showing.
/// It clears its own span and a cell either side, so no star twinkles between its words.
fn write(g: *Cells, x: i32, row: i32, text: []const u8, ink: Ink, shown: f32) void {
    if (shown < 0) return;
    const risen: Ink = if (shown < 0.4) .faint else if (shown < 0.8) .far else if (shown < 1.2) .near else .bright;
    const now = @min(ink.id(), risen.id());
    g.put(x - 1, row, ' ', 0);
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    var col = x;
    while (it.nextCodepoint()) |cp| : (col += 1) g.put(col, row, cp, now);
    g.put(col, row, ' ', 0);
}

/// The scene `seconds` in.
fn compose(seconds: f32) Cells {
    var g = valley.ground(seconds);

    for (sky) |line| {
        const shown = seconds - line.at;
        if (line.role.len > 0) {
            // Roles end and names begin either side of the middle column.
            write(&g, 48 - @as(i32, @intCast(line.role.len)), line.row, line.role, .far, shown);
            write(&g, 49, line.row, "\u{00b7}", .far, shown);
            write(&g, 51, line.row, line.name, .near, shown);
        } else {
            write(&g, @divFloor(valley.w - @as(i32, @intCast(line.text.len)), 2), line.row, line.text, line.ink, shown);
        }
    }

    // Smoke from the roof: a puff every so often, rising, drifting and thinning.
    const newest: i32 = @intFromFloat(@floor(seconds / 0.45));
    var k = newest;
    while (k > newest - 11 and k >= 0) : (k -= 1) {
        const age: f64 = seconds - @as(f32, @floatFromInt(k)) * 0.45;
        const sway = Rng.of(@intCast(k * 7919 + 13)) * 6;
        const x = @as(f64, @floatFromInt(hut_x)) + 7.5 + age * 0.9 + @sin(age * 1.3 + sway) * 0.8;
        const y = @as(f64, @floatFromInt(hut_foot)) - 10 - age * 1.1;
        const cp: u21 = if (age < 1.5) (if (@mod(k, 2) == 1) '(' else ')') else if (age < 3.5) '~' else '.';
        const ink: Ink = if (age < 2) .near else if (age < 4) .far else .faint;
        g.put(@intFromFloat(@floor(x)), @intFromFloat(@floor(y)), cp, ink.id());
    }

    // The shelter, in front of the trees behind it.
    valley.trees(&g, 0, hut_foot);
    solid(&g, &hut, hut_x, hut_foot);
    g.stamp(&thatch, hut_x, hut_foot, Ink.far.id(), null);
    g.stamp(&hut, hut_x, hut_foot, Ink.near.id(), null);
    // The firelight inside wavers.
    const glow: Ink = if (Rng.of(tick(seconds, 5)) < 0.2) .warm else .flame;
    g.stamp(&lit, hut_x, hut_foot, glow.id(), null);

    valley.trees(&g, hut_foot, fire_foot);

    // The fire, and the two beside it: the one who came alone, on the left, waves now and
    // then; the elder sits.
    const flame = flames[@intCast(@as(i32, @intFromFloat(@floor(Rng.of(tick(seconds, 7)) * 3))))];
    g.stamp(flame[0..1], fire_x, fire_foot - 1, Ink.flame.id(), null);
    g.stamp(flame[1..2], fire_x, fire_foot, Ink.ember.id(), null);

    const beat = @mod(seconds, 8);
    const waving = beat >= 3 and beat < 5.5;
    const up = waving and @mod(@as(i32, @intFromFloat(@floor(seconds / 0.35))), 2) == 1;
    const head: []const u8 = if (up) " o/" else if (waving) " o|" else " o ";
    g.stamp(&.{ head, if (waving) "/| " else "/|\\", "/ \\" }, 31, 29, Ink.bright.id(), null);
    g.stamp(&.{ " o ", "_|)" }, 40, 29, Ink.warm.id(), null);

    valley.trees(&g, fire_foot, valley.h);

    // The two who stand, and the child running back and forth in front of the shelter.
    g.stamp(&.{ "_o_", "/|\\", "/ \\" }, 26, 30, Ink.warm.id(), null);
    g.stamp(&.{ " o ", "/|\\", "/_\\" }, 44, 30, Ink.warm.id(), null);
    const lap = @mod(seconds, 9) / 9;
    const along = if (lap < 0.5) lap * 2 else 2 - lap * 2;
    const child_x: i32 = @intFromFloat(@round(48 + along * 12));
    g.stamp(&.{ " o ", if (@mod(child_x, 2) == 1) " A " else " | " }, child_x, 30, Ink.warm.id(), null);
    return g;
}

/// Which of `per_second` equal slices of a second `seconds` is in: the seed for something
/// that changes that many times a second.
fn tick(seconds: f32, per_second: f32) u32 {
    return @intFromFloat(@floor(@max(0, seconds) * per_second));
}

pub fn ui_thanks(ctx: *uic.UiCtx) !uic.Trees {
    const clock = &ctx.res.scene.seconds;
    clock.* += ctx.res.game.time.real_dt;

    const cells = compose(clock.*);
    const s = try t.scene(ctx, "thanks", .{
        .cells = &cells,
        .caption = caption,
        .caption_s = clock.* - caption_s,
        .go = "TITLE \u{2192}",
    });
    if (s.skip) clock.* = @max(clock.*, played_s);
    if (s.replay) clock.* = 0;
    if (s.go) ctx.res.fade.to(.title);
    return try uic.oneRoot(ctx.arena, s.root);
}

const testing = std.testing;

fn rowText(g: *const Cells, row: i32, from: i32, buf: []u8) []const u8 {
    var n: usize = 0;
    var x = from;
    while (x < valley.w and n < buf.len) : (x += 1) {
        const c = g.at(x, row) orelse {
            buf[n] = ' ';
            n += 1;
            continue;
        };
        buf[n] = if (c.cp < 0x80) @intCast(c.cp) else '?';
        n += 1;
    }
    return buf[0..n];
}

test "thanks: the scene is the same for the same time" {
    const a = compose(11.7);
    const b = compose(11.7);
    try testing.expectEqualSlices(u8, a.ink[0..a.count()], b.ink[0..b.count()]);
    for (a.ink[0..a.count()], 0..) |k, i| if (k != 0) try testing.expectEqual(a.glyph[i], b.glyph[i]);
}

test "thanks: the sky is empty of words at first and holds every line at the end" {
    var buf: [100]u8 = undefined;
    const early = compose(1);
    try testing.expect(std.mem.indexOf(u8, rowText(&early, 2, 0, &buf), "T H A N K") == null);

    const late = compose(played_s);
    try testing.expect(std.mem.indexOf(u8, rowText(&late, 2, 0, &buf), "T H A N K   Y O U   F O R   P L A Y I N G") != null);
    try testing.expectEqual(Ink.bright.id(), late.at(29, 2).?.ink);
    try testing.expect(std.mem.indexOf(u8, rowText(&late, 4, 0, &buf), "they cannot have everything.") != null);
    // A credit: the role ends before the middle dot, the name begins after it.
    try testing.expectEqualStrings("Design and code ? Caio Lacerda de Castro", std.mem.trim(u8, rowText(&late, 6, 33, &buf)[0..41], " "));
    try testing.expectEqual(Ink.far.id(), late.at(33, 6).?.ink);
    try testing.expectEqual(Ink.near.id(), late.at(51, 6).?.ink);
    try testing.expect(std.mem.indexOf(u8, rowText(&late, 10, 0, &buf), "Ludwig von Mises") != null);
}

test "thanks: a line comes up out of the dark" {
    try testing.expectEqual(Ink.faint.id(), compose(2.1).at(29, 2).?.ink);
    try testing.expectEqual(Ink.far.id(), compose(2.5).at(29, 2).?.ink);
    try testing.expectEqual(Ink.near.id(), compose(3.0).at(29, 2).?.ink);
    try testing.expectEqual(Ink.bright.id(), compose(3.5).at(29, 2).?.ink);
}

test "thanks: the shelter stands where the figure sat, opaque, with its windows lit" {
    const g = compose(20);
    // The gable's apex, and the wall's foot.
    try testing.expectEqual(@as(u21, '/'), g.at(hut_x + 7, hut_foot - 9).?.cp);
    try testing.expectEqual(@as(u21, '\\'), g.at(hut_x + 8, hut_foot - 9).?.cp);
    try testing.expectEqual(@as(u21, '|'), g.at(hut_x + 1, hut_foot).?.cp);
    // A window, in a firelight ink.
    const window = g.at(hut_x + 3, hut_foot - 1).?;
    try testing.expectEqual(@as(u21, '['), window.cp);
    try testing.expect(window.ink == Ink.flame.id() or window.ink == Ink.warm.id());
    // The horizon line does not run through the shelter: the cell inside the roof on the
    // horizon's row holds thatch.
    try testing.expectEqual(@as(u21, ':'), g.at(hut_x + 7, valley.horizon).?.cp);
}

test "thanks: the one who came alone is in the foreground ink and waves now and then" {
    const still = compose(1);
    try testing.expectEqual(@as(u21, 'o'), still.at(32, 27).?.cp);
    try testing.expectEqual(Ink.bright.id(), still.at(32, 27).?.ink);
    try testing.expect(still.at(33, 27) == null);
    // Waving: an arm is up beside the head.
    try testing.expect(compose(4).at(33, 27) != null);
}

test "thanks: the child stays in front of the shelter" {
    var s: f32 = 0;
    while (s < 18) : (s += 0.25) {
        const g = compose(s);
        var found = false;
        var x: i32 = 48;
        while (x <= 62) : (x += 1) {
            if (g.at(x, 29)) |c| found = found or (c.cp == 'o' and c.ink == Ink.warm.id());
        }
        try testing.expect(found);
    }
}

test "thanks: the scene shows fewer distinct glyphs than a grid can cache" {
    const g = compose(played_s);
    var seen = std.AutoHashMap(u16, void).init(testing.allocator);
    defer seen.deinit();
    for (g.ink[0..g.count()], g.glyph[0..g.count()]) |k, cp| if (k != 0) try seen.put(cp, {});
    try testing.expect(seen.count() < 100);
}
