//! The engine's system params bound to this game's `World` and `Resources`, so a system spells
//! `Query(.{ comp.Vigor, With(tag.Player) })` and `run(world, res, metabolize)`. The engine
//! itself is the package `ecs` (`src/ecs/README.md`).
//!
//! `Query`, `Single` and `MaybeSingle` are over `*World` and yield `*T`; the `Const` forms are
//! over `*const World` and yield `*const T`. A system names a resource group (`*Sim`,
//! `*const Config`) rather than the whole `*Resources` where it can: the signature then states
//! its reach, and a system with no `*Platform` param cannot touch the renderer.

const engine = @import("ecs");
const World = @import("./world.zig").World;
const Resources = @import("./res.zig").Resources;

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
