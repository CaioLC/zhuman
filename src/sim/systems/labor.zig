//! The labor handler: `BeginLabor` intents become `actions.begin` calls. A refused begin changes
//! nothing and is answered by `Refused`; one that begins emits `WorkBegun` from the rule.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const actions = @import("../rules/actions.zig");
const Resources = @import("../res.zig").Resources;

const World = ecs.World;

pub fn labor(
    w: *World,
    res: *Resources,
    intents: ecs.EventReader(events.BeginLabor, .labor),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (actions.begin(w, it.agent, res, it.ai)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .begin_labor, .reason = reason });
        }
    }
}

// ============================ Tests ==========================================

const testing = std.testing;
const comp = @import("../components.zig");
const roster = @import("../data/roster.zig");

fn rig() !Resources {
    return .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
}

test "labor refuses without mutating and emits Refused" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    const e = w.spawn(.{ comp.Vigor{ .v = 1.7, .max = 10 }, comp.InventoryFood{}, comp.Goods{}, comp.Granted{} });
    const forage = res.catalog.actionIndex("forage").?;
    res.events.update();
    _ = res.events.writer(events.BeginLabor).push(.{ .agent = e, .ai = forage });
    _ = res.events.writer(events.BeginLabor).push(.{ .agent = e, .ai = 9999 });
    ecs.run(&w, &res, labor);

    try testing.expect(!w.has(e, comp.Busy));
    try testing.expectApproxEqAbs(@as(f32, 1.7), w.get(e, comp.Vigor).?.v, 1e-6);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.WorkBegun));
    var cursor: u64 = 0;
    const r = res.events.readerAt(events.Refused, &cursor);
    try testing.expectEqual(events.Refused{ .agent = e, .intent = .begin_labor, .reason = .energy }, r.next().?);
    try testing.expectEqual(events.Refused.Reason.unavailable, r.next().?.reason);
}

test "labor begins the work once and emits WorkBegun" {
    var w = World.init();
    var res = try rig();
    defer res.catalog.deinit();
    const e = w.spawn(.{ comp.Vigor{ .v = 10, .max = 10 }, comp.InventoryFood{}, comp.Goods{}, comp.Granted{} });
    const forage = res.catalog.actionIndex("forage").?;
    res.events.update();
    _ = res.events.writer(events.BeginLabor).push(.{ .agent = e, .ai = forage });
    ecs.run(&w, &res, labor);
    ecs.run(&w, &res, labor); // the intent is consumed once

    try testing.expect(w.get(e, comp.Busy).?.isLabor(forage));
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Refused));
    var cursor: u64 = 0;
    const begun = res.events.readerAt(events.WorkBegun, &cursor).next().?;
    try testing.expectEqual(e, begun.agent);
    try testing.expect(begun.doing.labor == forage);
    try testing.expect(!begun.weary);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.WorkBegun));
}
