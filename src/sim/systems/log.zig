//! The log system: the one reader that turns facts into `Log` lines. It reads every fact with
//! the `.log` cursor and words each with the rules' text helpers and the catalog. It reads the
//! fact types in the order the frame writes them (the handlers' facts, then the tick's in tick
//! order), so one agent's lines land in the order they happened. A fact no line describes
//! (`GoodsChanged`, an upward `BandCrossed`, a build beginning) is read and passed over.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const actions = @import("../rules/actions.zig");
const capital = @import("../rules/capital.zig");
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

    var ran_out = ev.reader(events.FoodRanOut, .log);
    while (ran_out.next()) |_| sim.log.push(.warn, "Your food has run out.");

    var crossed = ev.reader(events.BandCrossed, .log);
    while (crossed.next()) |f| {
        // Only a fall reads as hunger; climbing back is silent.
        if (f.from == .alive and f.to != .alive) sim.log.push(.warn, "You feel weak with hunger.");
        if (f.from != .spent and f.to == .spent) sim.log.push(.danger, "You are starving.");
    }

    var done = ev.reader(events.WorkDone, .log);
    while (done.next()) |f| switch (f.doing) {
        .labor => {
            var buf: [96]u8 = undefined;
            const msg = actions.receiptText(&buf, cat, f.receipt, f.act);
            sim.log.push(if (std.mem.eql(u8, msg, actions.nothing_text)) .dim else .normal, msg);
        },
        .build => |gi| {
            const rec = &cat.goods[gi];
            const units: u32 = if (f.receipt.len > 0) @intFromFloat(f.receipt.slice()[0].qty) else 0;
            if (f.owned > units) {
                // A repeat build is stock, not a second effect: count it and say so.
                var nbuf: [48]u8 = undefined;
                var buf: [80]u8 = undefined;
                sim.log.push(.good, std.mem.print(&buf, "Another {s}. You have {d}.", .{ capital.lowerName(rec.name, &nbuf), f.owned }) catch "You made another.");
            } else {
                sim.log.push(.good, if (rec.copy.built.len > 0) rec.copy.built else "You built it.");
            }
        },
    };

    var lost = ev.reader(events.WorkLost, .log);
    while (lost.next()) |_| sim.log.push(.dim, "The work came to nothing.");

    var broke = ev.reader(events.GoodBroke, .log);
    while (broke.next()) |f| {
        var nbuf: [48]u8 = undefined;
        var buf: [64]u8 = undefined;
        sim.log.push(.warn, std.mem.print(&buf, "Your {s} broke.", .{capital.lowerName(cat.goods[f.gi].name, &nbuf)}) catch "Something of yours broke.");
    }

    var reach = ev.reader(events.RecipeInReach, .log);
    while (reach.next()) |f| {
        var nbuf: [48]u8 = undefined;
        var buf: [96]u8 = undefined;
        sim.log.push(.good, std.mem.print(&buf, "A new recipe is within reach: {s}.", .{capital.lowerName(cat.goods[f.gi].name, &nbuf)}) catch "A new recipe is within reach.");
    }

    var died = ev.reader(events.Died, .log);
    while (died.next()) |_| sim.log.push(.danger, "You perished, cold and starved.");

    // Read and passed over: no line describes them.
    var changed = ev.reader(events.GoodsChanged, .log);
    while (changed.next()) |_| {}
}

// ============================ Tests ==========================================

const testing = std.testing;
const Tone = @import("../log.zig").Tone;

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

fn expectLine(rig: *const Rig, i: usize, tone: Tone, text: []const u8) !void {
    try testing.expectEqualStrings(text, rig.line(i));
    try testing.expectEqual(tone, rig.res.sim.log.get(i).tone);
}

test "the body's facts: food ran out, a fall in band, death; a climb is silent" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.emit(events.FoodRanOut{ .agent = 0 });
    rig.emit(events.BandCrossed{ .agent = 0, .from = .alive, .to = .spent });
    rig.emit(events.BandCrossed{ .agent = 0, .from = .spent, .to = .alive });
    rig.emit(events.BandCrossed{ .agent = 0, .from = .weary, .to = .spent });
    rig.emit(events.Died{ .agent = 0 });
    rig.run();
    try testing.expectEqual(@as(usize, 5), rig.res.sim.log.count);
    try expectLine(&rig, 4, .warn, "Your food has run out.");
    try expectLine(&rig, 3, .warn, "You feel weak with hunger.");
    try expectLine(&rig, 2, .danger, "You are starving.");
    try expectLine(&rig, 1, .danger, "You are starving.");
    try expectLine(&rig, 0, .danger, "You perished, cold and starved.");
}

test "WorkDone: the labor receipt, a miss, a first build, a repeat build; WorkLost" {
    var rig = try Rig.init();
    defer rig.deinit();
    const cat = &rig.res.catalog;
    const forage = cat.actionIndex("forage").?;
    const spear = cat.goodIndex("spear").?;
    const sandals = cat.goodIndex("sandals").?;
    var r = @import("../rules/ledger.zig").Receipt{};
    r.add(.{ .resource = .food }, 2.6);
    r.add(.{ .resource = .biomass }, 1.5);
    var one = @import("../rules/ledger.zig").Receipt{};
    one.add(.{ .good = spear }, 1);
    var pair = @import("../rules/ledger.zig").Receipt{};
    pair.add(.{ .good = sandals }, 1);
    rig.emit(events.WorkDone{ .agent = 0, .doing = .{ .labor = forage }, .receipt = r, .act = 1 });
    rig.emit(events.WorkDone{ .agent = 0, .doing = .{ .labor = forage }, .act = 1 });
    rig.emit(events.WorkDone{ .agent = 0, .doing = .{ .build = spear }, .receipt = one, .owned = 1 });
    rig.emit(events.WorkDone{ .agent = 0, .doing = .{ .build = sandals }, .receipt = pair, .owned = 2 });
    rig.emit(events.WorkLost{ .agent = 0, .doing = .{ .labor = forage } });
    rig.run();
    try testing.expectEqual(@as(usize, 5), rig.res.sim.log.count);
    try expectLine(&rig, 4, .normal, "You gathered 3 food and 2 materials.");
    try expectLine(&rig, 3, .dim, "You gathered nothing.");
    try expectLine(&rig, 2, .good, cat.goods[spear].copy.built);
    try expectLine(&rig, 1, .good, "Another sandals. You have 2.");
    try expectLine(&rig, 0, .dim, "The work came to nothing.");
}

test "a broken good, a recipe in reach; GoodsChanged says nothing" {
    var rig = try Rig.init();
    defer rig.deinit();
    const cat = &rig.res.catalog;
    rig.emit(events.GoodBroke{ .agent = 0, .gi = cat.goodIndex("sandals").? });
    rig.emit(events.RecipeInReach{ .agent = 0, .gi = cat.goodIndex("work_gloves").? });
    rig.emit(events.GoodsChanged{ .agent = 0 });
    rig.run();
    try testing.expectEqual(@as(usize, 2), rig.res.sim.log.count);
    try expectLine(&rig, 1, .warn, "Your sandals broke.");
    try expectLine(&rig, 0, .good, "A new recipe is within reach: work gloves.");
}
