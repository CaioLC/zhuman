const std = @import("std");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");
const world_mod = @import("./world.zig");

const Resources = res_mod.Resources;
const World = world_mod.World;
const Entity = world_mod.Entity;
const Query = ecs.Query;
const With = ecs.With;

/// How fast the body converts `Food` into `Satiety` (units/second) when hungry. Faster than
/// `Satiety.drain`, so a stocked larder keeps you topped up; an empty one lets you starve.
/// A ration policy (full / ½ / ¼) will scale this later — for now it's a flat full ration.
const metabolism_rate: f32 = 2.0;

/// Drain `Satiety` toward zero at `drain` units/second — the actor is always burning
/// calories (acting burns extra, applied at action resolution in `main.zig`). As satiety
/// falls it drags `Vigor`'s ceiling down with it (see `update_vigor`); empty = starvation.
pub fn update_satiety(
    res: *Resources,
    q: Query(.{comp.Satiety}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |s| {
        s.v -= dt * s.drain;
        if (s.v < 0) s.v = 0;
    }
}

/// Metabolize `Food` into `Satiety`: while there's food and room to fill, move it across at
/// `metabolism_rate`. This is the passive "eating" — keeping food in the larder is what
/// keeps satiety (and so the vigor ceiling) up. Spoilage + drain are what create the
/// pressure to keep producing food.
pub fn metabolize(
    res: *Resources,
    q: Query(.{ comp.Food, comp.Satiety }),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |entry| {
        const food, const sat = entry;
        const room = sat.max - sat.v;
        if (room <= 0 or food.v <= 0) continue;
        var bite = metabolism_rate * dt;
        if (bite > room) bite = room;
        if (bite > food.v) bite = food.v;
        food.v -= bite;
        sat.v += bite;
    }
}

/// Spoil `Food` toward zero at `spoil` units/second — the larder rots, so a surplus can't
/// simply be banked forever (this is what storage capital will later mitigate).
pub fn update_food(
    res: *Resources,
    q: Query(.{comp.Food}),
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
    var dead: [world_mod.MAX_ENTITIES]Entity = undefined;
    var n: usize = 0;
    var it = q.iter();
    while (it.next()) |entry| {
        dead[n] = entry[0]; // entry = .{ Entity, *Dead }; we only need the id
        n += 1;
    }
    for (dead[0..n]) |e| world.despawn(e);
}
