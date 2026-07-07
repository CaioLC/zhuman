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

/// Spoil `Food` toward zero at `spoil` units/second — the larder rots, so a surplus can't
/// simply be banked forever (this is what storage capital will later mitigate).
pub fn update_food(
    res: *Resources,
    q: Query(.{comp.StockFood}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |f| {
        f.v -= dt * f.spoil;
        if (f.v < 0) f.v = 0;
    }
}

/// Trickle `Vigor` back up at `trickle` units/second, but clamped to the *hunger ceiling*
/// `max × (satiety / satiety.max)` rather than `max`. Doing "nothing" recovers vigor up to
/// what hunger allows; as satiety falls the ceiling falls and vigor is dragged down with it,
/// reaching `0` (death) when satiety does. Comfort capital raises the `trickle`.
pub fn update_vigor(
    res: *Resources,
    q: Query(.{ comp.Vigor, comp.Satiety }),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |entry| {
        const v, const sat = entry;
        const cap = v.max * (sat.v / sat.max);
        v.v += dt * v.trickle;
        if (v.v > cap) v.v = cap; // hunger ceiling pulls vigor down as satiety falls
    }
}

/// Grow/shrink `Population.count` toward `capacity` — up while there's a sustained food
/// surplus, down (faster) while starving. `capacity` is catalog-dependent (which capital
/// goods count as "shelter"), so the host (`main.zig`'s `compute_capacity`) computes and
/// writes it each frame; this system only integrates `count` against whatever it finds
/// already set there — same split as `Vigor.trickle` (host sets it on a comfort-good
/// build, this system just applies it).
pub fn update_population(
    res: *Resources,
    q: Query(.{ comp.Population, comp.StockFood, comp.Satiety }),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |entry| {
        const pop, const food, const sat = entry;
        const sat_frac = sat.v / sat.max;
        if (sat_frac <= pop_starve_frac) {
            pop.count -= dt * pop_starve_rate;
        } else if (food.v > food.max * pop_surplus_frac) {
            pop.count += dt * pop_growth_rate;
        }
        if (pop.count < 0) pop.count = 0;
        if (pop.count > pop.capacity) pop.count = pop.capacity;
    }
}

/// Tag any actor whose `Vigor` has drained to zero as `Dead` — vigor `0` is death, and the
/// only thing that takes it there is the hunger ceiling collapsing (actions are gated so
/// they never spend the last unit). Guards on `has` so it tags once.
pub fn mark_dead(
    res: *Resources,
    world: *World,
    q: Query(.{ Entity, comp.Vigor }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const e, const vigor = entry;
        if (vigor.v <= 0 and !world.has(e, tag.Dead)) {
            world.add(e, tag.Dead{});
            res.log.push(.danger, "You perished, cold and starved.");
        }
    }
}

/// Reap every entity tagged `Dead`. Collects ids first, then despawns: `despawn`
/// swap-removes from the `Dead` storage this query iterates, so mutating mid-walk
/// would shuffle the dense array and skip entities. Once the actor is gone, the UI
/// (which queries it with `MaybeSingle`) shows the "start over" screen.
pub fn despawn_dead(
    world: *World,
    q: Query(.{ Entity, tag.Dead }),
) void {
    var dead: [world.MAX_ENTITIES]Entity = undefined;
    var n: usize = 0;
    var it = q.iter();
    while (it.next()) |entry| {
        dead[n] = entry[0]; // entry = .{ Entity, *Dead }; we only need the id
        n += 1;
    }
    for (dead[0..n]) |e| world.despawn(e);
}
