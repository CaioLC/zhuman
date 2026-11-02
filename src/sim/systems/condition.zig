//! The `condition` system: the one writer of `comp.Condition`. It brings every agent's band up
//! to date with its vigor (`rules/condition.refresh`) and emits `BandCrossed` for each band that
//! moved. It runs before the frame's last readers (`outlook`, `quotes`, `log`) in each act's
//! `handle` and `update` sets, after `metabolize` and after every rule that moves vigor, so the
//! metabolism's crossing is a fact the same tick and a band moved by a handler or by a finished
//! build is current when the page reads it. Running it again on an unchanged world changes
//! nothing and emits nothing.

const std = @import("std");
const ecs = @import("../ecs.zig");
const comp = @import("../components.zig");
const events = @import("../events.zig");
const res_mod = @import("../res.zig");
const rule = @import("../rules/condition.zig");

const Entity = ecs.Entity;

pub fn condition(
    cfg: *const res_mod.Config,
    crossed: ecs.EventWriter(events.BandCrossed),
    q: ecs.Query(.{ Entity, comp.Vigor, comp.Condition }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const e: Entity, const vigor: *comp.Vigor, const cond: *comp.Condition = entry;
        if (rule.refresh(cfg, vigor, cond)) |c| _ = crossed.push(.{ .agent = e, .from = c.from, .to = c.to });
    }
}

// ============================ Tests ==========================================

const testing = std.testing;

test "condition writes the band and reports the crossing once; a second run changes nothing" {
    var w = ecs.World.init();
    var res = res_mod.Resources{};
    res.events.update();
    const e = w.spawn(.{ comp.Vigor{ .v = 3, .max = 10 }, comp.Condition{} });
    var heard: u64 = 0;

    ecs.run(&w, &res, condition);
    try testing.expectEqual(comp.Condition.Band.weary, w.get(e, comp.Condition).?.band);
    try testing.expectEqual(events.BandCrossed{ .agent = e, .from = .alive, .to = .weary }, res.events.readerAt(events.BandCrossed, &heard).next().?);

    // Idempotent: the same world, run again, keeps the band and emits nothing.
    const before = w.get(e, comp.Condition).?.*;
    ecs.run(&w, &res, condition);
    try testing.expectEqual(before, w.get(e, comp.Condition).?.*);
    try testing.expect(res.events.readerAt(events.BandCrossed, &heard).next() == null);
}
