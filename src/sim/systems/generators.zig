//! Collectable generators: the handlers for `ToggleGenerator` (`capital.toggle_generator`) and
//! `CollectGenerator` (`capital.collect_generator`), and the update system that matures every
//! held generator not switched off and collects the `auto` ones that are ready
//! (`capital.run_generators`). A refused intent changes nothing and is answered by `Refused`; a
//! collection, the player's or an `auto` one, emits `Collected` from the rule.

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
        if (capital.toggle_generator(w, it.agent, cat, it.ai)) |reason| {
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
        if (capital.collect_generator(w, it.agent, res, it.ai)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .collect_generator, .reason = reason });
        }
    }
}

/// Accumulate held generators not switched off toward readiness by this frame's `dt`, and
/// collect each `auto` one that is ready.
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
    ai: u16 = 0,

    /// An agent owning one garden bed whose Tend garden cycle is complete.
    fn init(self: *Rig) !void {
        self.w = try World.init(testing.allocator);
        errdefer self.w.deinit();
        self.res = .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
        self.res.events.update();
        self.ai = self.res.catalog.actionIndex("tend_garden").?;
        self.e = self.w.spawn(.{
            comp.Vigor{ .v = 10, .max = 10 },
            comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
            comp.InventoryBiomass{ .v = 10 },
            comp.Goods{},
            comp.Generators{},
            comp.Granted{},
        });
        self.w.get(self.e, comp.Goods).?.count[self.res.catalog.goodIndex("garden_bed").?] = 1;
        self.w.get(self.e, comp.Generators).?.progress[self.ai] = 1e9;
    }

    fn deinit(self: *Rig) void {
        self.w.deinit();
        self.res.catalog.deinit();
    }

    fn refusal(self: *Rig) ?events.Refused {
        var cursor: u64 = 0;
        return self.res.events.readerAt(events.Refused, &cursor).next();
    }
};

test "toggle refuses a verb that is not a held generator, without mutating" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const hunt = rig.res.catalog.actionIndex("hunt").?;
    _ = rig.res.events.writer(events.ToggleGenerator).push(.{ .agent = rig.e, .ai = hunt });
    ecs.run(&rig.w, &rig.res, generators_toggle);
    try testing.expectEqual(comp.Generators.Mode.on, rig.w.get(rig.e, comp.Generators).?.mode[hunt]);
    try testing.expectEqual(events.Refused{ .agent = rig.e, .intent = .toggle_generator, .reason = .unavailable }, rig.refusal().?);
}

test "toggle moves a held generator to its next mode once per intent" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = rig.res.events.writer(events.ToggleGenerator).push(.{ .agent = rig.e, .ai = rig.ai });
    ecs.run(&rig.w, &rig.res, generators_toggle);
    ecs.run(&rig.w, &rig.res, generators_toggle);
    try testing.expectEqual(comp.Generators.Mode.auto, rig.w.get(rig.e, comp.Generators).?.mode[rig.ai]);
    try testing.expect(rig.refusal() == null);
}

test "collect refuses a switched-off generator without mutating and emits Refused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.w.get(rig.e, comp.Generators).?.mode[rig.ai] = .off;
    _ = rig.res.events.writer(events.CollectGenerator).push(.{ .agent = rig.e, .ai = rig.ai });
    ecs.run(&rig.w, &rig.res, generators_collect);
    try testing.expectEqual(@as(f32, 1e9), rig.w.get(rig.e, comp.Generators).?.progress[rig.ai]);
    try testing.expectEqual(@as(f32, 0), rig.w.get(rig.e, comp.InventoryFood).?.v);
    try testing.expectEqual(events.Refused.Reason.off, rig.refusal().?.reason);
    try testing.expectEqual(@as(usize, 0), rig.res.events.len(events.Collected));
}

test "collect settles a ready cycle and emits Collected; the update system matures it again" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = rig.res.events.writer(events.CollectGenerator).push(.{ .agent = rig.e, .ai = rig.ai });
    ecs.run(&rig.w, &rig.res, generators_collect);
    try testing.expectEqual(@as(f32, 0), rig.w.get(rig.e, comp.Generators).?.progress[rig.ai]);
    try testing.expect(rig.w.get(rig.e, comp.InventoryFood).?.v > 0);
    var cursor: u64 = 0;
    const got = rig.res.events.readerAt(events.Collected, &cursor).next().?;
    try testing.expectEqual(rig.ai, got.ai);
    try testing.expect(got.receipt.len > 0);
    try testing.expect(rig.refusal() == null);

    rig.res.time.dt = 5;
    ecs.run(&rig.w, &rig.res, generators);
    try testing.expectEqual(@as(f32, 5), rig.w.get(rig.e, comp.Generators).?.progress[rig.ai]);
}
