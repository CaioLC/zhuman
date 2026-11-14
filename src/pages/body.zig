//! `body` — the BODY panel's projection, the same in both acts: the sentences from an agent's
//! `Outlook` (food days, recovery, work pace), and the lines for what the body is working with
//! (the quality and spoilage of the food it eats, its vigor ceiling), each read from a live
//! component against its baseline. Pure projection into the frame arena; it builds no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const uic = ha.ui_client;
const vd = uic.style.verdict;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("./templates/root.zig");
const Line = t.HouseholdLine;
const Sentence = t.HouseholdSentence;

/// Agent `e`'s BODY panel. The sentences are the `outlook` system's projection at the eating
/// policy's rate; the policy reads its own word under BODY, so the body names only what it
/// moves. An agent with no `Outlook` shows a note in their place.
pub fn project(a: std.mem.Allocator, world: *const World, e: Entity) !t.HouseholdBody {
    const ls = try lines(a, world, e);
    const outlook = world.get(e, comp.Outlook) orelse return .{ .note = "no body projection", .lines = ls };
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
    return .{ .sentences = sentences, .lines = ls };
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

/// What agent `e`'s body is working with: the food's quality where it has moved from the
/// baseline, its spoilage against the baseline, and the vigor ceiling. A component the agent
/// lacks adds no line.
fn lines(a: std.mem.Allocator, world: *const World, e: Entity) ![]const Line {
    var out: std.ArrayList(Line) = .empty;
    if (world.get(e, comp.InventoryFood)) |food| {
        const q0 = ha.sim.baselines.food_quality;
        if (food.quality != q0) try out.append(a, .{
            .key = "quality",
            .label = "Food quality",
            .value = try a.print("{d} \u{2192} {d}", .{ q0, food.quality }),
            .verdict = vd.margin(@floatFromInt(food.quality), @floatFromInt(q0), .higher),
        });
        const s0 = ha.sim.baselines.food_spoils;
        try out.append(a, .{
            .key = "spoilage",
            .label = "Food spoilage",
            .value = try a.print("{d:.0}% \u{2192} {d:.0}%/day", .{ s0 * 100, food.spoils * 100 }),
            .verdict = vd.margin(food.spoils, s0, .lower),
        });
    }
    if (world.get(e, comp.Vigor)) |vigor| try out.append(a, .{
        .key = "vigor",
        .label = "Vigor ceiling",
        .value = try a.print("{d:.0}", .{vigor.max}),
    });
    return out.items;
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

test "the body's lines read the food and the ceiling against their baselines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const base = ha.sim.baselines;

    // A fresh body: the quality has not moved, so it shows no line.
    const fresh = w.spawn(.{ comp.InventoryFood{}, comp.Vigor{} });
    var ls = try lines(arena.allocator(), &w, fresh);
    try std.testing.expectEqual(@as(usize, 2), ls.len);
    try std.testing.expectEqualStrings("spoilage", ls[0].key);
    try std.testing.expectEqualStrings("vigor", ls[1].key);

    // Better food that keeps longer reads as two gains.
    const fed = w.spawn(.{ comp.InventoryFood{ .quality = base.food_quality + 1, .spoils = base.food_spoils / 2 }, comp.Vigor{} });
    ls = try lines(arena.allocator(), &w, fed);
    try std.testing.expectEqual(@as(usize, 3), ls.len);
    try std.testing.expectEqualStrings("quality", ls[0].key);
    try std.testing.expect(ls[0].verdict.? == vd.margin(2, 1, .higher));
    try std.testing.expect(ls[1].verdict.? == vd.margin(1, 2, .lower));

    // Nothing to read, no lines.
    const bare = w.spawn(.{comp.Goods{}});
    try std.testing.expectEqual(@as(usize, 0), (try lines(arena.allocator(), &w, bare)).len);
}
