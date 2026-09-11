//! `body` (ACT1-03) — the **authoritative BODY projection**: from an agent's real component
//! state (larder units + quality, vigor deficit/ceiling, base metabolism, the bounded rate, and
//! `vigor_per_food`) it computes **food coverage** (days the larder lasts at the current rate)
//! and the **recovery** outcome — either a time-to-full-vigor in days, or an explicit
//! unavailable/no-recovery state (empty larder, zero-quality food, already at the ceiling, or a
//! larder that cannot reach full). It reads the *same* products the metabolism loop applies
//! (`base_rate × rate` consumption, `× vigor_per_food × quality` conversion), so the projection
//! can never disagree with what actually happens.
//!
//! Leaf, pure, allocation-free — imports only `std`. The caller (Holdings/BODY, and the ACT1-08
//! ACTIONS eating panel) passes the scalar inputs it read from the components/config; this owns
//! no ECS and no formatting, only the arithmetic and the state classification.

const std = @import("std");

/// The recovery outcome of a projection — a tagged result, never a bare number, so the caller
/// renders the right copy for each state instead of guessing from a sentinel.
pub const Recovery = union(enum) {
    /// Already at the vigor ceiling — nothing to recover.
    at_ceiling,
    /// No larder — the body is starving, not recovering.
    no_food,
    /// Food has zero quality — it fills the belly but yields no vigor, so no recovery.
    no_quality,
    /// The larder yields some vigor but **cannot reach the ceiling**; carries the days the
    /// larder lasts and the vigor it will have restored by then (a partial recovery).
    partial: struct { days: f32, restored: f32 },
    /// Full vigor is reachable at the current rate; carries the days to reach it.
    recovering: struct { days: f32 },
};

/// A complete BODY projection: `coverage` (days of food at the current rate; `0` when empty)
/// and the `recovery` outcome.
pub const Projection = struct {
    coverage: f32,
    recovery: Recovery,
};

/// The inputs, read from the agent's components/config by the caller.
pub const Inputs = struct {
    food: f32,
    quality: u8,
    vigor: f32,
    vigor_max: f32,
    base_rate: f32,
    rate: f32,
    vigor_per_food: f32,
};

/// Project coverage + recovery from the current state. Pure; mirrors the metabolism loop's
/// arithmetic (`metabolize`): consumption per day is `base_rate × rate`, and each consumed unit
/// yields `vigor_per_food × quality` vigor (clamped at the ceiling).
pub fn project(in: Inputs) Projection {
    const per_day = @max(0, in.base_rate * in.rate); // food/day consumed
    const coverage: f32 = if (in.food <= 0 or per_day <= 0) 0 else in.food / per_day;

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
            // coverage window (`food / per_day` days).
            break :blk .{ .partial = .{ .days = coverage, .restored = restorable } };
        }
        // Full is reachable: days = deficit / gain_per_day.
        break :blk .{ .recovering = .{ .days = deficit / gain_per_day } };
    };

    return .{ .coverage = coverage, .recovery = rec };
}

// ============================ Tests =====================================================

const testing = std.testing;
const base_in = Inputs{ .food = 4, .quality = 1, .vigor = 5, .vigor_max = 10, .base_rate = 1.5, .rate = 1.0, .vigor_per_food = 2.0 };

test "coverage is food / (base_rate*rate); empty larder is 0 coverage and no_food" {
    // 4 / (1.5*1.0) = 2.667 days.
    try testing.expectApproxEqAbs(@as(f32, 2.6667), project(base_in).coverage, 1e-3);
    // Faster rate ⇒ less coverage: 4 / (1.5*2.0) = 1.333.
    var fast = base_in;
    fast.rate = 2.0;
    try testing.expectApproxEqAbs(@as(f32, 1.3333), project(fast).coverage, 1e-3);
    // Empty larder: 0 coverage, and recovery is the no_food state (not a spurious time).
    var empty = base_in;
    empty.food = 0;
    try testing.expectEqual(@as(f32, 0), project(empty).coverage);
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
    // Coverage still counts — you still eat it, it just does not restore vigor.
    try testing.expect(project(zeroq).coverage > 0);
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
            try testing.expectApproxEqAbs(@as(f32, 1.0 / 1.5), r.days, 1e-3); // coverage window
        },
        else => try testing.expect(false),
    }
}

test "rate min/max shift coverage and recovery time monotonically" {
    var lo = base_in;
    lo.rate = 0.5;
    var hi = base_in;
    hi.rate = 2.0;
    // Ration (0.5) stretches coverage; feast (2.0) shortens it.
    try testing.expect(project(lo).coverage > project(base_in).coverage);
    try testing.expect(project(hi).coverage < project(base_in).coverage);
    // Feast recovers faster (more gain/day) — fewer days to full when reachable.
    // At rate 2.0: gain/day = 1.5*2*2*1 = 6, deficit 5 ⇒ 0.833; larder 4 restores 8 ≥ 5.
    switch (project(hi).recovery) {
        .recovering => |r| try testing.expectApproxEqAbs(@as(f32, 5.0 / 6.0), r.days, 1e-3),
        else => try testing.expect(false),
    }
}
