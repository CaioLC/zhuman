//! Capital definitions.
//!
//! Capital goods split into two behavioral variants (tagged, not typed, since both
//! share the same build-cost shape): an `ActionModifier` mutates a target action's
//! Requires/Yields once, at build and at break (Sandals, Fishing rod, Axe below) —
//! the apply/remove pairs are that creation/destruction side effect. A `Generator`
//! instead runs continuously — provided its Requires are met each tick, it keeps
//! depositing Yields (Fireplace, `comp.Fireplace` below); `run_generators` is that
//! running system, over the manually-listed `generator_bundle`. A category ("every
//! Generator") is a fact about types, not entities, so there's no runtime query for
//! it — `generator_bundle` + `run_generator` mirror `actions_bundle` + `gather` in
//! actions.zig exactly, one level up (a list of types instead of a list of instances).
//! Wiring `run_generators` into the per-frame loop is still systems.zig's job, parked
//! with the rest of the systems/UI tidy-up.
const ha = @import("ha");
const comp = ha.comp;
const tag = ha.tag;
const dist = ha.dist;
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");
const world = @import("./world.zig");

const World = world.World;
const Entity = world.Entity;
const Resources = res_mod.Resources;

// --- capital build archetypes: removed ---
// The old `sandals`/`fishing_rod`/`axe`/`fireplace` const bundles built a good as a
// *separate entity* (Label + Requires + category tag) and named the private
// `comp.Requires`, so they neither compiled nor matched the redesign's "capital is a
// component on the owning agent" model. They're dropped until that per-agent migration
// lands; the ActionModifier apply/remove pairs and the Generator runner below already
// speak the new model, so they stay.

// --- ActionModifier creation/destruction ---
// Each pair applies/reverses its good's effect on the target action component, which
// lives directly on the owning agent entity (per the labor pattern in actions.zig).

// Yields are distributions (`dist.Dist`), not flat numbers — a boost scales `.s` (the
// mean/scale) and `.sd` together so the distribution's relative shape is preserved
// (and `.sd == 0`, meaning "auto-derive", stays exactly 0 either way).

pub fn apply_sandals(w: *World, agent: Entity) void {
    const forage = ecs.getMany(w, agent, .{comp.ActionForage});
    forage.yields.food.s *= 1.1;
    forage.yields.food.sd *= 1.1;
}
pub fn remove_sandals(w: *World, agent: Entity) void {
    const forage = ecs.getMany(w, agent, .{comp.ActionForage});
    forage.yields.food.s /= 1.1;
    forage.yields.food.sd /= 1.1;
}

pub fn apply_fishing_rod(w: *World, agent: Entity) void {
    const fish = ecs.getMany(w, agent, .{comp.ActionFish});
    fish.yields.food.s *= 1.6;
    fish.yields.food.sd *= 1.6;
}
pub fn remove_fishing_rod(w: *World, agent: Entity) void {
    const fish = ecs.getMany(w, agent, .{comp.ActionFish});
    fish.yields.food.s /= 1.6;
    fish.yields.food.sd /= 1.6;
}

pub fn apply_axe(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy *= 0.6;
}
pub fn remove_axe(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy /= 0.6;
}

// --- Generator running system ---
// A manual per-type list, the same shape as `actions.actions_bundle`: there's no
// runtime query for "every component type tagged Generator" (that's a fact about
// types, not entities), so the types that should tick each frame are named here
// explicitly. Adding a new Generator good means adding it to this list too.
pub const generator_bundle = .{
    comp.Fireplace,
};

/// Shared body for every Generator — mirrors `actions.gather`'s shape exactly: if its
/// Requires are currently affordable, deposit its Yields. `GenT` is one of the typed
/// per-generator components (each carrying its own Requires/Yields), so distinct
/// generators stay distinct component types while sharing this one resolution path.
fn run_generator(w: *World, e: Entity, res: *Resources, comptime GenT: type) void {
    const gen, const vigor, const stock, const food = ecs.getMany(w, e, .{ GenT, comp.Vigor, comp.InventoryMaterial, comp.InventoryFood });
    if (gen.requires.energy >= vigor.v or gen.requires.materials >= stock.v) {
        return; // can't pay this tick
    }
    stock.v += dist.sample(gen.yields.materials, res.random());
    food.v += dist.sample(gen.yields.food, res.random());
}

/// The system: ticks every Generator-category good on every entity that owns one.
/// `inline for` unrolls `generator_bundle` at comptime into one Query per type. Not
/// called anywhere yet — wiring it into the per-frame loop is systems.zig's job,
/// parked with the rest of the systems/UI tidy-up.
pub fn run_generators(w: *World, res: *Resources) void {
    inline for (generator_bundle) |GenT| {
        var q: ecs.Query(.{ Entity, GenT }) = .{ .world = w };
        var it = q.iter();
        while (it.next()) |entry| {
            const e, const gen = entry;
            _ = gen;
            run_generator(w, e, res, GenT);
        }
    }
}
