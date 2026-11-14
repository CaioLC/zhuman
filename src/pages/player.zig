//! `player` — the PLAYER panel's projection, the same in both acts: `label … value` lines from
//! the player's `Outlook` (food days, recovery, work pace), in the grammar SETTLEMENT's lines
//! use. Pure projection into the frame arena; it builds no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const uic = ha.ui_client;
const vd = uic.style.verdict;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("./templates/root.zig");
const Line = t.HouseholdLine;

/// Agent `e`'s PLAYER panel. The lines are the `outlook` system's projection at the eating
/// policy's rate; the policy reads its own word on the line under them, so these name only
/// what it moves. An agent with no `Outlook` shows a note in their place.
pub fn project(a: std.mem.Allocator, world: *const World, e: Entity) !t.HouseholdPlayer {
    const outlook = world.get(e, comp.Outlook) orelse return .{ .note = "no projection" };
    const lines = try a.alloc(Line, 3);
    lines[0] = .{
        .key = "coverage",
        .label = "Food lasts",
        .value = try a.print("{d:.1}d", .{outlook.food_days}),
        .tone = .fg,
        .verdict = vd.when(outlook.food_days < 2, .low),
    };
    lines[1] = try recovery(a, outlook.recovery);
    lines[2] = try pace(a, outlook.pace);
    return .{ .lines = lines };
}

/// Whether vigor is recovering, full, starving, or stalled on food that does not restore.
fn recovery(a: std.mem.Allocator, r: comp.Outlook.Recovery) !Line {
    return switch (r) {
        .at_ceiling => .{ .key = "recovery", .label = "Vigor", .value = "full", .tone = .good },
        .no_food => .{ .key = "recovery", .label = "Recovery", .value = "starving", .tone = .danger },
        .no_quality => .{ .key = "recovery", .label = "Recovery", .value = "no vigor", .tone = .danger },
        .partial => |p| .{ .key = "recovery", .label = "Can recover", .value = try a.print("+{d:.0} vigor", .{p.restored}), .tone = .warn },
        .recovering => |rec| .{ .key = "recovery", .label = "Full vigor in", .value = try a.print("{d:.1}d", .{rec.days}), .tone = .fg },
    };
}

/// The pace the body works at on its ration, as a whole percentage of the normal ration's.
fn pace(a: std.mem.Allocator, p: f32) !Line {
    const pct: i32 = @intFromFloat(@round(p * 100));
    return .{ .key = "pace", .label = "Work pace", .value = try a.print("{d}%", .{pct}), .tone = .fg };
}

test "PLAYER ends on the work pace: 100% at the normal ration, the slowest pace's share unfed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Outlook{ .food_days = 5.2, .recovery = .{ .recovering = .{ .days = 0.4 } }, .pace = 1 }});

    var b = try project(a, &w, e);
    try std.testing.expectEqual(@as(usize, 3), b.lines.len);
    try std.testing.expectEqualStrings("coverage", b.lines[0].key);
    try std.testing.expectEqualStrings("Food lasts", b.lines[0].label);
    try std.testing.expectEqualStrings("5.2d", b.lines[0].value);
    try std.testing.expectEqualStrings("recovery", b.lines[1].key);
    try std.testing.expectEqualStrings("Full vigor in", b.lines[1].label);
    const last = b.lines[2];
    try std.testing.expectEqualStrings("pace", last.key);
    try std.testing.expectEqualStrings("Work pace", last.label);
    try std.testing.expectEqualStrings("100%", last.value);
    // The neutral value ink of `Food lasts 5.2d`, with no verdict.
    try std.testing.expect(last.tone == .fg and last.verdict == null);

    const cfg = ha.sim.res.Config{};
    w.get(e, comp.Outlook).?.pace = cfg.pace(1.0, 1, false);
    b = try project(a, &w, e);
    const slowest = try std.fmt.allocPrint(a, "{d}%", .{@as(i32, @intFromFloat(@round(cfg.pace(cfg.metabolism_rate_min, 1, true) * 100)))});
    try std.testing.expectEqualStrings(slowest, b.lines[2].value);
    try std.testing.expectEqualStrings("69%", b.lines[2].value);
}

test "PLAYER with no projection carries no lines, the pace among them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Goods{}});
    const b = try project(arena.allocator(), &w, e);
    try std.testing.expectEqual(@as(usize, 0), b.lines.len);
    try std.testing.expectEqualStrings("no projection", b.note.?);
}
