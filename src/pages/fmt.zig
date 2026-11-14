//! Number formatting helpers for page copy (pure functions — no node building).
//! Leaf module: imports only std.

const std = @import("std");

/// A small resource amount for a price/cost segment (energy/materials): one decimal only when
/// fractional, so `1.7` renders `1.7` but `2.0` renders `2` and `2.5` renders `2.5`: the
/// ACTIONS metric style. Rounds to a tenth to avoid float noise.
pub fn fmt_amount(buf: []u8, n: f32) []const u8 {
    const tenths = @round(n * 10);
    if (@mod(tenths, 10) == 0) return std.mem.print(buf, "{d:.0}", .{tenths / 10}) catch "?";
    return std.mem.print(buf, "{d:.1}", .{tenths / 10}) catch "?";
}

/// A held amount as the whole number a `have/need` counter prints: floored, never rounded, so a
/// counter never reads its target while `have >= need` is false (239.6 of 240 reads 239). No
/// drift guard: a value an f32 holds a hair under a whole number is under it, and reads under
/// it, as the comparison does. Non-finite reads 0; the magnitude is clamped so the cast holds.
pub fn held_whole(have: f32) i64 {
    if (!std.math.isFinite(have)) return 0;
    return @intFromFloat(@floor(std.math.clamp(have, -1e15, 1e15)));
}

test "held_whole floors, so a counter never shows the target before it is met" {
    const eq = std.testing.expectEqual;
    try eq(@as(i64, 11), held_whole(11.6));
    try eq(@as(i64, 14), held_whole(14.96));
    try eq(@as(i64, 239), held_whole(239.6));
    try eq(@as(i64, 12), held_whole(12.0));
    try eq(@as(i64, 0), held_whole(0));
    // A hair under a whole number after arithmetic is under it: 12 - ulp reads 11, as `>= 12`
    // reads it unmet.
    const hair: f32 = 12.0 - std.math.floatEps(f32) * 8;
    try std.testing.expect(hair < 12.0);
    try eq(@as(i64, 11), held_whole(hair));
    try eq(@as(i64, 11), held_whole(11.9999995));
    // The invariant: the floored amount reaches the need only when the real amount does.
    for ([_]f32{ 11.6, 11.9999995, 12, 12.0001, 239.6, 239.99998, 240 }) |have| {
        for ([_]f32{ 12, 15, 240 }) |need| {
            try std.testing.expectEqual(have >= need, @as(f32, @floatFromInt(held_whole(have))) >= need);
        }
    }
    try eq(@as(i64, 0), held_whole(std.math.nan(f32)));
}

test "fmt_amount: one decimal only when fractional" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2", fmt_amount(&buf, 2.0));
    try std.testing.expectEqualStrings("1.7", fmt_amount(&buf, 1.7));
    try std.testing.expectEqualStrings("2.5", fmt_amount(&buf, 2.5));
    try std.testing.expectEqualStrings("1", fmt_amount(&buf, 1.0));
}
