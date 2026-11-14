//! `act_one/household` — Act I's content for the shared `household` rail template. One person
//! is no settlement, so the column is BODY alone: the sentences from the agent's `Outlook`
//! (food days, recovery, work pace), then what the body is working with (`pages/body.zig`).
//! Pure projection over live state into the frame arena; it builds no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const uic = ha.ui_client;
const vd = uic.style.verdict;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("../templates/root.zig");
const body = @import("../body.zig");
const Sentence = t.HouseholdSentence;

/// Project agent `e` into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HouseholdContent {
    const a = ctx.arena;
    const lines = try body.lines(a, world, e);

    // The `outlook` system's projection at the eating policy's rate; the policy reads its own
    // word under BODY, so the body names only what it moves.
    const outlook = world.get(e, comp.Outlook) orelse
        return .{ .body = .{ .note = "no body projection", .lines = lines } };
    const sentences = try a.alloc(Sentence, 3);
    sentences[0] = .{
        .key = "coverage",
        .prefix = "Food lasts ",
        .value = try a.print("{d:.1}d", .{outlook.food_days}),
        .suffix = ".",
        .verdict = vd.when(outlook.food_days < 2, .low),
    };
    sentences[1] = try body.recovery(a, outlook.recovery);
    sentences[2] = try body.pace(a, outlook.pace);
    return .{ .body = .{ .sentences = sentences, .lines = lines } };
}

test "Act I has no settlement: the column is BODY alone" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{ comp.Outlook{}, comp.InventoryFood{}, comp.Vigor{}, comp.Goods{} });
    const c = try content(&ctx, &w, e);
    try std.testing.expect(c.settlement == null);
    // The food's spoilage and the vigor ceiling; the quality has not moved.
    try std.testing.expectEqual(@as(usize, 2), c.body.lines.len);
}

test "BODY ends on the work pace: 100% at the normal ration, the slowest pace's share unfed" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Outlook{ .food_days = 5.2, .recovery = .{ .recovering = .{ .days = 0.4 } }, .pace = 1 }});

    var c = try content(&ctx, &w, e);
    try std.testing.expectEqual(@as(usize, 3), c.body.sentences.len);
    const last = c.body.sentences[c.body.sentences.len - 1];
    try std.testing.expectEqualStrings("pace", last.key);
    try std.testing.expectEqualStrings("Work pace ", last.prefix);
    try std.testing.expectEqualStrings("100%", last.value);
    try std.testing.expectEqualStrings(".", last.suffix);
    // The neutral value ink of "Food lasts 5.2d.", with no verdict.
    try std.testing.expect(last.tone == .fg and last.verdict == null);

    const cfg = res.game.config;
    w.get(e, comp.Outlook).?.pace = cfg.pace(1.0, 1, false);
    c = try content(&ctx, &w, e);
    const slowest = try std.fmt.allocPrint(arena.allocator(), "{d}%", .{@as(i32, @intFromFloat(@round(cfg.pace(cfg.metabolism_rate_min, 1, true) * 100)))});
    try std.testing.expectEqualStrings(slowest, c.body.sentences[c.body.sentences.len - 1].value);
    try std.testing.expectEqualStrings("69%", c.body.sentences[c.body.sentences.len - 1].value);
}

test "BODY with no projection carries no sentences, the pace among them" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Goods{}});
    const c = try content(&ctx, &w, e);
    try std.testing.expectEqual(@as(usize, 0), c.body.sentences.len);
    try std.testing.expectEqualStrings("no body projection", c.body.note.?);
}
