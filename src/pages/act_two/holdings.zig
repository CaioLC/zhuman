//! `act_two/holdings` — Act II's content for the shared `holdings` rail template (ACT2-15):
//! every good the settlement owns (Act I's carried across the curtain beside Act II's) with its
//! short copy, the per-day FLOWS (an inflow reads `better`, a deficit `worse`, no flow `flat`), and the
//! **population-relevant** BODY projections: how many live under one roof, how long the larder
//! feeds them at the eating policy's rate, when water runs short at its flow, and the hall's
//! vigor. No decorative durability/maintenance meters: those systems do not exist.
//!
//! The roster, the stocks, the vigor and the eating rate are live; the population is
//! `Sim.population`'s stand-in, and the flows and the per-person ration come from
//! `fixtures.zig`, until a population and production model compute them. Pure projection into
//! the frame arena; no nodes.

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
const Line = t.HoldingsLine;
const Sentence = t.HoldingsSentence;
const Tone = @TypeOf(@as(Sentence, undefined).tone);

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

/// Project agent `e`'s settlement into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HoldingsContent {
    const a = ctx.arena;
    const cat = &ctx.res.game.catalog;

    var owned: std.ArrayList(Line) = .empty;
    var units: u32 = 0;
    if (world.get(e, comp.Goods)) |g| {
        for (cat.goods, 0..) |*rec, gi| {
            const n = g.count[gi];
            if (n == 0) continue;
            units += n;
            const label = if (n > 1) try a.print("{s} \u{00d7}{d}", .{ rec.name, n }) else rec.name;
            try owned.append(a, .{ .key = rec.id, .label = label, .value = rec.copy.short });
        }
    }

    const flows = try a.alloc(Line, fx.flows.len);
    for (fx.flows, flows) |f, *l| l.* = .{
        .key = @tagName(f.resource),
        .label = f.resource.labelIn(2),
        .value = try flowText(a, f.per_day),
        .verdict = vd.marginDelta(f.per_day, .higher),
    };

    var body: std.ArrayList(Sentence) = .empty;
    const people = ctx.res.game.sim.population;
    try body.append(a, .{ .key = "population", .prefix = "Population ", .value = try a.print("{d:.0}", .{people}), .suffix = " under one roof.", .tone = .good });

    // The larder at the eating policy's rate: the rail's slider moves this line.
    const rate = if (world.get(e, comp.Metabolism)) |m| ctx.res.game.config.clampMetabolism(m.rate) else 1;
    if (larderDays(ledger.balance(world, e, .food), people, rate)) |d| {
        try body.append(a, .{ .key = "larder", .prefix = "Larder feeds all for ", .value = try a.print("{d:.1}d", .{d}), .suffix = ".", .tone = runwayTone(d) });
    }
    if (waterDays(ledger.balance(world, e, .water), fx.flowOf(.water))) |d| {
        try body.append(a, .{ .key = "water", .prefix = "Water runs short in ", .value = try a.print("{d:.1}d", .{d}), .suffix = ".", .verdict = vd.of(d < 2, .low, .attention) });
    } else {
        try body.append(a, .{ .key = "water", .prefix = "Water ", .value = "holds", .suffix = ".", .tone = .good });
    }
    // The hall's vigor reads the household's condition until each person carries their own.
    if (world.get(e, comp.Condition)) |c| {
        const cond = c.band;
        try body.append(a, .{ .key = "vigor", .prefix = "Vigor across the hall: ", .value = switch (cond) {
            .alive => "rested",
            .weary => "weary",
            .spent => "spent",
        }, .suffix = ".", .tone = switch (cond) {
            .alive => .good,
            .weary => .warn,
            .spent => .danger,
        } });
    }

    return .{
        .count = try a.print("{d} KINDS, {d}", .{ owned.items.len, units }),
        .roster = owned.items,
        .empty_roster = "nothing established yet",
        .section_title = "FLOWS / DAY",
        .section = flows,
        .body = body.items,
    };
}

test "the larder runway follows the people and the eating rate" {
    // The prototype's numbers: 23 food feeds 7 people 10.3 days at the normal ration.
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
