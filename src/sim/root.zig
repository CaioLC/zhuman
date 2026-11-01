//! The `sim` hub: the simulation's resources surface, `sim.Resources` and the types its fields
//! hold. The library re-exports it as `ha.sim`.

pub const res = @import("./res.zig");
pub const Resources = res.Resources;
pub const Sim = res.Sim;
pub const Config = res.Config;
pub const Time = res.Time;
pub const Condition = res.Condition;
pub const hours_to_secs = res.hours_to_secs;

test {
    _ = res;
}
