const std = @import("std");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");
const world = @import("./world.zig");
const actions = @import("./actions.zig");
const capital = @import("./capital.zig");
const roster = @import("./roster.zig");
const Resources = res_mod.Resources;
const World = world.World;
const Entity = world.Entity;
const Query = ecs.Query;
const With = ecs.With;

/// Advance the run clock while the actor lives. Driven by the player's presence — with no
/// player (dead) the clock freezes, so the game-over screen shows the day you died. One
/// player today, so this bumps `elapsed` once for the frame it finds one.
pub fn advance_clock(
    sim: *res_mod.Sim,
    time: *const res_mod.Time,
    q: Query(.{ comp.Vigor, With(tag.Player) }),
) void {
    var it = q.iter();
    if (it.next() != null) sim.elapsed += time.dt;
    sim.log.now = sim.elapsed; // lines pushed this frame carry the current game time
}

/// Spoil the larder toward zero at `spoils` units/second — food rots, so a surplus can't
/// simply be banked forever (this is what storage capital will later mitigate).
pub fn update_food(
    time: *const res_mod.Time,
    q: Query(.{comp.InventoryFood}),
) void {
    const dt = time.dt;
    var it = q.iter();
    while (it.next()) |f| {
        f.v -= dt * f.spoils;
        if (f.v < 0) f.v = 0;
    }
}

/// Net daily food drawdown (Holdings/BODY projection): the metabolism's per-day
/// consumption (`base_rate × rate` — the *same* product `metabolize` applies, with `rate` the
/// bounded scalar) minus a per-day generator inflow. `≤0` means the larder holds.
/// Lives here beside `metabolize` so the projection provably reads the loop's rate rather than
/// a copied tuning constant, and so it is covered by `zig build test`.
pub fn net_food_drawdown(base_rate: f32, rate: f32, inflow_per_day: f32) f32 {
    return base_rate * rate - inflow_per_day;
}

test "net_food_drawdown: consumption minus inflow; days = food/net when positive" {
    const base: f32 = 1.5;
    // The scalar rate scales the drawdown directly: normal (1.0) is base_rate; ration (0.5)
    // halves it; a big enough generator inflow makes it hold.
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), net_food_drawdown(base, 1.0, 0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), net_food_drawdown(base, 0.5, 0), 1e-4);
    try std.testing.expect(net_food_drawdown(base, 0.5, 1.0) <= 0);
    // Days-of-food is food / net when net is positive.
    const net = net_food_drawdown(base, 1.0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 4), @as(f32, 6) / net, 1e-4); // 6 / 1.5 = 4 days
}

/// The metabolism loop: every agent with a `Metabolism` eats continuously from its own
/// larder — no eat action, eating happens regardless; the *rate* is the agent's standing
/// choice (`Metabolism.rate`, a bounded scalar). Food converts to vigor as it's consumed (scaled by the
/// larder's `quality`, clamped at `max`); an **empty larder starves vigor down** instead —
/// this is the drain that finally makes `mark_dead` fire, and the clock pressure that
/// makes every action intentional: ration and stay weak, feast and burn the stock.
/// Edge-crossings feed the log once, on the frame they happen. Runs after `update_food`
/// (spoilage claims its share first) and before `mark_dead` (starving to 0 dies the same
/// frame).
pub fn metabolize(
    time: *const res_mod.Time,
    cfg: *const res_mod.Config,
    sim: *res_mod.Sim,
    q: Query(.{ comp.Vigor, comp.InventoryFood, comp.Metabolism }),
) void {
    const dt_days = time.dt / cfg.secs_per_day;
    var it = q.iter();
    while (it.next()) |entry| {
        const vigor: *comp.Vigor, const food: *comp.InventoryFood, const met: *comp.Metabolism = entry;
        const food_before = food.v;
        const frac_before = vigor.v / vigor.max;

        if (food.v > 0) {
            const want = met.base_rate * cfg.clampMetabolism(met.rate) * dt_days;
            const eaten = @min(food.v, want);
            food.v -= eaten;
            vigor.v = @min(vigor.v + eaten * cfg.vigor_per_food * @as(f32, @floatFromInt(food.quality)), vigor.max);
        } else {
            vigor.v = @max(0, vigor.v - cfg.starve_per_day * dt_days);
        }

        // Edge-triggered log lines — once, on the crossing frame. The vigor thresholds
        // only ever cross *downward* here while starving (eating raises), so these read
        // as hunger, not labor fatigue.
        if (food_before > 0 and food.v <= 0) sim.log.push(.warn, "Your food has run out.");
        const frac = vigor.v / vigor.max;
        const was = cfg.condition(frac_before);
        const now = cfg.condition(frac);
        if (was == .alive and now != .alive) sim.log.push(.warn, "You feel weak with hunger.");
        if (was != .spent and now == .spent) sim.log.push(.danger, "You are starving.");
    }
}

/// Tick every act in progress and resolve the ones whose time is up: dispatch `doing`
/// back to its completion half (deposit + receipt for labor, the grant for a build) and
/// drop the `Busy`. Collect-then-apply, like `despawn_dead`: finishing removes from the
/// storage this query iterates. Runs after `metabolize` (the body pays its keep while
/// working) and before `mark_dead` (a death this frame still forfeits nothing extra —
/// the work either resolved just now or despawns with the agent).
pub fn resolve_busy(
    res: *Resources,
    w: *World,
    q: Query(.{ Entity, comp.Busy }),
) void {
    var done: [world.MAX_ENTITIES]Entity = undefined;
    var n: usize = 0;
    var it = q.iter();
    while (it.next()) |entry| {
        const e: Entity, const b: *comp.Busy = entry;
        b.remaining -= res.time.dt;
        if (b.remaining <= 0) {
            done[n] = e;
            n += 1;
        }
    }
    for (done[0..n]) |e| {
        const b = w.get(e, comp.Busy).?.*; // copy out before removing the slot
        w.remove(e, comp.Busy);
        switch (b.doing) {
            // labor: draw at the locked quality, deposit, receipt
            .labor => |ai| actions.finish(w, e, res, ai, b.quality),
            // capital: own the good, settle what it does, receipt
            .build => |gi| capital.finish(w, e, res, gi),
        }
    }
}

/// Tag any actor whose `Vigor` has drained to zero as `Dead` — vigor `0` is death. Guards
/// on `has` so it tags once. Starvation (`metabolize` on an empty larder) is what drains
/// vigor to zero in practice; labor can't (its energy gate is strict).
pub fn mark_dead(
    sim: *res_mod.Sim,
    w: *World,
    q: Query(.{ Entity, comp.Vigor }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const e: Entity, const vigor: *comp.Vigor = entry;
        if (vigor.v <= 0 and !w.has(e, tag.Dead)) {
            w.add(e, tag.Dead{});
            sim.log.push(.danger, "You perished, cold and starved.");
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

/// **Eligibility transition tracking.** For each prerequisite-gated good of this act, when
/// its prerequisite becomes satisfied for the first time this run, log one "A new recipe is
/// within reach: {name}." Only goods with `needs` participate — a good with no prerequisite
/// is reachable from the first breath, so it is not a *transition* and never logs. The seen-set
/// is sim state (`Sim.reach_seen`, by catalog index), so it survives
/// frames untouched by the UI — tab switches, filter/sort changes, and rebuilds cannot re-emit
/// the line; only this tick, on the actual false→true edge, does. Cleared by `Sim.reset` so a
/// fresh run re-announces. Runs once per frame over the player.
pub fn track_reach(
    res: *Resources,
    w: *World,
    q: Query(.{ Entity, comp.Vigor, With(tag.Player) }),
) void {
    const cat = &res.catalog;
    var it = q.iter();
    while (it.next()) |entry| {
        const e: Entity = entry[0];
        for (cat.goods, 0..) |rec, gi| {
            // Only this act's goods with a `needs` transition; one without is reachable from
            // the start and would false-fire on the first tick, so it is skipped entirely, and
            // a later act's recipe is announced by that act's own edge detector.
            if (rec.needs.len == 0 or rec.act > 1) continue;
            const met = capital.needsMet(w, e, cat, @intCast(gi));
            if (met and !res.sim.reach_seen[gi]) {
                res.sim.reach_seen[gi] = true;
                var nbuf: [48]u8 = undefined;
                var buf: [96]u8 = undefined;
                const msg = std.mem.print(&buf, "A new recipe is within reach: {s}.", .{capital.lowerName(rec.name, &nbuf)}) catch "A new recipe is within reach.";
                res.sim.log.push(.good, msg);
            } else if (!met) {
                // The prerequisite went away (tool broke) — allow a fresh announcement if it
                // returns, so the transition tracking is symmetric.
                res.sim.reach_seen[gi] = false;
            }
        }
    }
}

// ============================ Tests ==========================================

/// A Resources with only the groups `metabolize` touches (`time`, `sim`, `config`)
/// initialized — `platform` stays undefined and untouched.
fn test_res(dt: f32) Resources {
    var res: Resources = undefined;
    res.time = .{ .dt = dt };
    res.sim = .{};
    res.config = .{};
    return res;
}

test "resolve_busy ticks the work and resolves it exactly once, at completion" {
    var w = World.init();
    var res = test_res(0);
    res.catalog = try roster.load(std.testing.allocator, roster.shipped, null);
    defer res.catalog.deinit();
    res.time.dt = res_mod.hours_to_secs(2, res.config.secs_per_day); // 2h per tick
    const forage = res.catalog.actionIndex("forage").?; // 4h of work, innate
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = 0 },
        comp.Goods{},
        comp.Granted{},
        comp.Busy{ .doing = .{ .labor = forage }, .total = res_mod.hours_to_secs(4, res.config.secs_per_day), .remaining = res_mod.hours_to_secs(4, res.config.secs_per_day), .quality = 1 },
    });

    ecs.run(&w, &res, resolve_busy); // 2h in — still working
    try std.testing.expect(w.has(e, comp.Busy));
    try std.testing.expectEqual(@as(usize, 0), res.sim.log.count);

    ecs.run(&w, &res, resolve_busy); // 4h — done: deposit + receipt, Busy gone
    try std.testing.expect(!w.has(e, comp.Busy));
    try std.testing.expect(w.get(e, comp.InventoryFood).?.v >= 0);
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);

    ecs.run(&w, &res, resolve_busy); // idle tick — nothing to resolve
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);
}

test "metabolize eats continuously, converting food to vigor (clamped at max)" {
    var w = World.init();
    var res = test_res(0);
    res.time.dt = res.config.secs_per_day; // one full day per tick
    const e = w.spawn(.{
        comp.Vigor{ .v = 5, .max = 10 },
        comp.InventoryFood{ .v = 2, .quality = 1, .spoils = 0 },
        comp.Metabolism{}, // normal: 1.5 food/day
    });

    ecs.run(&w, &res, metabolize);
    try std.testing.expectEqual(@as(f32, 0.5), w.get(e, comp.InventoryFood).?.v); // 2 − 1.5
    try std.testing.expectEqual(@as(f32, 8), w.get(e, comp.Vigor).?.v); // 5 + 1.5·2·q1
    try std.testing.expectEqual(@as(usize, 0), res.sim.log.count); // nothing crossed
}

test "metabolize at feast burns the larder dry and logs the crossing" {
    var w = World.init();
    var res = test_res(0);
    res.time.dt = res.config.secs_per_day;
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 2, .quality = 1, .spoils = 0 },
        comp.Metabolism{ .rate = 2.0 }, // wants 3/day, finds only 2
    });

    ecs.run(&w, &res, metabolize);
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v);
    try std.testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // clamped at max
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count); // "Your food has run out."
}

test "metabolize starves vigor down on an empty larder, logging the thresholds" {
    var w = World.init();
    var res = test_res(0);
    res.time.dt = res.config.secs_per_day;
    const e = w.spawn(.{
        comp.Vigor{ .v = 5, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.Metabolism{ .rate = 0.5 }, // rate is irrelevant when starving
    });

    ecs.run(&w, &res, metabolize); // 5 → 1 (starve 4/day): crosses weak (3.5) and starving (1.2)
    try std.testing.expectEqual(@as(f32, 1), w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count);

    ecs.run(&w, &res, metabolize); // 1 → 0 (clamped), no re-logging — mark_dead's turn
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count);
}

test "track_reach logs a newly in-reach recipe once, not on repeats, and re-arms if the prereq goes away" {
    var w = World.init();
    var res = test_res(0);
    res.catalog = try roster.load(std.testing.allocator, roster.shipped, null);
    defer res.catalog.deinit();
    const hatchet = res.catalog.goodIndex("hatchet").?;
    // A player without Split wood: Work gloves / Chainsaw (both need it) are not in reach
    // yet, and goods that need nothing never announce.
    const e = w.spawn(.{ comp.Vigor{}, comp.Goods{}, comp.Granted{}, tag.Player{} });
    ecs.run(&w, &res, track_reach);
    try std.testing.expectEqual(@as(usize, 0), res.sim.log.count); // nothing became reachable

    // Own the hatchet (as finishing its build would): both goods that need Split wood
    // transition false→true this tick — two announcements, once each.
    w.get(e, comp.Goods).?.count[hatchet] = 1;
    ecs.run(&w, &res, track_reach);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count);
    try std.testing.expectEqual(@import("./log.zig").Tone.good, res.sim.log.get(0).tone);
    // The message names the good and uses the exact copy.
    try std.testing.expect(std.mem.find(u8, res.sim.log.get(0).text(), "within reach") != null);

    // A rebuild/tab-switch/sort does not re-run the tick; running it again emits nothing new.
    ecs.run(&w, &res, track_reach);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count); // no repeat

    // The prerequisite going away (tool broke) re-arms the announcement; regaining it logs again.
    w.get(e, comp.Goods).?.count[hatchet] = 0;
    ecs.run(&w, &res, track_reach);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count); // losing it does not log
    w.get(e, comp.Goods).?.count[hatchet] = 1;
    ecs.run(&w, &res, track_reach);
    try std.testing.expectEqual(@as(usize, 4), res.sim.log.count); // re-armed: two more
}

test "track_reach announces this act's recipes only" {
    var w = World.init();
    var res = test_res(0);
    res.catalog = try roster.load(std.testing.allocator, .{
        .actions =
        \\.{
        \\    .{ .id = "forage", .name = "Forage", .innate = true, .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\}
        ,
        .goods =
        \\.{
        \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .effects = .{ .{ .grant = "fish" } } },
        \\    .{ .id = "hook", .name = "Hook", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .needs = .{"fish"} },
        \\    .{ .id = "weir", .name = "Weir", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .needs = .{"fish"} },
        \\}
        ,
    }, null);
    defer res.catalog.deinit();
    const e = w.spawn(.{ comp.Vigor{}, comp.Goods{}, comp.Granted{}, tag.Player{} });
    w.get(e, comp.Goods).?.count[res.catalog.goodIndex("rod").?] = 1;
    ecs.run(&w, &res, track_reach);
    // The hook (this act) is announced; the weir (the next act) is not.
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);
    try std.testing.expect(std.mem.find(u8, res.sim.log.get(0).text(), "hook") != null);
}
