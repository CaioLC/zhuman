const std = @import("std");
const comp = @import("../components.zig");
const tag = @import("../tags.zig");
const ecs = @import("../ecs.zig");
const res_mod = @import("../res.zig");
const world = @import("../ecs.zig");
const actions = @import("../rules/actions.zig");
const capital = @import("../rules/capital.zig");
const roster = @import("../data/roster.zig");
const events = @import("../events.zig");
const Resources = res_mod.Resources;
const World = world.World;
const Entity = world.Entity;
const Query = ecs.Query;
const With = ecs.With;
const EventWriter = ecs.EventWriter;
const condition = @import("./condition.zig").condition;

/// Advance the run clock while the actor lives. Driven by the player's presence — with no
/// player (dead) the clock freezes, so the game-over screen shows the day you died. With one
/// player this bumps `elapsed` once for the frame it finds one.
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
/// simply be banked forever.
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

/// The metabolism loop: every agent with a `Metabolism` eats continuously from its own
/// larder — no eat action, eating happens regardless; the *rate* is the agent's standing
/// choice (`Metabolism.rate`, a bounded scalar). Food converts to vigor as it's consumed (scaled
/// by the larder's `quality`, clamped at `max`); an **empty larder starves vigor down** instead —
/// this is the drain that makes `mark_dead` fire, and the clock pressure that
/// makes every action intentional: ration and stay weak, feast and burn the stock.
/// The larder emptying is a fact once, on the frame it happens: `FoodRanOut`. The band the
/// vigor now falls in is the `condition` system's, which runs right after this one and reports
/// the crossing. Runs after `update_food` (spoilage claims its share first) and before
/// `mark_dead` (starving to 0 dies the same frame).
pub fn metabolize(
    time: *const res_mod.Time,
    cfg: *const res_mod.Config,
    ran_out: EventWriter(events.FoodRanOut),
    q: Query(.{ Entity, comp.Vigor, comp.InventoryFood, comp.Metabolism }),
) void {
    const dt_days = time.dt / cfg.secs_per_day;
    var it = q.iter();
    while (it.next()) |entry| {
        const e: Entity, const vigor: *comp.Vigor, const food: *comp.InventoryFood, const met: *comp.Metabolism = entry;
        const food_before = food.v;

        if (food.v > 0) {
            const want = met.base_rate * cfg.clampMetabolism(met.rate) * dt_days;
            const eaten = @min(food.v, want);
            food.v -= eaten;
            vigor.v = @min(vigor.v + eaten * cfg.vigor_per_food * @as(f32, @floatFromInt(food.quality)), vigor.max);
        } else {
            vigor.v = @max(0, vigor.v - cfg.starve_per_day * dt_days);
        }

        // Edge-triggered — once, on the frame the larder empties.
        if (food_before > 0 and food.v <= 0) _ = ran_out.push(.{ .agent = e });
    }
}

/// Tick every act in progress and resolve the ones whose time is up: dispatch `doing`
/// back to its completion half (deposit + receipt for labor, the good for a build) and
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

/// Tag any actor whose `Vigor` has drained to zero as `Dead` — vigor `0` is death — and emit
/// `Died`. Guards on `has` so it tags once. Starvation (`metabolize` on an empty larder) is what
/// drains vigor to zero in practice; labor can't (its energy gate is strict).
pub fn mark_dead(
    w: *World,
    died: EventWriter(events.Died),
    q: Query(.{ Entity, comp.Vigor }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const e: Entity, const vigor: *comp.Vigor = entry;
        if (vigor.v <= 0 and !w.has(e, tag.Dead)) {
            w.add(e, tag.Dead{});
            _ = died.push(.{ .agent = e });
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
/// its prerequisite becomes satisfied for the first time this run, emit one `RecipeInReach`
/// (the log's "A new recipe is within reach: {name}."). Only goods with an `any`/`all` gate participate:
/// a good with no prerequisite is reachable from the first breath, so it is not a *transition*
/// and never logs. The seen-set
/// is sim state (`Sim.reach_seen`, by catalog index), so it survives
/// frames untouched by the UI — tab switches, filter/sort changes, and rebuilds cannot re-emit
/// the fact; only this tick, on the actual false→true edge, does. Cleared by `Sim.reset` so a
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
            // Only this act's goods with an `any`/`all` gate; one without is reachable from
            // the start and would false-fire on the first tick, so it is skipped entirely, and
            // a later act's recipe is announced by that act's own edge detector.
            if ((rec.requires.any.len == 0 and rec.requires.all.len == 0) or rec.act > 1) continue;
            const met = capital.gatesMet(w, e, cat, @intCast(gi));
            if (met and !res.sim.reach_seen[gi]) {
                res.sim.reach_seen[gi] = true;
                _ = res.events.writer(events.RecipeInReach).push(.{ .agent = e, .gi = @intCast(gi) });
            } else if (!met) {
                // The prerequisite went away (tool broke) — allow a fresh announcement if it
                // returns, so the transition tracking is symmetric.
                res.sim.reach_seen[gi] = false;
            }
        }
    }
}

// ============================ Tests ==========================================

/// The simulation's resources with `time.dt` set; every other field is its default.
fn test_res(dt: f32) Resources {
    return .{ .time = .{ .dt = dt } };
}

/// Word the facts the systems emitted, as the frame's log system does.
fn logged(w: *World, res: *Resources) void {
    ecs.run(w, res, @import("./log.zig").log);
}

test "resolve_busy ticks the work and resolves it exactly once, at completion" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = test_res(0);
    res.catalog = try roster.load(std.testing.allocator, roster.shipped, null);
    defer res.catalog.deinit();
    res.time.dt = res_mod.hours_to_secs(2, res.config.secs_per_day); // 2h per tick
    const forage = res.catalog.actionIndex("forage").?; // 4h of work
    const e = w.spawn(.{
        comp.Verbs.of(&res.catalog, &.{"forage"}),
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = 0 },
        comp.Goods{},
        comp.Granted{},
        comp.Busy{ .doing = .{ .labor = forage }, .total = res_mod.hours_to_secs(4, res.config.secs_per_day), .remaining = res_mod.hours_to_secs(4, res.config.secs_per_day), .quality = 1 },
    });

    ecs.run(&w, &res, resolve_busy); // 2h in — still working
    logged(&w, &res);
    try std.testing.expect(w.has(e, comp.Busy));
    try std.testing.expectEqual(@as(usize, 0), res.sim.log.count);

    ecs.run(&w, &res, resolve_busy); // 4h — done: deposit + receipt, Busy gone
    logged(&w, &res);
    try std.testing.expect(!w.has(e, comp.Busy));
    try std.testing.expect(w.get(e, comp.InventoryFood).?.v >= 0);
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);

    ecs.run(&w, &res, resolve_busy); // idle tick — nothing to resolve
    logged(&w, &res);
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);
}

test "metabolize eats continuously, converting food to vigor (clamped at max)" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = test_res(0);
    res.time.dt = res.config.secs_per_day; // one full day per tick
    const e = w.spawn(.{
        comp.Vigor{ .v = 5, .max = 10 },
        comp.InventoryFood{ .v = 2, .quality = 1, .spoils = 0 },
        comp.Metabolism{}, // normal: 1.5 food/day
    });

    ecs.run(&w, &res, metabolize);
    logged(&w, &res);
    try std.testing.expectEqual(@as(f32, 0.5), w.get(e, comp.InventoryFood).?.v); // 2 − 1.5
    try std.testing.expectEqual(@as(f32, 8), w.get(e, comp.Vigor).?.v); // 5 + 1.5·2·q1
    try std.testing.expectEqual(@as(usize, 0), res.sim.log.count); // nothing crossed
}

test "metabolize at feast burns the larder dry and logs the crossing" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = test_res(0);
    res.time.dt = res.config.secs_per_day;
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 2, .quality = 1, .spoils = 0 },
        comp.Metabolism{ .rate = 2.0 }, // wants 3/day, finds only 2
    });

    ecs.run(&w, &res, metabolize);
    logged(&w, &res);
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v);
    try std.testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // clamped at max
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count); // "Your food has run out."
}

test "metabolize starves vigor down on an empty larder; the condition writer logs the thresholds" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = test_res(0);
    res.time.dt = res.config.secs_per_day;
    const e = w.spawn(.{
        comp.Vigor{ .v = 5, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.Metabolism{ .rate = 0.5 }, // rate is irrelevant when starving
        comp.Condition{},
    });

    ecs.run(&w, &res, metabolize); // 5 → 1 (starve 4/day): crosses weak (3.5) and starving (1.2)
    ecs.run(&w, &res, condition);
    logged(&w, &res);
    try std.testing.expectEqual(@as(f32, 1), w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count);

    ecs.run(&w, &res, metabolize); // 1 → 0 (clamped), no re-logging — mark_dead's turn
    ecs.run(&w, &res, condition);
    logged(&w, &res);
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count);
}

test "track_reach logs a newly in-reach recipe once, not on repeats, and re-arms if the prereq goes away" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = test_res(0);
    res.catalog = try roster.load(std.testing.allocator, roster.shipped, null);
    defer res.catalog.deinit();
    const hatchet = res.catalog.goodIndex("hatchet").?;
    // A player without Split wood: Work gloves (which needs it) is not in reach
    // yet, and goods that need nothing never announce.
    const e = w.spawn(.{ comp.Vigor{}, comp.Goods{}, comp.Granted{}, tag.Player{} });
    ecs.run(&w, &res, track_reach);
    logged(&w, &res);
    try std.testing.expectEqual(@as(usize, 0), res.sim.log.count); // nothing became reachable

    // Own the hatchet (as buying it would): the good that needs Split wood transitions
    // false→true this tick — one announcement.
    w.get(e, comp.Goods).?.count[hatchet] = 1;
    ecs.run(&w, &res, track_reach);
    logged(&w, &res);
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);
    try std.testing.expectEqual(@import("../log.zig").Tone.good, res.sim.log.get(0).tone);
    // The message names the good and uses the exact copy.
    try std.testing.expect(std.mem.find(u8, res.sim.log.get(0).text(), "within reach") != null);

    // A rebuild/tab-switch/sort does not re-run the tick; running it again emits nothing new.
    ecs.run(&w, &res, track_reach);
    logged(&w, &res);
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count); // no repeat

    // The prerequisite going away (tool broke) re-arms the announcement; regaining it logs again.
    w.get(e, comp.Goods).?.count[hatchet] = 0;
    ecs.run(&w, &res, track_reach);
    logged(&w, &res);
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count); // losing it does not log
    w.get(e, comp.Goods).?.count[hatchet] = 1;
    ecs.run(&w, &res, track_reach);
    logged(&w, &res);
    try std.testing.expectEqual(@as(usize, 2), res.sim.log.count); // re-armed: one more
}

test "track_reach announces this act's recipes only" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = test_res(0);
    res.catalog = try roster.load(std.testing.allocator, .{
        .actions =
        \\.{
        \\    .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .hours = 1.0, .any = .{"rod"} } },
        \\}
        ,
        .goods =
        \\.{
        \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\    .{ .id = "hook", .name = "Hook", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0, .all = .{"fish"} } },
        \\    .{ .id = "weir", .name = "Weir", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0, .all = .{"fish"} } },
        \\}
        ,
    }, null);
    defer res.catalog.deinit();
    const e = w.spawn(.{ comp.Vigor{}, comp.Goods{}, comp.Granted{}, tag.Player{} });
    w.get(e, comp.Goods).?.count[res.catalog.goodIndex("rod").?] = 1;
    ecs.run(&w, &res, track_reach);
    logged(&w, &res);
    // The hook (this act) is announced; the weir (the next act) is not.
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);
    try std.testing.expect(std.mem.find(u8, res.sim.log.get(0).text(), "hook") != null);
}
