//! The `sim` namespace: the simulation, re-exported by the library as `ha.sim`. A caller spells
//! the folder (`sim.rules.actions.begin`, `sim.kernel.hex`, `sim.data.roster`), so the call says
//! what it reaches. The folders are namespaces declared here as nested structs: `systems` (what
//! runs each tick), `rules` (the operations the systems and the UI call), `kernel` (pure math
//! over `std`) and `data` (the authored roster, its reload and the act migration).
//!
//! It is also the root of `test-sim`, which compiles the simulation with no UI host and no SDL.
//! That module is given only `ecs` and the three roster data files, so a sim file that imports
//! `ui_client/`, the host `res.zig` or `sdl3` fails the step. The `test` block names every file,
//! because Zig analyses a file only when something references it.

const std = @import("std");

pub const comp = @import("./components.zig");
pub const tag = @import("./tags.zig");
pub const res = @import("./res.zig");
pub const Resources = res.Resources;
pub const Sim = res.Sim;
pub const Config = res.Config;
pub const Time = res.Time;
pub const Condition = res.Condition;
pub const hours_to_secs = res.hours_to_secs;
pub const ecs = @import("./ecs.zig");
pub const events = @import("./events.zig");
pub const log = @import("./log.zig");
pub const baselines = @import("./baselines.zig");

pub const systems = struct {
    pub const tick = @import("./systems/tick.zig");
    pub const labor = @import("./systems/labor.zig");
    pub const build = @import("./systems/build.zig");
    pub const generators = @import("./systems/generators.zig");
    pub const passerby = @import("./systems/passerby.zig");
    pub const log = @import("./systems/log.zig");
};

pub const rules = struct {
    pub const actions = @import("./rules/actions.zig");
    pub const capital = @import("./rules/capital.zig");
    pub const effects = @import("./rules/effects.zig");
    pub const ledger = @import("./rules/ledger.zig");
    pub const barter = @import("./rules/barter.zig");
    pub const market = @import("./rules/market.zig");
    pub const neighbours = @import("./rules/neighbours.zig");
    pub const research = @import("./rules/research.zig");
};

pub const kernel = struct {
    pub const dist = @import("./kernel/dist.zig");
    pub const hex = @import("./kernel/hex.zig");
};

pub const data = struct {
    pub const roster = @import("./data/roster.zig");
    pub const reload = @import("./data/reload.zig");
    pub const migration = @import("./data/migration.zig");
};

test {
    _ = comp;
    _ = tag;
    _ = res;
    _ = ecs;
    _ = events;
    _ = log;
    _ = baselines;
    std.testing.refAllDecls(systems);
    std.testing.refAllDecls(rules);
    std.testing.refAllDecls(kernel);
    std.testing.refAllDecls(data);
}
