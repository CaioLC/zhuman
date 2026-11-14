//! `act_two/household` — Act II's content for the shared `household` rail template.
//! SETTLEMENT holds the aggregates: how many people against the housing, then PRODUCTION /
//! DEMAND, what the settlement makes and uses a day of energy and of every stock (`+14 / −8`;
//! more produced than demanded reads `better`, less `worse`, even `flat`). BODY is the
//! player's own condition, the same projection as Act I's (`pages/body.zig`).
//!
//! The population is `Sim.population`'s stand-in, and the housing and the production and
//! demand are stand-ins from `fixtures.zig`. Pure projection into the frame arena; no nodes.

const std = @import("std");
const ha = @import("ha");
const fx = @import("./fixtures.zig");

const comp = ha.sim.comp;
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

/// The settlement's aggregates.
fn settlement(ctx: *uic.UiCtx) !t.HouseholdSettlement {
    const a = ctx.arena;
    const people = ctx.res.game.sim.population;
    const lines = try a.alloc(Line, 1);
    lines[0] = .{
        .key = "population",
        .label = "Population",
        .value = try a.print("{d:.0}/{d:.0}", .{ people, fx.capacityOf(people) }),
        .tone = .fg,
    };
    // Both sides of every flow; the net is what the value's color says.
    const flows = try a.alloc(Line, fx.flows.len);
    for (fx.flows, flows) |f, *l| l.* = .{
        .key = f.key,
        .label = f.label,
        .value = try flowText(a, f),
        .verdict = vd.marginDelta(f.net(), .higher),
    };
    return .{ .lines = lines, .section_title = "PRODUCTION / DEMAND \u{00b7} DAY", .section = flows };
}

/// Project agent `e` and its settlement into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HouseholdContent {
    return .{ .settlement = try settlement(ctx), .body = try body.project(ctx.arena, world, e) };
}

test "SETTLEMENT is the population against its housing, then both sides of energy and every stock" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Condition{}});
    res.game.sim.population = 520;

    const s = (try content(&ctx, &w, e)).settlement.?;
    try std.testing.expectEqual(@as(usize, 1), s.lines.len);
    try std.testing.expectEqualStrings("population", s.lines[0].key);
    try std.testing.expectEqualStrings("520/640", s.lines[0].value);
    try std.testing.expectEqualStrings("PRODUCTION / DEMAND \u{00b7} DAY", s.section_title);
    // Energy, the six stocks of the header, and coin.
    try std.testing.expectEqual(@as(usize, 8), s.section.len);
    try std.testing.expectEqualStrings("energy", s.section[0].key);
    try std.testing.expectEqualStrings("+7 / \u{2212}5", s.section[0].value);
    // More produced than demanded reads as a gain, less as a loss, even as flat.
    try std.testing.expect(s.section[0].verdict.? == vd.marginDelta(1, .higher));
    for (s.section) |l| {
        if (std.mem.eql(u8, l.key, "water")) {
            try std.testing.expectEqualStrings("+9 / \u{2212}12", l.value);
            try std.testing.expect(l.verdict.? == vd.marginDelta(-1, .higher));
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
