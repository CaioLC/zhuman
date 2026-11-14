//! `act_one/household` — Act I's content for the shared `household` rail template. One person
//! is no settlement, so the column is BODY alone (`pages/body.zig`).
//! Pure projection over live state into the frame arena; it builds no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const uic = ha.ui_client;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("../templates/root.zig");
const body = @import("../body.zig");

/// Project agent `e` into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HouseholdContent {
    return .{ .body = try body.project(ctx.arena, world, e) };
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
    try std.testing.expectEqual(@as(usize, 3), c.body.sentences.len);
    // The food's spoilage and the vigor ceiling; the quality has not moved.
    try std.testing.expectEqual(@as(usize, 2), c.body.lines.len);
}
