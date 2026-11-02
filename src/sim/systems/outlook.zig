//! The `outlook` system: the one writer of `comp.Outlook`, the body's projection at the current
//! eating rate. From the agent's real component state (larder units and quality, the vigor
//! deficit and ceiling, the base metabolism, the bounded rate, and `vigor_per_food`) it computes
//! **food days** (how long the larder lasts at the current rate) and the **recovery** outcome:
//! either a time to full vigor in days, or an explicit no-recovery state (empty larder,
//! zero-quality food, already at the ceiling, or a larder that cannot reach full). It reads the
//! same products the metabolism loop applies (`base_rate × rate` consumption,
//! `× vigor_per_food × quality` conversion), so the projection cannot disagree with what
//! happens. It runs before `log` in each act's `handle` and `update` sets, so the BODY lines read
//! the frame's state; running it again on an unchanged world changes nothing.

const std = @import("std");
const ecs = @import("../ecs.zig");
const comp = @import("../components.zig");
const res_mod = @import("../res.zig");

const Recovery = comp.Outlook.Recovery;

/// Write every agent's outlook. The rate is made legal through `Config.clampMetabolism`, as
/// `metabolize` makes it.
pub fn outlook(
    cfg: *const res_mod.Config,
    q: ecs.Query(.{ comp.Vigor, comp.InventoryFood, comp.Metabolism, comp.Outlook }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const vigor: *comp.Vigor, const food: *comp.InventoryFood, const met: *comp.Metabolism, const out: *comp.Outlook = entry;
        out.* = project(.{
            .food = food.v,
            .quality = food.quality,
            .vigor = vigor.v,
            .vigor_max = vigor.max,
            .base_rate = met.base_rate,
            .rate = cfg.clampMetabolism(met.rate),
            .vigor_per_food = cfg.vigor_per_food,
        });
    }
}

/// The inputs, read from the agent's components and the config.
pub const Inputs = struct {
    food: f32,
    quality: u8,
    vigor: f32,
    vigor_max: f32,
    base_rate: f32,
    rate: f32,
    vigor_per_food: f32,
};

/// Project food days and recovery from the current state. Pure; mirrors the metabolism loop's
/// arithmetic (`metabolize`): consumption per day is `base_rate × rate`, and each consumed unit
/// yields `vigor_per_food × quality` vigor (clamped at the ceiling).
pub fn project(in: Inputs) comp.Outlook {
    const per_day = @max(0, in.base_rate * in.rate); // food/day consumed
    const food_days: f32 = if (in.food <= 0 or per_day <= 0) 0 else in.food / per_day;

    const deficit = @max(0, in.vigor_max - in.vigor);
    const rec: Recovery = blk: {
        if (deficit <= 0) break :blk .at_ceiling; // already full
        if (in.food <= 0) break :blk .no_food; // starving, not recovering
        if (in.quality == 0) break :blk .no_quality; // food gives no vigor

        const q: f32 = @floatFromInt(in.quality);
        const gain_per_day = per_day * in.vigor_per_food * q; // vigor gained/day while eating
        if (gain_per_day <= 0) break :blk .no_quality; // degenerate (rate or vpf zero)

        // The most vigor the *current* larder can restore before it runs out.
        const restorable = in.food * in.vigor_per_food * q;
        if (restorable < deficit) {
            // The larder empties before full — a partial recovery of `restorable`, lasting the
            // food-days window (`food / per_day` days).
            break :blk .{ .partial = .{ .days = food_days, .restored = restorable } };
        }
        // Full is reachable: days = deficit / gain_per_day.
        break :blk .{ .recovering = .{ .days = deficit / gain_per_day } };
    };

    return .{ .food_days = food_days, .recovery = rec };
}

// ============================ Tests =====================================================

const testing = std.testing;
const base_in = Inputs{ .food = 4, .quality = 1, .vigor = 5, .vigor_max = 10, .base_rate = 1.5, .rate = 1.0, .vigor_per_food = 2.0 };

test "food_days is food / (base_rate*rate); empty larder is 0 food_days and no_food" {
    // 4 / (1.5*1.0) = 2.667 days.
    try testing.expectApproxEqAbs(@as(f32, 2.6667), project(base_in).food_days, 1e-3);
    // Faster rate ⇒ fewer food days: 4 / (1.5*2.0) = 1.333.
    var fast = base_in;
    fast.rate = 2.0;
    try testing.expectApproxEqAbs(@as(f32, 1.3333), project(fast).food_days, 1e-3);
    // Empty larder: 0 food days, and recovery is the no_food state (not a spurious time).
    var empty = base_in;
    empty.food = 0;
    try testing.expectEqual(@as(f32, 0), project(empty).food_days);
    try testing.expect(project(empty).recovery == .no_food);
}

test "at ceiling ⇒ at_ceiling (no recovery needed)" {
    var full = base_in;
    full.vigor = full.vigor_max;
    try testing.expect(project(full).recovery == .at_ceiling);
}

test "zero-quality food ⇒ no_quality (belly full, no vigor)" {
    var zeroq = base_in;
    zeroq.quality = 0;
    try testing.expect(project(zeroq).recovery == .no_quality);
    // Food days still count — you still eat it, it just does not restore vigor.
    try testing.expect(project(zeroq).food_days > 0);
}

test "recovering: full reachable ⇒ time = deficit / gain_per_day" {
    // deficit 5, gain/day = 1.5*1.0*2.0*1 = 3.0 ⇒ 5/3 = 1.667 days; larder (4) restores
    // 4*2*1 = 8 vigor ≥ deficit 5, so full is reachable.
    const p = project(base_in);
    switch (p.recovery) {
        .recovering => |r| try testing.expectApproxEqAbs(@as(f32, 1.6667), r.days, 1e-3),
        else => try testing.expect(false),
    }
}

test "partial: larder too small to reach full ⇒ partial with restored vigor" {
    // Big deficit, tiny larder: deficit 9 (vigor 1/10), food 1 restores only 1*2*1 = 2 < 9.
    var small = base_in;
    small.vigor = 1;
    small.food = 1;
    const p = project(small);
    switch (p.recovery) {
        .partial => |r| {
            try testing.expectApproxEqAbs(@as(f32, 2.0), r.restored, 1e-4); // 1*2*1
            try testing.expectApproxEqAbs(@as(f32, 1.0 / 1.5), r.days, 1e-3); // food-days window
        },
        else => try testing.expect(false),
    }
}

test "rate min/max shift food_days and recovery time monotonically" {
    var lo = base_in;
    lo.rate = 0.5;
    var hi = base_in;
    hi.rate = 2.0;
    // Ration (0.5) stretches the larder; feast (2.0) shortens it.
    try testing.expect(project(lo).food_days > project(base_in).food_days);
    try testing.expect(project(hi).food_days < project(base_in).food_days);
    // Feast recovers faster (more gain/day) — fewer days to full when reachable.
    // At rate 2.0: gain/day = 1.5*2*2*1 = 6, deficit 5 ⇒ 0.833; larder 4 restores 8 ≥ 5.
    switch (project(hi).recovery) {
        .recovering => |r| try testing.expectApproxEqAbs(@as(f32, 5.0 / 6.0), r.days, 1e-3),
        else => try testing.expect(false),
    }
}

test "outlook writes the projection at the clamped rate; a second run changes nothing" {
    var w = try ecs.World.init(std.testing.allocator);
    defer w.deinit();
    var res = res_mod.Resources{};
    const e = w.spawn(.{
        comp.Vigor{ .v = 5, .max = 10 },
        comp.InventoryFood{ .v = 4, .quality = 1, .spoils = 0 },
        comp.Metabolism{ .rate = 9 }, // clamps to the 2.0 maximum
        comp.Outlook{},
    });

    ecs.run(&w, &res, outlook);
    const once = w.get(e, comp.Outlook).?.*;
    try testing.expectApproxEqAbs(@as(f32, 4.0 / 3.0), once.food_days, 1e-4); // 4 / (1.5*2)
    try testing.expectApproxEqAbs(@as(f32, 5.0 / 6.0), once.recovery.recovering.days, 1e-4);

    // Idempotent: the same world, run again, writes the same outlook.
    ecs.run(&w, &res, outlook);
    try testing.expectEqual(once, w.get(e, comp.Outlook).?.*);
}
