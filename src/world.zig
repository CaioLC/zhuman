//! This game's world: the engine's `World` over `components.zig` and `tags.zig`.

const ecs = @import("ecs");

pub const Entity = ecs.Entity;
pub const MAX_ENTITIES = ecs.MAX_ENTITIES;
pub const SparseSet = ecs.SparseSet;
pub const World = ecs.World(@import("./components.zig"), @import("./tags.zig"));
