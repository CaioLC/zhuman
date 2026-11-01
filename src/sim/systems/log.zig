//! The log system: the one reader that turns facts into `Log` lines. It reads every fact with
//! the `.log` cursor, in the order the tick writes them, and words each with the rules' text
//! helpers and the catalog. A fact that no line describes is read and passed over.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const actions = @import("../rules/actions.zig");
const res_mod = @import("../res.zig");
const roster = @import("../data/roster.zig");

/// Run last in the frame, after every writer of a fact.
pub fn log(sim: *res_mod.Sim, cat: *const roster.Catalog, ev: *ecs.Events) void {
    var begun = ev.reader(events.WorkBegun, .log);
    while (begun.next()) |f| {
        if (f.weary) sim.log.push(.warn, "You feel weak. Work will yield less.");
        switch (f.doing) {
            .labor => {
                var buf: [64]u8 = undefined;
                sim.log.push(.dim, actions.paymentText(&buf, cat, f.energy, f.paid, f.act));
            },
            .build => {},
        }
    }
}

// ============================ Tests ==========================================

const testing = std.testing;

const Rig = struct {
    res: res_mod.Resources,

    fn init() !Rig {
        var r = Rig{ .res = .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) } };
        r.res.events.update();
        return r;
    }

    fn deinit(self: *Rig) void {
        self.res.catalog.deinit();
    }

    fn emit(self: *Rig, fact: anytype) void {
        _ = self.res.events.writer(@TypeOf(fact)).push(fact);
    }

    fn run(self: *Rig) void {
        var w = ecs.World.init();
        ecs.run(&w, &self.res, log);
    }

    fn line(self: *const Rig, i: usize) []const u8 {
        return self.res.sim.log.get(i).text();
    }
};

test "WorkBegun: the payment line, the weariness warning before it, nothing for a build" {
    var rig = try Rig.init();
    defer rig.deinit();
    const forage = rig.res.catalog.actionIndex("forage").?;
    var paid = @import("../rules/ledger.zig").Receipt{};
    paid.add(.{ .resource = .biomass }, 1);
    rig.emit(events.WorkBegun{ .agent = 0, .doing = .{ .labor = forage }, .weary = true, .energy = 4, .paid = paid, .act = 1 });
    rig.emit(events.WorkBegun{ .agent = 0, .doing = .{ .build = 0 }, .energy = 2 });
    rig.run();
    try testing.expectEqual(@as(usize, 2), rig.res.sim.log.count);
    try testing.expectEqualStrings("You feel weak. Work will yield less.", rig.line(1));
    try testing.expectEqual(@import("../log.zig").Tone.warn, rig.res.sim.log.get(1).tone);
    try testing.expectEqualStrings("You spend 4.0e 1m to begin.", rig.line(0));
    try testing.expectEqual(@import("../log.zig").Tone.dim, rig.res.sim.log.get(0).tone);
    rig.run(); // each fact is worded once
    try testing.expectEqual(@as(usize, 2), rig.res.sim.log.count);
}
