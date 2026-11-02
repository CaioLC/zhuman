//! The Exchange: Act II's milestone, its price, the rule that unlocks it, and the handler for
//! `RaiseExchange`. Raising it pays the price from the ledger and stands it; the settlement then
//! reads as Act III. A refused raise changes nothing and is answered by `Refused`; one that
//! stands emits `ExchangeRaised`.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const comp = @import("../components.zig");
const ledger = @import("../rules/ledger.zig");
const roster = @import("../data/roster.zig");
const res_mod = @import("../res.zig");

const World = ecs.World;
const Reason = events.Refused.Reason;

/// The Exchange's price, the prototype's (`act-ii.html`).
pub const cost = [_]struct { roster.Resource, f32 }{ .{ .biomass, 80 }, .{ .minerals, 40 }, .{ .metal, 24 } };

/// The population the Exchange waits on: strictly more than this many people.
pub const people_needed: f32 = 500;

/// Where the Exchange stands: locked until its conditions are met, unfunded while an input is
/// short, ready to raise, then done.
pub const Lifecycle = enum { locked, unfunded, ready, done };

/// The Exchange's lifecycle: standing once raised; locked until a ring-4 technology stands and
/// the settlement is strictly more than 500 people; then unfunded while any input is short.
pub fn lifecycle(standing: bool, people: f32, ring_four: bool, short_kinds: u32) Lifecycle {
    if (standing) return .done;
    if (!(ring_four and people > people_needed)) return .locked;
    return if (short_kinds > 0) .unfunded else .ready;
}

/// The first ring-4 technology established on `board`, alphabetically (the card names one), or
/// null while none is.
pub fn ringFour(cat: *const roster.Catalog, board: *const comp.Research) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (cat.technologies, 0..) |tech, i| {
        if (tech.coord.ring() != 4 or board.state[i] != .researched) continue;
        if (best == null or std.mem.order(u8, tech.name, best.?) == .lt) best = tech.name;
    }
    return best;
}

/// How many of the price's inputs the agent holds too little of.
pub fn shortKinds(w: *const World, e: ecs.Entity) u32 {
    var n: u32 = 0;
    for (cost) |c| n += @intFromBool(ledger.balance(w, e, c[0]) < c[1]);
    return n;
}

pub fn raise_exchange(
    w: *World,
    sim: *res_mod.Sim,
    cat: *const roster.Catalog,
    intents: ecs.EventReader(events.RaiseExchange, .exchange),
    raised: ecs.EventWriter(events.ExchangeRaised),
    refused: ecs.EventWriter(events.Refused),
) void {
    while (intents.next()) |it| {
        const four = if (w.get(it.agent, comp.Research)) |board| ringFour(cat, board) != null else false;
        const reason: ?Reason = switch (lifecycle(sim.exchange.standing, sim.population, four, shortKinds(w, it.agent))) {
            .done => .already_standing,
            .locked => .locked,
            .unfunded => .short,
            .ready => null,
        };
        if (reason) |r| {
            _ = refused.push(.{ .agent = it.agent, .intent = .raise_exchange, .reason = r });
            continue;
        }
        for (cost) |c| _ = ledger.move(w, it.agent, c[0], -c[1]);
        sim.exchange.standing = true;
        _ = raised.push(.{ .agent = it.agent });
    }
}

// ============================ Tests ==========================================

const testing = std.testing;
const Resources = res_mod.Resources;

test "the Exchange unlocks past 500 people with a ring-4 technology, and funds separately" {
    const x = testing.expectEqual;
    try x(Lifecycle.locked, lifecycle(false, 500, true, 0));
    try x(Lifecycle.ready, lifecycle(false, 501, true, 0));
    try x(Lifecycle.locked, lifecycle(false, 501, false, 0));
    // Each short input keeps it unfunded on its own.
    try x(Lifecycle.unfunded, lifecycle(false, 501, true, 1));
    try x(Lifecycle.unfunded, lifecycle(false, 501, true, 3));
    try x(Lifecycle.done, lifecycle(true, 0, false, 3));
}

const Rig = struct {
    w: World,
    res: Resources,
    e: ecs.Entity = 0,

    /// A settlement of 520 holding `n` of each input, with a ring-4 tile established when `four`.
    fn init(self: *Rig, n: f32, four: bool) !void {
        self.w = try World.init(testing.allocator);
        errdefer self.w.deinit();
        self.res = .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
        self.res.events.update();
        self.res.sim.population = 520;
        var board = comp.Research.entry(&self.res.catalog);
        if (four) for (self.res.catalog.technologies, 0..) |t, i| {
            if (t.coord.ring() == 4) {
                board.state[i] = .researched;
                break;
            }
        };
        self.e = self.w.spawn(.{ comp.InventoryBiomass{ .v = n }, comp.InventoryMinerals{ .v = n }, comp.InventoryMetal{ .v = n }, board });
    }

    fn deinit(self: *Rig) void {
        self.w.deinit();
        self.res.catalog.deinit();
    }

    fn raise(self: *Rig) void {
        _ = self.res.events.writer(events.RaiseExchange).push(.{ .agent = self.e });
        ecs.run(&self.w, &self.res, raise_exchange);
    }

    /// The live refusal's reason, or null; clears the store for the next attempt.
    fn refusal(self: *Rig) ?Reason {
        var cursor: u64 = 0;
        const got = self.res.events.readerAt(events.Refused, &cursor).next();
        self.res.events.update();
        self.res.events.update();
        return if (got) |r| r.reason else null;
    }
};

test "raise_exchange refuses locked, short and standing without paying" {
    var locked: Rig = undefined;
    try locked.init(100, false); // no ring-4 tile
    defer locked.deinit();
    locked.raise();
    try testing.expectEqual(@as(?Reason, .locked), locked.refusal());
    try testing.expectEqual(@as(f32, 100), ledger.balance(&locked.w, locked.e, .biomass));
    // With the tile but the stand-in population, still locked.
    var small: Rig = undefined;
    try small.init(100, true);
    defer small.deinit();
    small.res.sim.population = 48;
    small.raise();
    try testing.expectEqual(@as(?Reason, .locked), small.refusal());

    var short: Rig = undefined;
    try short.init(30, true);
    defer short.deinit();
    short.raise();
    try testing.expectEqual(@as(?Reason, .short), short.refusal());
    try testing.expectEqual(@as(f32, 30), ledger.balance(&short.w, short.e, .biomass));

    var standing: Rig = undefined;
    try standing.init(100, true);
    defer standing.deinit();
    standing.res.sim.exchange.standing = true;
    standing.raise();
    try testing.expectEqual(@as(?Reason, .already_standing), standing.refusal());
    try testing.expectEqual(@as(f32, 100), ledger.balance(&standing.w, standing.e, .biomass));
    try testing.expectEqual(@as(usize, 0), standing.res.events.len(events.ExchangeRaised));
}

test "raise_exchange pays the price, stands the Exchange and emits ExchangeRaised" {
    var rig: Rig = undefined;
    try rig.init(100, true);
    defer rig.deinit();
    rig.raise();
    try testing.expect(rig.res.sim.exchange.standing);
    try testing.expectEqual(@as(f32, 20), ledger.balance(&rig.w, rig.e, .biomass));
    try testing.expectEqual(@as(f32, 60), ledger.balance(&rig.w, rig.e, .minerals));
    try testing.expectEqual(@as(f32, 76), ledger.balance(&rig.w, rig.e, .metal));
    var cursor: u64 = 0;
    try testing.expectEqual(events.ExchangeRaised{ .agent = rig.e }, rig.res.events.readerAt(events.ExchangeRaised, &cursor).next().?);
    try testing.expectEqual(@as(?Reason, null), rig.refusal());
}
