//! Library root for the ECS engine (`src/ecs/`). Re-exports the world, the queries, the events,
//! `run`, and the states and schedule under one namespace, so a host imports `ecs` and reaches
//! everything. See `README.md`.

const world = @import("./world.zig");
const query = @import("./query.zig");
const run_mod = @import("./run.zig");
const events = @import("./events.zig");
const schedule = @import("./schedule.zig");

pub const Entity = world.Entity;
pub const MAX_ENTITIES = world.MAX_ENTITIES;
pub const SparseSet = world.SparseSet;
pub const World = world.World;
pub const Ref = world.Ref;

pub const Query = query.Query;
pub const Single = query.Single;
pub const MaybeSingle = query.MaybeSingle;
pub const Entry = query.Entry;
pub const getMany = query.getMany;
pub const With = query.With;
pub const Without = query.Without;
pub const Maybe = query.Maybe;

pub const Events = events.Events;

pub const run = run_mod.run;

pub const States = schedule.States;
pub const Schedule = schedule.Schedule;
pub const SetKind = schedule.SetKind;
pub const sameSystem = schedule.sameSystem;

test {
    _ = world;
    _ = query;
    _ = run_mod;
    _ = events;
    _ = schedule;
}
