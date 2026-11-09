//! The build handlers: `BeginBuild` intents become `capital.begin` calls and `CancelBuild`
//! intents `capital.cancel_build` calls. A refused intent changes nothing and is answered by
//! `Refused`; one that applies emits `WorkBegun` or `BuildCancelled` from the rule.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const capital = @import("../rules/capital.zig");
const Resources = @import("../res.zig").Resources;

const World = ecs.World;

pub fn build(
    w: *World,
    res: *Resources,
    intents: ecs.EventReader(events.BeginBuild, .build),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (capital.begin(w, it.agent, res, it.gi)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .begin_build, .reason = reason });
        }
    }
}

pub fn cancel(
    w: *World,
    res: *Resources,
    intents: ecs.EventReader(events.CancelBuild, .build),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (capital.cancel_build(w, it.agent, res)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .cancel_build, .reason = reason });
        }
    }
}

// ============================ Tests ==========================================

const testing = std.testing;
const comp = @import("../components.zig");
const roster = @import("../data/roster.zig");

fn rig() !Resources {
    var res = Resources{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
    res.events.update();
    return res;
}

fn agent(w: *World, materials: f32) ecs.Entity {
    return w.spawn(.{ comp.Vigor{ .v = 10, .max = 10 }, comp.InventoryFood{}, comp.InventoryBiomass{ .v = materials }, comp.Goods{}, comp.Granted{} });
}

/// The one live event of `T`, or null when there is none.
fn only(res: *Resources, comptime T: type) ?T {
    var cursor: u64 = 0;
    const r = res.events.readerAt(T, &cursor);
    const first = r.next() orelse return null;
    std.debug.assert(r.next() == null);
    return first;
}

test "build refuses without mutating and emits Refused" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const spear = res.catalog.goodIndex("spear").?;
    const e = agent(&w, 1); // short of the build order
    _ = res.events.writer(events.BeginBuild).push(.{ .agent = e, .gi = spear });
    ecs.run(&w, &res, build);
    try testing.expect(!w.has(e, comp.Busy));
    try testing.expectEqual(@as(f32, 1), w.get(e, comp.InventoryBiomass).?.v);
    try testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v);
    try testing.expectEqual(events.Refused{ .agent = e, .intent = .begin_build, .reason = .short }, only(&res, events.Refused).?);
    try testing.expect(only(&res, events.WorkBegun) == null);
}

test "build begins the work and emits WorkBegun; cancel salvages and emits BuildCancelled" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const spear = res.catalog.goodIndex("spear").?;
    const order = res.catalog.goods[spear].requires.biomass;
    const e = agent(&w, order);
    _ = res.events.writer(events.BeginBuild).push(.{ .agent = e, .gi = spear });
    ecs.run(&w, &res, build);
    try testing.expect(w.get(e, comp.Busy).?.isBuild(spear));
    const begun = only(&res, events.WorkBegun).?;
    try testing.expect(begun.doing.build == spear);
    try testing.expectEqual(order, begun.paid.total());

    _ = res.events.writer(events.CancelBuild).push(.{ .agent = e });
    ecs.run(&w, &res, cancel);
    try testing.expect(!w.has(e, comp.Busy));
    const back = only(&res, events.BuildCancelled).?;
    try testing.expectEqual(spear, back.gi);
    try testing.expectApproxEqAbs(order * res.config.cancel_refund, back.refund.total(), 1e-5);
    try testing.expect(only(&res, events.Refused) == null);
}

test "cancel refuses on an idle body without mutating and emits Refused" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const e = agent(&w, 5);
    _ = res.events.writer(events.CancelBuild).push(.{ .agent = e });
    ecs.run(&w, &res, cancel);
    try testing.expectEqual(@as(f32, 5), w.get(e, comp.InventoryBiomass).?.v);
    try testing.expectEqual(events.Refused{ .agent = e, .intent = .cancel_build, .reason = .nothing_to_cancel }, only(&res, events.Refused).?);
    try testing.expect(only(&res, events.BuildCancelled) == null);
}
