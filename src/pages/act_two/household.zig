//! `act_two/household` — Act II's content for the shared `household` rail template.
//! SETTLEMENT holds the aggregates: how many people against the housing, the energy generated
//! and consumed, how long the larder feeds everyone at the eating policy's rate, when water
//! runs short at its flow, the hall's vigor, and the per-day FLOWS (an inflow reads `better`,
//! a deficit `worse`, no flow `flat`). BODY is the player's own condition: recovery, the work
//! pace on the current ration, and what the body is working with (`pages/body.zig`).
//!
//! The stocks, the vigor, the eating rate and the pace are live; the population is
//! `Sim.population`'s stand-in, and the housing, the energy rate, the flows and the per-person
//! ration are stand-ins from `fixtures.zig`. Pure projection into the frame arena; no nodes.

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
const Sentence = t.HouseholdSentence;
const Tone = t.HouseholdTone;

/// A per-day flow as the rail prints it: `+6/day`, `-3/day`.
fn flowText(a: std.mem.Allocator, per_day: f32) ![]const u8 {
    return a.print("{s}{d:.0}/day", .{ if (per_day >= 0) "+" else "-", @abs(per_day) });
}

/// Days the larder feeds `people` at `rate` times the normal ration; null when nobody eats.
pub fn larderDays(food: f32, people: f32, rate: f32) ?f32 {
    const per_day = people * fx.ration_per_person * rate;
    if (per_day <= 0) return null;
    return @max(0, food) / per_day;
}

/// Days until water runs out at its per-day flow; null while the flow holds or fills.
pub fn waterDays(water: f32, per_day: f32) ?f32 {
    if (per_day >= 0) return null;
    return @max(0, water) / -per_day;
}

/// The tone of a runway of `days`: under two days is a shortage, under a week a caution.
pub fn runwayTone(days: f32) Tone {
    if (days < 2) return .danger;
    if (days < 7) return .warn;
    return .good;
}

/// The settlement's aggregates around agent `e`'s stocks.
fn settlement(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HouseholdSettlement {
    const a = ctx.arena;
    var lines: std.ArrayList(Line) = .empty;

    const people = ctx.res.game.sim.population;
    try lines.append(a, .{
        .key = "population",
        .label = "Population",
        .value = try a.print("{d:.0}/{d:.0}", .{ people, fx.capacityOf(people) }),
        .tone = .fg,
    });
    // Generated against consumed: the net is what the value's color says.
    try lines.append(a, .{
        .key = "energy",
        .label = "Energy",
        .value = try a.print("+{d} / \u{2212}{d}", .{ @round(fx.energy_gen), @round(fx.energy_consumed) }),
        .verdict = vd.marginDelta(fx.energy_gen - fx.energy_consumed, .higher),
    });
    // The larder at the eating policy's rate: the rail's slider moves this line.
    const rate = if (world.get(e, comp.Metabolism)) |m| ctx.res.game.config.clampMetabolism(m.rate) else 1;
    if (larderDays(ledger.balance(world, e, .food), people, rate)) |d| {
        try lines.append(a, .{ .key = "larder", .label = "Larder feeds all", .value = try a.print("{d:.1}d", .{d}), .tone = runwayTone(d) });
    }
    if (waterDays(ledger.balance(world, e, .water), fx.flowOf(.water))) |d| {
        try lines.append(a, .{ .key = "water", .label = "Water runs short in", .value = try a.print("{d:.1}d", .{d}), .verdict = vd.of(d < 2, .low, .attention) });
    } else {
        try lines.append(a, .{ .key = "water", .label = "Water", .value = "holds", .tone = .good });
    }
    // The hall's vigor reads the player's condition (a stand-in for per-person vigor).
    if (world.get(e, comp.Condition)) |c| try lines.append(a, .{
        .key = "vigor",
        .label = "Vigor across the hall",
        .value = switch (c.band) {
            .alive => "rested",
            .weary => "weary",
            .spent => "spent",
        },
        .tone = switch (c.band) {
            .alive => .good,
            .weary => .warn,
            .spent => .danger,
        },
    });

    const flows = try a.alloc(Line, fx.flows.len);
    for (fx.flows, flows) |f, *l| l.* = .{
        .key = @tagName(f.resource),
        .label = f.resource.labelIn(2),
        .value = try flowText(a, f.per_day),
        .verdict = vd.marginDelta(f.per_day, .higher),
    };
    return .{ .lines = lines.items, .section_title = "FLOWS / DAY", .section = flows };
}

/// Project agent `e` and its settlement into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HouseholdContent {
    const a = ctx.arena;
    var sentences: std.ArrayList(Sentence) = .empty;
    const outlook = world.get(e, comp.Outlook);
    if (outlook) |o| try sentences.append(a, try body.recovery(a, o.recovery));
    // The pace the player works at on this ration; the normal ration's with no projection.
    try sentences.append(a, try body.pace(a, if (outlook) |o| o.pace else 1));
    return .{
        .settlement = try settlement(ctx, world, e),
        .body = .{ .sentences = sentences.items, .lines = try body.lines(a, world, e) },
    };
}

test "the larder runway follows the people and the eating rate" {
    // 23 food feeds 7 people 10.3 days at the normal ration.
    try std.testing.expectApproxEqAbs(@as(f32, 10.27), larderDays(23, 7, 1).?, 0.01);
    // A lavish ration (2x) halves it; a meager one (0.5x) doubles it.
    try std.testing.expectApproxEqAbs(larderDays(23, 7, 1).? / 2, larderDays(23, 7, 2).?, 0.001);
    try std.testing.expectApproxEqAbs(larderDays(23, 7, 1).? * 2, larderDays(23, 7, 0.5).?, 0.001);
    try std.testing.expectEqual(@as(?f32, null), larderDays(23, 0, 1));
}

test "water runs short only on a deficit, and the runway tones by length" {
    try std.testing.expectApproxEqAbs(@as(f32, 3), waterDays(9, -3).?, 1e-5);
    try std.testing.expectEqual(@as(?f32, null), waterDays(9, 0));
    try std.testing.expectEqual(@as(?f32, null), waterDays(9, 2));
    try std.testing.expectEqual(Tone.danger, runwayTone(1.5));
    try std.testing.expectEqual(Tone.warn, runwayTone(3));
    try std.testing.expectEqual(Tone.good, runwayTone(10.3));
}

test "SETTLEMENT leads with the population against its housing, then the energy rate" {
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
    try std.testing.expectEqualStrings("population", s.lines[0].key);
    try std.testing.expectEqualStrings("520/640", s.lines[0].value);
    try std.testing.expectEqualStrings("energy", s.lines[1].key);
    try std.testing.expectEqualStrings("+7 / \u{2212}5", s.lines[1].value);
    // More generated than consumed reads as a gain.
    try std.testing.expect(s.lines[1].verdict.? == vd.marginDelta(1, .higher));
    // The hall's vigor closes the aggregates; the flows are their own section.
    try std.testing.expectEqualStrings("vigor", s.lines[s.lines.len - 1].key);
    try std.testing.expectEqualStrings("FLOWS / DAY", s.section_title);
    try std.testing.expectEqual(fx.flows.len, s.section.len);
}

test "BODY is the player's own: it ends on the work pace, 100% at the normal ration or with no projection, the slowest pace's share unfed" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Condition{}});

    var c = try content(&ctx, &w, e);
    // No projection: the pace alone, and no line about the settlement.
    try std.testing.expectEqual(@as(usize, 1), c.body.sentences.len);
    var last = c.body.sentences[c.body.sentences.len - 1];
    try std.testing.expectEqualStrings("pace", last.key);
    try std.testing.expectEqualStrings("Work pace ", last.prefix);
    try std.testing.expectEqualStrings("100%", last.value);
    try std.testing.expectEqualStrings(".", last.suffix);

    const cfg = res.game.config;
    w.add(e, comp.Outlook{ .pace = cfg.pace(1.0, 1, false) });
    c = try content(&ctx, &w, e);
    try std.testing.expectEqualStrings("recovery", c.body.sentences[0].key);
    last = c.body.sentences[c.body.sentences.len - 1];
    try std.testing.expectEqualStrings("pace", last.key);
    try std.testing.expectEqualStrings("69%", last.value);
}
