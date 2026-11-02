//! The act boundaries. `detect_shelter`, in Act I's `update` set, requests Act II the tick the
//! player owns the Act I milestone and emits `ActEnded` with it: the fact belongs to the
//! detector, not to an `on_exit` set, because a restart also leaves Act I and the act did not
//! end. `cross_curtain`, Act II's `on_enter`, carries the player across
//! (`migration.migrate_to_act_two`). `detect_exchange`, in Act II's `update` set, requests Act
//! III once the Exchange stands. The curtain the player sees is the UI's response to `ActEnded`.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const comp = @import("../components.zig");
const tag = @import("../tags.zig");
const res_mod = @import("../res.zig");
const capital = @import("../rules/capital.zig");
const migration = @import("../data/migration.zig");
const roster = @import("../data/roster.zig");
const States = @import("../state.zig").States;

const World = ecs.World;
const Entity = ecs.Entity;

/// Request Act II and emit `ActEnded{ .act_one }` once, the tick the player owns the Act I
/// milestone. Only in Act I with no transition pending, so the request is made once.
pub fn detect_shelter(
    w: *World,
    cat: *const roster.Catalog,
    states: *States,
    ended: ecs.EventWriter(events.ActEnded),
    player: ecs.MaybeSingle(.{ Entity, comp.Goods, ecs.With(tag.Player) }),
) void {
    if (!states.in(.act_one) or states.next != null) return;
    const p = player.get() orelse return;
    if (!capital.ownsMilestone(w, p[0], cat, .act_one)) return;
    states.set(.act_two);
    _ = ended.push(.{ .act = .act_one });
}

/// Carry every player across the Act I curtain. The migration is versioned and idempotent, so
/// a player already carried is untouched.
pub fn cross_curtain(
    w: *World,
    cat: *const roster.Catalog,
    players: ecs.Query(.{ Entity, comp.Vigor, ecs.With(tag.Player) }),
) void {
    var ids: [ecs.MAX_ENTITIES]Entity = undefined;
    var n: usize = 0;
    var it = players.iter();
    while (it.next()) |entry| {
        ids[n] = entry[0];
        n += 1;
    }
    for (ids[0..n]) |e| _ = migration.migrate_to_act_two(w, e, cat);
}

/// Request Act III once the Exchange stands, from Act II with no transition pending.
pub fn detect_exchange(sim: *const res_mod.Sim, states: *States) void {
    if (sim.exchange.standing and states.in(.act_two) and states.next == null) states.set(.act_three);
}

// ============================ Tests ==========================================

const testing = std.testing;
const spawn_player = @import("./run.zig").spawn_player;

fn rig() !res_mod.Resources {
    return .{
        .catalog = try roster.load(testing.allocator, roster.shipped, null),
        .states = .{ .current = .act_one },
    };
}

/// Give `e` one of the good that ends Act I.
fn house(w: *World, e: Entity, cat: *const roster.Catalog) void {
    for (cat.goods, 0..) |g, gi| if (g.milestone == .act_one) {
        w.get(e, comp.Goods).?.count[gi] = 1;
        return;
    };
    unreachable;
}

test "detect_shelter waits for the milestone, then requests Act II and emits ActEnded once" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    res.events.update();
    const e = spawn_player(&w);
    ecs.run(&w, &res, detect_shelter);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.ActEnded));
    try testing.expect(res.states.next == null);

    house(&w, e, &res.catalog);
    ecs.run(&w, &res, detect_shelter);
    ecs.run(&w, &res, detect_shelter); // the request is pending: no second fact
    try testing.expectEqual(@as(usize, 1), res.events.len(events.ActEnded));
    try testing.expectEqual(@as(?@TypeOf(res.states.current), .act_two), res.states.next);
    var cursor: u64 = 0;
    try testing.expectEqual(events.ActEnded{ .act = .act_one }, res.events.readerAt(events.ActEnded, &cursor).next().?);
}

test "cross_curtain migrates the player once" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    const e = spawn_player(&w);
    ecs.run(&w, &res, cross_curtain);
    try testing.expect(migration.is_migrated(&w, e));
    try testing.expectEqual(@as(u8, 2), migration.actOf(&w, e));
    ecs.run(&w, &res, cross_curtain);
    try testing.expect(migration.is_migrated(&w, e));
}

test "detect_exchange requests Act III from Act II once the Exchange stands" {
    var w = World.init();
    var res = res_mod.Resources{ .states = .{ .current = .act_two } };
    ecs.run(&w, &res, detect_exchange);
    try testing.expect(res.states.next == null);
    res.sim.exchange.standing = true;
    ecs.run(&w, &res, detect_exchange);
    try testing.expectEqual(@as(?@TypeOf(res.states.current), .act_three), res.states.next);
}
