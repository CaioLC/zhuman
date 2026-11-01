//! This game's world, the engine's `World` over `components.zig` and `tags.zig`, and the
//! engine's system params bound to it and to `sim.Resources`, so a system
//! spells `Query(.{ comp.Vigor, With(tag.Player) })` and `run(world, &res.game, metabolize)`. The
//! engine itself is the package `ecs` (`src/ecs/README.md`).
//!
//! `Query`, `Single` and `MaybeSingle` are over `*World` and yield `*T`; the `Const` forms are
//! over `*const World` and yield `*const T`. A system names a group of `sim.Resources` (`*Sim`,
//! `*const Config`) rather than the whole `*sim.Resources` where it can: the signature then
//! states its reach. `run` takes the simulation's resources, not the host's, so no system can
//! reach the renderer, the input or the view.

const engine = @import("ecs");
const Resources = @import("./res.zig").Resources;

pub const Entity = engine.Entity;
pub const MAX_ENTITIES = engine.MAX_ENTITIES;
pub const SparseSet = engine.SparseSet;
pub const World = engine.World(@import("./components.zig"), @import("./tags.zig"));

pub const With = engine.With;
pub const Without = engine.Without;
pub const Maybe = engine.Maybe;
pub const getMany = engine.getMany;

pub fn Query(comptime params: anytype) type {
    return engine.Query(*World, params);
}

pub fn Single(comptime params: anytype) type {
    return engine.Single(*World, params);
}

pub fn MaybeSingle(comptime params: anytype) type {
    return engine.MaybeSingle(*World, params);
}

pub fn ConstQuery(comptime params: anytype) type {
    return engine.Query(*const World, params);
}

pub fn ConstSingle(comptime params: anytype) type {
    return engine.Single(*const World, params);
}

pub fn ConstMaybeSingle(comptime params: anytype) type {
    return engine.MaybeSingle(*const World, params);
}

pub fn run(world: *World, res: *Resources, comptime sys: anytype) void {
    engine.run(world, res, sys);
}
