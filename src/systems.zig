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

/// Accumulate `v` continuously at `1 / multiplier` units per second (no bound).
/// Continuous, not unit ticks — the displayed integer comes from rounding at render
/// (`{d:.0}`), so no buffer is needed. `multiplier` is seconds-per-unit.
pub fn update_counter(
    res: *Resources,
    q: Query(.{comp.Counter}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |c| {
        c.v += dt / c.multiplier;
    }
}

/// Drain `v` continuously toward `end` at `1 / multiplier` units per second, then
/// wrap back to `start`. Continuous (not unit ticks) so the countdown bar moves
/// smoothly every frame — `v / start` changes by a sub-pixel amount per frame
/// instead of jumping once per whole unit. `multiplier` is seconds-per-unit.
pub fn update_timer_wrap(
    res: *Resources,
    q: Query(.{comp.TimerWrap}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |t| {
        t.v -= dt / t.multiplier;
        if (t.v <= t.end) t.v = t.start; // cycle: empty wraps back to full
    }
}

/// Fill `v` continuously toward `end` at `1 / multiplier` units per second and
/// stop there — no wrap. Drives the fill-up bar; userland resets `v` to `start`
/// on click. `multiplier` is seconds-per-unit.
pub fn update_counter_fill(
    res: *Resources,
    q: Query(.{comp.CounterFill}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |t| {
        if (t.v >= t.end) continue; // already full — hold until reset
        t.v += dt / t.multiplier;
        if (t.v > t.end) t.v = t.end; // clamp at full
    }
}

/// Drain `v` continuously toward `end` at `1 / multiplier` units per second and
/// stop there — no wrap (the down-counting mirror of `update_counter_fill`, so
/// `start > end`). One-shot countdown; userland resets `v` to `start` on click.
/// `multiplier` is seconds-per-unit.
pub fn update_timer_fill(
    res: *Resources,
    q: Query(.{comp.TimerFill}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |t| {
        if (t.v <= t.end) continue; // already drained — hold until reset
        t.v -= dt / t.multiplier;
        if (t.v < t.end) t.v = t.end; // clamp at empty
    }
}

/// Drain `Life` toward zero at `1 / multiplier` units per second and stop there
/// (a `TimerFill` whose floor is implicitly 0). `multiplier` is seconds-per-unit.
pub fn update_life(
    res: *Resources,
    q: Query(.{comp.Life}),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |l| {
        if (l.v <= 0) continue; // already dead — hold at zero
        l.v -= dt / l.multiplier;
        if (l.v < 0) l.v = 0;
    }
}

/// Tag any entity whose `Life` has drained to zero as `Dead`. Fetches the entity id
/// (`Entity` in the query) so it can attach the tag, and guards on `has` so it tags
/// once — `Life` holds at 0, so this would otherwise match every frame after death.
pub fn mark_dead(
    world: *World,
    q: Query(.{ Entity, comp.Life }),
) void {
    var it = q.iter();
    while (it.next()) |entry| {
        const e, const life = entry;
        if (life.v <= 0 and !world.has(e, tag.Dead)) world.add(e, tag.Dead{});
    }
}

/// Reap every entity tagged `Dead`. Collects ids first, then despawns: `despawn`
/// swap-removes from the `Dead` storage this query iterates, so mutating mid-walk
/// would shuffle the dense array and skip entities.
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
