//! Collectable generators: the handlers for `ToggleGenerator` (`capital.toggle_generator`) and
//! `CollectGenerator` (`capital.collect_generator`), and the update system that matures every
//! owned, enabled generator (`capital.run_generators`). A refused intent changes nothing and is
//! answered by `Refused`; a collection emits `Collected` from the rule.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const capital = @import("../rules/capital.zig");
const roster = @import("../data/roster.zig");
const Resources = @import("../res.zig").Resources;

const World = ecs.World;

pub fn generators_toggle(
    w: *World,
    cat: *const roster.Catalog,
    intents: ecs.EventReader(events.ToggleGenerator, .generators),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (capital.toggle_generator(w, it.agent, cat, it.gi)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .toggle_generator, .reason = reason });
        }
    }
}

pub fn generators_collect(
    w: *World,
    res: *Resources,
    intents: ecs.EventReader(events.CollectGenerator, .generators),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        if (capital.collect_generator(w, it.agent, res, it.gi)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .collect_generator, .reason = reason });
        }
    }
}

/// Accumulate owned, enabled generators toward readiness by this frame's `dt`.
pub fn generators(w: *World, res: *Resources) void {
    capital.run_generators(w, res);
}

// ============================ Tests ==========================================

const testing = std.testing;
const comp = @import("../components.zig");

const Rig = struct {
    w: World,
    res: Resources,
    e: ecs.Entity = 0,
    gi: u16 = 0,

    /// An agent owning one garden bed whose cycle is complete.
    fn init(self: *Rig) !void {
        self.w = World.init();
        self.res = .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
        self.res.events.update();
        self.gi = self.res.catalog.goodIndex("garden_bed").?;
        self.e = self.w.spawn(.{
            comp.Vigor{ .v = 10, .max = 10 },
            comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
            comp.InventoryBiomass{ .v = 10 },
            comp.Goods{},
            comp.Generators{},
            comp.Granted{},
        });
        self.w.get(self.e, comp.Goods).?.count[self.gi] = 1;
        self.w.get(self.e, comp.Generators).?.progress[self.gi] = 1e9;
    }

    fn refusal(self: *Rig) ?events.Refused {
        var cursor: u64 = 0;
        return self.res.events.readerAt(events.Refused, &cursor).next();
    }
};

test "toggle refuses a good that is not an owned generator, without mutating" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.res.catalog.deinit();
    const spear = rig.res.catalog.goodIndex("spear").?;
    _ = rig.res.events.writer(events.ToggleGenerator).push(.{ .agent = rig.e, .gi = spear });
    ecs.run(&rig.w, &rig.res, generators_toggle);
    try testing.expect(!rig.w.get(rig.e, comp.Generators).?.off[spear]);
    try testing.expectEqual(events.Refused{ .agent = rig.e, .intent = .toggle_generator, .reason = .unavailable }, rig.refusal().?);
}

test "toggle switches an owned generator off once per intent" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.res.catalog.deinit();
    _ = rig.res.events.writer(events.ToggleGenerator).push(.{ .agent = rig.e, .gi = rig.gi });
    ecs.run(&rig.w, &rig.res, generators_toggle);
    ecs.run(&rig.w, &rig.res, generators_toggle);
    try testing.expect(rig.w.get(rig.e, comp.Generators).?.off[rig.gi]);
    try testing.expect(rig.refusal() == null);
}

test "collect refuses a switched-off generator without mutating and emits Refused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.res.catalog.deinit();
    rig.w.get(rig.e, comp.Generators).?.off[rig.gi] = true;
    _ = rig.res.events.writer(events.CollectGenerator).push(.{ .agent = rig.e, .gi = rig.gi });
    ecs.run(&rig.w, &rig.res, generators_collect);
    try testing.expectEqual(@as(f32, 1e9), rig.w.get(rig.e, comp.Generators).?.progress[rig.gi]);
    try testing.expectEqual(@as(f32, 0), rig.w.get(rig.e, comp.InventoryFood).?.v);
    try testing.expectEqual(events.Refused.Reason.off, rig.refusal().?.reason);
    try testing.expectEqual(@as(usize, 0), rig.res.events.len(events.Collected));
}

test "collect settles a ready cycle and emits Collected; the update system matures it again" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.res.catalog.deinit();
    _ = rig.res.events.writer(events.CollectGenerator).push(.{ .agent = rig.e, .gi = rig.gi });
    ecs.run(&rig.w, &rig.res, generators_collect);
    try testing.expectEqual(@as(f32, 0), rig.w.get(rig.e, comp.Generators).?.progress[rig.gi]);
    try testing.expect(rig.w.get(rig.e, comp.InventoryFood).?.v > 0);
    var cursor: u64 = 0;
    const got = rig.res.events.readerAt(events.Collected, &cursor).next().?;
    try testing.expectEqual(rig.gi, got.gi);
    try testing.expect(got.receipt.len > 0);
    try testing.expect(rig.refusal() == null);

    rig.res.time.dt = 5;
    ecs.run(&rig.w, &rig.res, generators);
    try testing.expectEqual(@as(f32, 5), rig.w.get(rig.e, comp.Generators).?.progress[rig.gi]);
}
