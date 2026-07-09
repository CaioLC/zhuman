//! Actions definitions.
//!
//! Actions are direct manipulation of component states
const ha = @import("ha");
const comp = ha.comp;
const tag = ha.tag;
const dist = ha.dist;
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");
const world = @import("./world.zig");

const Resources = res_mod.Resources;
const World = world.World;
const Entity = world.Entity;
const Query = ecs.Query;
const With = ecs.With;

// --- actions archetypes (World.spawn bundles) ---
pub const actions_bundle = .{
    comp.ActionChopWood,
    comp.ActionFish,
    comp.ActionForage,
};

// action queues
pub fn action_eat(
    w: *World,
    e: Entity,
) void {
    const food, const vigor = ecs.getMany(w, e, .{ comp.InventoryFood, comp.Vigor });
    if (food.v == 0.0) return;
    food.v -= 1.0;
    vigor.v += 2.0 * @as(f32, @floatFromInt(food.quality));
}

/// Shared body for the labor actions (Forage/Fish/ChopWood): spend energy/materials,
/// draw food/materials yield from `dist.sample` (the spread *is* the risk — no separate
/// success roll). `ActionT` is one of the typed per-action components, each carrying its
/// own `Requires`/`Yields` — so distinct actions stay distinct component types
/// (queryable independently) while sharing this one resolution path.
fn gather(w: *World, e: Entity, res: *Resources, comptime ActionT: type) void {
    const act, const vigor, const stock, const food = ecs.getMany(w, e, .{ ActionT, comp.Vigor, comp.InventoryMaterial, comp.InventoryFood });
    if (act.requires.energy >= vigor.v or act.requires.materials >= stock.v) {
        return; // cannot do the action
    }
    stock.v += dist.sample(act.yields.materials, res.random());
    food.v += dist.sample(act.yields.food, res.random());
}

pub fn action_forage(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    gather(w, e, res, comp.ActionForage);
}

pub fn action_fish(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    gather(w, e, res, comp.ActionFish);
}

pub fn action_chop_wood(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    gather(w, e, res, comp.ActionChopWood);
}
