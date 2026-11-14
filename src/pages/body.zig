//! `body` — the BODY panel's projection, the same in both acts: the sentences from an agent's
//! `Outlook` (food days, recovery, work pace). Pure projection into the frame arena; it builds
//! no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const uic = ha.ui_client;
const vd = uic.style.verdict;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("./templates/root.zig");
const Sentence = t.HouseholdSentence;

/// Agent `e`'s BODY panel. The sentences are the `outlook` system's projection at the eating
/// policy's rate; the policy reads its own word under BODY, so the body names only what it
/// moves. An agent with no `Outlook` shows a note in their place.
pub fn project(a: std.mem.Allocator, world: *const World, e: Entity) !t.HouseholdBody {
    const outlook = world.get(e, comp.Outlook) orelse return .{ .note = "no body projection" };
    const sentences = try a.alloc(Sentence, 3);
    sentences[0] = .{
        .key = "coverage",
        .prefix = "Food lasts ",
        .value = try a.print("{d:.1}d", .{outlook.food_days}),
        .suffix = ".",
        .verdict = vd.when(outlook.food_days < 2, .low),
    };
    sentences[1] = try recovery(a, outlook.recovery);
    sentences[2] = try pace(a, outlook.pace);
    return .{ .sentences = sentences };
}

/// Whether vigor is recovering, full, starving, or stalled on food that does not restore.
fn recovery(a: std.mem.Allocator, r: comp.Outlook.Recovery) !Sentence {
    return switch (r) {
        .at_ceiling => .{ .key = "recovery", .prefix = "Vigor is ", .value = "full", .suffix = ".", .tone = .good },
        .no_food => .{ .key = "recovery", .prefix = "Recovery: ", .value = "starving", .suffix = ".", .tone = .danger },
        .no_quality => .{ .key = "recovery", .prefix = "Recovery: ", .value = "no vigor", .suffix = ".", .tone = .danger },
        .partial => |p| .{ .key = "recovery", .prefix = "Can recover ", .value = try a.print("+{d:.0} vigor", .{p.restored}), .suffix = ".", .tone = .warn },
        .recovering => |rec| .{ .key = "recovery", .prefix = "Full vigor in ", .value = try a.print("{d:.1}d", .{rec.days}), .suffix = "." },
    };
}

/// The pace the body works at on its ration, as a whole percentage of the normal ration's.
fn pace(a: std.mem.Allocator, p: f32) !Sentence {
    const pct: i32 = @intFromFloat(@round(p * 100));
    return .{ .key = "pace", .prefix = "Work pace ", .value = try a.print("{d}%", .{pct}), .suffix = "." };
}

test "BODY ends on the work pace: 100% at the normal ration, the slowest pace's share unfed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Outlook{ .food_days = 5.2, .recovery = .{ .recovering = .{ .days = 0.4 } }, .pace = 1 }});

    var b = try project(a, &w, e);
    try std.testing.expectEqual(@as(usize, 3), b.sentences.len);
    try std.testing.expectEqualStrings("coverage", b.sentences[0].key);
    try std.testing.expectEqualStrings("recovery", b.sentences[1].key);
    const last = b.sentences[2];
    try std.testing.expectEqualStrings("pace", last.key);
    try std.testing.expectEqualStrings("Work pace ", last.prefix);
    try std.testing.expectEqualStrings("100%", last.value);
    try std.testing.expectEqualStrings(".", last.suffix);
    // The neutral value ink of "Food lasts 5.2d.", with no verdict.
    try std.testing.expect(last.tone == .fg and last.verdict == null);

    const cfg = ha.sim.res.Config{};
    w.get(e, comp.Outlook).?.pace = cfg.pace(1.0, 1, false);
    b = try project(a, &w, e);
    const slowest = try std.fmt.allocPrint(a, "{d}%", .{@as(i32, @intFromFloat(@round(cfg.pace(cfg.metabolism_rate_min, 1, true) * 100)))});
    try std.testing.expectEqualStrings(slowest, b.sentences[2].value);
    try std.testing.expectEqualStrings("69%", b.sentences[2].value);
}

test "BODY with no projection carries no sentences, the pace among them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Goods{}});
    const b = try project(arena.allocator(), &w, e);
    try std.testing.expectEqual(@as(usize, 0), b.sentences.len);
    try std.testing.expectEqualStrings("no body projection", b.note.?);
}
