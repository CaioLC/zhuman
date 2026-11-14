//! `glyph_cells` — the **pure, SDL-free** cell buffer the `glyph_grid` feature paints: a grid
//! of monospace cells, each one glyph and one ink.
//!
//! An ink is an index into a palette the feature is given beside the cells, so whoever
//! composes a grid names roles (faint, near, flame) and the colors arrive at attach. Ink 0
//! is the empty cell.
//!
//! A grid is composed by writing over it: `put` one cell, `stamp` a block of art. Later
//! writes cover earlier ones, a space in stamped art leaves the cell under it alone, and a
//! write outside the grid is dropped, so a sprite can walk in from off the edge.

const std = @import("std");

/// A rectangle of cells, inclusive on every side, that a `stamp` stays inside.
pub const Clip = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

pub const Cells = struct {
    /// The most cells a grid holds. A grid asked for more is **refused whole** — it is
    /// 0 × 0 and every write to it is dropped — the refusal the text and geometry states
    /// share.
    pub const cap = 4096;

    cols: u16 = 0,
    rows: u16 = 0,
    /// The codepoint in each cell, row by row. Basic Multilingual Plane only.
    glyph: [cap]u16 = undefined,
    /// The ink of each cell; 0 is empty.
    ink: [cap]u8 = @splat(0),

    /// An empty `cols` × `rows` grid, or the 0 × 0 grid when that is more than `cap` cells.
    pub fn init(cols: u16, rows: u16) Cells {
        if (@as(usize, cols) * rows > cap) return .{};
        return .{ .cols = cols, .rows = rows };
    }

    pub fn count(self: *const Cells) usize {
        return @as(usize, self.cols) * self.rows;
    }

    /// Empty every cell.
    pub fn clear(self: *Cells) void {
        @memset(self.ink[0..self.count()], 0);
    }

    /// Write one cell. A space, ink 0, a codepoint outside the BMP or a position outside
    /// the grid empties the cell or is dropped; none is an error.
    pub fn put(self: *Cells, x: i32, y: i32, cp: u21, ink: u8) void {
        if (x < 0 or y < 0 or x >= self.cols or y >= self.rows) return;
        const i = @as(usize, @intCast(y)) * self.cols + @as(usize, @intCast(x));
        if (cp == ' ' or cp > 0xFFFF or ink == 0) {
            self.ink[i] = 0;
            return;
        }
        self.glyph[i] = @intCast(cp);
        self.ink[i] = ink;
    }

    /// The codepoint and ink at a cell, or null when it is empty or outside the grid.
    pub fn at(self: *const Cells, x: i32, y: i32) ?struct { cp: u21, ink: u8 } {
        if (x < 0 or y < 0 or x >= self.cols or y >= self.rows) return null;
        const i = @as(usize, @intCast(y)) * self.cols + @as(usize, @intCast(x));
        if (self.ink[i] == 0) return null;
        return .{ .cp = self.glyph[i], .ink = self.ink[i] };
    }

    /// Write a block of art, one UTF-8 string a row, its left column at `x` and its **last**
    /// row on `foot` — art stands on a row, so a taller block grows upward. A space leaves
    /// the cell under it alone. `clip` keeps the writes inside a rectangle of cells. A row
    /// that is not valid UTF-8 stops at the bad byte.
    pub fn stamp(self: *Cells, lines: []const []const u8, x: i32, foot: i32, ink: u8, clip: ?Clip) void {
        const top = foot - @as(i32, @intCast(lines.len)) + 1;
        for (lines, 0..) |line, r| {
            const y = top + @as(i32, @intCast(r));
            var it = (std.unicode.Utf8View.init(line) catch continue).iterator();
            var col: i32 = x;
            while (it.nextCodepoint()) |cp| : (col += 1) {
                if (cp == ' ') continue;
                if (clip) |c| if (col < c.x0 or col > c.x1 or y < c.y0 or y > c.y1) continue;
                self.put(col, y, cp, ink);
            }
        }
    }
};

const testing = std.testing;

test "glyph_cells: a put lands in its cell and nowhere else" {
    var g = Cells.init(4, 3);
    g.put(2, 1, 'x', 5);
    try testing.expectEqual(@as(u21, 'x'), g.at(2, 1).?.cp);
    try testing.expectEqual(@as(u8, 5), g.at(2, 1).?.ink);
    var filled: usize = 0;
    for (g.ink[0..g.count()]) |k| filled += @intFromBool(k != 0);
    try testing.expectEqual(@as(usize, 1), filled);
}

test "glyph_cells: a write outside the grid is dropped" {
    var g = Cells.init(4, 3);
    g.put(-1, 0, 'x', 1);
    g.put(4, 0, 'x', 1);
    g.put(0, -1, 'x', 1);
    g.put(0, 3, 'x', 1);
    for (g.ink[0..g.count()]) |k| try testing.expectEqual(@as(u8, 0), k);
    try testing.expect(g.at(4, 0) == null);
}

test "glyph_cells: a space or ink 0 empties the cell" {
    var g = Cells.init(2, 1);
    g.put(0, 0, 'x', 1);
    g.put(0, 0, ' ', 1);
    try testing.expect(g.at(0, 0) == null);
    g.put(1, 0, 'x', 1);
    g.put(1, 0, 'y', 0);
    try testing.expect(g.at(1, 0) == null);
}

test "glyph_cells: a grid past the capacity is refused whole" {
    var g = Cells.init(128, 33);
    try testing.expectEqual(@as(usize, 0), g.count());
    g.put(0, 0, 'x', 1);
    try testing.expect(g.at(0, 0) == null);
    try testing.expectEqual(@as(usize, Cells.cap), Cells.init(128, 32).count());
}

test "glyph_cells: stamped art stands on its foot row and its spaces are transparent" {
    var g = Cells.init(6, 4);
    g.put(2, 2, '#', 9);
    g.stamp(&.{ " o ", "/|\\", "/ \\" }, 1, 3, 2, null);
    // The head is two rows above the foot.
    try testing.expectEqual(@as(u21, 'o'), g.at(2, 1).?.cp);
    try testing.expectEqual(@as(u21, '|'), g.at(2, 2).?.cp);
    try testing.expectEqual(@as(u21, '/'), g.at(1, 3).?.cp);
    try testing.expectEqual(@as(u21, '\\'), g.at(3, 3).?.cp);
    // The gap between the legs is a space in the art: the cell keeps what it had (nothing).
    try testing.expect(g.at(2, 3) == null);
    // The space beside the head did not erase anything either.
    try testing.expect(g.at(1, 1) == null);
}

test "glyph_cells: a space in stamped art leaves the cell under it" {
    var g = Cells.init(3, 1);
    g.put(1, 0, '#', 9);
    g.stamp(&.{"a b"}, 0, 0, 2, null);
    try testing.expectEqual(@as(u21, '#'), g.at(1, 0).?.cp);
    try testing.expectEqual(@as(u8, 9), g.at(1, 0).?.ink);
}

test "glyph_cells: stamped art counts codepoints, not bytes" {
    var g = Cells.init(4, 1);
    g.stamp(&.{"•·x"}, 0, 0, 1, null);
    try testing.expectEqual(@as(u21, 0x2022), g.at(0, 0).?.cp);
    try testing.expectEqual(@as(u21, 0x00B7), g.at(1, 0).?.cp);
    try testing.expectEqual(@as(u21, 'x'), g.at(2, 0).?.cp);
}

test "glyph_cells: a clip keeps a stamp inside its rectangle" {
    var g = Cells.init(6, 3);
    g.stamp(&.{ "abcd", "efgh" }, 0, 1, 1, .{ .x0 = 1, .y0 = 1, .x1 = 2, .y1 = 2 });
    try testing.expect(g.at(1, 0) == null); // above the clip
    try testing.expect(g.at(0, 1) == null); // left of it
    try testing.expectEqual(@as(u21, 'f'), g.at(1, 1).?.cp);
    try testing.expectEqual(@as(u21, 'g'), g.at(2, 1).?.cp);
    try testing.expect(g.at(3, 1) == null); // right of it
}

test "glyph_cells: art walks in from off the edge" {
    var g = Cells.init(3, 1);
    g.stamp(&.{"abc"}, -2, 0, 1, null);
    try testing.expectEqual(@as(u21, 'c'), g.at(0, 0).?.cp);
    try testing.expect(g.at(1, 0) == null);
}

test "glyph_cells: clear empties every cell" {
    var g = Cells.init(3, 2);
    g.stamp(&.{ "abc", "def" }, 0, 1, 1, null);
    g.clear();
    for (g.ink[0..g.count()]) |k| try testing.expectEqual(@as(u8, 0), k);
}
