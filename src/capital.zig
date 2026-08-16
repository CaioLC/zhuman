//! Capital definitions.
//!
//! Capital goods split into three behavioral variants (all share the same build-cost
//! shape): an **Unlocker** grants a target action component outright — owning the good
//! is what makes the verb possible at all (the fish rod below; `build_/break_` pairs) —
//! roundabout production made literal: spend today's vigor + materials, and a new verb
//! exists tomorrow. An **`ActionModifier`** mutates an *existing* action's
//! Requires/Yields once, at build and at break (Sandals, Axe below) — the apply/remove
//! pairs are that creation/destruction side effect. A **`Generator`** instead runs
//! continuously — provided its Requires are met each tick, it keeps depositing Yields
//! (Fireplace, `comp.Fireplace` below); `run_generators` is that running system, over
//! the manually-listed `generator_bundle`. A category ("every Generator") is a fact
//! about types, not entities, so there's no runtime query for it — `generator_bundle` +
//! `run_generator` mirror `actions_bundle` + `gather` in actions.zig exactly, one level
//! up (a list of types instead of a list of instances). Wiring `run_generators` into
//! the per-frame loop is still systems.zig's job, parked with the rest of the
//! systems/UI tidy-up.
const std = @import("std");
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

pub fn apply_axe(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy *= 0.6;
}
pub fn remove_axe(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy /= 0.6;
}

// --- Unlocker build/break ---
// Owning the good is what makes an action possible at all: building pays the good's
// Requires once and *grants* the target action component on the owning agent; breaking
// (reachable once durability lands) revokes it. The sparse-set's one-component-per-
// entity guarantee backs both "one rod per agent" and "owning ⟺ the verb exists" —
// no runtime bookkeeping. (The rod was an ActionModifier here before 2026-08-15; the
// redesign made it gate fishing instead of improving it.)

/// Build a fish rod: pay `comp.FishRod`'s build price, own the rod, gain the Fish verb.
/// Refuses silently if already owned or unaffordable — same gates as `actions.gather`
/// (energy strict, vigor 0 is death; materials may be spent to exactly 0).
pub fn build_fish_rod(w: *World, e: Entity, res: *Resources) void {
    if (w.has(e, comp.FishRod)) return; // one per agent (SparseSet.add doesn't guard dupes)
    const vigor, const stock = ecs.getMany(w, e, .{ comp.Vigor, comp.InventoryMaterial });
    const cost = (comp.FishRod{}).requires;
    if (cost.energy >= vigor.v or cost.materials > stock.v) return;

    vigor.v -= cost.energy;
    stock.v -= cost.materials;
    w.add(e, comp.FishRod{});
    w.add(e, comp.ActionFish{}); // the unlock: the rod grants the verb
    res.log.push(.good, "You built a fish rod. Fishing is now possible.");
}

/// Break the rod: the verb leaves with the tool. Nothing calls this yet (no durability);
/// written now so the grant/revoke pair stays symmetric, like the modifier pairs above.
pub fn break_fish_rod(w: *World, e: Entity, res: *Resources) void {
    if (!w.has(e, comp.FishRod)) return;
    w.remove(e, comp.FishRod);
    w.remove(e, comp.ActionFish);
    res.log.push(.warn, "Your fish rod broke.");
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

// ============================ Tests ==========================================

/// A Resources with only the fields the build path touches (`prng`, `log`, `game`)
/// initialized — the SDL-backed fields stay undefined and untouched.
fn test_res() Resources {
    var res: Resources = undefined;
    res.prng = std.Random.DefaultPrng.init(7);
    res.log = .{};
    res.game = .{};
    return res;
}

test "build_fish_rod pays, grants the rod and the Fish verb, and logs" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = 8 }, // exactly the price — spendable to 0
    });
    try std.testing.expect(!w.has(e, comp.ActionFish)); // no rod, no verb

    build_fish_rod(&w, e, &res);

    try std.testing.expect(w.has(e, comp.FishRod));
    try std.testing.expect(w.has(e, comp.ActionFish)); // the unlock
    try std.testing.expectEqual(@as(f32, 7), w.get(e, comp.Vigor).?.v); // 10 − 3 energy
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryMaterial).?.v); // 8 − 8
    try std.testing.expectEqual(@as(usize, 1), res.log.count);
}

test "build_fish_rod refuses when unaffordable, and only ever builds one" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = 7 }, // one material short
    });

    build_fish_rod(&w, e, &res);
    try std.testing.expect(!w.has(e, comp.FishRod)); // refused, nothing granted
    try std.testing.expect(!w.has(e, comp.ActionFish));
    try std.testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // unpaid

    w.get(e, comp.InventoryMaterial).?.v = 20;
    build_fish_rod(&w, e, &res);
    try std.testing.expect(w.has(e, comp.FishRod));
    build_fish_rod(&w, e, &res); // second build must refuse (one per agent)
    try std.testing.expectEqual(@as(f32, 12), w.get(e, comp.InventoryMaterial).?.v); // paid once
    try std.testing.expectEqual(@as(usize, 1), res.log.count); // one receipt
}

test "break_fish_rod revokes the verb with the tool" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = 8 },
    });
    build_fish_rod(&w, e, &res);

    break_fish_rod(&w, e, &res);

    try std.testing.expect(!w.has(e, comp.FishRod));
    try std.testing.expect(!w.has(e, comp.ActionFish)); // the verb left with the tool
}
