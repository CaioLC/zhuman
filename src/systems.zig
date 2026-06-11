const std = @import("std");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");

const Resources = res_mod.Resources;
const Query = ecs.Query;
const With = ecs.With;

pub fn update_counter(
    res: *Resources,
    q: Query(.{ comp.Counter }),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |c| {
        c.buffer += dt;
        if (c.buffer >= c.multiplier) {
            c.v += 1;
            c.buffer -= c.multiplier;
        }
    }
}

/// Drain `v` continuously toward `end` at `1 / multiplier` units per second, then
/// wrap back to `start`. Continuous (not unit ticks) so the countdown bar moves
/// smoothly every frame — `v / start` changes by a sub-pixel amount per frame
/// instead of jumping once per whole unit. `multiplier` is seconds-per-unit.
pub fn update_timer(
    res: *Resources,
    q: Query(.{ comp.Timer }),
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
pub fn update_fill_timer(
    res: *Resources,
    q: Query(.{ comp.FillTimer }),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |t| {
        if (t.v >= t.end) continue; // already full — hold until reset
        t.v += dt / t.multiplier;
        if (t.v > t.end) t.v = t.end; // clamp at full
    }
}
