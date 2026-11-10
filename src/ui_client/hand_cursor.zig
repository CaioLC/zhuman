//! The open-hand and closed-hand cursor art, authored as pixel maps and converted to RGBA
//! at compile time. `.` is transparent, `#` the black outline, `o` the white fill. Each map
//! is `size` x `size` logical pixels; `rgba(art, 2)` is its nearest-neighbour doubling, the
//! alternate image SDL picks on a 2x display. Pure data and SDL-free.

const std = @import("std");

pub const size = 32;

pub const Art = struct {
    rows: [size]*const [size]u8,
    hot_x: u8,
    hot_y: u8,
};

/// An open hand, palm toward the viewer, fingers together and the thumb out to the left.
pub const open_hand: Art = .{
    .hot_x = 16,
    .hot_y = 16,
    .rows = .{
        "................................",
        "................................",
        "................................",
        "................................",
        "..............###...............",
        "..........####ooo####...........",
        ".........#ooo#ooo#ooo#..........",
        ".........#ooo#ooo#ooo####.......",
        ".........#ooo#ooo#ooo#ooo#......",
        ".........#ooo#ooo#ooo#ooo#......",
        ".....##..#ooo#ooo#ooo#ooo#......",
        "....#oo#.#ooo#ooo#ooo#ooo#......",
        "....#ooo##ooo#ooo#ooo#ooo#......",
        ".....#ooo#ooo#ooo#ooo#ooo#......",
        "......#oooooo#ooo#ooo#ooo#......",
        ".......#ooooooooooooooooo#......",
        "........#oooooooooooooooo#......",
        ".........#ooooooooooooooo#......",
        "..........#ooooooooooooo#.......",
        "..........#oooooooooooo#........",
        "...........#ooooooooooo#........",
        "...........#ooooooooooo#........",
        "...........#############........",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
    },
};

/// A closed hand seen from the back: the knuckles of the curled fingers on top, the pinky's
/// lower at the right, the folded thumb bulging at the left.
pub const closed_hand: Art = .{
    .hot_x = 16,
    .hot_y = 16,
    .rows = .{
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "...........###.###.###..........",
        "..........#ooo#ooo#ooo###.......",
        "..........#ooo#ooo#ooo#oo#......",
        "...........#ooooooooooooo#......",
        ".........###ooooooooooooo#......",
        "........#oooooooooooooooo#......",
        "........#oooooooooooooooo#......",
        ".........#ooooooooooooooo#......",
        "..........#oooooooooooooo#......",
        "...........#oooooooooooo#.......",
        "............#ooooooooooo#.......",
        "............#ooooooooooo#.......",
        "............#############.......",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
    },
};

/// The RGBA8 bytes (row-major, R G B A per pixel) of `art` at `scale` times its logical size.
pub fn rgba(comptime art: Art, comptime scale: usize) [size * scale * size * scale * 4]u8 {
    @setEvalBranchQuota(200_000);
    const side = size * scale;
    var out: [side * side * 4]u8 = undefined;
    for (0..side) |y| {
        for (0..side) |x| {
            const px: [4]u8 = switch (art.rows[y / scale][x / scale]) {
                '.' => .{ 0, 0, 0, 0 },
                '#' => .{ 0, 0, 0, 255 },
                'o' => .{ 255, 255, 255, 255 },
                else => @compileError("hand cursor art uses only '.', '#' and 'o'"),
            };
            @memcpy(out[(y * side + x) * 4 ..][0..4], &px);
        }
    }
    return out;
}

/// The number of non-transparent pixels in `art`.
fn coverage(art: Art) usize {
    var n: usize = 0;
    for (art.rows) |row| {
        for (row) |ch| n += @intFromBool(ch != '.');
    }
    return n;
}

test "each hand holds its hotspot on the white palm" {
    for ([_]Art{ open_hand, closed_hand }) |art| {
        try std.testing.expectEqual(@as(u8, 'o'), art.rows[art.hot_y][art.hot_x]);
    }
}

test "each hand's outline is closed: no white pixel touches a transparent one" {
    for ([_]Art{ open_hand, closed_hand }) |art| {
        for (art.rows, 0..) |row, y| {
            for (row, 0..) |ch, x| {
                if (ch != 'o') continue;
                // An edge-touching white pixel would also be an open outline.
                try std.testing.expect(x > 0 and y > 0 and x < size - 1 and y < size - 1);
                try std.testing.expect(art.rows[y - 1][x] != '.' and art.rows[y + 1][x] != '.');
                try std.testing.expect(row[x - 1] != '.' and row[x + 1] != '.');
            }
        }
    }
}

test "the closed hand is visibly smaller than the open one" {
    try std.testing.expect(coverage(closed_hand) * 4 < coverage(open_hand) * 3);
}

test "rgba maps the art's three marks and doubles by nearest neighbour" {
    const one = comptime rgba(open_hand, 1);
    const two = comptime rgba(open_hand, 2);
    const at = struct {
        fn px(bytes: []const u8, side: usize, x: usize, y: usize) [4]u8 {
            return bytes[(y * side + x) * 4 ..][0..4].*;
        }
    }.px;
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, at(&one, size, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(&one, size, 16, 16));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(&one, size, 14, 4));
    for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |d| {
        try std.testing.expectEqual(at(&one, size, 14, 4), at(&two, size * 2, 28 + d[0], 8 + d[1]));
    }
}
