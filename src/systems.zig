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

/// Decay `Energy` toward zero at `decay` units per second — the actor is cold and
/// hungry, and idleness costs it (capital upkeep raises `decay`). Actions (see
/// `main.zig`) push it back up; surviving means producing faster than this drains.
pub fn update_energy(
    res: *Resources,
    q: Query(.{comp.Energy}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |e| {
        if (e.v <= 0) continue; // already perished — hold at zero for the death pipeline
        e.v -= dt * e.decay;
        if (e.v < 0) e.v = 0;
    }
}

/// Trickle `Stamina` back up at `trickle` units/second, capped at `max`. This is only
/// the tiny passive drip — the bulk of recovery is the deliberate `Rest` action — so
/// the actor is never hard-stuck with no stamina and no way to earn any.
pub fn update_stamina(
    res: *Resources,
    q: Query(.{comp.Stamina}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |s| {
        s.v += dt * s.trickle;
        if (s.v > s.max) s.v = s.max;
    }
}

/// Tag any actor whose `Energy` has drained to zero as `Dead`. Fetches the entity id
/// (`Entity` in the query) so it can attach the tag, and guards on `has` so it tags
/// once — `Energy` holds at 0, so this would otherwise match every frame after death.
pub fn mark_dead(
    world: *World,
    q: Query(.{ Entity, comp.Energy }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const e, const energy = entry;
        if (energy.v <= 0 and !world.has(e, tag.Dead)) world.add(e, tag.Dead{});
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
