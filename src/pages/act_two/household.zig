//! `act_two/household` — Act II's content for the shared `household` rail template.
//! SETTLEMENT holds the aggregates in one list: how many people against the housing, then what
//! the settlement produces and demands a day of energy and of every stock (`+14 / −8`; more
//! produced than demanded reads `better`, less `worse`, even `flat`), each stock followed by
//! the stockpile, floored to a whole number (`22`; `low` at zero). Energy is not held and
//! shows none. BODY is the
//! player's own condition, the same projection as Act I's (`pages/body.zig`).
//!
//! The stockpile is the player's ledger, the same balances as the header's stockline. The
//! population is `Sim.population`'s stand-in, and the housing and the production and demand
//! are stand-ins from `fixtures.zig`. Pure projection into the frame arena; no nodes.

const std = @import("std");
const ha = @import("ha");
const fx = @import("./fixtures.zig");

const comp = ha.sim.comp;
const ledger = ha.sim.rules.ledger;
const uic = ha.ui_client;
const vd = uic.style.verdict;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("../templates/root.zig");
const body = @import("../body.zig");
const Line = t.HouseholdLine;

/// Production against demand as the rail prints it: `+14 / −8`.
fn flowText(a: std.mem.Allocator, f: fx.FlowRecord) ![]const u8 {
    return a.print("+{d:.0} / \u{2212}{d:.0}", .{ f.produced, f.demanded });
}

/// The settlement's aggregates, its stockpile read from agent `e`'s ledger.
fn settlement(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HouseholdSettlement {
    const a = ctx.arena;
    const people = ctx.res.game.sim.population;
    const lines = try a.alloc(Line, 1 + fx.flows.len);
    lines[0] = .{
        .key = "population",
        .label = "Population",
        .value = try a.print("{d:.0}/{d:.0}", .{ people, fx.capacityOf(people) }),
        .tone = .fg,
    };
    // Both sides of every flow; the net is what the value's color says.
    for (fx.flows, lines[1..]) |f, *l| {
        l.* = .{
            .key = f.key,
            .label = f.label,
            .value = try flowText(a, f),
            .verdict = vd.marginDelta(f.net(), .higher),
            .stock = "",
        };
        // What is held, floored so it never shows more than there is.
        if (f.resource) |r| {
            const held = ledger.balance(world, e, r);
            l.stock = try std.fmt.allocPrint(a, "{d:.0}", .{@as(f64, @floatFromInt(@import("../fmt.zig").held_whole(held)))});
            l.stock_verdict = vd.when(held <= 0, .low);
        }
    }
    return .{ .lines = lines };
}

/// Project agent `e` and its settlement into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HouseholdContent {
    return .{ .settlement = try settlement(ctx, world, e), .body = try body.project(ctx.arena, world, e) };
}

test "SETTLEMENT is the population against its housing, then both sides of energy and every stock" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{ comp.InventoryFood{ .v = 22.9 }, comp.Goods{} });
    res.game.sim.population = 520;

    const s = (try content(&ctx, &w, e)).settlement.?;
    // The population, then energy, the six stocks of the header, and coin, in one list.
    try std.testing.expectEqual(@as(usize, 9), s.lines.len);
    try std.testing.expectEqualStrings("population", s.lines[0].key);
    try std.testing.expectEqualStrings("520/640", s.lines[0].value);
    try std.testing.expectEqualStrings("energy", s.lines[1].key);
    try std.testing.expectEqualStrings("+7 / \u{2212}5", s.lines[1].value);
    // More produced than demanded reads as a gain, less as a loss, even as flat.
    try std.testing.expect(s.lines[1].verdict.? == vd.marginDelta(1, .higher));
    // The population and energy hold nothing; a stock shows its stockpile, floored.
    try std.testing.expect(s.lines[0].stock == null);
    try std.testing.expectEqualStrings("", s.lines[1].stock.?);
    try std.testing.expectEqualStrings("food", s.lines[2].key);
    try std.testing.expectEqualStrings("22", s.lines[2].stock.?);
    try std.testing.expect(s.lines[2].stock_verdict == null);
    for (s.lines) |l| {
        if (std.mem.eql(u8, l.key, "water")) {
            try std.testing.expectEqualStrings("+9 / \u{2212}12", l.value);
            try std.testing.expect(l.verdict.? == vd.marginDelta(-1, .higher));
            // None held reads low.
            try std.testing.expectEqualStrings("0", l.stock.?);
            try std.testing.expect(l.stock_verdict.? == vd.when(true, .low).?);
        }
        if (std.mem.eql(u8, l.key, "metal")) try std.testing.expect(l.verdict.? == vd.marginDelta(0, .higher));
    }
}

test "BODY is the player's own, the projection Act I shows" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Outlook{ .food_days = 5.2, .recovery = .at_ceiling, .pace = 1 }});

    const c = try content(&ctx, &w, e);
    try std.testing.expectEqual(@as(usize, 3), c.body.sentences.len);
    try std.testing.expectEqualStrings("coverage", c.body.sentences[0].key);
    try std.testing.expectEqualStrings("5.2d", c.body.sentences[0].value);
    try std.testing.expectEqualStrings("pace", c.body.sentences[2].key);
}
