//! Number formatting helpers for the HUD (pure functions — no node building).
//! Leaf module: imports only std.

const std = @import("std");

/// Compact number format for the HUD's big counters — `1.2M`, `12k`, `3.4k`, or a bare int.
pub fn fmt_num(buf: []u8, n: f32) []const u8 {
    const r = @round(n);
    if (r >= 1_000_000) return std.fmt.bufPrint(buf, "{d:.1}M", .{r / 1_000_000}) catch "?";
    if (r >= 10_000) return std.fmt.bufPrint(buf, "{d:.0}k", .{r / 1000}) catch "?";
    if (r >= 1_000) return std.fmt.bufPrint(buf, "{d:.1}k", .{r / 1000}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0}", .{r}) catch "?";
}

/// A small resource amount for a price/cost segment (energy/materials): one decimal only when
/// fractional, so `1.7` renders `1.7` but `2.0` renders `2` and `2.5` renders `2.5` — the
/// finalized ACTIONS metric style (ACT1-08). Rounds to a tenth to avoid float noise.
pub fn fmt_amount(buf: []u8, n: f32) []const u8 {
    const tenths = @round(n * 10);
    if (@mod(tenths, 10) == 0) return std.fmt.bufPrint(buf, "{d:.0}", .{tenths / 10}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1}", .{tenths / 10}) catch "?";
}

test "fmt_amount: one decimal only when fractional" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2", fmt_amount(&buf, 2.0));
    try std.testing.expectEqualStrings("1.7", fmt_amount(&buf, 1.7));
    try std.testing.expectEqualStrings("2.5", fmt_amount(&buf, 2.5));
    try std.testing.expectEqualStrings("1", fmt_amount(&buf, 1.0));
}
