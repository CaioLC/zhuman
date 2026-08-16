const std = @import("std");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");
const world = @import("./world.zig");
const Resources = res_mod.Resources;
const World = world.World;
const Entity = world.Entity;
const Query = ecs.Query;
const With = ecs.With;

/// Advance the run clock while the actor lives. Driven by the player's presence — with no
/// player (dead) the clock freezes, so the game-over screen shows the day you died. One
/// player today, so this bumps `elapsed` once for the frame it finds one.
pub fn advance_clock(
    res: *Resources,
    q: Query(.{ comp.Vigor, With(tag.Player) }),
) void {
    var it = q.iter();
    if (it.next() != null) res.time.elapsed += res.time.dt;
}

/// Spoil the larder toward zero at `spoils` units/second — food rots, so a surplus can't
/// simply be banked forever (this is what storage capital will later mitigate).
pub fn update_food(
    res: *Resources,
    q: Query(.{comp.InventoryFood}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |f| {
        f.v -= dt * f.spoils;
        if (f.v < 0) f.v = 0;
    }
}

/// Vigor drained by starvation once the larder is empty, in vigor/day. ~2.5 days from a
/// full tank to death — the countdown that makes rationing a real decision.
const starve_per_day: f32 = 4.0;

/// Per-day food consumption multiplier for the player-set eating policy.
fn ration_mult(s: comp.Metabolism.Setting) f32 {
    return switch (s) {
        .ration => 0.5,
        .normal => 1.0,
        .feast => 2.0,
    };
}

/// The metabolism loop: every agent with a `Metabolism` eats continuously from its own
/// larder — no eat action, eating happens regardless; the *rate* is the agent's standing
/// choice (`Metabolism.setting`). Food converts to vigor as it's consumed (scaled by the
/// larder's `quality`, clamped at `max`); an **empty larder starves vigor down** instead —
/// this is the drain that finally makes `mark_dead` fire, and the clock pressure that
/// makes every action intentional: ration and stay weak, feast and burn the stock.
/// Edge-crossings feed the log once, on the frame they happen. Runs after `update_food`
/// (spoilage claims its share first) and before `mark_dead` (starving to 0 dies the same
/// frame).
pub fn metabolize(
    res: *Resources,
    q: Query(.{ comp.Vigor, comp.InventoryFood, comp.Metabolism }),
) void {
    const dt_days = res.time.dt / res_mod.secs_per_day;
    var it = q.iter();
    while (it.next()) |entry| {
        const vigor, const food, const met = entry;
        const food_before = food.v;
        const frac_before = vigor.v / vigor.max;

        if (food.v > 0) {
            const want = met.base_rate * ration_mult(met.setting) * dt_days;
            const eaten = @min(food.v, want);
            food.v -= eaten;
            vigor.v = @min(vigor.v + eaten * 2.0 * @as(f32, @floatFromInt(food.quality)), vigor.max);
        } else {
            vigor.v = @max(0, vigor.v - starve_per_day * dt_days);
        }

        // Edge-triggered log lines — once, on the crossing frame. The vigor thresholds
        // only ever cross *downward* here while starving (eating raises), so these read
        // as hunger, not labor fatigue.
        if (food_before > 0 and food.v <= 0) res.log.push(.warn, "Your food has run out.");
        const frac = vigor.v / vigor.max;
        if (frac_before >= 0.35 and frac < 0.35) res.log.push(.warn, "You feel weak with hunger.");
        if (frac_before >= 0.12 and frac < 0.12) res.log.push(.danger, "You are starving.");
    }
}

/// Tag any actor whose `Vigor` has drained to zero as `Dead` — vigor `0` is death. Guards
/// on `has` so it tags once. Starvation (`metabolize` on an empty larder) is what drains
/// vigor to zero in practice; labor can't (its energy gate is strict).
pub fn mark_dead(
    res: *Resources,
    w: *World,
    q: Query(.{ Entity, comp.Vigor }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const e, const vigor = entry;
        if (vigor.v <= 0 and !w.has(e, tag.Dead)) {
            w.add(e, tag.Dead{});
            res.log.push(.danger, "You perished, cold and starved.");
        }
    }
}

/// Reap every entity tagged `Dead`. Collects ids first, then despawns: `despawn`
/// swap-removes from the `Dead` storage this query iterates, so mutating mid-walk
/// would shuffle the dense array and skip entities. Once the actor is gone, the UI
/// (which queries it with `MaybeSingle`) shows the "start over" screen.
pub fn despawn_dead(
    w: *World,
    q: Query(.{ Entity, tag.Dead }),
) void {
    var dead: [world.MAX_ENTITIES]Entity = undefined;
    var n: usize = 0;
    var it = q.iter();
    while (it.next()) |entry| {
        dead[n] = entry[0]; // entry = .{ Entity, *Dead }; we only need the id
        n += 1;
    }
    for (dead[0..n]) |e| w.despawn(e);
}

// ============================ Tests ==========================================

/// A Resources with only the fields `metabolize` touches (`time`, `log`, `game`)
/// initialized — the SDL-backed fields stay undefined and untouched.
fn test_res(dt: f32) Resources {
    var res: Resources = undefined;
    res.time = .{ .dt = dt };
    res.log = .{};
    res.game = .{};
    return res;
}

test "metabolize eats continuously, converting food to vigor (clamped at max)" {
    var w = World.init();
    var res = test_res(res_mod.secs_per_day); // one full day per tick
    const e = w.spawn(.{
        comp.Vigor{ .v = 5, .max = 10 },
        comp.InventoryFood{ .v = 2, .quality = 1, .spoils = 0 },
        comp.Metabolism{}, // normal: 1.5 food/day
    });

    ecs.run(&w, &res, metabolize);
    try std.testing.expectEqual(@as(f32, 0.5), w.get(e, comp.InventoryFood).?.v); // 2 − 1.5
    try std.testing.expectEqual(@as(f32, 8), w.get(e, comp.Vigor).?.v); // 5 + 1.5·2·q1
    try std.testing.expectEqual(@as(usize, 0), res.log.count); // nothing crossed
}

test "metabolize at feast burns the larder dry and logs the crossing" {
    var w = World.init();
    var res = test_res(res_mod.secs_per_day);
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 2, .quality = 1, .spoils = 0 },
        comp.Metabolism{ .setting = .feast }, // wants 3/day, finds only 2
    });

    ecs.run(&w, &res, metabolize);
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v);
    try std.testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // clamped at max
    try std.testing.expectEqual(@as(usize, 1), res.log.count); // "Your food has run out."
}

test "metabolize starves vigor down on an empty larder, logging the thresholds" {
    var w = World.init();
    var res = test_res(res_mod.secs_per_day);
    const e = w.spawn(.{
        comp.Vigor{ .v = 5, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.Metabolism{ .setting = .ration }, // setting is irrelevant when starving
    });

    ecs.run(&w, &res, metabolize); // 5 → 1 (starve 4/day): crosses weak (3.5) and starving (1.2)
    try std.testing.expectEqual(@as(f32, 1), w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(usize, 2), res.log.count);

    ecs.run(&w, &res, metabolize); // 1 → 0 (clamped), no re-logging — mark_dead's turn
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(usize, 2), res.log.count);
}
