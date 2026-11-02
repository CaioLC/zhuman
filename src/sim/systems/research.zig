//! The research handler: `Research` intents establish a technology on the agent's board
//! (`rules/research.research`) and pay its cost from the ledger in the same function, so the
//! board and the ledger have one writer. A refused intent changes nothing and is answered by
//! `Refused`; one that establishes the tile emits `Researched` with the tiles it opened.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const comp = @import("../components.zig");
const board_rule = @import("../rules/research.zig");
const ledger = @import("../rules/ledger.zig");
const roster = @import("../data/roster.zig");

const World = ecs.World;
const Reason = events.Refused.Reason;

/// The resources a research cost names, read from the ledger as whole units.
const wedges = [_]roster.Resource{ .food, .water, .fuel, .metal, .minerals, .biomass };

/// The tiles `Researched.newly` can name, one bit each by catalog index.
const newly_bits = @bitSizeOf(@FieldType(events.Researched, "newly"));

pub fn research(
    w: *World,
    cat: *const roster.Catalog,
    intents: ecs.EventReader(events.Research, .research),
    done: ecs.EventWriter(events.Researched),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        var fact: events.Researched = .{ .agent = it.agent, .ti = it.ti };
        if (establish(w, cat, it, &fact.newly)) |reason| {
            _ = refused.push(.{ .agent = it.agent, .intent = .research, .reason = reason });
        } else {
            _ = done.push(fact);
        }
    }
}

/// Establish `it.ti` on the agent's board and pay for it, setting `newly` to the tiles that
/// became available; on any failure return the reason and change nothing.
fn establish(w: *World, cat: *const roster.Catalog, it: events.Research, newly: *u64) ?Reason {
    const board = w.get(it.agent, comp.Research) orelse return .no_board;
    if (it.ti >= cat.technologies.len) return .unavailable;

    var bal = board_rule.Balances{};
    for (wedges) |r| bal.set(r, @intFromFloat(@max(0, @floor(ledger.balance(w, it.agent, r)))));
    var before: u64 = 0;
    for (0..@min(cat.technologies.len, newly_bits)) |i| if (board.state[i] == .available) {
        before |= @as(u64, 1) << @intCast(i);
    };
    switch (board_rule.research(cat, board, it.ti, &bal)) {
        .not_available => return .unavailable,
        .unaffordable => return .unaffordable,
        .researched => {},
    }
    for (cat.technologies[it.ti].cost) |line| {
        const r = roster.Catalog.resource(line.item) orelse continue;
        _ = ledger.move(w, it.agent, r, -@round(line.n));
    }
    newly.* = 0;
    for (0..@min(cat.technologies.len, newly_bits)) |i| {
        const bit = @as(u64, 1) << @intCast(i);
        if (board.state[i] == .available and before & bit == 0) newly.* |= bit;
    }
    return null;
}

// ============================ Tests ==========================================

const testing = std.testing;
const Resources = @import("../res.zig").Resources;

const Rig = struct {
    w: World,
    res: Resources,
    e: ecs.Entity = 0,

    /// A settlement at the curtain's board, holding `n` of every research resource.
    fn init(self: *Rig, n: f32) !void {
        self.w = try World.init(testing.allocator);
        errdefer self.w.deinit();
        self.res = .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
        self.res.events.update();
        self.e = self.w.spawn(.{
            comp.InventoryFood{ .v = n },
            comp.InventoryWater{ .v = n },
            comp.InventoryFuel{ .v = n },
            comp.InventoryMetal{ .v = n },
            comp.InventoryMinerals{ .v = n },
            comp.InventoryBiomass{ .v = n },
            comp.Research.entry(&self.res.catalog),
        });
    }

    fn deinit(self: *Rig) void {
        self.w.deinit();
        self.res.catalog.deinit();
    }

    fn refusal(self: *Rig) ?events.Refused {
        var cursor: u64 = 0;
        return self.res.events.readerAt(events.Refused, &cursor).next();
    }

    /// The first available tile that names a cost.
    fn openTile(self: *Rig) u16 {
        const board = self.w.get(self.e, comp.Research).?;
        for (self.res.catalog.technologies, 0..) |t, i| {
            if (board.state[i] == .available and t.cost.len > 0) return @intCast(i);
        }
        unreachable;
    }
};

test "research refuses without a board, a locked tile, or a short ledger, and changes nothing" {
    var rig: Rig = undefined;
    try rig.init(0);
    defer rig.deinit();
    const ti = rig.openTile();
    const board_before = rig.w.get(rig.e, comp.Research).?.*;

    _ = rig.res.events.writer(events.Research).push(.{ .agent = rig.e, .ti = ti });
    ecs.run(&rig.w, &rig.res, research);
    try testing.expectEqual(events.Refused{ .agent = rig.e, .intent = .research, .reason = .unaffordable }, rig.refusal().?);
    try testing.expectEqual(board_before, rig.w.get(rig.e, comp.Research).?.*);
    try testing.expectEqual(@as(usize, 0), rig.res.events.len(events.Researched));

    rig.res.events.update();
    rig.res.events.update();
    const locked: u16 = for (0..rig.res.catalog.technologies.len) |i| {
        if (board_before.state[i] == .locked) break @intCast(i);
    } else unreachable;
    _ = rig.res.events.writer(events.Research).push(.{ .agent = rig.e, .ti = locked });
    ecs.run(&rig.w, &rig.res, research);
    try testing.expectEqual(Reason.unavailable, rig.refusal().?.reason);

    rig.res.events.update();
    rig.res.events.update();
    const nobody = rig.w.spawn(.{comp.InventoryFood{ .v = 99 }});
    _ = rig.res.events.writer(events.Research).push(.{ .agent = nobody, .ti = ti });
    ecs.run(&rig.w, &rig.res, research);
    try testing.expectEqual(Reason.no_board, rig.refusal().?.reason);
    try testing.expectEqual(@as(f32, 99), rig.w.get(nobody, comp.InventoryFood).?.v);
}

test "research establishes the tile, pays its cost from the ledger and names what it opened" {
    var rig: Rig = undefined;
    try rig.init(500);
    defer rig.deinit();
    const ti = rig.openTile();
    const tech = rig.res.catalog.technologies[ti];
    _ = rig.res.events.writer(events.Research).push(.{ .agent = rig.e, .ti = ti });
    ecs.run(&rig.w, &rig.res, research);
    ecs.run(&rig.w, &rig.res, research); // the intent is consumed once

    const board = rig.w.get(rig.e, comp.Research).?;
    try testing.expectEqual(roster.TechState.researched, board.state[ti]);
    for (tech.cost) |line| {
        const r = roster.Catalog.resource(line.item).?;
        try testing.expectEqual(500 - @round(line.n), ledger.balance(&rig.w, rig.e, r));
    }
    try testing.expect(rig.refusal() == null);
    var cursor: u64 = 0;
    const got = rig.res.events.readerAt(events.Researched, &cursor).next().?;
    try testing.expectEqual(ti, got.ti);
    try testing.expect(got.newly != 0);
    for (0..rig.res.catalog.technologies.len) |i| {
        if (got.newly & (@as(u64, 1) << @intCast(i)) != 0) try testing.expectEqual(roster.TechState.available, board.state[i]);
    }
    try testing.expectEqual(@as(usize, 1), rig.res.events.len(events.Researched));
}
