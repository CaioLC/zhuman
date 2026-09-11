//! Capital definitions.
//!
//! Capital goods split into three behavioral variants (all share the same build-cost
//! shape — `requires`, hours included — so one begin/finish path serves them all):
//!
//! - an **Unlocker** grants a target action component outright — owning the good is what
//!   makes the verb possible at all (Fishing rod → Fish, Hatchet → Split wood, Wire
//!   snares → Check traps, Air rifle → Hunt). Roundabout production made literal: spend
//!   today's vigor, materials and hours, and a new verb exists tomorrow.
//! - an **ActionModifier** mutates an *existing* margin once, at build and at break — an
//!   action's Requires/Yields (Sandals, Work gloves, Bicycle, Chainsaw), the larder's
//!   quality/spoilage (Cookpot, Root cellar), or the body's vigor ceiling (Bed, Pantry,
//!   Medicine chest). The apply/remove pairs are that creation/destruction side effect.
//! - a **Generator** runs continuously instead: `run_generator` pays its `upkeep` and
//!   deposits its `yields` every tick it can afford (Garden bed, Chicken coop).
//!   `run_generators` is that system, over the manually-listed `generator_bundle` — a
//!   category ("every Generator") is a fact about types, not entities, so there's no
//!   runtime query for it; the list mirrors `actions.actions_bundle` exactly, one level
//!   up (a list of types instead of a list of instances).
//!
//! `begin_build`/`finish_build`/`break_good` are comptime-parameterized over the good,
//! the same way `actions.begin_labor` is over the action — the gate/pay/start half is
//! identical for every good, and only `grant`/`revoke` differ. A good whose effect needs
//! a verb the agent lacks (Work gloves and Chainsaw both work on Split wood) declares
//! that in `prereq_of`, which gates the build *and* the tile — so a modifier can never
//! be applied to a component that isn't there.
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

// --- the buildable catalog ---------------------------------------------------------
// Manual per-type mappings, the `actions_bundle` idiom: facts about types, not entities.

/// Every buildable good, in BUILD-shelf order. `inline for`-able by any caller that
/// needs to sweep the catalog.
pub const buildable_bundle = .{
    comp.FishRod,       comp.Hatchet,    comp.WireSnares,  comp.AirRifle,
    comp.Sandals,       comp.WorkGloves, comp.Bicycle,     comp.Cookpot,
    comp.RootCellar,    comp.Chainsaw,   comp.LeafBed,     comp.Pantry,
    comp.MedicineChest, comp.GardenBed,  comp.ChickenCoop, comp.Shelter,
};

/// The `Busy.Doing` name for a good's build — what `resolve_busy` dispatches on.
pub fn doing_of_good(comptime GoodT: type) comp.Busy.Doing {
    return switch (GoodT) {
        comp.FishRod => .build_fish_rod,
        comp.Hatchet => .build_hatchet,
        comp.WireSnares => .build_wire_snares,
        comp.AirRifle => .build_air_rifle,
        comp.Sandals => .build_sandals,
        comp.WorkGloves => .build_work_gloves,
        comp.Bicycle => .build_bicycle,
        comp.Cookpot => .build_cookpot,
        comp.RootCellar => .build_root_cellar,
        comp.Chainsaw => .build_chainsaw,
        comp.LeafBed => .build_leaf_bed,
        comp.Pantry => .build_pantry,
        comp.MedicineChest => .build_medicine_chest,
        comp.GardenBed => .build_garden_bed,
        comp.ChickenCoop => .build_chicken_coop,
        comp.Shelter => .build_shelter,
        else => @compileError("no Busy.Doing for " ++ @typeName(GoodT)),
    };
}

/// The component a good's effect needs to already exist on the agent, if any. Only the
/// modifiers that target an *unlocked* verb have one — a Chainsaw with no Split wood to
/// improve would panic in `getMany`, so this turns that into an honest gate: you need
/// the hatchet before the tools that sharpen it.
pub fn prereq_of(comptime GoodT: type) ?type {
    return switch (GoodT) {
        comp.WorkGloves, comp.Chainsaw => comp.ActionChopWood,
        else => null,
    };
}

/// Whether a good is **crude** — scrap-and-hands work, the tier one person can actually
/// make in half a day. Everything else is manufactured, carrying ×8 the materials and ×10
/// the hours (see `components.zig`). The split cuts across the three behavioral variants
/// rather than restating them, and it is the roster's own fact, so it lives here beside
/// `good_name` rather than in whichever screen happens to group by it.
pub fn is_crude(comptime GoodT: type) bool {
    return switch (GoodT) {
        comp.Sandals, comp.LeafBed, comp.WireSnares, comp.RootCellar, comp.GardenBed => true,
        else => false,
    };
}

/// Whether `GoodT`'s prerequisite (if it has one) is satisfied on this agent.
pub fn prereq_met(w: *World, e: Entity, comptime GoodT: type) bool {
    if (prereq_of(GoodT)) |P| return w.has(e, P);
    return true;
}

/// How many goods from the catalog this agent owns - the "you have made a life here"
/// count an `unlock` measures against.
pub fn goods_owned(w: *World, e: Entity) u32 {
    var n: u32 = 0;
    inline for (buildable_bundle) |G| {
        if (w.has(e, G)) n += 1;
    }
    return n;
}

/// Whether the builder meets `GoodT`'s standing conditions - the second gate, beside
/// `prereq_met`. A good with no `unlock` field has none, which is all of them but the
/// Shelter. Checked at `begin_build` and not again: a dip mid-build doesn't stop work
/// already paid for, the same rule every other act follows.
pub fn unlock_met(w: *World, e: Entity, comptime GoodT: type) bool {
    if (!@hasField(GoodT, "unlock")) return true;
    const u = (GoodT{}).unlock;
    const vigor, const food = ecs.getMany(w, e, .{ comp.Vigor, comp.InventoryFood });
    if (vigor.v < u.vigor_abs) return false; // ACT1-04: absolute current Vigor, not a fraction
    if (food.v < u.food) return false;
    return goods_owned(w, e) >= u.goods;
}

/// The receipt line for a completed build.
fn built_msg(comptime GoodT: type) []const u8 {
    return switch (GoodT) {
        comp.FishRod => "You built a fish rod. Fishing is now possible.",
        comp.Hatchet => "You built a hatchet. You can split wood now.",
        comp.WireSnares => "You set wire snares. Check them for game.",
        comp.AirRifle => "You assembled an air rifle. You can hunt now.",
        comp.Sandals => "You bound sandals from bark. Foraging costs a little less.",
        comp.WorkGloves => "You stitched work gloves. Splitting wood costs less.",
        comp.Bicycle => "You rebuilt a bicycle. Distance got cheap.",
        comp.Cookpot => "You built a cookpot. Cooked food feeds you further.",
        comp.RootCellar => "You dug a root cellar. Food keeps twice as long.",
        comp.Chainsaw => "You got a chainsaw running. The engine works, not your back.",
        comp.LeafBed => "You piled a leaf bed. You sleep off the ground now.",
        comp.Pantry => "You built a pantry. You eat properly now.",
        comp.MedicineChest => "You stocked a medicine chest. You mend properly now.",
        comp.GardenBed => "You planted a garden bed. It grows without you.",
        comp.ChickenCoop => "You raised a chicken coop. The hens lay without you.",
        comp.Shelter => "You raised a shelter. There is room here for others.",
        else => @compileError("no build message for " ++ @typeName(GoodT)),
    };
}

/// What a good does the moment it exists — the whole difference between the categories.
fn grant(w: *World, e: Entity, comptime GoodT: type) void {
    switch (GoodT) {
        // Unlockers: the good *is* the verb. Fishing/chopping recompute the family so a rank-2
        // tool supersedes a rank-1 one (and vice-versa on the way out).
        comp.FishRod => recompute_fishing(w, e),
        comp.FishNet => recompute_fishing(w, e),
        comp.Hatchet => recompute_chopping(w, e),
        comp.HandAxe => recompute_chopping(w, e),
        comp.WireSnares => w.add(e, comp.ActionCheckTraps{}),
        comp.AirRifle => w.add(e, comp.ActionHunt{}),
        // Modifiers: a one-shot mutation of a margin.
        comp.Sandals => apply_sandals(w, e),
        comp.WorkGloves => apply_work_gloves(w, e),
        comp.Bicycle => apply_bicycle(w, e),
        comp.Cookpot => apply_cookpot(w, e),
        comp.RootCellar => apply_root_cellar(w, e),
        comp.Chainsaw => apply_chainsaw(w, e),
        comp.LeafBed => health_apply(w, e, 1.0),
        comp.Pantry => health_apply(w, e, 2.0),
        comp.MedicineChest => health_apply(w, e, 2.0),
        // Generators: holding the component is the whole effect — `run_generators`
        // finds it by query from the next tick on.
        comp.GardenBed, comp.ChickenCoop => {},
        // Shelter: holding it is the whole effect too, but what reads it is the screen -
        // owning a shelter is the end of Act I (`pages.build_ui` routes on it).
        comp.Shelter => {},
        else => @compileError("no grant for " ++ @typeName(GoodT)),
    }
}

/// A public wrapper over `grant` — the same "apply the good's effect once, on the way in from
/// absent" the build path runs, exposed so a **bought** good (ACT1-14 barter) lands its effect
/// through the identical path rather than duplicating the switch. Ownership (`w.add`) is the
/// caller's; this is only the effect.
pub fn grant_public(w: *World, e: Entity, comptime GoodT: type) void {
    grant(w, e, GoodT);
}

/// The exact reverse of `grant` — every pair is symmetric so durability can walk a good
/// back out without special cases.
fn revoke(w: *World, e: Entity, comptime GoodT: type) void {
    switch (GoodT) {
        comp.FishRod => recompute_fishing(w, e),
        comp.FishNet => recompute_fishing(w, e),
        comp.Hatchet => recompute_chopping(w, e),
        comp.HandAxe => recompute_chopping(w, e),
        comp.WireSnares => w.remove(e, comp.ActionCheckTraps),
        comp.AirRifle => w.remove(e, comp.ActionHunt),
        comp.Sandals => remove_sandals(w, e),
        comp.WorkGloves => remove_work_gloves(w, e),
        comp.Bicycle => remove_bicycle(w, e),
        comp.Cookpot => remove_cookpot(w, e),
        comp.RootCellar => remove_root_cellar(w, e),
        comp.Chainsaw => remove_chainsaw(w, e),
        comp.LeafBed => health_remove(w, e, 1.0),
        comp.Pantry => health_remove(w, e, 2.0),
        comp.MedicineChest => health_remove(w, e, 2.0),
        comp.GardenBed, comp.ChickenCoop, comp.Shelter => {},
        else => @compileError("no revoke for " ++ @typeName(GoodT)),
    }
}

// --- build / break -----------------------------------------------------------------

/// Begin building `GoodT`: pay its build price upfront and start the work — the good
/// (and whatever it grants) arrives only when `finish_build` resolves, `requires.hours`
/// later. Refuses silently if already owned, already busy (one body, one act), missing
/// the good's prerequisite verb, short of its standing `unlock` conditions, or unaffordable — same gates as labor (energy strict,
/// vigor 0 is death; materials may be spent to exactly 0). Dying mid-build loses the work.
pub fn begin_build(w: *World, e: Entity, res: *Resources, comptime GoodT: type) void {
    if (w.has(e, comp.Busy)) return; // one body, one act
    if (!prereq_met(w, e, GoodT)) return; // nothing to modify yet
    if (!unlock_met(w, e, GoodT)) return; // standing conditions not met
    const vigor, const stock = ecs.getMany(w, e, .{ comp.Vigor, comp.InventoryMaterial });
    const cost = (GoodT{}).requires;
    if (cost.energy >= vigor.v or cost.materials > stock.v) return;

    vigor.v -= cost.energy;
    stock.v -= cost.materials;
    const total = res_mod.hours_to_secs(cost.hours, res.config.secs_per_day);
    // quality is a labor concept — a build either completes or it doesn't, so lock 1.
    w.add(e, comp.Busy{ .doing = doing_of_good(GoodT), .total = total, .remaining = total, .quality = 1 });
}

/// Completion of a build: own the good, apply what it does, log the receipt. Called by
/// `systems.resolve_busy`; `begin_build`'s gates guarantee the good doesn't exist yet.
pub fn finish_build(w: *World, e: Entity, res: *Resources, comptime GoodT: type) void {
    // A repeat build is stock, not a second effect: increment and say so. `w.add` a
    // second time would not overwrite — `SparseSet.add` doesn't guard duplicates, so it
    // would append a second dense entry and leave the index pointing at one of them.
    if (w.get(e, GoodT)) |held| {
        held.count += 1;
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Another {s}. You have {d}.", .{ good_name(GoodT), held.count }) catch "You made another.";
        res.sim.log.push(.good, msg);
        return;
    }
    w.add(e, GoodT{});
    grant(w, e, GoodT); // the effect lands once, on the way in from absent
    res.sim.log.push(.good, built_msg(GoodT));
}

/// The good a `Busy.Doing` is building, or null for the labor verbs — the inverse of
/// `doing_of_good`, and the reason a cancel can recover a price it was never handed.
/// Comptime, so the caller reaches it through an `inline else` over the tag.
fn good_of_doing(comptime d: comp.Busy.Doing) ?type {
    return switch (d) {
        .build_fish_rod => comp.FishRod,
        .build_hatchet => comp.Hatchet,
        .build_wire_snares => comp.WireSnares,
        .build_air_rifle => comp.AirRifle,
        .build_sandals => comp.Sandals,
        .build_work_gloves => comp.WorkGloves,
        .build_bicycle => comp.Bicycle,
        .build_cookpot => comp.Cookpot,
        .build_root_cellar => comp.RootCellar,
        .build_chainsaw => comp.Chainsaw,
        .build_leaf_bed => comp.LeafBed,
        .build_pantry => comp.Pantry,
        .build_medicine_chest => comp.MedicineChest,
        .build_garden_bed => comp.GardenBed,
        .build_chicken_coop => comp.ChickenCoop,
        .build_shelter => comp.Shelter,
        .forage, .scavenge, .fish, .chop_wood, .check_traps, .hunt => null, // labor, not a build
    };
}

/// Abandon a build in progress: salvage `config.cancel_refund` of its materials and free
/// the body. The energy and every hour already spent are gone — this is an exit from a
/// four-day build with an emptying larder, not an undo.
///
/// Refuses on a labor verb: `Busy` covers both, and half-foraging is not a thing you can
/// take materials back from. Returns whether it cancelled.
pub fn cancel_build(w: *World, e: Entity, res: *Resources) bool {
    const busy = w.get(e, comp.Busy) orelse return false;
    switch (busy.doing) {
        inline else => |d| {
            if (comptime good_of_doing(d)) |G| {
                const refund = (G{}).requires.materials * res.config.cancel_refund;
                const stock = ecs.getMany(w, e, .{comp.InventoryMaterial});
                stock.v += refund;
                w.remove(e, comp.Busy);
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "You gave up on the {s}. Salvaged {d:.0} materials.",
                    .{ good_name(G), refund },
                ) catch "You gave up on the build.";
                res.sim.log.push(.warn, msg);
                return true;
            }
            return false;
        },
    }
}

/// Break a good: its effect leaves with it. Nothing calls this yet (no durability);
/// written now so every grant/revoke pair stays symmetric.
pub fn break_good(w: *World, e: Entity, res: *Resources, comptime GoodT: type) void {
    const held = w.get(e, GoodT) orelse return;
    // Spares go first, and the effect only leaves with the last one — losing a spare
    // pair of sandals must not cost you the discount you are still wearing.
    if (held.count > 1) {
        held.count -= 1;
        return;
    }
    // Remove the component **first**, then revoke — so a family recompute (ACT1-16) sees the
    // post-removal state and restores the correct next-best rank. Every other revoke reads its
    // *target* component (a verb, the larder, Vigor), never the good itself, so the order is
    // safe for them too.
    w.remove(e, GoodT);
    revoke(w, e, GoodT);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Your {s} broke.", .{good_name(GoodT)}) catch "Something of yours broke.";
    res.sim.log.push(.warn, msg);
}

/// The good's display name, lowercase — used in the break line and by the BUILD tiles.
pub fn good_name(comptime GoodT: type) []const u8 {
    return switch (GoodT) {
        comp.FishRod => "fish rod",
        comp.FishNet => "fishing net",
        comp.Hatchet => "hatchet",
        comp.HandAxe => "hand axe",
        comp.WireSnares => "wire snares",
        comp.AirRifle => "air rifle",
        comp.Sandals => "sandals",
        comp.WorkGloves => "work gloves",
        comp.Bicycle => "bicycle",
        comp.Cookpot => "cookpot",
        comp.RootCellar => "root cellar",
        comp.Chainsaw => "chainsaw",
        comp.LeafBed => "leaf bed",
        comp.Pantry => "pantry",
        comp.MedicineChest => "medicine chest",
        comp.Shelter => "shelter",
        comp.GardenBed => "garden bed",
        comp.ChickenCoop => "chicken coop",
        else => @compileError("no name for " ++ @typeName(GoodT)),
    };
}

// Named wrappers for the rod — the shape `action_forage` has over `begin_labor`. Kept
// because the rod is the tutorial's first build and reads better spelled out at call sites.
pub fn build_fish_rod(w: *World, e: Entity, res: *Resources) void {
    begin_build(w, e, res, comp.FishRod);
}
pub fn finish_fish_rod(w: *World, e: Entity, res: *Resources) void {
    finish_build(w, e, res, comp.FishRod);
}
pub fn break_fish_rod(w: *World, e: Entity, res: *Resources) void {
    break_good(w, e, res, comp.FishRod);
}

// --- ActionModifier creation/destruction -------------------------------------------
// Each pair applies/reverses its good's effect on a component that already lives on the
// owning agent entity (per the labor pattern in actions.zig).
//
// Yields are distributions (`dist.Dist`), not flat numbers — a boost scales `.s` (the
// mean/scale) and `.sd` together so the distribution's relative shape is preserved (and
// `.sd == 0`, meaning "auto-derive", stays exactly 0 either way).

pub fn apply_sandals(w: *World, agent: Entity) void {
    const forage = ecs.getMany(w, agent, .{comp.ActionForage});
    forage.requires.energy *= 0.85;
}
pub fn remove_sandals(w: *World, agent: Entity) void {
    const forage = ecs.getMany(w, agent, .{comp.ActionForage});
    forage.requires.energy /= 0.85;
}

pub fn apply_work_gloves(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy *= 0.75;
}
pub fn remove_work_gloves(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy /= 0.75;
}

/// Bicycle: distance gets cheap — both roaming verbs at once (one good may touch several
/// components; the grammar is the apply/remove pair, not one-target-only). Both targets
/// are innate, so no prerequisite is needed.
pub fn apply_bicycle(w: *World, agent: Entity) void {
    const forage, const scav = ecs.getMany(w, agent, .{ comp.ActionForage, comp.ActionScavenge });
    forage.requires.energy *= 0.6;
    scav.requires.energy *= 0.6;
}
pub fn remove_bicycle(w: *World, agent: Entity) void {
    const forage, const scav = ecs.getMany(w, agent, .{ comp.ActionForage, comp.ActionScavenge });
    forage.requires.energy /= 0.6;
    scav.requires.energy /= 0.6;
}

/// Cookpot: consumption-side capital — `quality` scales what every unit of stored food is
/// worth as it's eaten (`systems.metabolize` converts at `2·quality`).
pub fn apply_cookpot(w: *World, agent: Entity) void {
    const food = ecs.getMany(w, agent, .{comp.InventoryFood});
    food.quality += 1;
}
pub fn remove_cookpot(w: *World, agent: Entity) void {
    const food = ecs.getMany(w, agent, .{comp.InventoryFood});
    food.quality -= 1;
}

/// Root cellar: storage capital — halves spoilage, so it's only worth what your surpluses
/// are.
pub fn apply_root_cellar(w: *World, agent: Entity) void {
    const food = ecs.getMany(w, agent, .{comp.InventoryFood});
    food.spoils *= 0.5;
}
pub fn remove_root_cellar(w: *World, agent: Entity) void {
    const food = ecs.getMany(w, agent, .{comp.InventoryFood});
    food.spoils /= 0.5;
}

/// Chainsaw: the first substitution of external energy for muscle. Splitting wood stops
/// pricing your body (energy ×0.3) and starts pricing fuel (+1m per use); yields ×2.5.
pub fn apply_chainsaw(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy *= 0.3;
    chop.requires.materials += 1.0;
    chop.yields.materials.s *= 2.5;
    chop.yields.materials.sd *= 2.5;
}
pub fn remove_chainsaw(w: *World, agent: Entity) void {
    const chop = ecs.getMany(w, agent, .{comp.ActionChopWood});
    chop.requires.energy /= 0.3;
    chop.requires.materials -= 1.0;
    chop.yields.materials.s /= 2.5;
    chop.yields.materials.sd /= 2.5;
}

// --- Tool families and supersession (ACT1-16) ---------------------------------------
// A family's verb stats come from the **highest-rank tool owned**, recomputed **from the
// action's canonical base** each time family membership changes. Recomputing from base (rather
// than multiply-on-equip / divide-on-remove) is what makes supersession correct *and*
// drift-free: equipping the better tool replaces the weaker one's stats instead of stacking with
// it, losing the better one restores the next-best exactly, and any number of build→sell→build
// cycles leaves the base untouched (no accumulated floating-point error). Independent modifiers
// that merely share the target verb (Work gloves, Chainsaw on chopping) are **re-applied on top**
// after the family base is set, so they keep stacking — supersession is family-specific.

/// The **fishing** family's best rank owned: FishNet (2) supersedes FishRod (1); 0 ⇒ none.
fn fishing_rank(w: *World, e: Entity) u8 {
    if (w.has(e, comp.FishNet)) return 2;
    if (w.has(e, comp.FishRod)) return 1;
    return 0;
}

/// Recompute `ActionFish` from the best fishing tool owned. No tool ⇒ the verb leaves; a tool ⇒
/// the verb exists (added exactly once — never a duplicate `SparseSet.add`) with that rank's
/// stats set from `comp.ActionFish{}`'s canonical base.
fn recompute_fishing(w: *World, e: Entity) void {
    const rank = fishing_rank(w, e);
    if (rank == 0) {
        if (w.has(e, comp.ActionFish)) w.remove(e, comp.ActionFish);
        return;
    }
    if (!w.has(e, comp.ActionFish)) w.add(e, comp.ActionFish{}); // single add — the guard prevents a dup
    const fish = ecs.getMany(w, e, .{comp.ActionFish});
    fish.* = comp.ActionFish{}; // reset to the canonical base — the drift-free part
    if (rank >= 2) {
        // The net: less body, more catch. Set relative to the base, so it is exact every time.
        fish.requires.energy = (comp.ActionFish{}).requires.energy * 0.7;
        fish.yields.food.s = (comp.ActionFish{}).yields.food.s * 1.5;
    }
}

/// The **chopping** family's best rank owned: HandAxe (2) supersedes Hatchet (1); 0 ⇒ none.
fn chopping_rank(w: *World, e: Entity) u8 {
    if (w.has(e, comp.HandAxe)) return 2;
    if (w.has(e, comp.Hatchet)) return 1;
    return 0;
}

/// Recompute `ActionChopWood` from the best chopping tool owned, then **re-stack** the
/// independent modifiers that target it (Work gloves, Chainsaw) so a family upgrade never drops a
/// modifier the player still owns. Base-reset makes it idempotent and drift-free.
fn recompute_chopping(w: *World, e: Entity) void {
    const rank = chopping_rank(w, e);
    if (rank == 0) {
        if (w.has(e, comp.ActionChopWood)) w.remove(e, comp.ActionChopWood);
        return;
    }
    if (!w.has(e, comp.ActionChopWood)) w.add(e, comp.ActionChopWood{});
    const chop = ecs.getMany(w, e, .{comp.ActionChopWood});
    chop.* = comp.ActionChopWood{}; // canonical base
    if (rank >= 2) {
        chop.requires.energy = (comp.ActionChopWood{}).requires.energy * 0.7;
        chop.yields.materials.s = (comp.ActionChopWood{}).yields.materials.s * 1.4;
    }
    // Re-stack independent modifiers on top of the (possibly upgraded) base — family-specific
    // supersession: a bicycle-and-sandals-style independent modifier keeps its effect.
    if (w.has(e, comp.WorkGloves)) apply_work_gloves(w, e);
    if (w.has(e, comp.Chainsaw)) apply_chainsaw(w, e);
}

// --- Health goods: capacity capital -------------------------------------------------
// Bed / Pantry / Medicine chest each raise the vigor *ceiling*. Apply also fills what it
// adds (first night in a real bed, you wake refreshed), so `v/max` — the fraction the
// status word, the vitals figure and `yield_factor` all read — never dips on an upgrade.
// All mutations are relative (+=/−=), so a future aging system decrementing `max`
// composes underneath without special cases.
//
// **ACT1-16 — the asymmetry is intentional, and now explicit.** `health_apply` raises `max` *and*
// fills `v` by the same amount; `health_remove` lowers `max` and only *clamps* `v` down to the
// new ceiling. So the pair does **not** round-trip: a bed that you sleep in (filling you) and then
// lose leaves you with the vigor you gained, capped at the lower ceiling — you do not un-rest. This
// is the designed lifecycle (a gained night's rest is real), documented and tested as such rather
// than a bug to be forced symmetric.

fn health_apply(w: *World, agent: Entity, amount: f32) void {
    const vigor = ecs.getMany(w, agent, .{comp.Vigor});
    vigor.max += amount;
    vigor.v = @min(vigor.v + amount, vigor.max);
}
fn health_remove(w: *World, agent: Entity, amount: f32) void {
    const vigor = ecs.getMany(w, agent, .{comp.Vigor});
    vigor.max -= amount;
    if (vigor.v > vigor.max) vigor.v = vigor.max;
}

// --- Generator running system -------------------------------------------------------
// A manual per-type list, the same shape as `actions.actions_bundle`: there's no runtime
// query for "every component type tagged Generator" (that's a fact about types, not
// entities), so the types that tick each frame are named here explicitly. Adding a new
// Generator good means adding it to this list too.
pub const generator_bundle = .{
    comp.GardenBed,
    comp.ChickenCoop,
};

/// Shared body for every Generator — `actions.begin_labor`'s shape, one level up and
/// continuous: if this tick's slice of `upkeep` is affordable, pay it and deposit the
/// same slice of `yields`. Both are authored **per in-game day**, so everything scales by
/// the frame's `dt` in days — the flow reads as a trickle (a discrete daily harvest, which
/// would restore poisson's lumpiness, is a later refinement). Gates match labor's: energy
/// strict (a generator must never drain its keeper to death), materials to exactly 0.
fn run_generator(w: *World, e: Entity, res: *Resources, comptime GenT: type) void {
    const gen, const vigor, const stock, const food = ecs.getMany(w, e, .{ GenT, comp.Vigor, comp.InventoryMaterial, comp.InventoryFood });
    const dt_days = res.time.dt / res.config.secs_per_day;
    const energy = gen.upkeep.energy * dt_days;
    const materials = gen.upkeep.materials * dt_days;
    if (energy >= vigor.v or materials > stock.v) {
        return; // can't pay this tick
    }
    vigor.v -= energy;
    stock.v -= materials;
    stock.v += dist.sample(gen.yields.materials, res.random()) * dt_days;
    food.v += dist.sample(gen.yields.food, res.random()) * dt_days;
}

/// The system: ticks every Generator-category good on every entity that owns one.
/// `inline for` unrolls `generator_bundle` at comptime into one Query per type.
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

/// A Resources with only the groups the build/generator paths touch (`sim`, `time`,
/// `config`) initialized — `platform` stays undefined and untouched.
fn test_res() Resources {
    var res: Resources = undefined;
    res.sim = .{ .prng = std.Random.DefaultPrng.init(7) };
    res.time = .{ .dt = 0 };
    res.config = .{};
    return res;
}

fn spawn_test_agent(w: *World) Entity {
    return w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0.05 },
        comp.InventoryMaterial{ .v = 1 },
    } ++ @import("./actions.zig").actions_bundle);
}

test "build pays upfront and starts the work; finish grants the rod and the verb" {
    var w = World.init();
    var res = test_res();
    const price = (comp.FishRod{}).requires; // from the catalog, so a re-price can't rot this
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = price.materials }, // exactly the price — spendable to 0
    });
    try std.testing.expect(!w.has(e, comp.ActionFish)); // no rod, no verb

    build_fish_rod(&w, e, &res);

    // Paid and busy — the rod doesn't exist until the work completes.
    try std.testing.expect(!w.has(e, comp.FishRod));
    try std.testing.expect(!w.has(e, comp.ActionFish));
    try std.testing.expectEqual(10 - price.energy, w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryMaterial).?.v); // spent to 0
    const b = w.get(e, comp.Busy).?;
    try std.testing.expectEqual(comp.Busy.Doing.build_fish_rod, b.doing);
    try std.testing.expectEqual(res_mod.hours_to_secs(price.hours, res.config.secs_per_day), b.total);

    finish_fish_rod(&w, e, &res);
    try std.testing.expect(w.has(e, comp.FishRod));
    try std.testing.expect(w.has(e, comp.ActionFish)); // the unlock
    try std.testing.expectEqual(@as(usize, 1), res.sim.log.count);
}

test "build_fish_rod refuses when unaffordable or busy" {
    var w = World.init();
    var res = test_res();
    const price = (comp.FishRod{}).requires;
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = price.materials - 1 }, // one material short
    });

    build_fish_rod(&w, e, &res);
    try std.testing.expect(!w.has(e, comp.Busy)); // refused, no work started
    try std.testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // unpaid

    w.get(e, comp.InventoryMaterial).?.v = price.materials + 12;
    build_fish_rod(&w, e, &res); // starts the build
    build_fish_rod(&w, e, &res); // busy — must refuse, not double-pay
    try std.testing.expectEqual(@as(f32, 12), w.get(e, comp.InventoryMaterial).?.v); // paid once

    w.remove(e, comp.Busy);
    finish_fish_rod(&w, e, &res);
    build_fish_rod(&w, e, &res); // owned, but 12 materials short of the price
    try std.testing.expect(!w.has(e, comp.Busy));
    try std.testing.expectEqual(@as(f32, 12), w.get(e, comp.InventoryMaterial).?.v);
}

test "a repeat build is stock: the count rises, the effect does not" {
    var w = World.init();
    var res = test_res();
    const price = (comp.Sandals{}).requires;
    const e = spawn_test_agent(&w);
    w.get(e, comp.InventoryMaterial).?.v = price.materials * 3;
    const base = w.get(e, comp.ActionForage).?.requires.energy;

    begin_build(&w, e, &res, comp.Sandals);
    finish_build(&w, e, &res, comp.Sandals);
    const once = w.get(e, comp.ActionForage).?.requires.energy;
    try std.testing.expectEqual(@as(u32, 1), w.get(e, comp.Sandals).?.count);
    try std.testing.expect(once < base); // the first pair is capital in use

    // Owning it no longer refuses the build — that is what makes a good sellable.
    begin_build(&w, e, &res, comp.Sandals);
    finish_build(&w, e, &res, comp.Sandals);
    try std.testing.expectEqual(@as(u32, 2), w.get(e, comp.Sandals).?.count);
    try std.testing.expectEqual(once, w.get(e, comp.ActionForage).?.requires.energy); // no second discount

    // Kinds, not units: four pairs of sandals are never four goods built.
    try std.testing.expectEqual(@as(u32, 1), goods_owned(&w, e));

    // Losing a spare keeps the discount; losing the last pair takes it back.
    break_good(&w, e, &res, comp.Sandals);
    try std.testing.expectEqual(@as(u32, 1), w.get(e, comp.Sandals).?.count);
    try std.testing.expectEqual(once, w.get(e, comp.ActionForage).?.requires.energy);
    break_good(&w, e, &res, comp.Sandals);
    try std.testing.expect(!w.has(e, comp.Sandals));
    try std.testing.expectApproxEqAbs(base, w.get(e, comp.ActionForage).?.requires.energy, 1e-5);
}

test "break_fish_rod revokes the verb with the tool" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = 8 },
    });
    build_fish_rod(&w, e, &res);
    finish_fish_rod(&w, e, &res);

    break_fish_rod(&w, e, &res);

    try std.testing.expect(!w.has(e, comp.FishRod));
    try std.testing.expect(!w.has(e, comp.ActionFish)); // the verb left with the tool
}

test "the hatchet unlocks splitting wood — the innate hands cannot" {
    var w = World.init();
    var res = test_res();
    const e = spawn_test_agent(&w);
    try std.testing.expect(!w.has(e, comp.ActionChopWood)); // not innate

    w.get(e, comp.InventoryMaterial).?.v = 6;
    begin_build(&w, e, &res, comp.Hatchet);
    finish_build(&w, e, &res, comp.Hatchet);

    try std.testing.expect(w.has(e, comp.ActionChopWood));
    break_good(&w, e, &res, comp.Hatchet);
    try std.testing.expect(!w.has(e, comp.ActionChopWood));
}

test "a modifier whose target verb is missing refuses to build" {
    var w = World.init();
    var res = test_res();
    const e = spawn_test_agent(&w);
    w.get(e, comp.InventoryMaterial).?.v = 100;

    // No hatchet ⟹ no ActionChopWood ⟹ gloves have nothing to improve.
    try std.testing.expect(!prereq_met(&w, e, comp.WorkGloves));
    begin_build(&w, e, &res, comp.WorkGloves);
    try std.testing.expect(!w.has(e, comp.Busy)); // refused, not a panic
    try std.testing.expectEqual(@as(f32, 100), w.get(e, comp.InventoryMaterial).?.v); // unpaid

    // With the hatchet, the same build goes through.
    begin_build(&w, e, &res, comp.Hatchet);
    finish_build(&w, e, &res, comp.Hatchet);
    w.remove(e, comp.Busy);
    try std.testing.expect(prereq_met(&w, e, comp.WorkGloves));
    begin_build(&w, e, &res, comp.WorkGloves);
    try std.testing.expect(w.has(e, comp.Busy));
}

test "modifier pairs are symmetric — apply then remove restores the margin" {
    var w = World.init();
    const e = spawn_test_agent(&w);

    apply_sandals(&w, e);
    apply_bicycle(&w, e);
    const forage = w.get(e, comp.ActionForage).?;
    const scav = w.get(e, comp.ActionScavenge).?;
    // Two goods on one verb stack rather than supersede: crude footwear and a bicycle are
    // both in use at once. A *better tool replacing a weaker one* is the other rule, and
    // it has no subject yet (docs/roadmap.md, Act I).
    try std.testing.expectApproxEqAbs(@as(f32, 1.7 * 0.85 * 0.6), forage.requires.energy, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 * 0.6), scav.requires.energy, 1e-5);

    remove_bicycle(&w, e);
    remove_sandals(&w, e);
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), forage.requires.energy, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), scav.requires.energy, 1e-5);
}

test "chainsaw trades muscle for fuel on the hatchet's verb" {
    var w = World.init();
    var res = test_res();
    const e = spawn_test_agent(&w);
    w.get(e, comp.InventoryMaterial).?.v = 6;
    begin_build(&w, e, &res, comp.Hatchet);
    finish_build(&w, e, &res, comp.Hatchet);

    apply_chainsaw(&w, e);
    const chop = w.get(e, comp.ActionChopWood).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), chop.requires.energy, 1e-5); // 2.5 × 0.3
    try std.testing.expectEqual(@as(f32, 1.0), chop.requires.materials); // fuel per use
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), chop.yields.materials.s, 1e-4); // 5 × 2.5

    remove_chainsaw(&w, e);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), chop.requires.energy, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), chop.requires.materials, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), chop.yields.materials.s, 1e-4);
}

test "health goods raise the ceiling and fill what they add; removal clamps" {
    var w = World.init();
    var res = test_res();
    const e = spawn_test_agent(&w);
    w.get(e, comp.InventoryMaterial).?.v = 10;

    begin_build(&w, e, &res, comp.LeafBed);
    finish_build(&w, e, &res, comp.LeafBed);
    const vigor = w.get(e, comp.Vigor).?;
    try std.testing.expectEqual(@as(f32, 11), vigor.max); // the crude bed buys 1, not 2
    // 10 − 2 energy paid at begin = 8, then +1 filled on completion.
    try std.testing.expectEqual(@as(f32, 9), vigor.v);

    break_good(&w, e, &res, comp.LeafBed);
    try std.testing.expectEqual(@as(f32, 10), vigor.max);
    try std.testing.expectEqual(@as(f32, 9), vigor.v); // still under the ceiling
}

test "cookpot and root cellar work the larder, symmetrically" {
    var w = World.init();
    const e = spawn_test_agent(&w);

    apply_cookpot(&w, e);
    apply_root_cellar(&w, e);
    const food = w.get(e, comp.InventoryFood).?;
    try std.testing.expectEqual(@as(u8, 2), food.quality);
    try std.testing.expectApproxEqAbs(@as(f32, 0.025), food.spoils, 1e-6);

    remove_cookpot(&w, e);
    remove_root_cellar(&w, e);
    try std.testing.expectEqual(@as(u8, 1), food.quality);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), food.spoils, 1e-6);
}

test "a generator pays its upkeep and deposits its flow, per day" {
    var w = World.init();
    var res = test_res();
    res.time = .{ .dt = res.config.secs_per_day }; // one full day per tick
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = 0.1 }, // exactly one day of upkeep
        comp.GardenBed{},
    });

    run_generators(&w, &res);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w.get(e, comp.InventoryMaterial).?.v, 1e-6);
    const fed = w.get(e, comp.InventoryFood).?.v;
    try std.testing.expect(fed > 0); // uniform's floor over a full day is 0.375

    // Broke now — the next day can't pay the upkeep, so nothing moves.
    run_generators(&w, &res);
    try std.testing.expectApproxEqAbs(fed, w.get(e, comp.InventoryFood).?.v, 1e-6);
}

/// An agent stocked to build a shelter: the unlock's three conditions all met, and enough
/// materials for the price. Individual conditions are then knocked out one at a time.
fn spawn_settler(w: *World) Entity {
    return w.spawn(.{
        comp.Vigor{ .v = 16, .max = 20 }, // 16 >= the absolute 15 (ACT1-04), max is irrelevant
        comp.InventoryFood{ .v = 25, .quality = 1, .spoils = 0 }, // >= the finalized 12
        comp.InventoryMaterial{ .v = 100 }, // >= the finalized 60 price
        comp.Sandals{},
        comp.LeafBed{},
        comp.Cookpot{},
        comp.RootCellar{},
        comp.WireSnares{}, // five goods owned >= the finalized 5
    });
}

test "the shelter is offered only once its standing conditions are met" {
    var w = World.init();
    var res = test_res();
    const e = spawn_settler(&w);

    try std.testing.expectEqual(@as(u32, 5), goods_owned(&w, e));
    try std.testing.expect(unlock_met(&w, e, comp.Shelter));

    begin_build(&w, e, &res, comp.Shelter);
    const b = w.get(e, comp.Busy).?;
    try std.testing.expectEqual(comp.Busy.Doing.build_shelter, b.doing);
    try std.testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // 16 - 6 energy
    try std.testing.expectEqual(@as(f32, 40), w.get(e, comp.InventoryMaterial).?.v); // 100 - 60

    // Vigor fell below the absolute 15 mid-build (16→10) — the work is already paid for, so it
    // stands even though the standing condition would now refuse a fresh start.
    try std.testing.expect(!unlock_met(&w, e, comp.Shelter));

    finish_build(&w, e, &res, comp.Shelter);
    try std.testing.expect(w.has(e, comp.Shelter));
    try std.testing.expectEqual(@as(u32, 4), w.get(e, comp.Shelter).?.capacity);
}

test "each standing condition refuses the shelter on its own" {
    var res = test_res();

    // Too tired: below the absolute 15 current Vigor refuses, regardless of the ceiling.
    {
        var w = World.init();
        const e = spawn_settler(&w);
        w.get(e, comp.Vigor).?.v = 7;
        try std.testing.expect(!unlock_met(&w, e, comp.Shelter));
        begin_build(&w, e, &res, comp.Shelter);
        try std.testing.expect(!w.has(e, comp.Busy));
    }
    // ACT1-04 boundary: the requirement is an *absolute* 15, independent of `max`. 14.99 fails
    // and 15 passes whether the ceiling is 15, 20, or 100.
    {
        var w = World.init();
        const e = spawn_settler(&w);
        const v = w.get(e, comp.Vigor).?;
        inline for ([_]f32{ 15, 20, 100 }) |ceiling| {
            v.max = ceiling;
            v.v = 14.99;
            try std.testing.expect(!unlock_met(&w, e, comp.Shelter)); // just under ⇒ fails
            v.v = 15;
            try std.testing.expect(unlock_met(&w, e, comp.Shelter)); // exactly at ⇒ passes
        }
    }
    // Larder too thin (below the finalized 12).
    {
        var w = World.init();
        const e = spawn_settler(&w);
        w.get(e, comp.InventoryFood).?.v = 11;
        try std.testing.expect(!unlock_met(&w, e, comp.Shelter));
        begin_build(&w, e, &res, comp.Shelter);
        try std.testing.expect(!w.has(e, comp.Busy));
    }
    // Nothing built yet - a full larder is not a settled life.
    {
        var w = World.init();
        const e = spawn_settler(&w);
        w.remove(e, comp.Sandals);
        try std.testing.expectEqual(@as(u32, 4), goods_owned(&w, e)); // one short of the finalized 5
        try std.testing.expect(!unlock_met(&w, e, comp.Shelter));
        begin_build(&w, e, &res, comp.Shelter);
        try std.testing.expect(!w.has(e, comp.Busy));
    }
}

test "a good with no unlock field has no standing conditions" {
    var w = World.init();
    const e = spawn_test_agent(&w); // 0 food, nothing built, and it does not matter
    try std.testing.expect(unlock_met(&w, e, comp.FishRod));
    try std.testing.expect(unlock_met(&w, e, comp.ChickenCoop));
}

test "cancel salvages half the materials, frees the body, and grants nothing" {
    var w = World.init();
    var res = test_res();
    const price = (comp.FishRod{}).requires;
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = price.materials },
    });

    build_fish_rod(&w, e, &res);
    try std.testing.expect(w.has(e, comp.Busy));
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryMaterial).?.v); // paid in full

    try std.testing.expect(cancel_build(&w, e, &res));
    try std.testing.expect(!w.has(e, comp.Busy)); // the body is free again
    try std.testing.expect(!w.has(e, comp.FishRod)); // and owns nothing for the trouble
    try std.testing.expect(!w.has(e, comp.ActionFish));
    try std.testing.expectApproxEqAbs(
        price.materials * res.config.cancel_refund,
        w.get(e, comp.InventoryMaterial).?.v,
        1e-5,
    );
    // The energy is gone with the hours — cancelling is an exit, not an undo.
    try std.testing.expectEqual(10 - price.energy, w.get(e, comp.Vigor).?.v);
}

test "cancel refuses on labor, and on an idle body" {
    var w = World.init();
    var res = test_res();
    const e = spawn_test_agent(&w);

    try std.testing.expect(!cancel_build(&w, e, &res)); // nothing in progress

    w.add(e, comp.Busy{ .doing = .forage, .total = 10, .remaining = 4, .quality = 1 });
    try std.testing.expect(w.has(e, comp.Busy));
    const before = w.get(e, comp.InventoryMaterial).?.v;
    try std.testing.expect(!cancel_build(&w, e, &res)); // `Busy` covers labor too
    try std.testing.expect(w.has(e, comp.Busy)); // still foraging
    try std.testing.expectEqual(before, w.get(e, comp.InventoryMaterial).?.v);
}

// ============================ ACT1-16: tool supersession & reversible effects ===========

/// Own a non-buildable rank-2 tool in a test (the passerby's upgrade), applying its family
/// recompute — the same two steps `barter.resolve` runs for a bought good.
fn equip(w: *World, e: Entity, comptime GoodT: type) void {
    if (w.get(e, GoodT)) |held| {
        held.count += 1;
    } else {
        w.add(e, GoodT{});
        grant_public(w, e, GoodT);
    }
}

test "a better tool supersedes the weaker one — stats replace, not stack" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = (comp.FishRod{}).requires.materials },
    });
    // Build the rod (rank 1): ActionFish at its canonical base.
    build_fish_rod(&w, e, &res);
    finish_fish_rod(&w, e, &res);
    const base_energy = (comp.ActionFish{}).requires.energy;
    const base_food = (comp.ActionFish{}).yields.food.s;
    try std.testing.expectApproxEqAbs(base_energy, w.get(e, comp.ActionFish).?.requires.energy, 1e-6);

    // Equip the net (rank 2): the stats REPLACE the rod's — 0.7× energy, 1.5× catch — not
    // 0.7×0.7 or any stack. And there is exactly one ActionFish (no duplicate add).
    equip(&w, e, comp.FishNet);
    const fish = w.get(e, comp.ActionFish).?;
    try std.testing.expectApproxEqAbs(base_energy * 0.7, fish.requires.energy, 1e-6);
    try std.testing.expectApproxEqAbs(base_food * 1.5, fish.yields.food.s, 1e-6);
    try std.testing.expect(w.has(e, comp.FishRod)); // the rod is still physically owned (sellable)
}

test "losing the better tool restores the next-best rank, not the base or nothing" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = (comp.FishRod{}).requires.materials },
    });
    build_fish_rod(&w, e, &res);
    finish_fish_rod(&w, e, &res);
    equip(&w, e, comp.FishNet); // rank 2 stats
    const base_energy = (comp.ActionFish{}).requires.energy;

    // Sell the net: the family recomputes to the rod (rank 1) — the verb stays, at base stats.
    break_good(&w, e, &res, comp.FishNet);
    try std.testing.expect(!w.has(e, comp.FishNet));
    try std.testing.expect(w.has(e, comp.ActionFish)); // still fishing — the rod remains
    try std.testing.expectApproxEqAbs(base_energy, w.get(e, comp.ActionFish).?.requires.energy, 1e-6);

    // Sell the rod too: no fishing tool left ⇒ the verb goes.
    break_good(&w, e, &res, comp.FishRod);
    try std.testing.expect(!w.has(e, comp.ActionFish));
}

test "supersession is family-specific: independent modifiers still stack" {
    var w = World.init();
    var res = test_res();
    const e = spawn_test_agent(&w);
    w.get(e, comp.InventoryMaterial).?.v = 200;
    // Chopping family: hatchet (rank 1) → hand axe (rank 2).
    begin_build(&w, e, &res, comp.Hatchet);
    finish_build(&w, e, &res, comp.Hatchet);
    if (w.has(e, comp.Busy)) w.remove(e, comp.Busy);
    equip(&w, e, comp.HandAxe); // rank 2 base: 2.5 × 0.7 energy, 5.0 × 1.4 yield

    const rank2_energy = (comp.ActionChopWood{}).requires.energy * 0.7;
    const rank2_yield = (comp.ActionChopWood{}).yields.materials.s * 1.4;
    {
        const chop = w.get(e, comp.ActionChopWood).?;
        try std.testing.expectApproxEqAbs(rank2_energy, chop.requires.energy, 1e-5);
        try std.testing.expectApproxEqAbs(rank2_yield, chop.yields.materials.s, 1e-5);
    }

    // Now stack independent modifiers on the SAME verb — they multiply on top of the rank-2 base
    // (family supersession does not swallow an independent modifier). Work gloves ×0.75 energy;
    // chainsaw ×0.3 energy, +1m, ×2.5 yield.
    begin_build(&w, e, &res, comp.WorkGloves);
    finish_build(&w, e, &res, comp.WorkGloves);
    if (w.has(e, comp.Busy)) w.remove(e, comp.Busy);
    equip(&w, e, comp.Chainsaw); // (not buildable-gated here; equip applies its modifier)
    {
        const chop = w.get(e, comp.ActionChopWood).?;
        try std.testing.expectApproxEqAbs(rank2_energy * 0.75 * 0.3, chop.requires.energy, 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), chop.requires.materials, 1e-5); // chainsaw fuel
        try std.testing.expectApproxEqAbs(rank2_yield * 2.5, chop.yields.materials.s, 1e-4);
    }
}

test "repeated build → sell → build never drifts (recompute from base)" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryMaterial{ .v = 0 },
    });
    const base_energy = (comp.ActionFish{}).requires.energy;
    const base_food = (comp.ActionFish{}).yields.food.s;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        w.get(e, comp.InventoryMaterial).?.v = (comp.FishRod{}).requires.materials;
        build_fish_rod(&w, e, &res);
        finish_fish_rod(&w, e, &res);
        equip(&w, e, comp.FishNet); // rank 2
        break_good(&w, e, &res, comp.FishNet); // back to rank 1
        break_good(&w, e, &res, comp.FishRod); // verb gone
        if (w.has(e, comp.Busy)) w.remove(e, comp.Busy); // free the body for the next build
    }
    // Rebuild once more and confirm the stats are *exactly* the base — no accumulated drift.
    w.get(e, comp.InventoryMaterial).?.v = (comp.FishRod{}).requires.materials;
    build_fish_rod(&w, e, &res);
    finish_fish_rod(&w, e, &res);
    const fish = w.get(e, comp.ActionFish).?;
    try std.testing.expectEqual(base_energy, fish.requires.energy); // exact equality, not approx
    try std.testing.expectEqual(base_food, fish.yields.food.s);
}

test "health lifecycle is intentionally non-round-tripping (ACT1-16 explicit)" {
    var w = World.init();
    var res = test_res();
    const e = spawn_test_agent(&w);
    w.get(e, comp.InventoryMaterial).?.v = 10;
    // Start below the ceiling so the fill on apply is observable.
    w.get(e, comp.Vigor).?.v = 8;
    w.get(e, comp.Vigor).?.max = 10;

    begin_build(&w, e, &res, comp.LeafBed); // pays 2 energy: v 8 → 6
    finish_build(&w, e, &res, comp.LeafBed); // +1 max (→11), fills +1 (v 6 → 7)
    const vig = w.get(e, comp.Vigor).?;
    try std.testing.expectEqual(@as(f32, 11), vig.max);
    try std.testing.expectEqual(@as(f32, 7), vig.v);

    // Break it: max drops back to 10, but v is only *clamped* (7 ≤ 10, so it stays) — the gained
    // rest is real and does NOT round-trip back out. This is the designed lifecycle.
    break_good(&w, e, &res, comp.LeafBed);
    try std.testing.expectEqual(@as(f32, 10), vig.max);
    try std.testing.expectEqual(@as(f32, 7), vig.v); // kept — not un-rested

    // When v exceeds the new ceiling, remove clamps it down.
    w.add(e, comp.LeafBed{});
    grant_public(&w, e, comp.LeafBed); // max 11, v filled to min(7+1,11)=8
    vig.v = 11; // fully rested at the raised ceiling
    break_good(&w, e, &res, comp.LeafBed); // max → 10, v clamped 11 → 10
    try std.testing.expectEqual(@as(f32, 10), vig.max);
    try std.testing.expectEqual(@as(f32, 10), vig.v);
}
