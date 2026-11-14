//! `act_one/status` — Act I's content for the shared `status` rail template. One person
//! is no settlement, so the column is PLAYER alone (`pages/player.zig`).
//! Pure projection over live state into the frame arena; it builds no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const uic = ha.ui_client;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("../templates/root.zig");
const player = @import("../player.zig");

/// Project agent `e` into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.StatusContent {
    return .{ .player = try player.project(ctx.arena, world, e) };
}

test "Act I has no settlement: the column is PLAYER alone" {
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
    try std.testing.expectEqual(@as(usize, 3), c.player.lines.len);
}
