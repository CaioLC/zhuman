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

/// Tag any actor whose `Vigor` has drained to zero as `Dead` — vigor `0` is death. Guards
/// on `has` so it tags once. (No mechanic drains vigor to zero yet — action cost deduction
/// is a known, still-open gap — so this doesn't fire in practice; it's the death path once
/// that lands.)
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
