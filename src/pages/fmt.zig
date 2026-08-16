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

test "fmt_num: compact ranges" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("342", fmt_num(&buf, 342));
    try std.testing.expectEqualStrings("3.4k", fmt_num(&buf, 3_421));
    try std.testing.expectEqualStrings("34k", fmt_num(&buf, 34_210));
    try std.testing.expectEqualStrings("3.4M", fmt_num(&buf, 3_421_000));
}
